// ClawdHomeCLI/CLIHelperClient.swift
// CLI 专用 XPC 客户端 — 同步调用，阻塞等待结果

import Foundation

enum CLIError: LocalizedError {
    case connectionFailed
    case helperNotRunning
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "无法连接 ClawdHome Helper 服务。请确认 Helper 已安装并正在运行。"
        case .helperNotRunning:
            return "Helper 服务未响应。请尝试: make install-helper"
        case .operationFailed(let msg):
            return msg
        }
    }
}

final class CLIHelperClient {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// 同步获取代理对象
    func proxy() throws -> ClawdHomeHelperProtocol {
        var xpcError: Error?
        guard let p = connection.synchronousRemoteObjectProxyWithErrorHandler({ error in
            xpcError = error
        }) as? ClawdHomeHelperProtocol else {
            throw xpcError ?? CLIError.connectionFailed
        }
        return p
    }

    /// 验证连接可用
    func verifyConnection() throws {
        let sema = DispatchSemaphore(value: 0)
        var version: String?
        var connectError: Error?

        let p = connection.remoteObjectProxyWithErrorHandler { error in
            connectError = error
            sema.signal()
        } as? ClawdHomeHelperProtocol

        p?.getVersion { v in
            version = v
            sema.signal()
        }

        let result = sema.wait(timeout: .now() + 5)
        if result == .timedOut {
            throw CLIError.helperNotRunning
        }
        if let err = connectError {
            throw CLIError.operationFailed("XPC 连接失败: \(err.localizedDescription)")
        }
        if version == nil {
            throw CLIError.helperNotRunning
        }
    }
}
