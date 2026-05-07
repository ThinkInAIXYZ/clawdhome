// ClawdHomeCLI/Commands/ChatCommand.swift
// clawdhome chat <name> <message> — 给虾发消息并等待回复
// 通过 Gateway WebSocket JSON-RPC（chat.send + chat event），无需额外配置

import Foundation

enum ChatCommand {
    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        let username = args[0]
        let message = args[1]
        var sessionKey = "default"
        var timeout: TimeInterval = 300

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--session" where i + 1 < args.count:
                sessionKey = args[i + 1]; i += 2
            case "--timeout" where i + 1 < args.count:
                timeout = TimeInterval(args[i + 1]) ?? 300; i += 2
            default:
                i += 1
            }
        }

        // 1. 获取 Gateway URL 和 token
        guard FileManager.default.fileExists(atPath: "/Users/\(username)") else {
            throw CLIError.operationFailed("虾 \(username) 不存在")
        }

        let proxy = try client.proxy()
        let gatewayURL = syncCallString { proxy.getGatewayURL(username: username, withReply: $0) }

        guard !gatewayURL.isEmpty,
              let url = URL(string: gatewayURL),
              let port = url.port else {
            throw CLIError.operationFailed("无法获取 \(username) 的 Gateway URL")
        }

        let token: String
        if let fragment = url.fragment, fragment.hasPrefix("token=") {
            token = String(fragment.dropFirst(6))
        } else {
            throw CLIError.operationFailed("Gateway URL 中未找到 token")
        }

        // 2. 检查 Gateway 是否运行
        var isRunning = false
        let sema0 = DispatchSemaphore(value: 0)
        proxy.getGatewayStatus(username: username) { running, _ in
            isRunning = running; sema0.signal()
        }
        sema0.wait()
        guard isRunning else {
            throw CLIError.operationFailed("Gateway \(username) 未运行。请先: clawdhome shrimp start \(username)")
        }

        // 3. WebSocket 连接 + chat.send + 等待回复
        let ws = GatewayChatWS(port: port, token: token, timeout: timeout, jsonMode: Output.jsonMode)
        let reply = try ws.sendAndWait(sessionKey: sessionKey, message: message)

        if Output.jsonMode {
            Output.printJSON(["sessionKey": sessionKey, "reply": reply])
        } else if reply.isEmpty {
            // delta 已经实时输出了，这里什么都不用做
        }
    }

    private static func printUsage() {
        Output.printErr("""
        用法: clawdhome chat <shrimp> <message> [options]

        Options:
          --session <key>       会话 key（默认 "default"）
          --timeout <seconds>   超时秒数（默认 300）

        示例:
          clawdhome chat openclaw "你好"
          clawdhome chat openclaw "总结一下最近的对话" --session my_session
          clawdhome chat openclaw "hello" --json
        """)
    }
}

// MARK: - 等待动画

private final class Spinner {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex = 0
    private var timer: DispatchSourceTimer?
    private var currentMessage = ""
    private let queue = DispatchQueue(label: "spinner")
    private var lastLineLen = 0

    func start(_ message: String) {
        currentMessage = message
        frameIndex = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(80))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
        t.resume()
    }

    func update(_ message: String) {
        queue.sync { currentMessage = message }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // 清除 spinner 行
        queue.sync {
            if lastLineLen > 0 {
                let clear = "\r" + String(repeating: " ", count: lastLineLen) + "\r"
                FileHandle.standardError.write(Data(clear.utf8))
                lastLineLen = 0
            }
        }
    }

    private func tick() {
        let frame = frames[frameIndex % frames.count]
        frameIndex += 1
        let line = "\r\(frame) \(currentMessage)"
        lastLineLen = line.count
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - Gateway WebSocket 聊天客户端

private final class GatewayChatWS: NSObject, URLSessionWebSocketDelegate {
    private let port: Int
    private let token: String
    private let timeout: TimeInterval
    private let jsonMode: Bool
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let spinner = Spinner()

    init(port: Int, token: String, timeout: TimeInterval, jsonMode: Bool) {
        self.port = port
        self.token = token
        self.timeout = timeout
        self.jsonMode = jsonMode
    }

    func sendAndWait(sessionKey: String, message: String) throws -> String {
        if !jsonMode { spinner.start("连接 Gateway...") }

        // 1. 建立 WebSocket 连接
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let wsURL = URL(string: "ws://127.0.0.1:\(port)/")!
        var request = URLRequest(url: wsURL)
        request.setValue("ClawdHomeCLI/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        socket = urlSession!.webSocketTask(with: request)
        socket!.maximumMessageSize = 16 * 1024 * 1024
        socket!.resume()

        defer {
            spinner.stop()
            socket?.cancel(with: .goingAway, reason: nil)
        }

        // 2. 等待 connect.challenge
        let nonce = try waitForChallenge()

        // 3. 发送 connect 认证
        if !jsonMode { spinner.update("认证中...") }
        try sendConnect(nonce: nonce)

        // 4. 发送 chat.send
        if !jsonMode { spinner.update("发送消息...") }
        let idempotencyKey = UUID().uuidString
        let runId = try sendChatMessage(sessionKey: sessionKey, message: message, idempotencyKey: idempotencyKey)

        // 5. 等待回复
        if !jsonMode { spinner.update("等待回复...") }
        let reply = try collectReply(runId: runId, sessionKey: sessionKey)

        return reply
    }

    // MARK: - 握手

    private func waitForChallenge() throws -> String {
        let sema = DispatchSemaphore(value: 0)
        var nonce: String?
        var error: Error?

        receiveLoop { dict, err in
            if let err = err { error = err; sema.signal(); return true }
            guard let dict = dict,
                  dict["type"] as? String == "event",
                  dict["event"] as? String == "connect.challenge",
                  let payload = dict["payload"] as? [String: Any],
                  let n = payload["nonce"] as? String else { return false }
            nonce = n
            sema.signal()
            return true
        }

        let result = sema.wait(timeout: .now() + 6)
        if result == .timedOut { throw CLIError.operationFailed("connect.challenge 超时") }
        if let err = error { throw err }
        guard let n = nonce else { throw CLIError.operationFailed("未收到 nonce") }
        return n
    }

    private func sendConnect(nonce: String) throws {
        let reqId = UUID().uuidString
        let frame: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "openclaw-control-ui",
                    "displayName": "ClawdHome CLI",
                    "version": "1.0",
                    "platform": "macos",
                    "mode": "ui",
                ],
                "role": "operator",
                "scopes": ["operator.admin", "operator.read", "operator.write"],
                "auth": ["token": token],
            ] as [String: Any],
        ]

        try sendJSON(frame)

        let sema = DispatchSemaphore(value: 0)
        var connectError: Error?

        receiveLoop { dict, err in
            if let err = err { connectError = err; sema.signal(); return true }
            guard let dict = dict,
                  dict["type"] as? String == "res",
                  dict["id"] as? String == reqId else { return false }
            if let ok = dict["ok"] as? Bool, !ok {
                let msg = (dict["error"] as? [String: Any])?["message"] as? String ?? "connect failed"
                connectError = CLIError.operationFailed("认证失败: \(msg)")
            }
            sema.signal()
            return true
        }

        let result = sema.wait(timeout: .now() + 10)
        if result == .timedOut { throw CLIError.operationFailed("connect 响应超时") }
        if let err = connectError { throw err }
    }

    // MARK: - chat.send

    private func sendChatMessage(sessionKey: String, message: String, idempotencyKey: String) throws -> String {
        let reqId = UUID().uuidString
        let frame: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "chat.send",
            "params": [
                "sessionKey": sessionKey,
                "message": message,
                "idempotencyKey": idempotencyKey,
            ] as [String: Any],
        ]

        try sendJSON(frame)

        let sema = DispatchSemaphore(value: 0)
        var runId: String?
        var sendError: Error?

        receiveLoop { dict, err in
            if let err = err { sendError = err; sema.signal(); return true }
            guard let dict = dict,
                  dict["type"] as? String == "res",
                  dict["id"] as? String == reqId else { return false }

            if let ok = dict["ok"] as? Bool, !ok {
                let msg = (dict["error"] as? [String: Any])?["message"] as? String ?? "chat.send failed"
                sendError = CLIError.operationFailed("发送失败: \(msg)")
                sema.signal()
                return true
            }

            if let payload = dict["payload"] as? [String: Any] {
                runId = payload["runId"] as? String
            }
            sema.signal()
            return true
        }

        let result = sema.wait(timeout: .now() + 30)
        if result == .timedOut { throw CLIError.operationFailed("chat.send 响应超时") }
        if let err = sendError { throw err }
        guard let id = runId else { throw CLIError.operationFailed("未获取到 runId") }
        return id
    }

    // MARK: - 收集回复

    private func collectReply(runId: String, sessionKey: String) throws -> String {
        var replyParts: [String] = []
        let sema = DispatchSemaphore(value: 0)
        var collectError: Error?
        var receivedFirstDelta = false
        let startTime = Date()

        receiveLoop { [weak self] dict, err in
            guard let self else { return true }

            if let err = err { collectError = err; sema.signal(); return true }
            guard let dict = dict else { return false }

            // 处理 chat event
            guard dict["type"] as? String == "event",
                  dict["event"] as? String == "chat",
                  let payload = dict["payload"] as? [String: Any],
                  payload["runId"] as? String == runId else {
                // 更新等待时间
                if !self.jsonMode && !receivedFirstDelta {
                    let elapsed = Int(Date().timeIntervalSince(startTime))
                    self.spinner.update("等待回复... (\(elapsed)s)")
                }
                return false
            }

            let state = payload["state"] as? String ?? ""

            switch state {
            case "delta":
                if !receivedFirstDelta {
                    receivedFirstDelta = true
                    self.spinner.stop()
                }
                if let msg = payload["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    replyParts.append(content)
                    if !self.jsonMode {
                        print(content, terminator: "")
                        fflush(stdout)
                    }
                }

            case "final":
                if !receivedFirstDelta {
                    self.spinner.stop()
                }
                if let msg = payload["message"] as? [String: Any] {
                    if let content = msg["content"] as? String, replyParts.isEmpty {
                        replyParts.append(content)
                        if !self.jsonMode { print(content) }
                    } else if let contentArr = msg["content"] as? [[String: Any]], replyParts.isEmpty {
                        for block in contentArr {
                            if block["type"] as? String == "text",
                               let text = block["text"] as? String {
                                replyParts.append(text)
                                if !self.jsonMode { print(text) }
                                break
                            }
                        }
                    } else if !self.jsonMode {
                        print("") // 流式输出后换行
                    }
                }
                sema.signal()
                return true

            case "error":
                self.spinner.stop()
                let errMsg = payload["errorMessage"] as? String ?? "agent 执行错误"
                collectError = CLIError.operationFailed(errMsg)
                sema.signal()
                return true

            case "aborted":
                self.spinner.stop()
                collectError = CLIError.operationFailed("对话被中止")
                sema.signal()
                return true

            default:
                break
            }

            return false
        }

        let result = sema.wait(timeout: .now() + timeout)
        if result == .timedOut {
            spinner.stop()
            throw CLIError.operationFailed("等待回复超时（\(Int(timeout))s）")
        }
        if let err = collectError { throw err }

        // jsonMode 时返回完整文本；非 jsonMode 时已实时输出，返回空
        return jsonMode ? replyParts.joined() : ""
    }

    // MARK: - WebSocket 底层

    private func sendJSON(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let sema = DispatchSemaphore(value: 0)
        var sendError: Error?
        socket?.send(.data(data)) { error in
            sendError = error; sema.signal()
        }
        sema.wait()
        if let err = sendError { throw err }
    }

    private func receiveLoop(handler: @escaping ([String: Any]?, Error?) -> Bool) {
        guard let socket = socket else {
            _ = handler(nil, CLIError.connectionFailed)
            return
        }
        socket.receive { [weak self] result in
            switch result {
            case .success(let msg):
                let dict = Self.decodeMessage(msg)
                if handler(dict, nil) { return }
                self?.receiveLoop(handler: handler)
            case .failure(let error):
                _ = handler(nil, error)
            }
        }
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
}
