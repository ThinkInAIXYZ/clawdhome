// ClawdHome/Services/HelperClient.swift
// 封装 ClawdHome.app 与 ClawdHomeHelper 之间的 XPC 连接

import Foundation
import Observation
import os.log

enum GatewayStartDiagnosis {
    case started
    case needsNodeRepair(reason: String)
}

@Observable
final class HelperClient {
    private var controlConnection: NSXPCConnection?
    /// Gateway 生命周期操作专用连接，避免与通用控制调用互相阻塞
    private var gatewayConnection: NSXPCConnection?
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

    /// 连接世代计数器：每次 connect()/disconnect() 递增。
    /// invalidationHandler 捕获创建时的世代值，仅当世代匹配时才修改 isConnected，
    /// 防止旧连接的异步回调干扰新连接状态。
    private var connectionGeneration: UInt64 = 0
    /// 当前是否有连接探针在进行；用于避免重复 connect() 互相 invalidate 造成重连风暴。
    private var verifyInFlightGeneration: UInt64?

    // MARK: - XPC 超时常量

    /// 普通操作默认超时（35 秒，适用于简单读写和状态查询）
    private static let xpcDefaultTimeout: Duration = .seconds(35)
    /// 命令执行类超时（5 分钟，CLI 命令可能涉及网络请求）
    private static let xpcCommandTimeout: Duration = .seconds(300)
    /// 安装类操作超时（10 分钟，npm install / brew install / 大文件下载）
    private static let xpcInstallTimeout: Duration = .seconds(600)

    // MARK: - 私有：创建 XPC 连接

    private func makeConnection(label: String, generation: UInt64, affectsConnectivity: Bool = false) -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            os_log(.error, "[HelperClient] %{public}@ invalidated (gen=%llu)", label, generation)
            appLog("[HelperClient] \(label) invalidated (gen=\(generation))", level: .warn)
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.clearConnection(label: label, generation: generation)
                if affectsConnectivity {
                    if self.verifyInFlightGeneration == generation {
                        self.verifyInFlightGeneration = nil
                    }
                    // control 通道偶发 invalidation 时，先尝试软重连探测，避免误判整机断连。
                    if self.isConnected {
                        os_log(
                            .error,
                            "[HelperClient] %{public}@ invalidated → soft-reconnect probe (gen=%llu)",
                            label,
                            generation
                        )
                        appLog(
                            "[HelperClient] \(label) invalidated -> soft-reconnect probe (gen=\(generation))",
                            level: .warn
                        )
                        self.verifyInFlightGeneration = generation
                        self.controlConnection = self.makeConnection(
                            label: "control",
                            generation: generation,
                            affectsConnectivity: true
                        )
                        self.verifyConnection(
                            generation: generation,
                            source: "\(label) invalidated soft-reconnect"
                        )
                    } else {
                        os_log(.error, "[HelperClient] %{public}@ invalidated → 标记断连 (gen=%llu)", label, generation)
                        appLog("[HelperClient] \(label) invalidated -> disconnected (gen=\(generation))", level: .warn)
                        self.isConnected = false
                    }
                } else {
                    os_log(.info, "[HelperClient] %{public}@ invalidated → 将按需重建通道 (gen=%llu)", label, generation)
                    appLog("[HelperClient] \(label) invalidated -> will recreate on demand (gen=\(generation))")
                }
            }
        }
        conn.interruptionHandler = {
            os_log(.info, "[HelperClient] %{public}@ interrupted — XPC 自动恢复中 (gen=%llu)", label, generation)
        }
        conn.resume()
        return conn
    }

    private func clearConnection(label: String, generation: UInt64) {
        guard connectionGeneration == generation else { return }
        switch label {
        case "control": controlConnection = nil
        case "gateway": gatewayConnection = nil
        case "dashboard": dashboardConnection = nil
        case "install": installConnection = nil
        case "file": fileConnection = nil
        case "process": processConnection = nil
        case "personaRead": personaReadConnection = nil
        default: break
        }
    }

    func connect(
        reason: String? = nil,
        fileID: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let source = reason ?? "\(fileID):\(line) \(function)"
        if let inflight = verifyInFlightGeneration {
            os_log(
                .info,
                "[HelperClient] connect() skipped: verify in-flight (gen=%llu, source=%{public}@)",
                inflight,
                source
            )
            appLog("[HelperClient] connect() skipped: verify in-flight (gen=\(inflight), source=\(source))")
            return
        }
        // 递增世代，使所有旧连接的回调失效
        connectionGeneration &+= 1
        let gen = connectionGeneration
        verifyInFlightGeneration = gen
        os_log(.info, "[HelperClient] connect() gen=%llu source=%{public}@", gen, source)
        appLog("[HelperClient] connect() gen=\(gen) source=\(source)")

        // 先清理旧连接
        controlConnection?.invalidate()
        gatewayConnection?.invalidate()
        dashboardConnection?.invalidate()
        installConnection?.invalidate()
        fileConnection?.invalidate()
        processConnection?.invalidate()
        personaReadConnection?.invalidate()

        controlConnection = makeConnection(label: "control", generation: gen, affectsConnectivity: true)
        gatewayConnection = makeConnection(label: "gateway", generation: gen)
        dashboardConnection = makeConnection(label: "dashboard", generation: gen)
        installConnection = makeConnection(label: "install", generation: gen)
        fileConnection = makeConnection(label: "file", generation: gen)
        processConnection = makeConnection(label: "process", generation: gen)
        personaReadConnection = makeConnection(label: "personaRead", generation: gen)
        verifyConnection(generation: gen, source: source)
    }

    func disconnect() {
        connectionGeneration &+= 1
        verifyInFlightGeneration = nil
        controlConnection?.invalidate(); controlConnection = nil
        gatewayConnection?.invalidate(); gatewayConnection = nil
        dashboardConnection?.invalidate(); dashboardConnection = nil
        installConnection?.invalidate(); installConnection = nil
        fileConnection?.invalidate(); fileConnection = nil
        processConnection?.invalidate(); processConnection = nil
        personaReadConnection?.invalidate(); personaReadConnection = nil
        isConnected = false
    }

    /// 通过真实 XPC 调用验证 Helper 可达，而非依赖连接对象状态
    private func verifyConnection(generation: UInt64, source: String) {
        let lock = NSLock()
        var finished = false
        var fallbackStarted = false

        func finish(_ connected: Bool, _ message: String) {
            lock.lock()
            let shouldApply = !finished
            if shouldApply { finished = true }
            lock.unlock()
            guard shouldApply else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                if connected {
                    os_log(
                        .info,
                        "[HelperClient] verify probe ok (gen=%llu, source=%{public}@)",
                        generation,
                        source
                    )
                    appLog("[HelperClient] verify probe ok (gen=\(generation), source=\(source))")
                } else {
                    os_log(
                        .error,
                        "[HelperClient] verify probe failed: %{public}@ (gen=%llu, source=%{public}@)",
                        message,
                        generation,
                        source
                    )
                    appLog(
                        "[HelperClient] verify probe failed: \(message) (gen=\(generation), source=\(source))",
                        level: .warn
                    )
                }
                // 超时类失败在长阻塞任务（如 install/diagnostics）期间可能是“假断连”。
                // 若当前已连接，则保持连接状态，避免 maintainConnection 触发重连风暴。
                if connected {
                    self.isConnected = true
                } else {
                    let lower = message.lowercased()
                    let isTimeout = lower.contains("timeout") || message.contains("超时")
                    if self.isConnected && isTimeout {
                        appLog(
                            "[HelperClient] verify timeout ignored (keep connected) (gen=\(generation), source=\(source))"
                        )
                    } else {
                        self.isConnected = false
                    }
                }
                if self.verifyInFlightGeneration == generation {
                    self.verifyInFlightGeneration = nil
                }
            }
        }

        func startFallback(primaryMessage: String) {
            lock.lock()
            let shouldStart = !finished && !fallbackStarted
            if shouldStart { fallbackStarted = true }
            lock.unlock()
            guard shouldStart else { return }

            os_log(
                .info,
                "[HelperClient] verify primary probe failed, fallback to getGatewayStatus (gen=%llu, source=%{public}@)",
                generation,
                source
            )
            appLog(
                "[HelperClient] verify primary probe failed -> fallback getGatewayStatus (gen=\(generation), source=\(source), reason=\(primaryMessage))"
            )

            guard let fallbackProxy = controlConnection?.remoteObjectProxyWithErrorHandler({ error in
                finish(false, "fallback proxy error: \(error.localizedDescription); primary: \(primaryMessage)")
            }) as? any ClawdHomeHelperProtocol else {
                finish(false, "fallback proxy unavailable; primary: \(primaryMessage)")
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
                finish(false, "fallback timeout (8s); primary: \(primaryMessage)")
            }

            fallbackProxy.getGatewayStatus(username: "__probe__") { _, _ in
                finish(true, "")
            }
        }

        guard let proxy = controlConnection?.remoteObjectProxyWithErrorHandler({ error in
            startFallback(primaryMessage: error.localizedDescription)
        }) as? any ClawdHomeHelperProtocol else {
            finish(false, "control proxy unavailable")
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            startFallback(primaryMessage: "probe timeout (4s)")
        }

        proxy.getVersion { _ in
            finish(true, "")
        }
    }

    // MARK: - 私有：获取 proxy
    // 使用 remoteObjectProxyWithErrorHandler 替代 remoteObjectProxy，
    // 避免 XPC 调用失败时 reply 回调永远不触发（导致 withCheckedContinuation 永久挂起）。

    private func proxyWithLogging(_ conn: NSXPCConnection?) -> (any ClawdHomeHelperProtocol)? {
        conn?.remoteObjectProxyWithErrorHandler { error in
            os_log(.error, "[HelperClient] XPC proxy error: %{public}@", error.localizedDescription)
        } as? any ClawdHomeHelperProtocol
    }

    private var controlProxy: (any ClawdHomeHelperProtocol)? {
        if controlConnection == nil, isConnected {
            controlConnection = makeConnection(
                label: "control",
                generation: connectionGeneration,
                affectsConnectivity: true
            )
        }
        return proxyWithLogging(controlConnection)
    }

    private var gatewayProxy: (any ClawdHomeHelperProtocol)? {
        if gatewayConnection == nil, isConnected {
            gatewayConnection = makeConnection(label: "gateway", generation: connectionGeneration)
        }
        return proxyWithLogging(gatewayConnection)
    }

    private var dashboardProxy: (any ClawdHomeHelperProtocol)? {
        if dashboardConnection == nil, isConnected {
            dashboardConnection = makeConnection(label: "dashboard", generation: connectionGeneration)
        }
        return proxyWithLogging(dashboardConnection)
    }

    private var installProxy: (any ClawdHomeHelperProtocol)? {
        if installConnection == nil, isConnected {
            installConnection = makeConnection(label: "install", generation: connectionGeneration)
        }
        return proxyWithLogging(installConnection)
    }

    private var fileProxy: (any ClawdHomeHelperProtocol)? {
        if fileConnection == nil, isConnected {
            fileConnection = makeConnection(label: "file", generation: connectionGeneration)
        }
        return proxyWithLogging(fileConnection)
    }

    private var processProxy: (any ClawdHomeHelperProtocol)? {
        if processConnection == nil, isConnected {
            processConnection = makeConnection(label: "process", generation: connectionGeneration)
        }
        return proxyWithLogging(processConnection)
    }

    private var personaReadProxy: (any ClawdHomeHelperProtocol)? {
        if personaReadConnection == nil, isConnected {
            personaReadConnection = makeConnection(label: "personaRead", generation: connectionGeneration)
        }
        return proxyWithLogging(personaReadConnection)
    }

    // MARK: - XPC 调用超时基础设施

    /// 带超时的 XPC 调用。
    /// 使用 withUnsafeContinuation 替代 withCheckedContinuation，配合 NSLock 防止 double-resume，
    /// 确保超时后 continuation 立即返回，不会被 TaskGroup 的子任务清理阻塞。
    private func requestWithTimeout<T>(
        timeout: Duration,
        timeoutMessage: String,
        operation: @escaping (@escaping (T) -> Void) -> Void
    ) async throws -> T {
        // 使用独立的 continuation 而非 TaskGroup，避免 group 等待子任务完成导致的假超时
        try await withUnsafeThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(with result: Result<T, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            let requestedSeconds = max(1, Int(timeout.components.seconds))
            let effectiveSeconds = XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: requestedSeconds)

            // 超时路径（基础超时 + 冗余缓冲，减少误伤）
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Double(effectiveSeconds)) {
                resumeOnce(with: .failure(HelperError.operationFailed(timeoutMessage)))
            }

            // XPC 调用路径
            operation { value in
                resumeOnce(with: .success(value))
            }
        }
    }

    /// 带默认超时保护的 XPC 调用（替代裸 withCheckedContinuation，防止永久挂起）
    private func xpcCall<T>(
        timeout: Duration = HelperClient.xpcDefaultTimeout,
        operation: @escaping (@escaping (T) -> Void) -> Void
    ) async throws -> T {
        let requestedSeconds = max(1, Int(timeout.components.seconds))
        let effectiveSeconds = XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: requestedSeconds)
        return try await requestWithTimeout(
            timeout: timeout,
            timeoutMessage: "XPC 调用超时（\(effectiveSeconds)s，基础 \(requestedSeconds)s + 冗余 \(effectiveSeconds - requestedSeconds)s）",
            operation: operation
        )
    }

    private func isGatewayRunningQuickly(username: String) async -> Bool {
        guard let proxy = gatewayProxy else { return false }
        do {
            let (running, _): (Bool, Int32) = try await xpcCall(timeout: .seconds(3)) { done in
                proxy.getGatewayStatus(username: username) { running, pid in
                    done((running, pid))
                }
            }
            return running
        } catch {
            return false
        }
    }

    // MARK: - 用户管理

    func createUser(username: String, fullName: String, password: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.createUser(username: username, fullName: fullName, password: password) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除用户（由 Helper 以 root 执行）
    func deleteUser(username: String, keepHome: Bool, adminUser: String, adminPassword: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.deleteUser(username: username, keepHome: keepHome, adminUser: adminUser, adminPassword: adminPassword) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除前预清理：停止 gateway + 从系统群组移除（必须在 sysadminctl 之前）
    func prepareDeleteUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.prepareDeleteUser(username: username) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 删除后清理：移除 Helper 侧状态文件
    func cleanupDeletedUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.cleanupDeletedUser(username: username) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 设置 Gateway 开机自启（写标志文件到 /var/lib/clawdhome/）
    func setGatewayAutostart(enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setGatewayAutostart(enabled: enabled) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取 Gateway 开机自启状态（默认 true）
    func getGatewayAutostart() async -> Bool {
        guard let proxy = controlProxy else { return true }
        do {
            return try await xpcCall { done in
                proxy.getGatewayAutostart { done($0) }
            }
        } catch { return true }
    }

    /// 设置 Helper 是否输出 DEBUG 日志
    func setHelperDebugLogging(enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setHelperDebugLogging(enabled: enabled) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.settings_debug", fallback: "设置 DEBUG 日志失败")) }
    }

    /// 读取 Helper DEBUG 日志开关状态
    func getHelperDebugLogging() async -> Bool {
        guard let proxy = controlProxy else { return false }
        do {
            return try await xpcCall { done in
                proxy.getHelperDebugLogging { done($0) }
            }
        } catch { return false }
    }

    /// 设置指定用户的开机自启开关
    func setUserAutostart(username: String, enabled: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setUserAutostart(username: username, enabled: enabled) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取指定用户的开机自启状态（默认 true）
    func getUserAutostart(username: String) async -> Bool {
        guard let proxy = controlProxy else { return true }
        do {
            return try await xpcCall { done in
                proxy.getUserAutostart(username: username) { done($0) }
            }
        } catch { return true }
    }

    /// 注销指定用户的登录会话（停止 gateway + launchctl bootout user/<uid>）
    func logoutUser(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.logoutUser(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - Gateway 管理

    func startGateway(username: String) async throws {
        guard let proxy = gatewayProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?)
        do {
            (ok, msg) = try await requestWithTimeout(
                timeout: .seconds(35),
                timeoutMessage: L10n.k(
                    "services.helper_client.gateway_start_timeout",
                    fallback: "启动 Gateway 超时，请检查 Helper 日志后重试"
                )
            ) { completion in
                proxy.startGateway(username: username) { ok, msg in
                    completion((ok, msg))
                }
            }
        } catch {
            // 某些场景下（例如 XPC 回调丢失）请求会超时，但 gateway 已经实际拉起。
            if await isGatewayRunningQuickly(username: username) { return }
            throw error
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func startGatewayDiagnoseNodeToolchain(username: String) async throws -> GatewayStartDiagnosis {
        do {
            try await startGateway(username: username)
            return .started
        } catch {
            let message = error.localizedDescription
            if await shouldSuggestNodeRepair(username: username, startupErrorMessage: message) {
                return .needsNodeRepair(reason: message)
            }
            throw error
        }
    }

    func stopGateway(username: String) async throws {
        guard let proxy = gatewayProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.stopGateway(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func restartGateway(username: String) async throws {
        guard let proxy = gatewayProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.restartGateway(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 查询 gateway 运行状态
    /// - Returns: (isRunning, pid)，pid 为 -1 表示未运行或未知
    func getGatewayStatus(username: String) async throws -> (running: Bool, pid: Int32) {
        guard let proxy = gatewayProxy else { throw HelperError.notConnected }
        return try await xpcCall { done in
            proxy.getGatewayStatus(username: username) { running, pid in
                done((running, pid))
            }
        }
    }

    // MARK: - 配置管理

    func setConfig(username: String, key: String, value: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setConfig(username: username, key: key, value: value) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 安装管理

    /// 安装或升级指定用户的 openclaw（输出实时写入 /tmp/clawdhome-init-<username>.log）
    /// 使用独立 installConnection，避免阻塞 controlConnection 上的其他 XPC 调用
    func installOpenclaw(username: String, version: String? = nil) async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.installOpenclaw(username: username, version: version) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 版本查询

    /// 查询指定用户已安装的 openclaw 版本，未安装返回 nil
    func getOpenclawVersion(username: String) async -> String? {
        guard let proxy = controlProxy else { return nil }
        do {
            let v: String = try await xpcCall { done in
                proxy.getOpenclawVersion(username: username) { version in
                    done(version)
                }
            }
            return v.isEmpty ? nil : v
        } catch { return nil }
    }

    // MARK: - 用户环境初始化

    private static func hasLocalNodeBinary(username: String) -> Bool {
        let userNode = "/Users/\(username)/.brew/bin/node"
        return FileManager.default.isExecutableFile(atPath: userNode)
    }

    private func shouldSuggestNodeRepair(username: String, startupErrorMessage: String) async -> Bool {
        let nodeInstalledProbe = await nodeInstalledIfControlReachable(username: username)
        return GatewayStartFailureClassifier.shouldSuggestNodeRepair(
            startupErrorMessage: startupErrorMessage,
            nodeInstalledProbe: nodeInstalledProbe
        )
    }

    private func nodeInstalledIfControlReachable(username: String) async -> Bool? {
        guard controlProxy != nil else { return nil }
        return await isNodeInstalled(username: username)
    }

    /// 安装 Node.js（输出实时写入 /tmp/clawdhome-init-<username>.log）
    func installNode(username: String, nodeDistURL: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.installNode(username: username, nodeDistURL: nodeDistURL) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 指定用户 Node.js 是否已安装就绪（用于控制 npm 相关操作）
    /// 注意：保留手动兜底机制，兼容旧版 Helper 回调丢失的情况
    func isNodeInstalled(username: String) async -> Bool {
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

            proxy.isNodeInstalled(username: username) { value in
                resolve(value)
            }

            // 兼容旧版 Helper（未实现 isNodeInstalled 回调）导致的悬挂
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                resolve(Self.hasLocalNodeBinary(username: username))
            }
        }
    }

    /// 复用初始化流程中的基础环境修复步骤，用于老环境自愈：
    /// 1) 修复 ~/.brew 权限（best effort）
    /// 2) 安装/修复 node/npm/npx 到用户私有目录
    /// 3) 修复 ~/.npm-global 与 shell 环境
    /// 4) 运行体检修复（权限归属与应用层审计）
    func repairBaseEnvironmentForStartup(username: String, nodeDistURL: String) async throws {
        // 1. 权限修复为 best-effort，不阻断后续核心修复
        try? await repairHomebrewPermission(username: username)

        // 2. node/npm/npx 是 Gateway 启动硬依赖，失败即抛错
        try await installNode(username: username, nodeDistURL: nodeDistURL)

        // 3. npm 全局目录与 shell 环境
        try await setupNpmEnv(username: username)

        // 4. 复用现有体检修复逻辑，修正历史权限/归属问题；失败不阻断启动
        _ = await runHealthCheck(username: username, fix: true)
    }

    /// 读取 Xcode/CLT 环境状态
    func getXcodeEnvStatus() async -> XcodeEnvStatus? {
        guard let proxy = controlProxy else { return nil }
        do {
            let json: String = try await xpcCall { done in
                proxy.getXcodeEnvStatus { done($0) }
            }
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(XcodeEnvStatus.self, from: data)
        } catch { return nil }
    }

    /// 触发 Xcode Command Line Tools 安装（系统弹窗）
    func installXcodeCommandLineTools() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.installXcodeCommandLineTools { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.trigger_install_failed", fallback: "触发安装失败")) }
    }

    /// 接受 Xcode license（非交互）
    func acceptXcodeLicense() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.acceptXcodeLicense { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.accept_license_failed", fallback: "接受 license 失败")) }
    }

    /// 初始化 npm 全局目录（~/.npm-global）并配置 shell 环境
    func setupNpmEnv(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.setupNpmEnv(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 修复普通用户 Homebrew 安装权限（安装到 ~/.brew，并写入环境变量）
    func repairHomebrewPermission(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.repairHomebrewPermission(username: username) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 设置 npm 安装源（写入用户级 ~/.npmrc）
    func setNpmRegistry(username: String, registry: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setNpmRegistry(username: username, registry: registry) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取 npm 安装源（优先用户级配置）
    func getNpmRegistry(username: String) async -> String {
        guard let proxy = controlProxy else { return NpmRegistryOption.npmOfficial.rawValue }
        do {
            return try await xpcCall { done in
                proxy.getNpmRegistry(username: username) { done($0) }
            }
        } catch { return NpmRegistryOption.npmOfficial.rawValue }
    }

    /// 取消指定用户的初始化命令
    func cancelInit(username: String) async {
        guard let proxy = controlProxy else { return }
        _ = try? await xpcCall { (done: @escaping (Bool) -> Void) in
            proxy.cancelInit(username: username) { done($0) }
        }
    }

    /// 保存向导进度 JSON（写入 /var/lib/clawdhome/<username>-init.json）
    func saveInitState(username: String, json: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.saveInitState(username: username, json: json) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取向导进度 JSON（文件不存在返回空字符串）
    func loadInitState(username: String) async -> String {
        guard let proxy = controlProxy else { return "" }
        do {
            return try await xpcCall { done in
                proxy.loadInitState(username: username) { done($0) }
            }
        } catch { return "" }
    }

    /// 重置用户的 openclaw 运行环境（删除 ~/.npm-global 和 ~/.openclaw）
    func resetUserEnv(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.resetUserEnv(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 备份与恢复

    func backupGlobal(destinationDir: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.backupGlobal(destinationDir: destinationDir) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func backupShrimp(username: String, destinationDir: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.backupShrimp(username: username, destinationDir: destinationDir) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func backupAllV2(destinationDir: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.backupAll(destinationDir: destinationDir) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func restoreGlobal(sourcePath: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.restoreGlobal(sourcePath: sourcePath) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func restoreShrimp(username: String, sourcePath: String, backupBeforeRestore: Bool) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.restoreShrimp(username: username, sourcePath: sourcePath, backupBeforeRestore: backupBeforeRestore) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func getBackupConfig() async throws -> BackupConfig {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let json: String? = try await xpcCall { done in
            proxy.getBackupConfig { json in done(json) }
        }
        guard let json, let data = json.data(using: .utf8) else { return .default }
        return (try? JSONDecoder().decode(BackupConfig.self, from: data)) ?? .default
    }

    func setBackupConfig(_ config: BackupConfig) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setBackupConfig(configJSON: json) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func listBackups(destinationDir: String) async throws -> [BackupListEntry] {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let json: String? = try await xpcCall { done in
            proxy.listBackups(destinationDir: destinationDir) { json in done(json) }
        }
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BackupListEntry].self, from: data)) ?? []
    }

    func deleteBackupFile(filePath: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.deleteBackup(filePath: filePath) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func pruneBackups(destinationDir: String, maxCount: Int) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.pruneBackups(destinationDir: destinationDir, maxCount: maxCount) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    /// 读取最近一次定时备份结果
    func getLastBackupResult() async throws -> BackupResult? {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let json: String? = try await xpcCall { done in
            proxy.getLastBackupResult { json in done(json) }
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(BackupResult.self, from: data)
    }

    /// 扫描来源虾可克隆项与大小
    func scanCloneClaw(username: String) async throws -> CloneScanResult {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (json, err): (String, String?) = try await xpcCall(timeout: .seconds(20)) { done in
            proxy.scanCloneClaw(username: username) { json, err in
                done((json, err))
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
        let (ok, resultJSON, err): (Bool, String, String?) = try await xpcCall(timeout: .seconds(240)) { done in
            proxy.cloneClaw(requestJSON: reqJSON) { ok, json, err in
                done((ok, json, err))
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
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.cancelCloneClaw(targetUsername: trimmed) { ok, err in
                done((ok, err))
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
        do {
            let status: String? = try await xpcCall { done in
                proxy.getCloneClawStatus(targetUsername: trimmed) { status in
                    done(status)
                }
            }
            let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalized.isEmpty ? nil : normalized
        } catch { return nil }
    }

    /// 返回用户 gateway 的访问 URL
    func getGatewayURL(username: String) async -> String {
        guard let proxy = gatewayProxy else { return "" }
        do {
            return try await xpcCall { done in
                proxy.getGatewayURL(username: username) { done($0) }
            }
        } catch { return "" }
    }

    // MARK: - 仪表盘

    /// 获取仪表盘快照，使用独立连接避免阻塞控制通道
    func getDashboardSnapshot() async -> DashboardSnapshot? {
        guard let proxy = dashboardProxy else { return nil }
        do {
            let json: String = try await xpcCall { done in
                proxy.getDashboardSnapshot { done($0) }
            }
            guard let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        } catch {
            if !(error is HelperError) {
                let preview = "\(error)".prefix(240)
                appLog("[dashboard] snapshot decode failed: \(preview)", level: .warn)
            }
            return nil
        }
    }

    func getCachedAppUpdateState() async -> AppUpdateState? {
        guard let proxy = dashboardProxy else { return nil }
        do {
            let json: String? = try await xpcCall { done in
                proxy.getCachedAppUpdateState { done($0) }
            }
            guard let json, let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(AppUpdateState.self, from: data)
        } catch {
            if !(error is HelperError) {
                let preview = "\(error)".prefix(240)
                appLog("[app-update] cached state decode failed: \(preview)", level: .warn)
            }
            return nil
        }
    }

    /// 获取当前连接列表（无连接或未连接时返回空数组）
    func getConnections() async -> [ConnectionInfo] {
        guard let proxy = dashboardProxy else { return [] }
        do {
            let json: String? = try await xpcCall { done in
                proxy.getConnections { done($0) }
            }
            guard let json, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ConnectionInfo].self, from: data)) ?? []
        } catch { return [] }
    }

    // MARK: - 网络策略

    func getShrimpNetworkPolicy(username: String) async -> ShrimpNetworkPolicy {
        guard let proxy = controlProxy else { return ShrimpNetworkPolicy() }
        do {
            let json: String? = try await xpcCall { done in
                proxy.getShrimpNetworkPolicy(username: username) { done($0) }
            }
            guard let json, let data = json.data(using: .utf8) else { return ShrimpNetworkPolicy() }
            return (try? JSONDecoder().decode(ShrimpNetworkPolicy.self, from: data)) ?? ShrimpNetworkPolicy()
        } catch { return ShrimpNetworkPolicy() }
    }

    func setShrimpNetworkPolicy(username: String, policy: ShrimpNetworkPolicy) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        guard let data = try? JSONEncoder().encode(policy),
              let json = String(data: data, encoding: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.serialization_failed", fallback: "序列化失败"))
        }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setShrimpNetworkPolicy(username: username, policyJSON: json) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func getGlobalNetworkConfig() async -> GlobalNetworkConfig {
        guard let proxy = controlProxy else { return GlobalNetworkConfig() }
        do {
            let json: String? = try await xpcCall { done in
                proxy.getGlobalNetworkConfig { done($0) }
            }
            guard let json, let data = json.data(using: .utf8) else { return GlobalNetworkConfig() }
            return (try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data)) ?? GlobalNetworkConfig()
        } catch { return GlobalNetworkConfig() }
    }

    func setGlobalNetworkConfig(_ config: GlobalNetworkConfig) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else {
            throw HelperError.operationFailed(L10n.k("services.helper_client.serialization_failed", fallback: "序列化失败"))
        }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setGlobalNetworkConfig(configJSON: json) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 配置（直接读写 JSON，零 CLI 开销）

    /// 直接读取 ~/.openclaw/openclaw.json 并解析为字典（毫秒级，不启动 CLI）
    func getConfigJSON(username: String) async -> [String: Any] {
        guard let proxy = controlProxy else { return [:] }
        do {
            let json: String = try await xpcCall { done in
                proxy.getConfigJSON(username: username) { done($0) }
            }
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return dict
        } catch { return [:] }
    }

    /// 直接写入 ~/.openclaw/openclaw.json 指定 dot-path（不启动 CLI）
    /// value 必须是 JSON-serializable（String / [String] / Bool / Number 等）
    func setConfigDirect(username: String, path: String, value: Any) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let valueJSON = try serializeJSONValue(value)
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.setConfigDirect(username: username, path: path, valueJSON: valueJSON) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 将代理环境变量注入到用户级系统环境（shell 配置 + launchctl user 域）
    func applySystemProxyEnv(username: String, enabled: Bool, proxyURL: String, noProxy: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.applySystemProxyEnv(username: username, enabled: enabled, proxyURL: proxyURL, noProxy: noProxy) { ok, msg in
                done((ok, msg))
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
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
            proxy.applyProxySettings(
                username: username,
                enabled: enabled,
                proxyURL: proxyURL,
                noProxy: noProxy,
                restartGatewayIfRunning: restartGatewayIfRunning
            ) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 新用户创建后应用"当前设置页保存的代理配置"
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
        do {
            return try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
                proxy.runModelCommand(username: username, argsJSON: argsJSON) { ok, out in
                    done((ok, out))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    // MARK: - 通用 openclaw 命令（经由 Helper，无需密码）

    /// 以指定用户身份运行 openclaw 任意子命令，返回 (success, output)
    func runOpenclawCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        do {
            return try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
                proxy.runOpenclawCommand(username: username, argsJSON: argsJSON) { ok, out in
                    done((ok, out))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    // MARK: - Pairing 配对管理

    /// 运行 openclaw pairing 子命令，返回 (success, output)
    func runPairingCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        do {
            return try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
                proxy.runPairingCommand(username: username, argsJSON: argsJSON) { ok, out in
                    done((ok, out))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    /// 运行飞书独立配置命令（当前 install-only）：npx -y @larksuite/openclaw-lark-tools install
    func runFeishuOnboardCommand(username: String, args: [String]) async -> (Bool, String) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let argsJSON = (try? String(data: JSONEncoder().encode(args), encoding: .utf8)) ?? "[]"
        appLog("[feishu] request start @\(username) args=\(args.joined(separator: " "))")
        do {
            let result: (Bool, String) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
                proxy.runFeishuOnboardCommand(username: username, argsJSON: argsJSON) { ok, out in
                    if ok {
                        appLog("[feishu] request success @\(username) outputBytes=\(out.utf8.count)")
                    } else {
                        appLog("[feishu] request failed @\(username): \(out)", level: .error)
                    }
                    done((ok, out))
                }
            }
            return result
        } catch {
            appLog("[feishu] request timeout @\(username)", level: .error)
            return (false, error.localizedDescription)
        }
    }

    /// 启动通用维护终端会话（Helper 侧 PTY）
    func startMaintenanceTerminalSession(username: String, command: [String]) async -> (Bool, String, String?) {
        guard let proxy = controlProxy else { return (false, "", L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let commandJSON = (try? String(data: JSONEncoder().encode(command), encoding: .utf8)) ?? "[]"
        appLog("[maintenance] session start request @\(username) cmd=\(command.joined(separator: " "))")
        do {
            return try await xpcCall { done in
                proxy.startMaintenanceTerminalSession(
                    username: username,
                    commandJSON: commandJSON
                ) { ok, sessionID, err in
                    if ok {
                        appLog("[maintenance] session started @\(username) session=\(sessionID)")
                    } else {
                        appLog("[maintenance] session start failed @\(username): \(err ?? "unknown")", level: .error)
                    }
                    done((ok, sessionID, err))
                }
            }
        } catch { return (false, "", error.localizedDescription) }
    }

    /// 轮询通用维护终端会话输出
    func pollMaintenanceTerminalSession(sessionID: String, fromOffset: Int64) async
    -> (Bool, String, Int64, Bool, Int32, String?) {
        guard let proxy = controlProxy else {
            return (false, "", fromOffset, true, -1, L10n.k("services.helper_client.disconnected", fallback: "未连接"))
        }
        do {
            return try await xpcCall(timeout: .seconds(10)) { done in
                proxy.pollMaintenanceTerminalSession(sessionID: sessionID, fromOffset: fromOffset) {
                    ok, chunk, nextOffset, exited, exitCode, err in
                    done((ok, chunk, nextOffset, exited, exitCode, err))
                }
            }
        } catch {
            return (false, "", fromOffset, true, -1, error.localizedDescription)
        }
    }

    /// 向通用维护终端会话发送输入
    func sendMaintenanceTerminalSessionInput(sessionID: String, input: Data) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        let base64 = input.base64EncodedString()
        do {
            return try await xpcCall { done in
                proxy.sendMaintenanceTerminalSessionInput(sessionID: sessionID, inputBase64: base64) { ok, err in
                    done((ok, err))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    /// 调整通用维护终端会话终端尺寸
    func resizeMaintenanceTerminalSession(sessionID: String, cols: Int, rows: Int) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        do {
            return try await xpcCall { done in
                proxy.resizeMaintenanceTerminalSession(sessionID: sessionID, cols: Int32(cols), rows: Int32(rows)) { ok, err in
                    done((ok, err))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    /// 终止通用维护终端会话
    func terminateMaintenanceTerminalSession(sessionID: String) async -> (Bool, String?) {
        guard let proxy = controlProxy else { return (false, L10n.k("services.helper_client.disconnected", fallback: "未连接")) }
        do {
            return try await xpcCall { done in
                proxy.terminateMaintenanceTerminalSession(sessionID: sessionID) { ok, err in
                    done((ok, err))
                }
            }
        } catch { return (false, error.localizedDescription) }
    }

    /// 获取模型状态（直接读取 openclaw.json，零 CLI 开销）
    func getModelsStatus(username: String) async -> ModelsStatus? {
        let config = await getConfigJSON(username: username)
        guard !config.isEmpty else { return nil }
        // agents.defaults.model.{primary, fallbacks}
        // OpenClaw schema 字段名为 "fallbacks"（复数）
        let model = (config["agents"] as? [String: Any])
            .flatMap { $0["defaults"] as? [String: Any] }
            .flatMap { $0["model"] as? [String: Any] }
        let primary = model?["primary"] as? String
        let fallbacks: [String]
        if let arr = model?["fallbacks"] as? [String] {
            fallbacks = arr
        } else if let single = model?["fallbacks"] as? String, !single.isEmpty {
            fallbacks = [single]
        } else {
            fallbacks = []
        }
        // meta.lastTouchedVersion — openclaw 每次修改配置时写入的版本号
        let version = (config["meta"] as? [String: Any])?["lastTouchedVersion"] as? String
        return ModelsStatus(defaultModel: primary, resolvedDefault: primary, fallbacks: fallbacks, imageModel: nil, imageFallbacks: [], installedVersion: version)
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
    func runHealthCheck(username: String, fix: Bool) async -> DiagnosticsResult? {
        guard let proxy = controlProxy else { return nil }
        do {
            let (_, json): (Bool, String) = try await xpcCall(timeout: HelperClient.xpcCommandTimeout) { done in
                proxy.runHealthCheck(username: username, fix: fix) { ok, json in
                    done((ok, json))
                }
            }
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DiagnosticsResult.self, from: data)
        } catch { return nil }
    }

    // MARK: - 统一诊断

    /// 对指定用户执行统一诊断（环境 + 权限 + 配置 + 安全 + Gateway + 网络）
    func runDiagnostics(username: String, fix: Bool) async -> DiagnosticsResult? {
        guard let proxy = controlProxy else { return nil }
        do {
            let (_, json): (Bool, String) = try await xpcCall(timeout: .seconds(60)) { done in
                proxy.runDiagnostics(username: username, fix: fix) { ok, json in
                    done((ok, json))
                }
            }
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DiagnosticsResult.self, from: data)
        } catch { return nil }
    }

    /// 单组诊断（逐组调用，实时展示进度）
    func runDiagnosticGroup(username: String, group: DiagnosticGroup, fix: Bool) async -> [DiagnosticItem] {
        guard let proxy = controlProxy else { return [] }
        do {
            let (_, json): (Bool, String) = try await xpcCall(timeout: .seconds(30)) { done in
                proxy.runDiagnosticGroup(username: username, groupName: group.rawValue, fix: fix) { ok, json in
                    done((ok, json))
                }
            }
            guard let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([DiagnosticItem].self, from: data)) ?? []
        } catch { return [] }
    }
    
    // MARK: - Helper 生命周期

    func getVersion() async throws -> String {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        return try await xpcCall { done in
            proxy.getVersion { version in done(version) }
        }
    }

    /// Helper 健康探针（5 秒超时的 getVersion 调用）
    /// 返回 .connected(version) / .unresponsive / .disconnected
    /// 当健康状态异常时同步更新 isConnected，触发顶部横幅显示
    func probeHealth() async -> HelperHealthState {
        guard let proxy = controlProxy else { return .disconnected }
        do {
            let version: String = try await xpcCall(timeout: .seconds(5)) { done in
                proxy.getVersion { done($0) }
            }
            return .connected(version: version)
        } catch {
            // 超时 = Helper 进程在但不响应 XPC
            return .unresponsive
        }
    }

    /// 请求 Helper 自行重启（exit(0) → launchd KeepAlive 自动拉起）
    func requestHelperRestart() async -> Bool {
        guard let proxy = controlProxy else { return false }
        do {
            let ok: Bool = try await xpcCall(timeout: .seconds(3)) { done in
                proxy.requestRestart { done($0) }
            }
            if ok {
                // Helper 即将退出，递增世代使旧回调失效，标记断连触发 maintainConnection 重连
                await MainActor.run {
                    connectionGeneration &+= 1
                    isConnected = false
                }
            }
            return ok
        } catch {
            return false
        }
    }

    // MARK: - 文件管理

    /// 列出指定用户 home 下 relativePath 的内容
    func listDirectory(username: String, relativePath: String, showHidden: Bool = false) async throws -> [FileEntry] {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = try await xpcCall { done in
            proxy.listDirectory(username: username, relativePath: relativePath, showHidden: showHidden) { j, e in
                done((j, e))
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
        do {
            let (data, _): (Data?, String?) = try await xpcCall { done in
                proxy.readSystemLog(name: name) { d, e in done((d, e)) }
            }
            return data ?? Data()
        } catch { return Data() }
    }

    /// 读取文件内容（Helper 侧限制 10MB）
    func readFile(username: String, relativePath: String) async throws -> Data {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (data, err): (Data?, String?) = try await xpcCall { done in
            proxy.readFile(username: username, relativePath: relativePath) { d, e in
                done((d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data else { throw HelperError.operationFailed(L10n.k("services.helper_client.file", fallback: "无文件数据")) }
        return data
    }

    /// 读取文件尾部内容（用于大日志文件，不受 readFile 10MB 限制）
    func readFileTail(username: String, relativePath: String, maxBytes: Int) async throws -> Data {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (data, err): (Data?, String?) = try await xpcCall { done in
            proxy.readFileTail(username: username, relativePath: relativePath, maxBytes: maxBytes) { d, e in
                done((d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        guard let data else { throw HelperError.operationFailed(L10n.k("services.helper_client.file", fallback: "无文件数据")) }
        return data
    }

    /// 写文件（覆盖）
    func writeFile(username: String, relativePath: String, data: Data) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.writeFile(username: username, relativePath: relativePath, data: data) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.write_failed", fallback: "写入失败")) }
    }

    /// 删除文件或目录
    func deleteItem(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.deleteItem(username: username, relativePath: relativePath) { ok, e in
                done((ok, e))
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
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.syncSecrets(
                username: username,
                secretsJSON: secretsPayload,
                authProfilesJSON: authProfilesPayload
            ) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.secrets_sync_failed", fallback: "secrets 同步失败")) }
    }

    /// 通知虾的 openclaw 热加载 secrets
    func reloadSecrets(username: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.reloadSecrets(username: username) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.secrets_reload_failed", fallback: "secrets reload 失败")) }
    }

    /// 新建目录
    func createDirectory(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.createDirectory(username: username, relativePath: relativePath) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.create_directory_failed", fallback: "创建目录失败")) }
    }

    /// 重命名文件或目录
    func renameItem(username: String, relativePath: String, newName: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.renameItem(username: username, relativePath: relativePath, newName: newName) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.rename_failed", fallback: "重命名失败")) }
    }

    /// 解压压缩包到同目录
    func extractArchive(username: String, relativePath: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.extractArchive(username: username, relativePath: relativePath) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.unzip_failed", fallback: "解压失败")) }
    }

    // MARK: - 记忆搜索

    /// 在用户的 memory SQLite 里全文搜索，返回匹配片段列表
    func searchMemory(username: String, query: String, limit: Int = 20) async throws -> [MemoryChunkResult] {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = try await xpcCall { done in
            proxy.searchMemory(username: username, query: query, limit: limit) { j, e in
                done((j, e))
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
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.changeUserPassword(username: username, newPassword: newPassword) { ok, msg in
                done((ok, msg))
            }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.password_change_failed", fallback: "密码修改失败")) }
    }

    // MARK: - 屏幕共享

    /// 查询系统屏幕共享是否正在运行
    func isScreenSharingEnabled() async -> Bool {
        guard let proxy = controlProxy else { return false }
        do {
            return try await xpcCall { done in
                proxy.isScreenSharingEnabled { done($0) }
            }
        } catch { return false }
    }

    /// 启用并启动屏幕共享守护进程
    func enableScreenSharing() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.enableScreenSharing { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.enable_screen_sharing_failed", fallback: "启用屏幕共享失败")) }
    }

    // MARK: - 本地 AI — omlx

    func installOmlx() async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.installOmlx { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func getLocalLLMStatus() async -> LocalServiceStatus {
        guard let proxy = controlProxy else {
            return LocalServiceStatus(isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
        }
        do {
            let json: String = try await xpcCall { done in
                proxy.getLocalLLMStatus { done($0) }
            }
            return (try? JSONDecoder().decode(LocalServiceStatus.self, from: Data(json.utf8)))
                ?? LocalServiceStatus(isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
        } catch {
            return LocalServiceStatus(isInstalled: false, isRunning: false, pid: -1, currentModelId: "", port: 18800)
        }
    }

    func listLocalModels() async -> [LocalModelInfo] {
        guard let proxy = controlProxy else { return [] }
        do {
            let json: String = try await xpcCall { done in
                proxy.listLocalModels { done($0) }
            }
            return (try? JSONDecoder().decode([LocalModelInfo].self, from: Data(json.utf8))) ?? []
        } catch { return [] }
    }

    func startLocalLLM() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.startLocalLLM { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func stopLocalLLM() async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.stopLocalLLM { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func downloadLocalModel(_ modelId: String) async throws {
        guard let proxy = installProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall(timeout: HelperClient.xpcInstallTimeout) { done in
            proxy.downloadLocalModel(modelId) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    func deleteLocalModel(_ modelId: String) async throws {
        guard let proxy = controlProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.deleteLocalModel(modelId) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 进程管理

    func getProcessListSnapshot(username: String) async -> ProcessListSnapshot {
        guard let proxy = processProxy else {
            return ProcessListSnapshot(entries: [], portsLoading: false, updatedAt: Date().timeIntervalSince1970)
        }
        do {
            let json: String = try await xpcCall { done in
                proxy.getProcessListSnapshot(username: username) { done($0) }
            }
            if let snapshot = try? JSONDecoder().decode(ProcessListSnapshot.self, from: Data(json.utf8)) {
                return snapshot
            }
            // 兼容旧 Helper：仍可能返回 [ProcessEntry]
            let fallbackEntries = (try? JSONDecoder().decode([ProcessEntry].self, from: Data(json.utf8))) ?? []
            return ProcessListSnapshot(entries: fallbackEntries, portsLoading: false, updatedAt: Date().timeIntervalSince1970)
        } catch {
            return ProcessListSnapshot(entries: [], portsLoading: false, updatedAt: Date().timeIntervalSince1970)
        }
    }

    func getProcessList(username: String) async -> [ProcessEntry] {
        await getProcessListSnapshot(username: username).entries
    }

    func getProcessDetail(pid: Int32) async -> ProcessDetail? {
        guard let proxy = processProxy else { return nil }
        do {
            let json: String = try await xpcCall { done in
                proxy.getProcessDetail(pid: pid) { done($0) }
            }
            return try? JSONDecoder().decode(ProcessDetail.self, from: Data(json.utf8))
        } catch { return nil }
    }

    func killProcess(pid: Int32, signal: Int32) async throws {
        guard let proxy = processProxy else { throw HelperError.notConnected }
        let (ok, msg): (Bool, String?) = try await xpcCall { done in
            proxy.killProcess(pid: pid, signal: signal) { ok, msg in done((ok, msg)) }
        }
        if !ok { throw HelperError.operationFailed(msg ?? L10n.k("services.helper_client.unknown", fallback: "未知错误")) }
    }

    // MARK: - 角色定义 Git 管理

    /// 初始化 workspace git repo（幂等，Tab 出现时自动调用）
    func initPersonaGitRepo(username: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.initPersonaGitRepo(username: username) { ok, e in done((ok, e)) }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.git_init_failed", fallback: "git 初始化失败")) }
    }

    /// 提交单个角色文件（writeFile 成功后调用）
    func commitPersonaFile(username: String, filename: String, message: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.commitPersonaFile(username: username, filename: filename, message: message) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.git_commit_failed", fallback: "git 提交失败")) }
    }

    /// 获取角色文件 git 历史（走独立只读连接，避免阻塞写操作队列）
    func getPersonaFileHistory(username: String, filename: String) async throws -> [PersonaCommit] {
        guard let proxy = personaReadProxy else { throw HelperError.notConnected }
        let (json, err): (String?, String?) = try await xpcCall { done in
            proxy.getPersonaFileHistory(username: username, filename: filename) { j, e in
                done((j, e))
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
        let (diff, err): (String?, String?) = try await xpcCall { done in
            proxy.getPersonaFileDiff(username: username, filename: filename, commitHash: commitHash) { d, e in
                done((d, e))
            }
        }
        if let err { throw HelperError.operationFailed(err) }
        return diff ?? ""
    }

    /// 将文件回滚到指定 commit（走文件写操作连接）
    func restorePersonaFileToCommit(username: String, filename: String, commitHash: String) async throws {
        guard let proxy = fileProxy else { throw HelperError.notConnected }
        let (ok, err): (Bool, String?) = try await xpcCall { done in
            proxy.restorePersonaFileToCommit(username: username, filename: filename, commitHash: commitHash) { ok, e in
                done((ok, e))
            }
        }
        if !ok { throw HelperError.operationFailed(err ?? L10n.k("services.helper_client.restore_failed", fallback: "回滚失败")) }
    }
}

// MARK: - Helper 健康状态
enum HelperHealthState: Equatable {
    /// Helper 正常响应，附带版本号
    case connected(version: String)
    /// XPC 连接存在但 Helper 不响应（可能死锁/卡死）
    case unresponsive
    /// XPC 连接不存在（Helper 未安装或进程已退出）
    case disconnected

    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
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
