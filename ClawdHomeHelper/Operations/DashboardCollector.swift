// ClawdHomeHelper/Operations/DashboardCollector.swift
// 仪表盘数据采集器：双频 Timer 采集系统/用户级统计数据
// 1秒：CPU、内存、网络（per UID）；60秒：磁盘、~/.openclaw 目录大小、skills 文件数

import Foundation
import Darwin
import IOKit

// MARK: - NetworkCollectorProtocol

/// 网络连接采集器协议：ConnectionCollector（sysctl）和 NStatCollector（NetworkStatistics.framework）共用
protocol NetworkCollectorProtocol {
    func collect(users: [(username: String, uid: uid_t)])
        -> (connections: [ConnectionInfo], uidBytes: [uid_t: (rx: UInt64, tx: UInt64)])
}

// MARK: - DashboardCollector

/// 双频采集仪表盘数据，内存缓存最新快照供 XPC 调用直接读取
final class DashboardCollector {

    static let shared = DashboardCollector()

    /// 托管用户列表（由 userRefreshTimer 定期刷新，无需外部注入）
    private(set) var managedUsers: [(username: String, uid: uid_t, isRunning: Bool)] = []

    /// 最新快照（NSLock 保护，线程安全读写）
    private(set) var snapshot: DashboardSnapshot = DashboardCollector.emptySnapshot()

    private let lock = NSLock()

    // 双频 Timer + 用户刷新 Timer
    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var userRefreshTimer: Timer?

    // 网络采集后台任务重入保护（DispatchQueue.global 不自动串行化）
    private var isCollectingNet = false

    // 上一帧 CPU ticks，用于差分计算 CPU 使用率
    private var prevCPUTicks: (idle: UInt64, total: UInt64) = (0, 0)

    /// 上一帧各 UID 的网络字节（用于差分计算速率）
    private var prevNetByUID: [uid_t: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    /// 自 Helper 启动以来各 UID 的累计外网字节（单调递增，Helper 重启时归零）
    private var accumulatedNetBytes: [uid_t: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    /// 上一帧采集时间（用于计算时间间隔）
    private var prevNetTime: Date = Date()
    /// EMA 平滑后的速率（alpha=0.3，兼顾响应与稳定）
    private var smoothedRateIn:  [uid_t: Double] = [:]
    private var smoothedRateOut: [uid_t: Double] = [:]
    /// 上一帧各 UID 的进程 CPU 时间（用于差分计算 CPU%）
    private var prevProcCPU: [uid_t: (timeNs: UInt64, date: Date)] = [:]

    /// 网络连接采集器：使用 sysctl ConnectionCollector（稳定路径）
    /// NStatCollector（NetworkStatistics.framework 私有 API）在 macOS 26.3 上
    /// 因 NWStatisticsManager queryAllCounts: 内部 null pointer 崩溃，暂时禁用。
    private let networkCollector: any NetworkCollectorProtocol = {
        helperLog("[nstat] Using sysctl ConnectionCollector", level: .debug, channel: .diagnostics)
        return ConnectionCollector()
    }()

    private init() {}

    // MARK: - 生命周期

    /// 启动双频采集（主线程调用；Timer 加入 main RunLoop）
    func start() {
        // 立即刷新用户列表，确保快照有虾列表
        managedUsers = DashboardCollector.fetchManagedUsers()
        // 立即将用户列表写入快照（网络采集尚未运行，先用空值占位）
        let initial = managedUsers
        lock.lock()
        snapshot.shrimps = initial.map { emptyShrimpStats(username: $0.username, uid: $0.uid, isRunning: $0.isRunning) }
        snapshot.totalShrimpCount   = initial.count
        snapshot.runningShrimpCount = initial.filter(\.isRunning).count
        lock.unlock()
        // 立即采集一次，确保快照非空
        collectFast()
        collectSlow()

        fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.collectFast()
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.collectSlow()
        }
        // 每 5 秒刷新用户列表（包含 gateway 运行状态）—— 与 XPC 热路径完全解耦
        userRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let users = DashboardCollector.fetchManagedUsers()
            self.managedUsers = users
            // 同步更新快照中的运行状态和计数
            self.lock.lock()
            self.snapshot.totalShrimpCount   = users.count
            self.snapshot.runningShrimpCount = users.filter(\.isRunning).count
            for i in self.snapshot.shrimps.indices {
                if let u = users.first(where: { $0.username == self.snapshot.shrimps[i].username }) {
                    self.snapshot.shrimps[i].isRunning = u.isRunning
                }
            }
            // 若用户列表发生变化（新增/删除），补全或裁剪 shrimps
            let existing = Set(self.snapshot.shrimps.map(\.username))
            let current  = Set(users.map(\.username))
            for u in users where !existing.contains(u.username) {
                self.snapshot.shrimps.append(self.emptyShrimpStats(username: u.username, uid: u.uid, isRunning: u.isRunning))
            }
            self.snapshot.shrimps.removeAll { !current.contains($0.username) }
            self.lock.unlock()
        }
    }

    /// 停止采集
    func stop() {
        fastTimer?.invalidate(); fastTimer = nil
        slowTimer?.invalidate(); slowTimer = nil
        userRefreshTimer?.invalidate(); userRefreshTimer = nil
    }

    // MARK: - 快照读取（线程安全）

    func currentSnapshot() -> DashboardSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// 只采集机器指标（CPU/内存/磁盘），速度快
    /// XPC 调用方在快照为空时可直接调用以获得即时数据
    func collectMachineStatsNow() {
        let cpu = readCPUPercent()
        let (memUsed, memTotal) = readMemoryMB()
        let (diskUsed, diskTotal) = readDiskGB()
        lock.lock()
        snapshot.machine.cpuPercent = cpu
        snapshot.machine.memUsedMB = memUsed
        snapshot.machine.memTotalMB = memTotal
        snapshot.machine.diskUsedGB = diskUsed
        snapshot.machine.diskTotalGB = diskTotal
        lock.unlock()
    }

    // MARK: - 1 秒采集

    private func collectFast() {
        let users = managedUsers
        let now   = Date()

        // ── 机器指标（同步，微秒级系统调用）──────────────────────────────────
        let cpu = readCPUPercent()
        let gpu = readGPUPercent()
        let (memUsed, memTotal) = readMemoryMB()
        let (diskUsed, diskTotal) = readDiskGB()

        // ── 进程指标：内存 + CPU（同步，微秒级，不依赖 nettop）─────────────
        // 使用 proc_listpids + proc_pid_rusage，涵盖所有子进程
        // 始终对所有托管用户采集（包括 gateway 未启动时的初始化、升级等过程）
        var procResults: [String: (rssMB: Double?, cpuPct: Double?)] = [:]
        for u in users {
            let (rss, totalCpuNs) = procStatsForUID(u.uid)
            if rss > 0 || totalCpuNs > 0 || u.isRunning {
                var cpuPct: Double? = nil
                if let prevCPU = prevProcCPU[u.uid] {
                    let dNs  = Double(totalCpuNs &- prevCPU.timeNs)
                    let dSec = now.timeIntervalSince(prevCPU.date)
                    if dSec > 0.1 { cpuPct = min(100, dNs / (dSec * 1e9) * 100) }
                }
                prevProcCPU[u.uid] = (totalCpuNs, now)
                procResults[u.username] = (rss > 0 ? rss : nil, cpuPct)
            } else {
                prevProcCPU.removeValue(forKey: u.uid)
            }
        }

        lock.lock()
        snapshot.machine.cpuPercent  = cpu
        snapshot.machine.gpuPercent  = gpu
        snapshot.machine.memUsedMB   = memUsed
        snapshot.machine.memTotalMB  = memTotal
        snapshot.machine.diskUsedGB  = diskUsed
        snapshot.machine.diskTotalGB = diskTotal
        // isRunning 由 userRefreshTimer（launchctl）负责维护，collectFast 只更新资源指标
        for i in snapshot.shrimps.indices {
            let uname = snapshot.shrimps[i].username
            if let p = procResults[uname] {
                snapshot.shrimps[i].cpuPercent = p.cpuPct
                snapshot.shrimps[i].memRssMB   = p.rssMB
            } else {
                snapshot.shrimps[i].cpuPercent = nil
                snapshot.shrimps[i].memRssMB   = nil
            }
        }
        lock.unlock()

        // ── 网络指标（networkCollector，独立后台线程，不阻塞上面的同步路径）────
        guard !isCollectingNet else { return }
        isCollectingNet = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.isCollectingNet = false } }
            let (netResult, connections, diag) = self.collectNetBytesOnly(users: users)
            self.lock.lock()
            for (username, net) in netResult {
                if let i = self.snapshot.shrimps.firstIndex(where: { $0.username == username }) {
                    self.snapshot.shrimps[i].netBytesIn    = net.bytesIn
                    self.snapshot.shrimps[i].netBytesOut   = net.bytesOut
                    self.snapshot.shrimps[i].netRateInBps  = net.rateIn
                    self.snapshot.shrimps[i].netRateOutBps = net.rateOut
                }
            }
            self.snapshot.connections = connections
            self.snapshot.debugLog = diag
            self.lock.unlock()
        }
    }

    // MARK: - 60 秒采集

    private func collectSlow() {
        let (diskUsed, diskTotal) = readDiskGB()
        let users = managedUsers

        // 采集各用户目录大小 / skills 数量 / 实际 gateway 端口（不加锁期间执行，涉及文件 IO）
        var dirData: [(username: String, memBytes: Int64, openclawBytes: Int64, homeBytes: Int64, skillCount: Int, gatewayPort: Int)] = []
        for u in users {
            let home  = "/Users/\(u.username)"
            let memBytes      = dirSize("\(home)/.openclaw/memory")
            let openclawBytes = dirSize("\(home)/.openclaw")
            let homeBytes     = dirSize(home)
            let skills        = fileCount("\(home)/.openclaw/skills")
            let gport         = DashboardCollector.readGatewayPort(username: u.username,
                                                                   defaultPort: 18000 + Int(u.uid))
            dirData.append((u.username, memBytes, openclawBytes, homeBytes, skills, gport))
        }

        lock.lock()
        snapshot.machine.diskUsedGB  = diskUsed
        snapshot.machine.diskTotalGB = diskTotal
        for i in snapshot.shrimps.indices {
            if let d = dirData.first(where: { $0.username == snapshot.shrimps[i].username }) {
                snapshot.shrimps[i].memoryDirBytes   = d.memBytes
                snapshot.shrimps[i].openclawDirBytes = d.openclawBytes
                snapshot.shrimps[i].homeDirBytes     = d.homeBytes
                snapshot.shrimps[i].skillCount       = d.skillCount
                snapshot.shrimps[i].gatewayPort      = d.gatewayPort
            }
        }
        lock.unlock()
    }

    // MARK: - CPU 使用率

    /// 返回 0–100 的 CPU 占用百分比（差分计算，首帧返回 0）
    private func readCPUPercent() -> Double {
        var cpuCount: natural_t = 0
        var cpuInfoRaw: processor_info_array_t? = nil
        var cpuInfoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfoRaw,
            &cpuInfoCount
        )
        guard kr == KERN_SUCCESS, let cpuInfo = cpuInfoRaw else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo),
                          vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<Int32>.size))
        }

        var idleTicks: UInt64 = 0
        var totalTicks: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user   = UInt64(cpuInfo[base + Int(CPU_STATE_USER)])
            let system = UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let nice   = UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
            let idle   = UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)])
            idleTicks  += idle
            totalTicks += user + system + nice + idle
        }

        let prevIdle  = prevCPUTicks.idle
        let prevTotal = prevCPUTicks.total
        prevCPUTicks = (idleTicks, totalTicks)

        let dTotal = totalTicks - prevTotal
        let dIdle  = idleTicks  - prevIdle
        guard dTotal > 0 else { return 0 }
        return Double(dTotal - dIdle) / Double(dTotal) * 100.0
    }

    // MARK: - GPU 使用率

    /// 通过 IOKit 读取 IOAccelerator 的 Device Utilization %（0–100），不需要 root
    /// 多 GPU 时取第一个（Apple Silicon 只有一个 GPU）
    private func readGPUPercent() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any],
                  let util = perf["Device Utilization %"] as? Double
            else { continue }
            return util
        }
        return nil
    }

    // MARK: - 内存用量

    /// 返回 (usedMB, totalMB)
    private func readMemoryMB() -> (Double, Double) {
        // 物理内存总量
        var totalBytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)
        let totalMB = Double(totalBytes) / (1024 * 1024)

        // 虚拟内存统计（HOST_VM_INFO64）
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, totalMB) }

        let pageSize = UInt64(vm_kernel_page_size)
        let usedPages = vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count
        let usedMB = Double(UInt64(usedPages) * pageSize) / (1024 * 1024)
        return (usedMB, totalMB)
    }

    // MARK: - 磁盘空间

    /// 返回 (usedGB, totalGB)，采样根分区
    private func readDiskGB() -> (Double, Double) {
        var stat = statvfs()
        guard statvfs("/", &stat) == 0 else { return (0, 0) }
        let blockSize = UInt64(stat.f_frsize)
        let totalGB = Double(UInt64(stat.f_blocks) * blockSize) / (1024 * 1024 * 1024)
        let freeGB  = Double(UInt64(stat.f_bfree)  * blockSize) / (1024 * 1024 * 1024)
        return (totalGB - freeGB, totalGB)
    }

    // MARK: - 网络统计（NetworkCollectorProtocol，仅字节，在后台线程调用）

    /// 仅采集网络收发字节和速率，CPU/内存已在 collectFast 同步路径处理
    /// 返回 (per-user net data, 活跃 TCP 连接列表, 诊断日志)
    private func collectNetBytesOnly(
        users: [(username: String, uid: uid_t, isRunning: Bool)]
    ) -> (data: [String: (bytesIn: UInt64, bytesOut: UInt64, rateIn: Double, rateOut: Double)],
          connections: [ConnectionInfo],
          diag: String) {
        let now = Date()
        let interval = max(0.1, now.timeIntervalSince(prevNetTime))
        prevNetTime = now

        // 使用 networkCollector（NStatCollector 或 ConnectionCollector fallback）
        // 对所有用户（含初始化/npm install 阶段）均采集，不过滤 isRunning
        let allUsers = users.map { (username: $0.username, uid: $0.uid) }
        let (connections, rawUidBytes) = networkCollector.collect(users: allUsers)
        var diag = "[conn] \(connections.count) active TCP conns across \(allUsers.count) users\n"

        var uidBytes: [uid_t: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for (uid, bytes) in rawUidBytes {
            uidBytes[uid] = (bytesIn: bytes.rx, bytesOut: bytes.tx)
        }

        var result: [String: (bytesIn: UInt64, bytesOut: UInt64, rateIn: Double, rateOut: Double)] = [:]
        for u in users {
            let cur  = uidBytes[u.uid] ?? (0, 0)
            let prev = prevNetByUID[u.uid] ?? cur
            let dIn  = cur.bytesIn  >= prev.bytesIn  ? cur.bytesIn  - prev.bytesIn  : 0
            let dOut = cur.bytesOut >= prev.bytesOut ? cur.bytesOut - prev.bytesOut : 0
            prevNetByUID[u.uid] = cur
            let acc = accumulatedNetBytes[u.uid] ?? (0, 0)
            let newAcc = (bytesIn: acc.bytesIn + dIn, bytesOut: acc.bytesOut + dOut)
            accumulatedNetBytes[u.uid] = newAcc
            let rawRateIn  = Double(dIn)  / interval
            let rawRateOut = Double(dOut) / interval
            // EMA 平滑（alpha=0.3）：消除 1 秒采样的尖刺，保持响应性
            let alpha = 0.3
            let emaIn  = smoothedRateIn[u.uid].map  { $0 * (1 - alpha) + rawRateIn  * alpha } ?? rawRateIn
            let emaOut = smoothedRateOut[u.uid].map { $0 * (1 - alpha) + rawRateOut * alpha } ?? rawRateOut
            smoothedRateIn[u.uid]  = emaIn
            smoothedRateOut[u.uid] = emaOut
            result[u.username] = (newAcc.bytesIn, newAcc.bytesOut, emaIn, emaOut)
            diag += "[rate] @\(u.username) uid=\(u.uid) d=(\(dIn),\(dOut)) raw=(\(String(format:"%.0f",rawRateIn)),\(String(format:"%.0f",rawRateOut)))/s ema=(\(String(format:"%.0f",emaIn)),\(String(format:"%.0f",emaOut)))/s interval=\(String(format:"%.1f",interval))s\n"
        }
        return (result, connections, diag)
    }

    /// 汇总指定 UID 下所有进程的物理内存（phys_footprint，与活动监视器一致）和 CPU 时间（纳秒）
    /// 使用 proc_listpids(PROC_UID_ONLY) 枚举，覆盖所有子进程（如 node fork）
    private func procStatsForUID(_ uid: uid_t) -> (rssMB: Double, cpuNs: UInt64) {
        let capacity = 2048
        var pids = [Int32](repeating: 0, count: capacity)
        let byteCount = proc_listpids(
            UInt32(PROC_UID_ONLY), uid,
            &pids, Int32(capacity * MemoryLayout<Int32>.size)
        )
        guard byteCount > 0 else { return (0, 0) }
        let pidCount = Int(byteCount) / MemoryLayout<Int32>.size
        var totalFootprint: UInt64 = 0
        var totalCpuNs: UInt64 = 0
        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            // phys_footprint 与活动监视器"内存"列一致（ri_phys_footprint 在公开 SDK 可用）
            // 注意：内核把 buffer 参数当 void* 用（直接往其指向地址写数据），
            // 因此必须传 rusageInfo 本身的地址，而非指向它的指针变量的地址。
            var rusageInfo = rusage_info_v4()
            withUnsafeMutablePointer(to: &rusageInfo) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                    _ = proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
                }
            }
            totalFootprint += rusageInfo.ri_phys_footprint
            // CPU 时间取自 proc_taskinfo
            var taskInfo = proc_taskinfo()
            let sz = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, sz) == sz {
                totalCpuNs += taskInfo.pti_total_user + taskInfo.pti_total_system
            }
        }
        return (Double(totalFootprint) / (1024 * 1024), totalCpuNs)
    }

    // MARK: - 目录工具

    /// 递归计算目录大小（字节），路径不存在返回 0
    private func dirSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// 统计目录下的文件数量（非递归，路径不存在返回 0）
    private func fileCount(_ path: String) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return 0
        }
        return items.count
    }

    // MARK: - 工具

    /// 扫描本机标准用户并查询各自的 gateway 运行状态
    /// 排除管理员账户、系统保留账户和 _ 开头服务账户
    /// 每 5 秒由 userRefreshTimer 调用，与 XPC 热路径完全解耦
    static func fetchManagedUsers() -> [(username: String, uid: uid_t, isRunning: Bool)] {
        // 收集 admin 组成员名单
        var adminNames = Set<String>()
        if let grp = getgrnam("admin") {
            var i = 0
            while let member = grp.pointee.gr_mem?[i] {
                adminNames.insert(String(cString: member))
                i += 1
            }
        }

        let usersDir = "/Users"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: usersDir) else {
            return []
        }
        return contents.compactMap { name -> (String, uid_t, Bool)? in
            guard ManagedUserFilter.shouldConsiderUsersDirectoryEntry(name) else { return nil }
            guard let pw = getpwnam(name) else { return nil }
            let uid = pw.pointee.pw_uid
            let signedUID = Int32(bitPattern: uid)
            guard ManagedUserFilter.isEligibleManagedUser(
                username: name,
                uid: Int(signedUID),
                adminNames: adminNames
            ) else { return nil }
            // 仪表盘周期性刷新使用轻量状态查询，避免触发 ps/lsof 回溯造成线程堆积。
            let (running, _) = GatewayManager.status(
                username: name,
                uid: Int(uid),
                includeProcessFallback: false
            )
            return (name, uid, running)
        }
    }

    private static func emptySnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            machine: MachineStats(
                cpuPercent: 0, gpuPercent: nil, memUsedMB: 0, memTotalMB: 0,
                diskUsedGB: 0, diskTotalGB: 0, cpuTempCelsius: nil),
            shrimps: [],
            totalShrimpCount: 0,
            runningShrimpCount: 0
        )
    }

    private func emptyShrimpStats(username: String, uid: uid_t, isRunning: Bool = false) -> ShrimpNetStats {
        ShrimpNetStats(
            username: username,
            isRunning: isRunning as Bool?,
            cpuPercent: nil, memRssMB: nil,
            netBytesIn: 0, netBytesOut: 0,
            netRateInBps: 0, netRateOutBps: 0,
            memoryDirBytes: 0, openclawDirBytes: 0, homeDirBytes: 0,
            skillCount: 0,
            gatewayPort: 18000 + Int(uid)
        )
    }

    /// 直接读取 openclaw.json 获取 gateway.port（不启动子进程）
    private static func readGatewayPort(username: String, defaultPort: Int) -> Int {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any]
        else { return defaultPort }
        if let p = gateway["port"] as? Int { return p }
        if let s = gateway["port"] as? String, let p = Int(s) { return p }
        return defaultPort
    }
}
