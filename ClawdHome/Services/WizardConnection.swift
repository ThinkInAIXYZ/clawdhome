// ClawdHome/Services/WizardConnection.swift
// 向导专用 XPC 连接：每个初始化向导独占一条，允许多虾并行初始化

import Foundation

/// 向导专用 XPC 连接封装。
/// 由 UserInitWizardView 在开始初始化时创建，完成/失败/取消后释放（wizardConn = nil）。
/// 独立于 HelperClient 的 controlConnection，长阻塞操作不会影响仪表盘或其他向导。
final class WizardConnection {
    private var connection: NSXPCConnection?

    init() {
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        conn.resume()
        connection = conn
    }

    deinit {
        connection?.invalidate()
    }

    private var proxy: (any ClawdHomeHelperProtocol)? {
        connection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    // MARK: - 向导步骤（长阻塞操作）

    func installNode(username: String, nodeDistURL: String) async throws {
        guard let proxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installNode(username: username, nodeDistURL: nodeDistURL) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.wizard_connection.unknown_error", fallback: "未知错误")) }
    }

    func setupNpmEnv(username: String) async throws {
        guard let proxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setupNpmEnv(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.wizard_connection.unknown_error", fallback: "未知错误")) }
    }

    func setNpmRegistry(username: String, registry: String) async throws {
        guard let proxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setNpmRegistry(username: username, registry: registry) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.wizard_connection.unknown_error", fallback: "未知错误")) }
    }

    func installOpenclaw(username: String, version: String? = nil) async throws {
        guard let proxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installOpenclaw(username: username, version: version) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.wizard_connection.unknown_error", fallback: "未知错误")) }
    }

    func cancelInit(username: String) async {
        guard let proxy else { return }
        await withCheckedContinuation { cont in
            proxy.cancelInit(username: username) { _ in cont.resume() }
        }
    }
}
