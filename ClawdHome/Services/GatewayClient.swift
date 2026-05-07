// ClawdHome/Services/GatewayClient.swift
// 单个用户 gateway 的 WebSocket JSON-RPC 客户端
// 协议：ws://127.0.0.1:<port>/ + shared token auth
// 不依赖 OpenClawKit（其要求 macOS 15，ClawdHome 目标 macOS 14）
// 参考 openclaw/apps/shared/OpenClawKit/Sources/OpenClawKit/GatewayChannel.swift

import CryptoKit
import Darwin
import Foundation
import OSLog

// MARK: - Gateway 事件

struct GatewayEvent {
    let name: String
    let payload: [String: Any]?
}

// MARK: - 错误类型

enum GatewayClientError: LocalizedError {
    case notConnected
    case connectFailed(String)
    case requestFailed(code: String?, message: String)
    case encodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return L10n.k("services.gateway_client.gateway", fallback: "Gateway 未连接")
        case .connectFailed(let msg):
            return String(format: L10n.k("services.gateway_client.connect_failed_message", fallback: "连接失败：%@"), msg)
        case .requestFailed(let code, let msg):
            return code.map { "[\($0)] \(msg)" } ?? msg
        case .encodingError(let err):
            return String(format: L10n.k("services.gateway_client.json_encoding_error", fallback: "JSON 编码错误：%@"), err.localizedDescription)
        }
    }
}

// MARK: - GatewayClient

/// 管理单个用户 openclaw gateway 的 WebSocket 连接
/// - 协议：JSON-RPC over WebSocket
/// - 认证：shared token + Ed25519 device identity
actor GatewayClient {

    private let url: URL
    private var token: String
    private let deviceIdentity: DeviceIdentity

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var listenTask: Task<Void, Never>?

    /// 待回复的 RPC 请求：requestId → continuation
    private var pending: [String: CheckedContinuation<[String: Any]?, Error>] = [:]

    nonisolated let eventStream: AsyncStream<GatewayEvent>
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?

    // MARK: - 初始化

    init(port: Int, token: String, deviceIdentity: DeviceIdentity = .loadOrCreate()) {
        self.url = URL(string: "ws://127.0.0.1:\(port)/")!
        self.token = token
        self.deviceIdentity = deviceIdentity
        var cont: AsyncStream<GatewayEvent>.Continuation?
        let stream = AsyncStream<GatewayEvent> { cont = $0 }
        self.eventStream = stream
        self.eventContinuation = cont
    }

    // MARK: - 连接管理

    var connected: Bool { isConnected }

    func connect() async throws {
        guard !isConnected else { return }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let sess = URLSession(configuration: config)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var wsRequest = URLRequest(url: url)
        wsRequest.setValue("ClawdHome/\(appVersion)", forHTTPHeaderField: "User-Agent")
        // Gateway Control UI 校验 Origin header；设为同 host 的 HTTP origin 以通过检查
        wsRequest.setValue("http://\(url.host ?? "127.0.0.1"):\(url.port ?? 80)", forHTTPHeaderField: "Origin")
        let sock = sess.webSocketTask(with: wsRequest)
        sock.maximumMessageSize = 16 * 1024 * 1024  // 16 MB，与 OpenClawKit 一致
        sock.resume()
        self.session = sess
        self.socket = sock

        do {
            // 1. 等待服务端发送 connect.challenge（最多 6s），提取 nonce
            let nonce = try await waitForChallenge(socket: sock)

            // 2. 发送 connect 请求（operator 角色，shared token + device identity）
            let reqId = UUID().uuidString
            let clientId = "openclaw-control-ui"
            let clientMode = "ui"
            let role = "operator"
            let scopes = ["operator.admin", "operator.read", "operator.write"]
            let device = deviceIdentity.connectDevice(
                clientId: clientId, clientMode: clientMode,
                role: role, scopes: scopes, token: token, nonce: nonce
            )
            let frame: [String: Any] = [
                "type": "req",
                "id": reqId,
                "method": "connect",
                "params": [
                    "minProtocol": 3,
                    "maxProtocol": 3,
                    "client": [
                        "id": clientId,
                        "displayName": "ClawdHome",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                        "platform": "macos",
                        "mode": clientMode,
                    ],
                    "role": role,
                    "scopes": scopes,
                    "device": device,
                    "auth": ["token": token],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: frame)
            try await sock.send(.data(data))

            // 3. 等待服务端回复 hello-ok
            try await waitForConnectResponse(socket: sock, reqId: reqId)
        } catch {
            sock.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            self.session = nil
            if error is GatewayClientError {
                throw error
            }
            throw GatewayClientError.connectFailed(error.localizedDescription)
        }

        isConnected = true
        startListening()
        appLog("gateway connected: \(self.url.absoluteString)")
    }

    func disconnect() {
        isConnected = false
        listenTask?.cancel()
        listenTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session = nil
        failAllPending(GatewayClientError.notConnected)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func updateToken(_ newToken: String) {
        self.token = newToken
        // 令牌更新后，下次 request 时会重连
        if isConnected {
            disconnect()
        }
    }

    // MARK: - JSON-RPC 请求

    /// 发送 RPC 请求，返回 payload 字典（服务端 ok=false 时 throw）
    func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any]? {
        if !isConnected {
            try await connect()
        }

        let id = UUID().uuidString
        var frame: [String: Any] = ["type": "req", "id": id, "method": method]
        if let params { frame["params"] = params }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: frame)
        } catch {
            throw GatewayClientError.encodingError(error)
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any]?, Error>) in
            self.pending[id] = cont
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let sock = await self.socketRef() else {
                        await self.resumePending(id: id, throwing: GatewayClientError.notConnected)
                        return
                    }
                    try await sock.send(.data(data))
                } catch {
                    // send 失败 = socket 已失效：先把错误交回本次请求，
                    // 再标记断开并清理其余 pending，下次 request 会重新 connect()。
                    let wrapped: GatewayClientError = (error as? GatewayClientError)
                        ?? .connectFailed(error.localizedDescription)
                    await self.resumePending(id: id, throwing: wrapped)
                    await self.markDisconnected(dueTo: wrapped)
                }
            }
        }
    }

    // MARK: - 配置便捷方法

    /// 读取配置项，支持 dot-path（如 "models.providers.anthropic.apiKey"）
    func configGet(path: String) async throws -> Any? {
        // config.get 返回 ConfigFileSnapshot: { config: {...}, hash: "..." }
        guard let payload = try await request(method: "config.get") else { return nil }
        let config = payload["config"] as? [String: Any] ?? payload
        let parts = path.split(separator: ".").map(String.init)
        var current: Any = config
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current
    }

    /// 写入配置项（调用 config.set，path + value）
    func configSet(path: String, value: Any) async throws {
        _ = try await request(method: "config.set", params: ["path": path, "value": value])
    }

    /// 读取完整配置快照 + hash（用于 config.patch 的乐观锁）
    /// 返回的 ConfigFileSnapshot 中 hash 字段名为 "hash"，传给 config.patch 时用作 baseHash
    func configGetFull() async throws -> (config: [String: Any], baseHash: String) {
        guard let payload = try await request(method: "config.get") else {
            throw GatewayClientError.requestFailed(code: nil, message: "config.get returned nil")
        }
        // config.get 返回 ConfigFileSnapshot，config 在 "config" 字段，hash 在 "hash" 字段
        let config = payload["config"] as? [String: Any] ?? payload
        let hash = payload["hash"] as? String ?? ""
        return (config, hash)
    }

    /// JSON Merge Patch 方式写入配置，自动触发 Gateway 热重启
    /// - Parameters:
    ///   - patch: 要合并的配置补丁（只包含变更部分）
    ///   - baseHash: 从 configGetFull() 获取的 hash（乐观锁）
    ///   - note: 变更说明（可选，记录在审计日志中）
    /// - Returns: (noop: 是否无实际变更, config: 脱敏后完整配置)
    @discardableResult
    func configPatch(patch: [String: Any], baseHash: String, note: String? = nil) async throws -> (noop: Bool, config: [String: Any]) {
        let raw = try serializeJSON(patch)
        var params: [String: Any] = ["raw": raw, "baseHash": baseHash]
        if let note { params["note"] = note }
        guard let payload = try await request(method: "config.patch", params: params) else {
            throw GatewayClientError.requestFailed(code: nil, message: "config.patch returned nil")
        }
        let noop = payload["noop"] as? Bool ?? false
        let config = payload["config"] as? [String: Any] ?? [:]
        return (noop, config)
    }

    private func serializeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.encodingError(
                NSError(domain: "GatewayClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
            )
        }
        return json
    }

    /// 读取健康状态
    func health() async throws -> [String: Any]? {
        try await request(method: "health")
    }

    /// 获取 models.list 原始条目
    /// - Returns: 原始字典数组，每项含 id / name / provider 等字段
    func modelsList() async throws -> [[String: Any]] {
        guard let payload = try await request(method: "models.list") else { return [] }
        return payload["models"] as? [[String: Any]] ?? []
    }

    // MARK: - 握手内部实现

    /// 等待 connect.challenge 事件，返回 nonce 字符串
    private func waitForChallenge(socket: URLSessionWebSocketTask) async throws -> String {
        // 使用 TaskGroup 实现超时竞争：challenge 到达 vs 6s 超时
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 6_000_000_000)
                throw GatewayClientError.connectFailed(L10n.k("services.gateway_client.connect_challenge_timeout", fallback: "connect.challenge 超时"))
            }
            group.addTask {
                while true {
                    let msg = try await socket.receive()
                    guard let dict = Self.decodeMessage(msg),
                          (dict["type"] as? String) == "event",
                          (dict["event"] as? String) == "connect.challenge",
                          let payload = dict["payload"] as? [String: Any],
                          let nonce = payload["nonce"] as? String
                    else { continue }
                    return nonce
                }
            }
            // 取第一个完成（成功或失败）
            let nonce = try await group.next()!
            group.cancelAll()
            return nonce
        }
    }

    private func waitForConnectResponse(socket: URLSessionWebSocketTask, reqId: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw GatewayClientError.connectFailed(L10n.k("services.gateway_client.connect_response_timeout", fallback: "connect response 超时"))
            }
            group.addTask {
                while true {
                    let msg = try await socket.receive()
                    guard let dict = Self.decodeMessage(msg),
                          (dict["type"] as? String) == "res",
                          (dict["id"] as? String) == reqId
                    else { continue }
                    if let ok = dict["ok"] as? Bool, !ok {
                        let errMsg = (dict["error"] as? [String: Any])?["message"] as? String
                            ?? "connect failed"
                        throw GatewayClientError.connectFailed(errMsg)
                    }
                    return
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - 监听循环

    private func startListening() {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }
            await self.listenLoop()
        }
    }

    private func listenLoop() async {
        while isConnected {
            guard let sock = socket else { break }
            do {
                let msg = try await sock.receive()
                guard let dict = Self.decodeMessage(msg),
                      let type = dict["type"] as? String
                else { continue }

                if type == "res", let id = dict["id"] as? String {
                    guard let cont = pending.removeValue(forKey: id) else { continue }
                    if let ok = dict["ok"] as? Bool, !ok {
                        let errMsg = (dict["error"] as? [String: Any])?["message"] as? String ?? L10n.k("services.gateway_client.request_failed", fallback: "请求失败")
                        let errCode = (dict["error"] as? [String: Any])?["code"] as? String
                        cont.resume(throwing: GatewayClientError.requestFailed(code: errCode, message: errMsg))
                    } else {
                        cont.resume(returning: dict["payload"] as? [String: Any])
                    }
                } else if type == "event",
                          let name = dict["event"] as? String {
                    let payload = dict["payload"] as? [String: Any]
                    eventContinuation?.yield(GatewayEvent(name: name, payload: payload))
                }
            } catch {
                appLog("gateway receive error: \(error.localizedDescription)", level: .error)
                isConnected = false
                failAllPending(error)
                break
            }
        }
    }

    // MARK: - 私有工具

    private func socketRef() -> URLSessionWebSocketTask? { socket }

    private func resumePending(id: String, throwing error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }
    }

    /// socket 异常 / send 失败时调用：回退到未连接态，让下一次 request 触发重连。
    /// 注意：当前请求已经通过 resumePending 单独 resume，这里只处理剩余 pending。
    private func markDisconnected(dueTo error: Error) {
        guard isConnected || socket != nil else { return }
        isConnected = false
        listenTask?.cancel()
        listenTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session = nil
        failAllPending(error)
    }

    private static func decodeMessage(_ msg: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data?
        switch msg {
        case .data(let d):   data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default:    data = nil
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Cron API

    func cronList() async throws -> [GatewayCronJob] {
        let payload = try await request(method: "cron.list", params: ["includeDisabled": true])
        guard let arr = payload?["jobs"] as? [[String: Any]] else { return [] }
        let data = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([GatewayCronJob].self, from: data)
    }

    func cronRuns(jobId: String, limit: Int = 100) async throws -> [GatewayCronRunLogEntry] {
        let payload = try await request(method: "cron.runs", params: ["id": jobId, "limit": limit])
        guard let arr = payload?["entries"] as? [[String: Any]] else { return [] }
        let data = try JSONSerialization.data(withJSONObject: arr)
        return try JSONDecoder().decode([GatewayCronRunLogEntry].self, from: data)
    }

    func cronRun(jobId: String) async throws {
        _ = try await request(method: "cron.run", params: ["id": jobId, "force": true])
    }

    func cronRemove(jobId: String) async throws {
        _ = try await request(method: "cron.remove", params: ["id": jobId])
    }

    func cronUpdate(jobId: String, enabled: Bool) async throws {
        _ = try await request(method: "cron.update", params: ["id": jobId, "enabled": enabled])
    }

    func cronAdd(_ params: GatewayCronAddParams) async throws -> GatewayCronJob {
        let dict = params.toDict()
        guard let payload = try await request(method: "cron.add", params: dict),
              let jobDict = payload["job"] as? [String: Any]
        else { throw GatewayClientError.requestFailed(code: nil, message: "cron.add returned no job") }
        let data = try JSONSerialization.data(withJSONObject: jobDict)
        return try JSONDecoder().decode(GatewayCronJob.self, from: data)
    }

    // MARK: - Skills API

    func skillsStatus() async throws -> GatewaySkillsStatusReport {
        guard let payload = try await request(method: "skills.status") else {
            throw GatewayClientError.requestFailed(code: nil, message: "skills.status returned nil")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GatewaySkillsStatusReport.self, from: data)
    }

    /// 安装 skill（本地 installer）
    func skillsInstall(name: String, installId: String, timeoutMs: Int = 300_000) async throws -> GatewaySkillInstallResult {
        let params: [String: Any] = ["name": name, "installId": installId, "timeoutMs": timeoutMs]
        guard let payload = try await request(method: "skills.install", params: params)
        else { throw GatewayClientError.requestFailed(code: nil, message: "skills.install returned nil") }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GatewaySkillInstallResult.self, from: data)
    }

    func skillsRemove(skillKey: String) async throws {
        _ = try await request(method: "skills.remove", params: ["skillKey": skillKey])
    }

    /// 更新 skill 配置（启用/禁用、API Key、环境变量）
    func skillsUpdate(
        skillKey: String,
        enabled: Bool? = nil,
        apiKey: String? = nil,
        env: [String: String]? = nil
    ) async throws -> GatewaySkillUpdateResult {
        var params: [String: Any] = ["skillKey": skillKey]
        if let enabled { params["enabled"] = enabled }
        if let apiKey { params["apiKey"] = apiKey }
        if let env, !env.isEmpty { params["env"] = env }
        guard let payload = try await request(method: "skills.update", params: params) else {
            throw GatewayClientError.requestFailed(code: nil, message: "skills.update returned nil")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(GatewaySkillUpdateResult.self, from: data)
    }

    // MARK: - Channels API

    /// 查询频道绑定状态
    func channelsStatus() async throws -> ChannelsStatusResult {
        guard let payload = try await request(method: "channels.status") else {
            throw GatewayClientError.requestFailed(code: nil, message: "channels.status returned nil")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(ChannelsStatusResult.self, from: data)
    }

    // MARK: - HTTP 探活（无需 WebSocket 连接）

    /// 共享探活 session，仅创建一次（探活不需要 cookie / 缓存）
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }()

    /// 快速探活：先 /readyz，再 /healthz，均 2s 超时
    /// - Returns: (alive: Bool, ready: Bool)
    ///   - (false, false): 端口无响应
    ///   - (true, false):  healthz OK，readyz 未通（启动中）
    ///   - (true, true):   readyz OK（完全就绪）
    static func httpProbe(port: Int) async -> (alive: Bool, ready: Bool) {
        let base = "http://127.0.0.1:\(port)"
        if await checkHTTP("\(base)/readyz") { return (true, true) }
        return (await checkHTTP("\(base)/healthz"), false)
    }

    private static func checkHTTP(_ urlStr: String) async -> Bool {
        guard let url = URL(string: urlStr) else { return false }
        do {
            let (_, resp) = try await probeSession.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - 连接类错误判定（共享）

/// 判断错误是否属于 Gateway 连接层问题，用于决定是否走 helper XPC 回退。
///
/// 识别范围：
/// - `GatewayClientError.notConnected` / `.connectFailed`
/// - `NSPOSIXErrorDomain` 下 ENOTCONN / EPIPE / ECONNRESET / ECONNREFUSED /
///   ECONNABORTED / ETIMEDOUT / ENETDOWN / ENETUNREACH / EHOSTUNREACH
/// - `URLError` 下 notConnectedToInternet / networkConnectionLost /
///   cannotConnectToHost / cannotFindHost / timedOut / resourceUnavailable
/// - localizedDescription 子串 "Gateway 未连接" / "连接失败" / "Socket" /
///   "socket is not connected"（语言兜底）
func isGatewayConnectivityError(_ error: Error) -> Bool {
    if let gatewayError = error as? GatewayClientError {
        switch gatewayError {
        case .notConnected, .connectFailed:
            return true
        case .requestFailed, .encodingError:
            return false
        }
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        switch nsError.code {
        case Int(ENOTCONN), Int(EPIPE), Int(ECONNRESET), Int(ECONNREFUSED),
             Int(ECONNABORTED), Int(ETIMEDOUT), Int(ENETDOWN),
             Int(ENETUNREACH), Int(EHOSTUNREACH):
            return true
        default:
            break
        }
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .cannotFindHost, .timedOut,
             .resourceUnavailable:
            return true
        default:
            break
        }
    }
    let message = error.localizedDescription
    return message.contains("Gateway 未连接")
        || message.contains("连接失败")
        || message.contains("Socket")
        || message.lowercased().contains("socket is not connected")
}
