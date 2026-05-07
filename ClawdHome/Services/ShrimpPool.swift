// ClawdHome/Services/ShrimpPool.swift
// 全局虾状态数据层：统一管理用户列表、Gateway 状态、资源占用
// 所有视图从此处读取，无需各自轮询

import Foundation
import Observation

@Observable @MainActor
final class ShrimpPool {

    // MARK: - 公开状态

    /// 托管用户列表（含管理员与标准用户）
    private(set) var users: [ManagedUser] = []
    /// 最新 Dashboard 快照（含机器指标、网络流量等）
    private(set) var snapshot: DashboardSnapshot? = nil
    /// 快照更新计数器，每次 refreshSnapshot 后递增（供 DashboardView 的 onChange 使用）
    private(set) var snapshotVersion: Int = 0
    /// 用户加载错误
    private(set) var loadError: String? = nil
    /// 虾列表首次加载是否已结束（成功或失败）
    private(set) var didFinishInitialUserLoad: Bool = false
    /// 机器指标历史（最多保留 300 秒）— 跨视图切换持久化
    private(set) var machineHistory: [MachineStats] = []
    /// 网络速率历史（最多保留 300 秒）— 跨视图切换持久化
    private(set) var netRateHistory: [(inBps: Double, outBps: Double)] = []
    /// 新创建用户的一次性“强制进入初始化向导”标记（按用户名小写保存）
    private var forceOnboardingUsernames: Set<String> = []

    private static let kHistoryMax = 300

    // MARK: - 依赖

    private let helperClient: HelperClient
    private let descriptionStore: ClawDescriptionStore
    private let freezeStateStore: ClawFreezeStateStore

    // MARK: - 内部轮询任务

    private var fastPollTask: Task<Void, Never>? = nil
    private var statusPollTask: Task<Void, Never>? = nil
    /// 仅在仪表盘可见时发布快照变更；不可见时继续采集但缓存历史，避免 UI 持续重绘
    private var dashboardVisible: Bool = true
    /// 其他页面（如 UserDetail）需要实时快照时，通过引用计数申请发布。
    private var liveSnapshotConsumers: Int = 0
    private var hiddenMachineBuffer: [MachineStats] = []
    private var hiddenNetBuffer: [(inBps: Double, outBps: Double)] = []
    private var hiddenLatestSnapshot: DashboardSnapshot? = nil

    // MARK: - 初始化

    init(helperClient: HelperClient) {
        self.helperClient = helperClient
        self.descriptionStore = ClawDescriptionStore()
        self.freezeStateStore = ClawFreezeStateStore()
    }

    // MARK: - 生命周期

    /// 启动数据采集（在 App 的 task 中调用）
    func start() {
        loadUsers()
        startFastPoll()
        startStatusPoll()
    }

    func stop() {
        fastPollTask?.cancel(); fastPollTask = nil
        statusPollTask?.cancel(); statusPollTask = nil
    }

    // MARK: - 用户管理

    func loadUsers() {
        Task {
            do {
                let records = try await UserDirectoryService.listStandardUsersAsync()
                let newUsers = records.map { record -> ManagedUser in
                    if let existing = users.first(where: { $0.username == record.username }) {
                        existing.macUID = record.uid
                        existing.profileDescription = descriptionStore.description(for: record.username)
                        if let frozen = freezeStateStore.frozenState(for: record.username) {
                            existing.setFrozen(
                                true,
                                mode: frozen.mode,
                                pausedPIDs: frozen.pausedPIDs,
                                previousAutostartEnabled: frozen.previousAutostartEnabled
                            )
                        } else {
                            existing.setFrozen(false)
                        }
                        return existing   // 复用已有对象，保留 @Observable 监听
                    }
                    let user = ManagedUser(
                        username: record.username,
                        fullName: record.fullName,
                        isAdmin: record.isAdmin,
                        clawType: .macosUser,
                        identifier: "@\(record.username)"
                    )
                    user.macUID = record.uid
                    user.profileDescription = descriptionStore.description(for: record.username)
                    if let frozen = freezeStateStore.frozenState(for: record.username) {
                        user.setFrozen(
                            true,
                            mode: frozen.mode,
                            pausedPIDs: frozen.pausedPIDs,
                            previousAutostartEnabled: frozen.previousAutostartEnabled
                        )
                    }
                    return user
                }
                users = newUsers
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            didFinishInitialUserLoad = true
        }
    }

    func removeUser(username: String) {
        users.removeAll { $0.username == username }
        freezeStateStore.setFrozenState(nil, for: username)
    }

    func setDescription(_ text: String, for username: String) {
        descriptionStore.setDescription(text, for: username)
        guard let user = users.first(where: { $0.username == username }) else { return }
        user.profileDescription = descriptionStore.description(for: username)
    }

    func setFrozen(
        _ frozen: Bool,
        mode: FreezeMode = .normal,
        pausedPIDs: [Int32] = [],
        previousAutostartEnabled: Bool? = nil,
        for username: String
    ) {
        if frozen {
            freezeStateStore.setFrozenState(
                ClawFreezeStateRecord(
                    mode: mode,
                    pausedPIDs: pausedPIDs,
                    updatedAt: Date().timeIntervalSince1970,
                    previousAutostartEnabled: previousAutostartEnabled
                ),
                for: username
            )
        } else {
            freezeStateStore.setFrozenState(nil, for: username)
        }

        guard let user = users.first(where: { $0.username == username }) else { return }
        user.setFrozen(
            frozen,
            mode: mode,
            pausedPIDs: pausedPIDs,
            previousAutostartEnabled: previousAutostartEnabled
        )
    }

    func markNeedsOnboarding(username: String) {
        forceOnboardingUsernames.insert(username.lowercased())
    }

    func consumeNeedsOnboarding(username: String) -> Bool {
        let key = username.lowercased()
        guard forceOnboardingUsernames.contains(key) else { return false }
        forceOnboardingUsernames.remove(key)
        return true
    }

    /// 控制仪表盘可见状态：
    /// - 可见：立即发布最新缓存快照，并补齐隐藏期间历史
    /// - 不可见：停止发布，仅后台缓存
    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        dashboardVisible = visible

        guard shouldPublishSnapshots, let latest = hiddenLatestSnapshot else { return }
        // hiddenLatest 会在 applySnapshot 时补一帧，这里先去掉重复尾点
        if !hiddenMachineBuffer.isEmpty { _ = hiddenMachineBuffer.removeLast() }
        if !hiddenNetBuffer.isEmpty { _ = hiddenNetBuffer.removeLast() }
        flushHiddenHistory()
        applySnapshot(latest)
        hiddenLatestSnapshot = nil
    }

    /// 详情页等非 Dashboard 页面可申请实时快照发布，避免“看起来不刷新”。
    func addLiveSnapshotConsumer() {
        liveSnapshotConsumers += 1
        if shouldPublishSnapshots, let latest = hiddenLatestSnapshot {
            if !hiddenMachineBuffer.isEmpty { _ = hiddenMachineBuffer.removeLast() }
            if !hiddenNetBuffer.isEmpty { _ = hiddenNetBuffer.removeLast() }
            flushHiddenHistory()
            applySnapshot(latest)
            hiddenLatestSnapshot = nil
        }
    }

    func removeLiveSnapshotConsumer() {
        liveSnapshotConsumers = max(0, liveSnapshotConsumers - 1)
    }

    // MARK: - 快速轮询（1 秒）：资源占用 + 机器指标

    private func startFastPoll() {
        fastPollTask?.cancel()
        fastPollTask = Task {
            while !Task.isCancelled {
                await refreshSnapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshSnapshot() async {
        guard helperClient.isConnected else { return }
        guard let s = await helperClient.getDashboardSnapshot() else { return }

        if shouldPublishSnapshots {
            flushHiddenHistory()
            applySnapshot(s)
            hiddenLatestSnapshot = nil
        } else {
            hiddenLatestSnapshot = s
            bufferHiddenHistory(machine: s.machine, shrimps: s.shrimps)
        }
    }

    private var shouldPublishSnapshots: Bool {
        dashboardVisible || liveSnapshotConsumers > 0
    }

    private func applySnapshot(_ s: DashboardSnapshot) {
        snapshot = s
        snapshotVersion &+= 1
        updateMachineHistory(s.machine)
        updateNetHistory(s.shrimps)
        // 将每用户资源数据合并进 ManagedUser（其他视图直接读 user 资源字段）
        for shrimp in s.shrimps {
            guard let user = users.first(where: { $0.username == shrimp.username }) else { continue }
            user.cpuPercent = shrimp.cpuPercent
            user.memRssMB   = shrimp.memRssMB
            user.openclawDirBytes = max(0, shrimp.openclawDirBytes)
        }
    }

    private func bufferHiddenHistory(machine: MachineStats, shrimps: [ShrimpNetStats]) {
        hiddenMachineBuffer.append(machine)
        if hiddenMachineBuffer.count > Self.kHistoryMax {
            hiddenMachineBuffer.removeFirst(hiddenMachineBuffer.count - Self.kHistoryMax)
        }

        let totalIn  = shrimps.reduce(0.0) { $0 + $1.netRateInBps }
        let totalOut = shrimps.reduce(0.0) { $0 + $1.netRateOutBps }
        hiddenNetBuffer.append((totalIn, totalOut))
        if hiddenNetBuffer.count > Self.kHistoryMax {
            hiddenNetBuffer.removeFirst(hiddenNetBuffer.count - Self.kHistoryMax)
        }
    }

    private func flushHiddenHistory() {
        if !hiddenMachineBuffer.isEmpty {
            machineHistory.append(contentsOf: hiddenMachineBuffer)
            if machineHistory.count > Self.kHistoryMax {
                machineHistory.removeFirst(machineHistory.count - Self.kHistoryMax)
            }
            hiddenMachineBuffer.removeAll(keepingCapacity: false)
        }

        if !hiddenNetBuffer.isEmpty {
            netRateHistory.append(contentsOf: hiddenNetBuffer)
            if netRateHistory.count > Self.kHistoryMax {
                netRateHistory.removeFirst(netRateHistory.count - Self.kHistoryMax)
            }
            hiddenNetBuffer.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - 历史记录维护

    private func updateMachineHistory(_ machine: MachineStats) {
        if machineHistory.isEmpty {
            machineHistory = Array(repeating: machine, count: 5)
        } else {
            machineHistory.append(machine)
            if machineHistory.count > Self.kHistoryMax {
                machineHistory.removeFirst(machineHistory.count - Self.kHistoryMax)
            }
        }
    }

    private func updateNetHistory(_ shrimps: [ShrimpNetStats]) {
        let totalIn  = shrimps.reduce(0.0) { $0 + $1.netRateInBps }
        let totalOut = shrimps.reduce(0.0) { $0 + $1.netRateOutBps }
        if netRateHistory.isEmpty {
            netRateHistory = Array(repeating: (totalIn, totalOut), count: 5)
        } else {
            netRateHistory.append((totalIn, totalOut))
            if netRateHistory.count > Self.kHistoryMax {
                netRateHistory.removeFirst(netRateHistory.count - Self.kHistoryMax)
            }
        }
    }

    // MARK: - 状态轮询（4 秒）：Gateway 运行状态、版本

    private func startStatusPoll() {
        statusPollTask?.cancel()
        statusPollTask = Task {
            // 等待 Helper 连接就绪（最多 5 秒）
            for _ in 0..<10 {
                if helperClient.isConnected { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            while !Task.isCancelled {
                await refreshStatuses()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func refreshStatuses() async {
        guard helperClient.isConnected else { return }
        let targets = users
        await withTaskGroup(of: Void.self) { group in
            for user in targets {
                group.addTask {
                    if let (running, pid) = try? await self.helperClient.getGatewayStatus(username: user.username) {
                        if user.isFrozen {
                            user.freezeWarning = await self.evaluateFreezeWarning(user: user, gatewayRunning: running)
                            user.isRunning = false
                            user.pid = nil
                            user.startedAt = nil
                        } else {
                            user.freezeWarning = nil
                            user.isRunning = running
                            user.pid       = running && pid > 0 ? pid : nil
                            user.startedAt = (running && pid > 0) ? GatewayHub.processStartTime(pid: pid) : nil
                        }
                    }
                    user.openclawVersion = await self.helperClient.getOpenclawVersion(username: user.username)
                    user.versionChecked = true
                }
            }
        }
    }

    private func evaluateFreezeWarning(user: ManagedUser, gatewayRunning: Bool) async -> String? {
        guard user.isFrozen, let mode = user.freezeMode else { return nil }

        let processes = await helperClient.getProcessList(username: user.username)
        let openclawProcesses = processes.filter(ProcessEmergencyFreezeResolver.isOpenclawRelated)

        switch mode {
        case .pause:
            if let resumed = openclawProcesses.first(where: { !$0.state.uppercased().hasPrefix("T") }) {
                return String(format: L10n.k("services.shrimp_pool.paused_process_resumed_pid", fallback: "检测到暂停进程恢复运行（PID %d）"), resumed.pid)
            }
            return nil
        case .normal, .flash:
            if gatewayRunning {
                return L10n.k("services.shrimp_pool.gateway_start", fallback: "检测到 Gateway 异常启动")
            }
            if let restarted = openclawProcesses.first {
                return String(format: L10n.k("services.shrimp_pool.openclaw_abnormal_start_pid", fallback: "检测到 openclaw 相关进程异常启动（PID %d）"), restarted.pid)
            }
            return nil
        }
    }
}
