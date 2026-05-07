// ClawdHome/Services/GatewayClient.swift
// 单个用户 gateway 的 WebSocket JSON-RPC 客户端
// 协议：ws://127.0.0.1:<port>/ + shared token auth
// 不依赖 OpenClawKit（其要求 macOS 15，ClawdHome 目标 macOS 14）

import Foundation
import OSLog

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
/// - 认证：shared token（connect 帧的 auth.token 字段）
/// - 设计简化：不实现 device identity / pairing，仅用于 operator 管理
actor GatewayClient {

    private let url: URL
    private var token: String

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var listenTask: Task<Void, Never>?

    /// 待回复的 RPC 请求：requestId → continuation
    private var pending: [String: CheckedContinuation<[String: Any]?, Error>] = [:]

    // MARK: - 初始化

    init(port: Int, token: String) {
        self.url = URL(string: "ws://127.0.0.1:\(port)/")!
        self.token = token
    }

    // MARK: - 连接管理

    var connected: Bool { isConnected }

    func connect() async throws {
        guard !isConnected else { return }

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let sess = URLSession(configuration: config)
        let sock = sess.webSocketTask(with: url)
        sock.maximumMessageSize = 16 * 1024 * 1024  // 16 MB，与 OpenClawKit 一致
        sock.resume()
        self.session = sess
        self.socket = sock

        do {
            // 1. 等待服务端发送 connect.challenge（最多 6s）
            try await waitForChallenge(socket: sock)

            // 2. 发送 connect 请求（operator 角色，shared token，无 device identity）
            let reqId = UUID().uuidString
            let frame: [String: Any] = [
                "type": "req",
                "id": reqId,
                "method": "connect",
                "params": [
                    "minProtocol": 3,
                    "maxProtocol": 3,
                    "client": [
                        "id": "openclaw-macos",
                        "displayName": "ClawdHome",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                        "platform": "macos",
                        "mode": "ui",
                    ],
                    "role": "operator",
                    "scopes": ["operator.admin", "operator.read", "operator.write"],
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
            throw error
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
                    await self.resumePending(id: id, throwing: error)
                }
            }
        }
    }

    // MARK: - 配置便捷方法

    /// 读取配置项，支持 dot-path（如 "models.providers.anthropic.apiKey"）
    func configGet(path: String) async throws -> Any? {
        // 拉取完整 config 再导航（避免猜测 config.get 的参数格式）
        guard let payload = try await request(method: "config.get") else { return nil }
        let parts = path.split(separator: ".").map(String.init)
        var current: Any = payload
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

    private func waitForChallenge(socket: URLSessionWebSocketTask) async throws {
        // 使用 TaskGroup 实现超时竞争：challenge 到达 vs 6s 超时
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 6_000_000_000)
                throw GatewayClientError.connectFailed(L10n.k("services.gateway_client.connect_challenge_timeout", fallback: "connect.challenge 超时"))
            }
            group.addTask {
                while true {
                    let msg = try await socket.receive()
                    guard let dict = Self.decodeMessage(msg),
                          (dict["type"] as? String) == "event",
                          (dict["event"] as? String) == "connect.challenge"
                    else { continue }
                    return  // 收到 challenge，退出
                }
            }
            // 取第一个完成（成功或失败）
            try await group.next()
            group.cancelAll()
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
                }
                // events 暂不处理（后续可扩展 pushHandler）
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
