// ClawdHome/Services/HelperClient.swift
// 封装 ClawdHome.app 与 ClawdHomeHelper 之间的 XPC 连接

import Foundation
import Observation

@Observable
final class HelperClient {
    private var controlConnection: NSXPCConnection?
    private var dashboardConnection: NSXPCConnection?
    /// 专用于长时间安装/升级操作，避免阻塞 controlConnection 上的其他 XPC 调用
    private var installConnection: NSXPCConnection?
    /// 文件管理专用连接，避免与控制操作互相阻塞
    private var fileConnection: NSXPCConnection?
    /// 进程管理专用连接，避免与文件管理/控制操作互相阻塞
    private var processConnection: NSXPCConnection?
    /// 角色定义只读操作专用连接（git log/diff 可能耗时，独立连接避免阻塞文件写入队列）
    private var personaReadConnection: NSXPCConnection?
    private(set) var isConnected: Bool = false

    // MARK: - 私有：创建 XPC 连接

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = false }
        }
        conn.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.isConnected = false }
        }
        conn.resume()
        return conn
    }

    func connect() {
        controlConnection = makeConnection()
        dashboardConnection = makeConnection()
        installConnection = makeConnection()
        fileConnection = makeConnection()
        processConnection = makeConnection()
        personaReadConnection = makeConnection()
        isConnected = true
    }

    func disconnect() {
        controlConnection?.invalidate(); controlConnection = nil
        dashboardConnection?.invalidate(); dashboardConnection = nil
        installConnection?.invalidate(); installConnection = nil
        fileConnection?.invalidate(); fileConnection = nil
        processConnection?.invalidate(); processConnection = nil
        personaReadConnection?.invalidate(); personaReadConnection = nil
        isConnected = false
    }

    // MARK: - 私有：获取 proxy

    private var controlProxy: (any ClawdHomeHelperProtocol)? {
        controlConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    private var dashboardProxy: (any ClawdHomeHelperProtocol)? {
        dashboardConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    private var installProxy: (any ClawdHomeHelperProtocol)? {
        installConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    private var fileProxy: (any ClawdHomeHelperProtocol)? {
        fileConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    private var processProxy: (any ClawdHomeHelperProtocol)? {
        processConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    private var personaReadProxy: (any ClawdHomeHelperProtocol)? {
        personaReadConnection?.remoteObjectProxy as? any ClawdHomeHelperProtocol
    }

    // MARK: - 用户管理

    func createUser(username: String, fullName: String, password: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.createUser(username: username, fullName: fullName, password: password) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除用户（由 Helper 以 root 执行）
    func deleteUser(username: String, keepHome: Bool, adminUser: String, adminPassword: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.deleteUser(username: username, keepHome: keepHome, adminUser: adminUser, adminPassword: adminPassword) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除前预清理：停止 gateway + 从系统群组移除（必须在 sysadminctl 之前）
    func prepareDeleteUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.prepareDeleteUser(username: username) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除后清理：移除 Helper 侧状态文件
    func cleanupDeletedUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.cleanupDeletedUser(username: username) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 设置 Gateway 开机自启（写标志文件到 /var/lib/clawdhome/）
    func setGatewayAutostart(enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setGatewayAutostart(enabled: enabled) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取 Gateway 开机自启状态（默认 true）
    func getGatewayAutostart() async -> Bool {
        guard let proxy = controlProxy else { return true }
        return await withCheckedContinuation { cont in
            proxy.getGatewayAutostart { cont.resume(returning: $0) }
        }
    }

    /// 设置 Helper 是否输出 DEBUG 日志
    func setHelperDebugLogging(enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setHelperDebugLogging(enabled: enabled) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.settings_debug", fallback: "设置 DEBUG 日志失败")) }
    }

    /// 读取 Helper DEBUG 日志开关状态
    func getHelperDebugLogging() async -> Bool {
        guard let proxy = controlProxy else { return false }
        return await withCheckedContinuation { cont in
            proxy.getHelperDebugLogging { cont.resume(returning: $0) }
        }
    }

    /// 设置指定用户的开机自启开关
    func setUserAutostart(username: String, enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setUserAutostart(username: username, enabled: enabled) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取指定用户的开机自启状态（默认 true）
    func getUserAutostart(username: String) async -> Bool {
        guard let proxy = controlProxy else { return true }
        return await withCheckedContinuation { cont in
            proxy.getUserAutostart(username: username) { cont.resume(returning: $0) }
        }
    }

    /// 注销指定用户的登录会话（停止 gateway + launchctl bootout user/<uid>）
    func logoutUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.logoutUser(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - Gateway 管理

    func startGateway(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.startGateway(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func stopGateway(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.stopGateway(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func restartGateway(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.restartGateway(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 查询 gateway 运行状态
    /// - Returns: (isRunning, pid)，pid 为 -1 表示未运行或未知
    func getGatewayStatus(username: String) async throws -> (running: Bool, pid: Int32) {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        return await withCheckedContinuation { cont in
            proxy.getGatewayStatus(username: username) { running, pid in
                cont.resume(returning: (running, pid))
            }
        }
    }

    // MARK: - 配置管理

    func setConfig(username: String, key: String, value: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setConfig(username: username, key: key, value: value) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 安装管理

    /// 安装或升级指定用户的 openclaw（输出实时写入 /tmp/clawdhome-init-<username>.log）
    /// 使用独立 installConnection，避免阻塞 controlConnection 上的其他 XPC 调用
    func installOpenclaw(username: String, version: String? = nil) async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installOpenclaw(username: username, version: version) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 版本查询

    /// 查询指定用户已安装的 openclaw 版本，未安装返回 nil
    func getOpenclawVersion(username: String) async -> String? {
        guard let proxy = controlProxy else { return nil }
        let v: String = await withCheckedContinuation { cont in
            proxy.getOpenclawVersion(username: username) { version in
                cont.resume(returning: version)
            }
        }
        return v.isEmpty ? nil : v
    }

    // MARK: - 用户环境初始化

    private static func hasLocalNodeBinary() -> Bool {
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        return candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 安装 Node.js（输出实时写入 /tmp/clawdhome-init-<username>.log）
    func installNode(username: String, nodeDistURL: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installNode(username: username, nodeDistURL: nodeDistURL) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// Node.js 是否已安装就绪（用于控制 npm 相关操作）
    func isNodeInstalled() async -> Bool {
        guard let proxy = controlProxy else { return false }
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var resolved = false

            func resolve(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                cont.resume(returning: value)
            }

            proxy.isNodeInstalled { value in
                resolve(value)
            }

            // 兼容旧版 Helper（未实现 isNodeInstalled 回调）导致的悬挂
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                resolve(Self.hasLocalNodeBinary())
            }
        }
    }

    /// 读取 Xcode/CLT 环境状态
    func getXcodeEnvStatus() async -> XcodeEnvStatus? {
        guard let proxy = controlProxy else { return nil }
        let json: String = await withCheckedContinuation { cont in
            proxy.getXcodeEnvStatus { cont.resume(returning: $0) }
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(XcodeEnvStatus.self, from: data)
    }

    /// 触发 Xcode Command Line Tools 安装（系统弹窗）
    func installXcodeCommandLineTools() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installXcodeCommandLineTools { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.trigger_install_failed", fallback: "触发安装失败")) }
    }

    /// 接受 Xcode license（非交互）
    func acceptXcodeLicense() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.acceptXcodeLicense { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.accept_license_failed", fallback: "接受 license 失败")) }
    }

    /// 初始化 npm 全局目录（~/.npm-global）并配置 shell 环境
    func setupNpmEnv(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setupNpmEnv(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 修复普通用户 Homebrew 安装权限（安装到 ~/.brew，并写入环境变量）
    func repairHomebrewPermission(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.repairHomebrewPermission(username: username) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 设置 npm 安装源（写入用户级 ~/.npmrc）
    func setNpmRegistry(username: String, registry: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setNpmRegistry(username: username, registry: registry) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取 npm 安装源（优先用户级配置）
    func getNpmRegistry(username: String) async -> String {
        guard let proxy = controlProxy else { return NpmRegistryOption.npmOfficial.rawValue }
        return await withCheckedContinuation { cont in
            proxy.getNpmRegistry(username: username) { cont.resume(returning: $0) }
        }
    }

    /// 取消指定用户的初始化命令
    func cancelInit(username: String) async {
        guard let proxy = controlProxy else { return }
        await withCheckedContinuation { cont in
            proxy.cancelInit(username: username) { _ in cont.resume() }
        }
    }

    /// 保存向导进度 JSON（写入 /var/lib/clawdhome/<username>-init.json）
    func saveInitState(username: String, json: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.saveInitState(username: username, json: json) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取向导进度 JSON（文件不存在返回空字符串）
    func loadInitState(username: String) async -> String {
        guard let proxy = controlProxy else { return "" }
        return await withCheckedContinuation { cont in
            proxy.loadInitState(username: username) { cont.resume(returning: $0) }
        }
    }

    /// 重置用户的 openclaw 运行环境（删除 ~/.npm-global 和 ~/.openclaw）
    func resetUserEnv(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.resetUserEnv(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 备份指定用户的 ~/.openclaw 到目标路径（tar.gz）
    func backupUser(username: String, destinationPath: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.backupUser(username: username, destinationPath: destinationPath) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 从备份包恢复指定用户的 ~/.openclaw（解压 tar.gz 并修正权限）
    func restoreUser(username: String, sourcePath: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.restoreUser(username: username, sourcePath: sourcePath) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 扫描来源虾可克隆项与大小
    func scanCloneClaw(username: String) async throws -> CloneScanResult {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (json, err): (String, String?) = await withCheckedContinuation { cont in
            let lock = NSLock()
            var resolved = false

            func resolve(_ value: (String, String?)) {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                cont.resume(returning: value)
            }

            proxy.scanCloneClaw(username: username) { json, err in
                resolve((json, err))
            }

            // 兜底：避免 helper 回调丢失时界面一直停在“扫描中”
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                resolve(("", L10n.k("services.helper_client.clone_scan_timeout", fallback: "克隆扫描超时，请重试")))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(CloneScanResult.self, from: data) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.failed", fallback: "克隆扫描结果解析失败"))
        }
        return result
    }

    /// 执行克隆新虾并返回目标 gateway URL
    func cloneClaw(request: CloneClawRequest) async throws -> CloneClawResult {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        guard let reqData = try? JSONEncoder().encode(request),
              let reqJSON = String(data: reqData, encoding: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.clone_request_serialization_failed", fallback: "克隆请求序列化失败"))
        }
        let (ok, resultJSON, err): (Bool, String, String?) = await withCheckedContinuation { cont in
            let lock = NSLock()
            var resolved = false

            func resolve(_ value: (Bool, String, String?)) {
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                cont.resume(returning: value)
            }

            proxy.cloneClaw(requestJSON: reqJSON) { ok, json, err in
                resolve((ok, json, err))
            }

            // 兜底：避免 helper 回调丢失时界面一直停在“克隆中”
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 240) {
                resolve((false, "", L10n.k("services.helper_client.clone_timeout", fallback: "克隆超时，请重试并检查 helper 日志")))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.clone_failed", fallback: "克隆失败")) }
        guard let data = resultJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(CloneClawResult.self, from: data) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.clone_result_parse_failed", fallback: "克隆结果解析失败"))
        }
        return result
    }

    /// 终止正在进行的克隆任务（按目标用户名）
    func cancelCloneClaw(targetUsername: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let trimmed = targetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.clone_cancel_username_required", fallback: "终止克隆失败：目标用户名为空"))
        }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.cancelCloneClaw(targetUsername: trimmed) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        if !ok {
            throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.clone_cancel_failed", fallback: "终止克隆失败"))
        }
    }

    /// 查询克隆当前阶段状态（按目标用户名）
    func getCloneClawStatus(targetUsername: String) async -> String? {
        guard let proxy = controlProxy else { return nil }
        let trimmed = targetUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let status: String? = await withCheckedContinuation { cont in
            proxy.getCloneClawStatus(targetUsername: trimmed) { status in
                cont.resume(returning: status)
            }
        }
        let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    /// 返回用户 gateway 的访问 URL
    func getGatewayURL(username: String) async -> String {
        guard let proxy = controlProxy else { return "" }
        return await withCheckedContinuation { cont in
            proxy.getGatewayURL(username: username) { cont.resume(returning: $0) }
        }
    }

    // MARK: - 仪表盘

    /// 获取仪表盘快照，使用独立连接避免阻塞控制通道
    func getDashboardSnapshot() async -> DashboardSnapshot? {
        guard let proxy = dashboardProxy else { return nil }
        let json: String = await withCheckedContinuation { cont in
            proxy.getDashboardSnapshot { cont.resume(returning: $0) }
        }
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        } catch {
            let preview = json.prefix(240).replacingOccurrences(of: "\n", with: " ")
            appLog("[dashboard] snapshot decode failed: \(error.localizedDescription); payload=\(preview)", level: .warn)
            return nil
        }
    }

    func getCachedAppUpdateState() async -> AppUpdateState? {
        guard let proxy = dashboardProxy else { return nil }
        let json: String? = await withCheckedContinuation { cont in
            proxy.getCachedAppUpdateState { cont.resume(returning: $0) }
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(AppUpdateState.self, from: data)
        } catch {
            let preview = json.prefix(240).replacingOccurrences(of: "\n", with: " ")
            appLog("[app-update] cached state decode failed: \(error.localizedDescription); payload=\(preview)", level: .warn)
            return nil
        }
    }

    /// 获取当前连接列表（无连接或未连接时返回空数组）
    func getConnections() async -> [ConnectionInfo] {
        guard let proxy = dashboardProxy else { return [] }
        return await withCheckedContinuation { cont in
            proxy.getConnections { json in
                guard let json,
                      let data = json.data(using: .utf8),
                      let conns = try? JSONDecoder().decode([ConnectionInfo].self, from: data)
                else { cont.resume(returning: []); return }
                cont.resume(returning: conns)
            }
        }
    }

    // MARK: - 网络策略

    func getShrimpNetworkPolicy(username: String) async -> ShrimpNetworkPolicy {
        guard let proxy = controlProxy else { return ShrimpNetworkPolicy() }
        return await withCheckedContinuation { cont in
            proxy.getShrimpNetworkPolicy(username: username) { json in
                guard let json, let data = json.data(using: .utf8),
                      let policy = try? JSONDecoder().decode(ShrimpNetworkPolicy.self, from: data)
                else { cont.resume(returning: ShrimpNetworkPolicy()); return }
                cont.resume(returning: policy)
            }
        }
    }

    func setShrimpNetworkPolicy(username: String, policy: ShrimpNetworkPolicy) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        guard let data = try? JSONEncoder().encode(policy),
              let json = String(data: data, encoding: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.serialization_failed", fallback: "序列化失败"))
        }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setShrimpNetworkPolicy(username: username, policyJSON: json) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func getGlobalNetworkConfig() async -> GlobalNetworkConfig {
        guard let proxy = controlProxy else { return GlobalNetworkConfig() }
        return await withCheckedContinuation { cont in
            proxy.getGlobalNetworkConfig { json in
                guard let json, let data = json.data(using: .utf8),
                      let config = try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data)
                else { cont.resume(returning: GlobalNetworkConfig()); return }
                cont.resume(returning: config)
            }
        }
    }

    func setGlobalNetworkConfig(_ config: GlobalNetworkConfig) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.serialization_failed", fallback: "序列化失败"))
        }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setGlobalNetworkConfig(configJSON: json) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 配置（直接读写 JSON，零 CLI 开销）

    /// 直接读取 ~/.openclaw/openclaw.json 并解析为字典（毫秒级，不启动 CLI）
    func getConfigJSON(username: String) async -> [String: Any] {
        guard let proxy = controlProxy else { return [:] }
        let json: String = await withCheckedContinuation { cont in
            proxy.getConfigJSON(username: username) { cont.resume(returning: $0) }
        }
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// 直接写入 ~/.openclaw/openclaw.json 指定 dot-path（不启动 CLI）
    /// value 必须是 JSON-serializable（String / [String] / Bool / Number 等）
    func setConfigDirect(username: String, path: String, value: Any) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let valueJSON = try serializeJSONValue(value)
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.setConfigDirect(username: username, path: path, valueJSON: valueJSON) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 将代理环境变量注入到用户级系统环境（shell 配置 + launchctl user 域）
    func applySystemProxyEnv(username: String, enabled: Bool, proxyURL: String, noProxy: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.applySystemProxyEnv(username: username, enabled: enabled, proxyURL: proxyURL, noProxy: noProxy) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 一次性应用代理配置（openclaw env + 系统环境注入 + 可选重启）
    func applyProxySettings(
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String,
        restartGatewayIfRunning: Bool
    ) async throws {
        // 代理批量应用属于长任务，走 installConnection，避免阻塞控制通道上的维护终端轮询。
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.applyProxySettings(
                username: username,
                enabled: enabled,
                proxyURL: proxyURL,
                noProxy: noProxy,
                restartGatewayIfRunning: restartGatewayIfRunning
            ) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 新用户创建后应用“当前设置页保存的代理配置”
    /// 读取 UserDefaults 中 proxy* 字段，写入 openclaw env + 系统 shell 环境
    func applySavedProxySettingsIfAny(username: String) async throws {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "proxyEnabled")
        let scheme = (defaults.string(forKey: "proxyScheme") ?? "http").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (defaults.string(forKey: "proxyHost") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (defaults.string(forKey: "proxyPort") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let noProxy = (defaults.string(forKey: "proxyNoProxy") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyUsername = (defaults.string(forKey: "proxyUsername") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyPassword = (defaults.string(forKey: "proxyPassword") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var proxyValue = ""
        if enabled {
            guard !host.isEmpty, Int(port) != nil else { return }
            let auth = proxyUsername.isEmpty ? "" : "\(proxyUsername):\(proxyPassword)@"
            proxyValue = "\(scheme)://\(auth)\(host):\(port)"
        }
        let noProxyValue = enabled ? noProxy : ""

        try await applyProxySettings(
            username: username,
            enabled: enabled,
            proxyURL: proxyValue,
            noProxy: noProxyValue,
            restartGatewayIfRunning: false
        )
    }

    /// 将 Any 序列化为 JSON 文本，支持对象/数组，也支持顶层 String/Bool/Number/null。
    private func serializeJSONValue(_ value: Any) throws -> String {
        // JSONObject（对象/数组）直接序列化
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        // 顶层 primitive 用数组包装后再取内部片段，避免 NSJSONSerialization 顶层类型崩溃。
        let wrapped: [Any] = [value]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: wrapped),
              var json = String(data: data, encoding: .utf8),
              json.first == "[", json.last == "]" else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.value_serialization_failed", fallback: "值序列化失败"))
        }
        json.removeFirst()
        json.removeLast()
        return json
    }

    /// 读取指定 dot-path 配置项（直接读 JSON 文件，未设置返回 nil）
    func getConfig(username: String, key: String) async -> String? {
        let config = await getConfigJSON(username: username)
        let parts = key.split(separator: ".").map(String.init)
        var current: Any = config
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        if let s = current as? String { return s.isEmpty ? nil : s }
        if let n = current as? NSNumber { return n.stringValue }
        return nil
    }

    /// 运行 openclaw models 子命令，返回 (success, output)（仅用于兜底场景）
    private func runModelCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        return await withCheckedContinuation { cont in
            proxy.runModelCommand(username: username, argsJSON: argsJSON) { ok, out in
                cont.resume(returning: (ok, out))
            }
        }
    }

    // MARK: - 通用 openclaw 命令（经由 Helper，无需密码）

    /// 以指定用户身份运行 openclaw 任意子命令，返回 (success, output)
    func runOpenclawCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        return await withCheckedContinuation { cont in
            proxy.runOpenclawCommand(username: username, argsJSON: argsJSON) { ok, out in
                cont.resume(returning: (ok, out))
            }
        }
    }

    // MARK: - Pairing 配对管理

    /// 运行 openclaw pairing 子命令，返回 (success, output)
    func runPairingCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        return await withCheckedContinuation { cont in
            proxy.runPairingCommand(username: username, argsJSON: argsJSON) { ok, out in
                cont.resume(returning: (ok, out))
            }
        }
    }

    /// 运行飞书独立配置命令（当前 install-only）：npx -y @larksuite/openclaw-lark-tools install
    func runFeishuOnboardCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        appLog("[feishu] request start @\(username) args=\(args.joined(separator: " "))")
        return await withCheckedContinuation { cont in
            proxy.runFeishuOnboardCommand(username: username, argsJSON: argsJSON) { ok, out in
                if ok {
                    appLog("[feishu] request success @\(username) outputBytes=\(out.utf8.count)")
                } else {
                    appLog("[feishu] request failed @\(username): \(out)", level: .error)
                }
                cont.resume(returning: (ok, out))
            }
        }
    }

    /// 启动通用维护终端会话（Helper 侧 PTY）
    func startMaintenanceTerminalSession(username: String, command: [String]) async -> (Bool, String, String?) {
        guard let proxy = controlProxy else { return (false, "", L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let commandJSON = (try? String(data: JSONEncoder().encode(command), encoding: .utf8)) ?? "[]"
        appLog("[maintenance] session start request @\(username) cmd=\(command.joined(separator: " "))")
        return await withCheckedContinuation { cont in
            proxy.startMaintenanceTerminalSession(
                username: username,
                commandJSON: commandJSON
            ) { ok, sessionID, err in
                if ok {
                    appLog("[maintenance] session started @\(username) session=\(sessionID)")
                } else {
                    appLog("[maintenance] session start failed @\(username): \(err ?? "unknown")", level: .error)
                }
                cont.resume(returning: (ok, sessionID, err))
            }
        }
    }

    /// 轮询通用维护终端会话输出
    func pollMaintenanceTerminalSession(sessionID: String, fromOffset: Int64) async
    -> (Bool, String, Int64, Bool, Int32, String?) {
        guard let proxy = controlProxy else {
            return (false, "", fromOffset, true, -1, L10n.k("services.helper_client.disconnected", fallback: "未连接"))
        }
        return await withCheckedContinuation { cont in
            proxy.pollMaintenanceTerminalSession(sessionID: sessionID, fromOffset: fromOffset) {
                ok, chunk, nextOffset, exited, exitCode, err in
                cont.resume(returning: (ok, chunk, nextOffset, exited, exitCode, err))
            }
        }
    }

    /// 向通用维护终端会话发送输入
    func sendMaintenanceTerminalSessionInput(sessionID: String, input: Data) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let base64 = input.base64EncodedString()
        return await withCheckedContinuation { cont in
            proxy.sendMaintenanceTerminalSessionInput(sessionID: sessionID, inputBase64: base64) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
    }

    /// 调整通用维护终端会话终端尺寸
    func resizeMaintenanceTerminalSession(sessionID: String, cols: Int, rows: Int) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        return await withCheckedContinuation { cont in
            proxy.resizeMaintenanceTerminalSession(sessionID: sessionID, cols: Int32(cols), rows: Int32(rows)) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
    }

    /// 终止通用维护终端会话
    func terminateMaintenanceTerminalSession(sessionID: String) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        return await withCheckedContinuation { cont in
            proxy.terminateMaintenanceTerminalSession(sessionID: sessionID) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
    }

    /// 获取模型状态（直接读取 openclaw.json，零 CLI 开销）
    func getModelsStatus(username: String) async -> ModelsStatus? {
        let config = await getConfigJSON(username: username)
        // agents.defaults.model.{primary, fallback}
        let model = (config["agents"] as? [String: Any])
            .flatMap { $0["defaults"] as? [String: Any] }
            .flatMap { $0["model"] as? [String: Any] }
        let primary = model?["primary"] as? String
        let fallbacks: [String]
        if let arr = model?["fallback"] as? [String] {
            fallbacks = arr
        } else if let single = model?["fallback"] as? String, !single.isEmpty {
            fallbacks = [single]
        } else {
            fallbacks = []
        }
        return ModelsStatus(defaultModel: primary, resolvedDefault: primary, fallbacks: fallbacks, imageModel: nil, imageFallbacks: [])
    }

    /// 设置默认模型（openclaw models set <model>）
    func setDefaultModel(username: String, model: String) async throws {
        let (ok, out) = await runModelCommand(username: username, args: ["set", model])
        if !ok { throw HelperError.operationFailed(out) }
    }

    /// 添加备用模型（openclaw models fallbacks add <model>）
    func addFallbackModel(username: String, model: String) async throws {
        let (ok, out) = await runModelCommand(username: username, args: ["fallbacks", "add", model])
        if !ok { throw HelperError.operationFailed(out) }
    }

    /// 移除备用模型（openclaw models fallbacks remove <model>）
    func removeFallbackModel(username: String, model: String) async throws {
        let (ok, out) = await runModelCommand(username: username, args: ["fallbacks", "remove", model])
        if !ok { throw HelperError.operationFailed(out) }
    }

    /// 用指定顺序覆盖备用模型列表（clear + 逐一 add）
    func setFallbackModels(username: String, models: [String]) async throws {
        let (ok, out) = await runModelCommand(username: username, args: ["fallbacks", "clear"])
        if !ok { throw HelperError.operationFailed(out) }
        for model in models {
            let (ok2, out2) = await runModelCommand(username: username, args: ["fallbacks", "add", model])
            if !ok2 { throw HelperError.operationFailed(out2) }
        }
    }

    // MARK: - 体检

    /// 对指定用户执行体检（环境隔离 + 安全审计）
    /// fix=true 时自动修复可修复的权限问题
    func runHealthCheck(username: String, fix: Bool) async -> HealthCheckResult? {
        guard let proxy = controlProxy else { return nil }
        let (_, json): (Bool, String) = await withCheckedContinuation { cont in
            proxy.runHealthCheck(username: username, fix: fix) { ok, json in
                cont.resume(returning: (ok, json))
            }
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HealthCheckResult.self, from: data)
    }

    // MARK: - Helper 版本验证

    func getVersion() async throws -> String {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        return await withCheckedContinuation { cont in
            proxy.getVersion { version in cont.resume(returning: version) }
        }
    }

    // MARK: - 文件管理

    /// 列出指定用户 home 下 relativePath 的内容
    func listDirectory(username: String, relativePath: String, showHidden: Bool = false) async throws -> [FileEntry] {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = await withCheckedContinuation { cont in
            proxy.listDirectory(username: username, relativePath: relativePath, showHidden: showHidden) { j, e in
                cont.resume(returning: (j, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let json, let data = json.data(using: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.invalid_response", fallback: "无效响应"))
        }
        return try JSONDecoder().decode([FileEntry].self, from: data)
    }

    /// 读取 /var/log/clawdhome/ 下的系统审计日志（name: "gateway"）
    func readSystemLog(name: String) async -> Data {
        guard let proxy = fileProxy else { return Data() }
        let (data, _): (Data?, String?) = await withCheckedContinuation { cont in
            proxy.readSystemLog(name: name) { d, e in cont.resume(returning: (d, e)) }
        }
        return data ?? Data()
    }

    /// 读取文件内容（Helper 侧限制 10MB）
    func readFile(username: String, relativePath: String) async throws -> Data {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (data, err): (Data?, String?) = await withCheckedContinuation { cont in
            proxy.readFile(username: username, relativePath: relativePath) { d, e in
                cont.resume(returning: (d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data else { throw HelperError.operationFailed(L10n.k("services.helper_client.file", fallback: "无文件数据")) }
        return data
    }

    /// 读取文件尾部内容（用于大日志文件，不受 readFile 10MB 限制）
    func readFileTail(username: String, relativePath: String, maxBytes: Int) async throws -> Data {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (data, err): (Data?, String?) = await withCheckedContinuation { cont in
            proxy.readFileTail(username: username, relativePath: relativePath, maxBytes: maxBytes) { d, e in
                cont.resume(returning: (d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data else { throw HelperError.operationFailed(L10n.k("services.helper_client.file", fallback: "无文件数据")) }
        return data
    }

    /// 写文件（覆盖）
    func writeFile(username: String, relativePath: String, data: Data) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.writeFile(username: username, relativePath: relativePath, data: data) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 删除文件或目录
    func deleteItem(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.deleteItem(username: username, relativePath: relativePath) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.delete", fallback: "删除失败")) }
    }

    // MARK: - Secrets 同步

    /// 将全局 secrets 和对应的 auth-profiles 同步到指定虾
    /// - secretsPayload: { "provider:accountName": "api-key", ... }
    /// - authProfilesPayload: keyRef 格式的 auth-profiles.json 内容
    func syncSecrets(username: String, secretsPayload: String, authProfilesPayload: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.syncSecrets(
                username: username,
                secretsJSON: secretsPayload,
                authProfilesJSON: authProfilesPayload
            ) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.secrets_sync_failed", fallback: "secrets 同步失败")) }
    }

    /// 通知虾的 openclaw 热加载 secrets
    func reloadSecrets(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.reloadSecrets(username: username) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.secrets_reload_failed", fallback: "secrets reload 失败")) }
    }

    /// 新建目录
    func createDirectory(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.createDirectory(username: username, relativePath: relativePath) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.create_directory_failed", fallback: "创建目录失败")) }
    }

    /// 重命名文件或目录
    func renameItem(username: String, relativePath: String, newName: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.renameItem(username: username, relativePath: relativePath, newName: newName) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.rename_failed", fallback: "重命名失败")) }
    }

    /// 解压压缩包到同目录
    func extractArchive(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.extractArchive(username: username, relativePath: relativePath) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.unzip_failed", fallback: "解压失败")) }
    }

    // MARK: - 记忆搜索

    /// 在用户的 memory SQLite 里全文搜索，返回匹配片段列表
    func searchMemory(username: String, query: String, limit: Int = 20) async throws -> [MemoryChunkResult] {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = await withCheckedContinuation { cont in
            proxy.searchMemory(username: username, query: query, limit: limit) { j, e in
                cont.resume(returning: (j, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data = (json ?? "[]").data(using: .utf8),
              let results = try? JSONDecoder().decode([MemoryChunkResult].self, from: data) else {
            return []
        }
        return results
    }

    // MARK: - 密码管理

    /// 修改受管用户的 macOS 账户密码（通过 Helper root 执行 dscl -passwd）
    func changeUserPassword(username: String, newPassword: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.changeUserPassword(username: username, newPassword: newPassword) { ok, msg in
                cont.resume(returning: (ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.password_change_failed", fallback: "密码修改失败")) }
    }

    // MARK: - 屏幕共享

    /// 查询系统屏幕共享是否正在运行
    func isScreenSharingEnabled() async -> Bool {
        guard let proxy = controlProxy else { return false }
        return await withCheckedContinuation { cont in
            proxy.isScreenSharingEnabled { cont.resume(returning: $0) }
        }
    }

    /// 启用并启动屏幕共享守护进程
    func enableScreenSharing() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.enableScreenSharing { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.enable_screen_sharing_failed", fallback: "启用屏幕共享失败")) }
    }

    // MARK: - 本地 AI — omlx

    func installOmlx() async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.installOmlx { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func getLocalLLMStatus() async -> LocalServiceStatus {
        guard let proxy = controlProxy else {
            return LocalServiceStatus(isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
        }
        let json: String = await withCheckedContinuation { cont in
            proxy.getLocalLLMStatus { cont.resume(returning: $0) }
        }
        return (try? JSONDecoder().decode(LocalServiceStatus.self, from: Data(json.utf8)))
            ?? LocalServiceStatus(isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
    }

    func listLocalModels() async -> [LocalModelInfo] {
        guard let proxy = controlProxy else { return [] }
        let json: String = await withCheckedContinuation { cont in
            proxy.listLocalModels { cont.resume(returning: $0) }
        }
        return (try? JSONDecoder().decode([LocalModelInfo].self, from: Data(json.utf8))) ?? []
    }

    func startLocalLLM() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.startLocalLLM { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func stopLocalLLM() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.stopLocalLLM { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func downloadLocalModel(_ modelId: String) async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.downloadLocalModel(modelId) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func deleteLocalModel(_ modelId: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.deleteLocalModel(modelId) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 进程管理

    func getProcessListSnapshot(username: String) async -> ProcessListSnapshot {
        guard let proxy = processProxy else {
            return ProcessListSnapshot(entries: [], portsLoading: false, updatedAt: Date().timeIntervalSince1970)
        }
        let json: String = await withCheckedContinuation { cont in
            proxy.getProcessListSnapshot(username: username) { cont.resume(returning: $0) }
        }
        if let snapshot = try? JSONDecoder().decode(ProcessListSnapshot.self, from: Data(json.utf8)) {
            return snapshot
        }
        // 兼容旧 Helper：仍可能返回 [ProcessEntry]
        let fallbackEntries = (try? JSONDecoder().decode([ProcessEntry].self, from: Data(json.utf8))) ?? []
        return ProcessListSnapshot(entries: fallbackEntries, portsLoading: false, updatedAt: Date().timeIntervalSince1970)
    }

    func getProcessList(username: String) async -> [ProcessEntry] {
        await getProcessListSnapshot(username: username).entries
    }

    func getProcessDetail(pid: Int32) async -> ProcessDetail? {
        guard let proxy = processProxy else { return nil }
        let json: String = await withCheckedContinuation { cont in
            proxy.getProcessDetail(pid: pid) { cont.resume(returning: $0) }
        }
        return try? JSONDecoder().decode(ProcessDetail.self, from: Data(json.utf8))
    }

    func killProcess(pid: Int32, signal: Int32) async throws {
        guard let proxy = processProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.killProcess(pid: pid, signal: signal) { ok, msg in cont.resume(returning: (ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 角色定义 Git 管理

    /// 初始化 workspace git repo（幂等，Tab 出现时自动调用）
    func initPersonaGitRepo(username: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.initPersonaGitRepo(username: username) { ok, e in cont.resume(returning: (ok, e)) }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.git_init_failed", fallback: "git 初始化失败")) }
    }

    /// 提交单个角色文件（writeFile 成功后调用）
    func commitPersonaFile(username: String, filename: String, message: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.commitPersonaFile(username: username, filename: filename, message: message) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.git_commit_failed", fallback: "git 提交失败")) }
    }

    /// 获取角色文件 git 历史（走独立只读连接，避免阻塞写操作队列）
    func getPersonaFileHistory(username: String, filename: String) async throws -> [PersonaCommit] {
        guard let proxy = personaReadProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = await withCheckedContinuation { cont in
            proxy.getPersonaFileHistory(username: username, filename: filename) { j, e in
                cont.resume(returning: (j, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PersonaCommit].self, from: data)) ?? []
    }

    /// 获取某 commit 的 diff（走独立只读连接）
    func getPersonaFileDiff(username: String, filename: String, commitHash: String) async throws -> String {
        guard let proxy = personaReadProxy else { throw HelperError.notConnected }
        let (diff, err): (String?, String?) = await withCheckedContinuation { cont in
            proxy.getPersonaFileDiff(username: username, filename: filename, commitHash: commitHash) { d, e in
                cont.resume(returning: (d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        return diff ?? ""
    }

    /// 将文件回滚到指定 commit（走文件写操作连接）
    func restorePersonaFileToCommit(username: String, filename: String, commitHash: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = await withCheckedContinuation { cont in
            proxy.restorePersonaFileToCommit(username: username, filename: filename, commitHash: commitHash) { ok, e in
                cont.resume(returning: (ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.restore_failed", fallback: "回滚失败")) }
    }
}

// MARK: - 错误类型
enum HelperError: LocalizedError {
    case notConnected
    case operationFailed(String)
    case brewNotFound

    var errorDescription: String? {
        switch self {
        case .notConnected:              return L10n.k("services.helper_client.helper_clawdhome", fallback: "Helper 未连接，请确认 ClawdHome 已正确安装")
        case .operationFailed(let msg): return msg
        case .brewNotFound:             return L10n.k("services.helper_client.homebrew_not_installed", fallback: "Homebrew 未安装")
        }
    }
}
