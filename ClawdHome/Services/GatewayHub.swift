// ClawdHome/Services/GatewayHub.swift
// 管理所有用户 GatewayClient 实例的 @Observable 中心
// 通过 @Environment 注入到视图层

import Darwin
import Foundation
import Observation

/// 全局 Gateway 连接管理器
/// - 每个标准用户对应一个 GatewayClient（按 username 键控）
/// - token 从 getGatewayURL() 返回的 URL fragment 中解析（#token=xxx）
/// - 仅在 gateway 运行后才能连接；gateway 停止时 isConnected 变为 false
/// - @MainActor 保证 clients/connectedUsernames 的所有访问串行在主线程，防止并发 data race
@Observable
@MainActor
final class GatewayHub {

    /// 已建立连接的用户名集合（UI 可观察）
    private(set) var connectedUsernames: Set<String> = []

    private var clients: [String: GatewayClient] = [:]
    private var cronStores: [String: GatewayCronStore] = [:]
    private var skillsStores: [String: GatewaySkillsStore] = [:]
    private var channelStores: [String: GatewayChannelStore] = [:]

    /// Gateway 就绪状态（HTTP 探活维护）
    private(set) var readinessMap: [String: GatewayReadiness] = [:]

    /// healthz 开始无响应的时间（用于 zombie 60s 超时判定）；healthz 恢复时清除
    private var healthzDeadSince: [String: Date] = [:]
    /// 每个用户当前进行中的 probe Task（用于取消旧 Task，防止堆积）
    private var probeTasks: [String: Task<Void, Never>] = [:]
    /// 每个用户最近一次发起探活的时间（用于节流）
    private var lastProbeAt: [String: Date] = [:]
    private let minProbeInterval: TimeInterval = 3

    // MARK: - 连接生命周期

    /// 为指定用户准备并建立 gateway 连接
    /// - Parameters:
    ///   - username: macOS 短账户名
    ///   - gatewayURL: getGatewayURL() 返回的完整 URL（包含 #token=xxx fragment）
    func connect(username: String, gatewayURL: String) async {
        guard let (port, token) = Self.parse(gatewayURL: gatewayURL) else { return }
        // 若已有连接且 token 未变化，复用
        if let existing = clients[username] {
            let isAlreadyConnected = await existing.connected
            if isAlreadyConnected { return }
            // token 可能已轮换，更新后重连
            await existing.updateToken(token)
        } else {
            clients[username] = GatewayClient(port: port, token: token)
        }
        do {
            try await clients[username]!.connect()
            connectedUsernames.insert(username)
            let connectedClient = clients[username]!
            let cron = cronStore(for: username)
            let skills = skillsStore(for: username)
            let channels = channelStore(for: username)
            Task {
                await cron.start(client: connectedClient, shrimpName: username)
                await skills.start(client: connectedClient, shrimpName: username)
                await channels.start(client: connectedClient, shrimpName: username)
            }
        } catch {
            appLog("GatewayHub connect(\(username)) failed: \(error.localizedDescription)", level: .error)
            connectedUsernames.remove(username)
        }
    }

    /// 断开并移除指定用户的连接
    func disconnect(username: String) async {
        if let client = clients[username] {
            await client.disconnect()
        }
        clients.removeValue(forKey: username)
        connectedUsernames.remove(username)
        cronStores[username]?.stop()
        skillsStores[username]?.stop()
        channelStores[username]?.stop()
    }

    /// 断开所有连接（应用退出时调用）
    func disconnectAll() async {
        for (username, client) in clients {
            await client.disconnect()
            connectedUsernames.remove(username)
            cronStores[username]?.stop()
            skillsStores[username]?.stop()
            channelStores[username]?.stop()
        }
        clients.removeAll()
    }

    // MARK: - Gateway Feature Stores

    func cronStore(for username: String) -> GatewayCronStore {
        if let existing = cronStores[username] { return existing }
        let store = GatewayCronStore()
        cronStores[username] = store
        return store
    }

    func skillsStore(for username: String) -> GatewaySkillsStore {
        if let existing = skillsStores[username] { return existing }
        let store = GatewaySkillsStore()
        skillsStores[username] = store
        return store
    }

    func channelStore(for username: String) -> GatewayChannelStore {
        if let existing = channelStores[username] { return existing }
        let store = GatewayChannelStore()
        channelStores[username] = store
        return store
    }

    // MARK: - View 层触发 Store 启动

    /// View 出现或连接状态变化时调用，确保 CronStore 已与 client 关联
    func ensureCronStarted(for username: String) async {
        guard let client = clients[username] else { return }
        let connected = await client.connected
        guard connected else { return }
        await cronStore(for: username).startIfNeeded(client: client, shrimpName: username)
    }

    /// View 出现或连接状态变化时调用，确保 SkillsStore 已与 client 关联
    func ensureSkillsStarted(for username: String) async {
        guard let client = clients[username] else { return }
        let connected = await client.connected
        guard connected else { return }
        await skillsStore(for: username).startIfNeeded(client: client, shrimpName: username)
    }

    /// View 出现或连接状态变化时调用，确保 ChannelStore 已与 client 关联
    func ensureChannelsStarted(for username: String) async {
        guard let client = clients[username] else { return }
        let connected = await client.connected
        guard connected else { return }
        await channelStore(for: username).startIfNeeded(client: client, shrimpName: username)
    }

    // MARK: - 配置读写

    /// 读取用户 openclaw 配置项（dot-path）
    /// 成功返回字符串值，失败或不存在返回 nil
    func configGet(username: String, path: String) async -> String? {
        guard let client = clients[username] else { return nil }
        let value = try? await client.configGet(path: path)
        // 处理常见类型：String / Number / Bool
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// 读取用户 openclaw 数组配置项（dot-path）
    /// 成功返回字符串数组，失败或不存在返回 nil
    func configGetArray(username: String, path: String) async -> [String]? {
        guard let client = clients[username] else { return nil }
        let value = try? await client.configGet(path: path)
        if let arr = value as? [Any] {
            return arr.compactMap { item in
                if let s = item as? String { return s }
                if let n = item as? NSNumber { return n.stringValue }
                return nil
            }
        }
        // 单值也当作单元素数组
        if let s = value as? String, !s.isEmpty { return [s] }
        return nil
    }

    /// 写入用户 openclaw 配置项（dot-path → JSON Merge Patch）
    func configSet(username: String, path: String, value: Any) async throws {
        guard let client = clients[username] else { throw GatewayClientError.notConnected }
        // 将 dot-path 构建为嵌套字典，通过 config.patch 写入
        let (config, baseHash) = try await client.configGetFull()
        _ = config // 仅需 baseHash
        let patch = Self.buildNestedDict(path: path, value: value)
        try await client.configPatch(patch: patch, baseHash: baseHash)
    }

    /// 批量写入多个配置项（一次 config.patch 调用）
    func configSetBatch(username: String, entries: [(path: String, value: Any)]) async throws {
        guard let client = clients[username] else { throw GatewayClientError.notConnected }
        let (_, baseHash) = try await client.configGetFull()
        var merged: [String: Any] = [:]
        for entry in entries {
            let nested = Self.buildNestedDict(path: entry.path, value: entry.value)
            merged = Self.deepMerge(merged, nested)
        }
        try await client.configPatch(patch: merged, baseHash: baseHash)
    }

    /// 将 dot-path + value 构建为嵌套字典
    /// 例: "channels.feishu.streaming", true → {"channels": {"feishu": {"streaming": true}}}
    private static func buildNestedDict(path: String, value: Any) -> [String: Any] {
        let parts = path.split(separator: ".").map(String.init)
        guard let last = parts.last else { return [:] }
        var current: [String: Any] = [last: value]
        for key in parts.dropLast().reversed() {
            current = [key: current]
        }
        return current
    }

    /// 深度合并两个字典
    private static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let baseDict = result[key] as? [String: Any],
               let overlayDict = value as? [String: Any] {
                result[key] = deepMerge(baseDict, overlayDict)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// 获取指定用户 gateway 可用模型列表，按 provider 分组
    /// - Returns: 分组列表；gateway 未连接或返回空时返回 nil
    func modelsList(username: String) async -> [ModelGroup]? {
        guard let client = clients[username] else { return nil }
        do {
            let raw = try await client.modelsList()
            guard !raw.isEmpty else { return nil }

            var groupMap: [String: [ModelEntry]] = [:]
            var order: [String] = []
            for entry in raw {
                guard let id = entry["id"] as? String,
                      let provider = entry["provider"] as? String else { continue }
                let name = entry["name"] as? String ?? id
                // gateway 返回的 id 不含 provider 前缀，拼为 "provider/id" 与 builtInModelGroups 格式一致
                let qualifiedId = id.contains("/") ? id : "\(provider)/\(id)"
                let contextWindow = entry["contextWindow"] as? Int
                let reasoning = entry["reasoning"] as? Bool
                if groupMap[provider] == nil {
                    groupMap[provider] = []
                    order.append(provider)
                }
                var modelEntry = ModelEntry(id: qualifiedId, label: name)
                if let contextWindow { modelEntry.contextWindow = contextWindow }
                if let reasoning { modelEntry.reasoning = reasoning }
                groupMap[provider]!.append(modelEntry)
            }
            let groups = order.compactMap { key -> ModelGroup? in
                guard let models = groupMap[key] else { return nil }
                // 优先使用 builtInModelGroups / supportedProviderKeys 的友好名，否则直接用 provider id
                let displayName = builtInModelGroups.first(where: { $0.id == key })?.provider
                    ?? supportedProviderKeys.first(where: { $0.id == key })?.displayName
                    ?? key
                return ModelGroup(id: key, provider: displayName, models: models)
            }
            return groups.isEmpty ? nil : groups
        } catch {
            return nil
        }
    }

    /// 通过 Gateway RPC 获取 agent 列表（gateway 运行时使用，比 XPC 读文件更准确）
    /// - Returns: agent 列表；gateway 未连接或返回空时返回 nil
    func agentsList(username: String) async -> [AgentProfile]? {
        guard let client = clients[username] else { return nil }
        do {
            guard let payload = try await client.request(method: "agents.list") else { return nil }
            guard let rawAgents = payload["agents"] as? [[String: Any]] else { return nil }
            let defaultId = payload["defaultId"] as? String ?? "main"

            let agents: [AgentProfile] = rawAgents.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                let name = entry["name"] as? String ?? id
                let emoji = entry["emoji"] as? String ?? ""
                // model 可能是字符串（旧格式）或字典（新格式）
                let (modelPrimary, modelFallbacks) = Self.parseModelConfig(entry["model"])
                let workspacePath = entry["workspacePath"] as? String
                return AgentProfile(
                    id: id,
                    name: name,
                    emoji: emoji,
                    modelPrimary: modelPrimary,
                    modelFallbacks: modelFallbacks,
                    workspacePath: workspacePath,
                    isDefault: id == defaultId
                )
            }
            return agents.isEmpty ? nil : agents
        } catch {
            return nil
        }
    }

    /// 读取完整配置快照 + baseHash
    func configGetFull(username: String) async throws -> (config: [String: Any], baseHash: String) {
        guard let client = clients[username] else { throw GatewayClientError.notConnected }
        return try await client.configGetFull()
    }

    /// JSON Merge Patch 写入配置（带 schema 校验 + 自动热重启）
    @discardableResult
    func configPatch(username: String, patch: [String: Any], baseHash: String, note: String? = nil) async throws -> (noop: Bool, config: [String: Any]) {
        guard let client = clients[username] else { throw GatewayClientError.notConnected }
        return try await client.configPatch(patch: patch, baseHash: baseHash, note: note)
    }

    /// 发送任意 RPC 方法（用于高级场景）
    func request(username: String, method: String, params: [String: Any]? = nil) async throws -> [String: Any]? {
        guard let client = clients[username] else { throw GatewayClientError.notConnected }
        return try await client.request(method: method, params: params)
    }

    // MARK: - Agent 管理（RPC）

    /// 通过 Gateway RPC 创建 agent（自动创建 workspace + bootstrap 文件 + IDENTITY.md）
    /// - Returns: 创建后的 AgentProfile（含服务端 normalize 后的 agentId）
    func agentsCreate(username: String, name: String, workspace: String, emoji: String? = nil, modelPrimary: String? = nil, modelFallbacks: [String] = []) async throws -> AgentProfile {
        var params: [String: Any] = ["name": name, "workspace": workspace]
        if let emoji, !emoji.isEmpty { params["emoji"] = emoji }
        if let model = modelPrimary, !model.isEmpty {
            var modelConfig: [String: Any] = ["primary": model]
            if !modelFallbacks.isEmpty { modelConfig["fallbacks"] = modelFallbacks }
            params["model"] = modelConfig
        }
        appLog("GatewayHub agentsCreate @\(username) name=\(name) workspace=\(workspace)")
        do {
            guard let payload = try await request(username: username, method: "agents.create", params: params) else {
                throw GatewayClientError.requestFailed(code: "empty_response", message: "agents.create 返回空")
            }
            let agentId = payload["agentId"] as? String ?? ""
            let resolvedName = payload["name"] as? String ?? name
            if !agentId.isEmpty {
                try? await agentsFileSet(
                    username: username,
                    agentId: agentId,
                    fileName: "TOOLS.md",
                    content: defaultToolsContent
                )
            }
            appLog("GatewayHub agentsCreate @\(username) success → agentId=\(agentId)")
            return AgentProfile(
                id: agentId,
                name: resolvedName,
                emoji: emoji ?? "",
                modelPrimary: modelPrimary,
                modelFallbacks: modelFallbacks,
                workspacePath: payload["workspace"] as? String,
                isDefault: false
            )
        } catch {
            appLog("GatewayHub agentsCreate @\(username) failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// 通过 Gateway RPC 更新 agent（name/workspace/model/emoji/avatar 任意组合）
    func agentsUpdate(username: String, agentId: String, name: String? = nil, workspace: String? = nil, emoji: String? = nil, modelPrimary: String? = nil, modelFallbacks: [String]? = nil) async throws {
        var params: [String: Any] = ["agentId": agentId]
        if let name, !name.isEmpty { params["name"] = name }
        if let workspace, !workspace.isEmpty { params["workspace"] = workspace }
        if let emoji, !emoji.isEmpty { params["emoji"] = emoji }
        if let primary = modelPrimary {
            var modelConfig: [String: Any] = ["primary": primary]
            if let fallbacks = modelFallbacks, !fallbacks.isEmpty {
                modelConfig["fallbacks"] = fallbacks
            }
            params["model"] = modelConfig
        } else if let fallbacks = modelFallbacks {
            params["model"] = ["fallbacks": fallbacks]
        }
        appLog("GatewayHub agentsUpdate @\(username) agentId=\(agentId) params=\(params.keys.joined(separator: ","))")
        do {
            _ = try await request(username: username, method: "agents.update", params: params)
            appLog("GatewayHub agentsUpdate @\(username) agentId=\(agentId) success")
        } catch {
            appLog("GatewayHub agentsUpdate @\(username) agentId=\(agentId) failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// 通过 Gateway RPC 删除 agent（移除配置 + 清理 workspace/sessions）
    func agentsDelete(username: String, agentId: String, deleteFiles: Bool = true) async throws {
        appLog("GatewayHub agentsDelete @\(username) agentId=\(agentId) deleteFiles=\(deleteFiles)")
        do {
            _ = try await request(username: username, method: "agents.delete", params: [
                "agentId": agentId,
                "deleteFiles": deleteFiles
            ])
            appLog("GatewayHub agentsDelete @\(username) agentId=\(agentId) success")
        } catch {
            appLog("GatewayHub agentsDelete @\(username) agentId=\(agentId) failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// 通过 Gateway RPC 写入 agent workspace 文件（如 SOUL.md, IDENTITY.md, USER.md）
    func agentsFileSet(username: String, agentId: String, fileName: String, content: String) async throws {
        _ = try await request(username: username, method: "agents.files.set", params: [
            "agentId": agentId,
            "name": fileName,
            "content": content
        ])
    }

    /// 查询连接状态（非 UI 用途）
    func isConnected(username: String) async -> Bool {
        guard let client = clients[username] else { return false }
        return await client.connected
    }

    // MARK: - HTTP 健康探活

    /// 由 DashboardView 每次快照刷新后调用
    /// 对所有已知用户发 HTTP 探活，用快照 isRunning 做 tiebreaker
    /// - Parameters:
    ///   - all: 所有已知标准用户及其 gateway 端口
    ///   - isRunning: 快照中各用户的进程运行状态（launchctl/proc 级）
    func updateProbes(all: [(username: String, port: Int)], isRunning: [String: Bool]) {
        // 清理不再出现在用户列表中的孤儿条目（用户删除等情况）
        let knownUsernames = Set(all.map(\.username))
        for orphan in Set(readinessMap.keys).subtracting(knownUsernames) {
            probeTasks[orphan]?.cancel()
            probeTasks.removeValue(forKey: orphan)
            readinessMap.removeValue(forKey: orphan)
            healthzDeadSince.removeValue(forKey: orphan)
            lastProbeAt.removeValue(forKey: orphan)
        }
        let now = Date()
        // 对需要探活的用户发请求；已确认 stopped 且进程未运行的跳过（避免无意义的 connection refused 日志刷屏）
        for (username, port) in all {
            let processRunning = isRunning[username] ?? false
            if !processRunning && readinessMap[username] == .stopped {
                probeTasks[username]?.cancel()
                probeTasks.removeValue(forKey: username)
                continue
            }
            if let last = lastProbeAt[username], now.timeIntervalSince(last) < minProbeInterval {
                continue
            }
            lastProbeAt[username] = now
            probeTasks[username]?.cancel()
            probeTasks[username] = Task {
                await probe(username: username, port: port, processRunning: processRunning)
            }
        }
    }

    private func probe(username: String, port: Int, processRunning: Bool) async {
        let (alive, ready) = await GatewayClient.httpProbe(port: port)
        guard !Task.isCancelled else { return }

        if ready {
            readinessMap[username] = .ready
            healthzDeadSince.removeValue(forKey: username)
        } else if alive {
            // healthz OK 但 readyz 未通：正常启动中
            healthzDeadSince.removeValue(forKey: username)
            readinessMap[username] = .starting
        } else {
            // 端口无响应：用进程状态和历史状态综合判定
            let prev = readinessMap[username]

            if processRunning {
                // 进程在跑但端口不通 → 启动中（绑端口前）或 zombie（卡死）
                if healthzDeadSince[username] == nil {
                    healthzDeadSince[username] = Date()
                }
                if Date().timeIntervalSince(healthzDeadSince[username]!) > 60 {
                    readinessMap[username] = .zombie
                } else {
                    readinessMap[username] = .starting
                }
            } else if prev == .ready || prev == .starting {
                // 进程不在 + 之前活着 → 可能 launchd 正在重启，给 10s 缓冲
                if healthzDeadSince[username] == nil {
                    healthzDeadSince[username] = Date()
                }
                if Date().timeIntervalSince(healthzDeadSince[username]!) > 10 {
                    readinessMap[username] = .stopped
                    healthzDeadSince.removeValue(forKey: username)
                } else {
                    readinessMap[username] = .starting
                }
            } else {
                // 从未活过 / 已确认 stopped / zombie 但进程也没了 → stopped
                readinessMap[username] = .stopped
                healthzDeadSince.removeValue(forKey: username)
            }
        }
    }

    /// 单用户探活（供 UserDetailView 等独立视图调用，不依赖 DashboardView）
    func probeSingle(username: String, port: Int) async {
        let (alive, ready) = await GatewayClient.httpProbe(port: port)
        if ready {
            readinessMap[username] = .ready
            healthzDeadSince.removeValue(forKey: username)
        } else if alive {
            healthzDeadSince.removeValue(forKey: username)
            readinessMap[username] = .starting
        }
        // 不处理 !alive 情况——留给 DashboardView 的完整 probe 逻辑（含 processRunning tiebreaker）
    }

    // MARK: - 即时状态标记（UI 操作时调用，消除等 probe 确认的延迟）

    /// UI 发起启动/重启时调用，立即显示L10n.k("services.gateway_hub.text_d19349b5", fallback: "启动中")
    func markPendingStart(username: String) {
        readinessMap[username] = .starting
        healthzDeadSince.removeValue(forKey: username)
    }

    /// UI 发起停止时调用，立即显示L10n.k("services.gateway_hub.text_82977854", fallback: "已停止")
    func markPendingStopped(username: String) {
        readinessMap[username] = .stopped
        healthzDeadSince.removeValue(forKey: username)
    }

    // MARK: - 工具

    /// 解析 agent model 配置，兼容旧版字符串格式和新版对象格式
    /// 旧格式: "model": "claude-3-5-sonnet"  → (primary: "claude-3-5-sonnet", fallbacks: [])
    /// 新格式: "model": { "primary": "...", "fallbacks": [...] }
    private static func parseModelConfig(_ raw: Any?) -> (primary: String?, fallbacks: [String]) {
        guard let raw else { return (nil, []) }
        if let str = raw as? String {
            return (str.isEmpty ? nil : str, [])
        }
        if let dict = raw as? [String: Any] {
            let primary = dict["primary"] as? String
            let fallbacks = (dict["fallbacks"] as? [String]) ?? []
            return (primary?.isEmpty == true ? nil : primary, fallbacks)
        }
        return (nil, [])
    }

    /// openclaw gateway 端口分配规则：18000 + UID（与 GatewayManager.port(for:) 一致）
    static func gatewayPort(for uid: Int) -> Int? {
        let port = 18000 + uid
        guard port > 1024, port < 65536 else { return nil }
        return port
    }

    /// 从 PID 获取进程真实启动时间（sysctl KERN_PROC_PID）
    /// 返回 nil 表示进程不存在或查询失败
    nonisolated static func processStartTime(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// 解析 getGatewayURL() 返回的 URL，提取 port 和 token
    /// 格式：http://127.0.0.1:<port>/#token=<token>  或  http://127.0.0.1:<port>/
    static func parse(gatewayURL: String) -> (port: Int, token: String)? {
        guard let url = URL(string: gatewayURL),
              let host = url.host, host == "127.0.0.1",
              let port = url.port
        else { return nil }

        let token: String
        if let fragment = url.fragment, fragment.hasPrefix("token=") {
            token = String(fragment.dropFirst(6))
        } else {
            token = ""
        }
        return (port, token)
    }
}
