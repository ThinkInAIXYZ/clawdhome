// ClawdHomeHelper/main.swift
// ClawdHomeHelper LaunchDaemon — root 权限常驻服务
// 接受来自 ClawdHome.app 的 XPC 请求，代理执行跨用户操作

import Foundation
import Security

// MARK: - Helper 实现

final class ClawdHomeHelperImpl: NSObject, ClawdHomeHelperProtocol {
    let maintenanceSessionLock = NSLock()
    var maintenanceSessions: [String: MaintenanceTerminalSession] = [:]
    let cloneControlLock = NSLock()
    var runningCloneTargets: Set<String> = []
    var cancelledCloneTargets: Set<String> = []
    var cloneStatusByTarget: [String: String] = [:]
    /// PTY 会话空闲超时（10 分钟无 poll 或进程已退出 60 秒后自动清理）
    private var sessionCleanupTimer: DispatchSourceTimer?

    override init() {
        super.init()
        startSessionCleanupTimer()
    }

    /// 定期清理空闲/已退出的 PTY 会话，防止 App 崩溃后内存泄漏
    private func startSessionCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer.schedule(deadline: .now() + 30, repeating: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.sweepStaleSessions()
        }
        sessionCleanupTimer = timer
        timer.resume()
    }

    private func sweepStaleSessions() {
        let now = Date()
        let idleTimeout: TimeInterval = 600   // 10 分钟无 poll
        let exitedTimeout: TimeInterval = 60  // 已退出 60 秒

        maintenanceSessionLock.lock()
        let snapshot = maintenanceSessions
        maintenanceSessionLock.unlock()

        var toRemove: [String] = []
        for (id, session) in snapshot {
            let idleSeconds = now.timeIntervalSince(session.lastPollTime)
            if session.exited && idleSeconds > exitedTimeout {
                toRemove.append(id)
                helperLog("[maintenance] auto-cleanup exited session id=\(id) user=\(session.username) idle=\(Int(idleSeconds))s")
            } else if !session.exited && idleSeconds > idleTimeout {
                session.terminate()
                toRemove.append(id)
                helperLog("[maintenance] auto-cleanup idle session id=\(id) user=\(session.username) idle=\(Int(idleSeconds))s")
            }
        }

        if !toRemove.isEmpty {
            maintenanceSessionLock.lock()
            for id in toRemove {
                maintenanceSessions.removeValue(forKey: id)
            }
            maintenanceSessionLock.unlock()
        }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
    }

    func requestRestart(withReply reply: @escaping (Bool) -> Void) {
        helperLog("[lifecycle] restart requested by app — exiting for launchd respawn", level: .warn)
        reply(true)
        // 延迟 0.5 秒退出，让 reply 有时间送达 App
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }

    // MARK: - 跨扩展共享工具方法

    func runAsUser(username: String,
                   nodePath: String,
                   command: String,
                   args: [String]) throws -> String {
        let home = "/Users/\(username)"
        let npmGlobalDir = "\(home)/.npm-global"
        let fullArgs = [
            "-n", "-u", username, "-H",
            "/usr/bin/env",
            "HOME=\(home)",
            "PATH=\(nodePath)",
            "NPM_CONFIG_PREFIX=\(npmGlobalDir)",
            "npm_config_prefix=\(npmGlobalDir)",
            command,
        ] + args
        return try run("/usr/bin/sudo", args: fullArgs)
    }

    func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    // MARK: - 克隆控制（跨扩展访问）

    func markCloneStarted(targetUsername: String) -> Bool {
        cloneControlLock.lock()
        defer { cloneControlLock.unlock() }
        if runningCloneTargets.contains(targetUsername) {
            return false
        }
        runningCloneTargets.insert(targetUsername)
        cancelledCloneTargets.remove(targetUsername)
        return true
    }

    func finishClone(targetUsername: String) {
        cloneControlLock.lock()
        runningCloneTargets.remove(targetUsername)
        cancelledCloneTargets.remove(targetUsername)
        cloneControlLock.unlock()
    }

    func requestCloneCancel(targetUsername: String) -> Bool {
        cloneControlLock.lock()
        defer { cloneControlLock.unlock() }
        guard runningCloneTargets.contains(targetUsername) else { return false }
        cancelledCloneTargets.insert(targetUsername)
        return true
    }

    func assertCloneNotCancelled(targetUsername: String) throws {
        cloneControlLock.lock()
        let cancelled = cancelledCloneTargets.contains(targetUsername)
        cloneControlLock.unlock()
        if cancelled {
            throw CloneClawManagerError.cloneCancelled(targetUsername)
        }
    }

    func setCloneStatus(targetUsername: String, status: String) {
        cloneControlLock.lock()
        cloneStatusByTarget[targetUsername] = status
        cloneControlLock.unlock()
    }
}

// MARK: - XPC 监听器

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// 每个 PID 的连接序号（仅递增）和活跃连接数
    private var seqByPID: [Int32: Int] = [:]
    private var activeByPID: [Int32: Int] = [:]
    private let lock = NSLock()

    /// 根据同一 PID 的连接序号推断连接用途（App 按固定顺序创建）
    private static let channelLabels = ["control", "dashboard", "install", "file", "process", "personaRead"]

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        // 如果该 PID 没有活跃连接（首次或全部断开后重连），重置序号
        lock.lock()
        if activeByPID[pid, default: 0] == 0 {
            seqByPID[pid] = 0
        }
        let seq = seqByPID[pid, default: 0]
        seqByPID[pid] = seq + 1
        activeByPID[pid, default: 0] += 1
        lock.unlock()
        let channel = seq < Self.channelLabels.count ? Self.channelLabels[seq] : "#\(seq)"

        helperLog("[xpc] incoming pid=\(pid) channel=\(channel)")
        guard Self.isCallerAuthorized(connection) else {
            helperLog("[xpc] rejected pid=\(pid) channel=\(channel)", level: .warn)
            lock.lock()
            activeByPID[pid, default: 1] -= 1
            lock.unlock()
            return false
        }
        connection.invalidationHandler = { [weak self] in
            helperLog("[xpc] invalidated pid=\(pid) channel=\(channel)")
            self?.lock.lock()
            self?.activeByPID[pid, default: 1] -= 1
            self?.lock.unlock()
        }
        connection.interruptionHandler = {
            helperLog("[xpc] interrupted pid=\(pid) channel=\(channel)", level: .warn)
        }
        connection.exportedInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        connection.exportedObject = ClawdHomeHelperImpl()
        connection.resume()
        helperLog("[xpc] accepted pid=\(pid) channel=\(channel)")
        return true
    }

    /// 校验调用方是否有权使用 Helper
    /// 两道检查均须通过：
    ///   1. 调用方进程属于 admin 组（纯 sysctl + getgrouplist，无子进程，DEBUG + Release 均生效）
    ///   2. 代码签名为 ClawdHome.app（DEBUG 跳过，Release 用 auditToken 强制校验）
    private static func isCallerAuthorized(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        // 第一层：调用方必须属于 admin 组
        guard let uid = Self.uid(ofPID: pid) else {
            helperLog("[xpc] auth reject pid=\(pid): uid lookup failed", level: .warn)
            return false
        }
        guard Self.isAdminUID(uid) else {
            helperLog("[xpc] auth reject pid=\(pid) uid=\(uid): not in admin group", level: .warn)
            return false
        }

        #if !DEBUG
        // 第二层（仅 Release）：校验调用方的代码签名
        // 使用 audit token（不可伪造）而非 PID（有 TOCTOU 风险）
        guard Self.isCodeSignatureValid(connection: connection, pid: pid) else {
            return false
        }
        #endif

        return true
    }

    /// 使用 audit token 校验调用方的代码签名
    /// 要求：bundle ID = ai.clawdhome.mac，Team ID = Y7P5QLKLYG
    private static func isCodeSignatureValid(connection: NSXPCConnection, pid: Int32) -> Bool {
        // 通过 KVC 获取 audit token（macOS 10.7+ 可用，非 App Store 分发无影响）
        guard let tokenValue = connection.value(forKey: "auditToken") as? NSValue else {
            helperLog("[xpc] auth reject pid=\(pid): cannot read auditToken", level: .warn)
            return false
        }

        var token = audit_token_t()
        tokenValue.getValue(&token)

        // 用 audit token 获取调用方的 SecCode 引用
        var code: SecCode?
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            helperLog("[xpc] auth reject pid=\(pid): SecCode lookup failed", level: .warn)
            return false
        }

        // 校验签名要求：bundle ID + Team ID
        let requirementStr = """
            identifier "ai.clawdhome.mac" \
            and anchor apple generic \
            and certificate leaf[subject.OU] = "Y7P5QLKLYG"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementStr as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            helperLog("[xpc] auth reject pid=\(pid): invalid requirement string", level: .error)
            return false
        }

        let result = SecCodeCheckValidity(code, [], requirement)
        if result != errSecSuccess {
            helperLog("[xpc] auth reject pid=\(pid): code signature mismatch (OSStatus=\(result))", level: .warn)
            return false
        }

        return true
    }

    /// 通过 sysctl 获取 PID 对应的有效 UID（无子进程，无竞争）
    private static func uid(ofPID pid: Int32) -> uid_t? {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0 else { return nil }
        return kinfo.kp_eproc.e_ucred.cr_uid
    }

    /// 用 getgrouplist() 检查 UID 是否属于 admin 组（gid 80），纯 libc 调用
    private static func isAdminUID(_ uid: uid_t) -> Bool {
        let adminGID: gid_t = 80
        guard let pw = getpwuid(uid) else { return false }
        var groups = [gid_t](repeating: 0, count: 64)
        var count = Int32(groups.count)
        getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count)
        return groups.prefix(Int(count)).contains(adminGID)
    }
}

// MARK: - 入口

let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()

// 注册信号处理器，记录 Helper 被终止的原因
for sig: Int32 in [SIGTERM, SIGINT, SIGQUIT, SIGHUP] {
    signal(sig) { caught in
        let name: String
        switch caught {
        case SIGTERM: name = "SIGTERM"
        case SIGINT:  name = "SIGINT"
        case SIGQUIT: name = "SIGQUIT"
        case SIGHUP:  name = "SIGHUP"
        default:      name = "SIG\(caught)"
        }
        helperLog("[lifecycle] 收到 \(name)，Helper 即将退出", level: .warn)
        exit(caught == SIGTERM ? 0 : 1)
    }
}

// 启动仪表盘数据采集（双频 Timer：1s 动态指标 / 60s 静态指标）
helperLog("Helper 启动")
DashboardCollector.shared.start()
AppUpdateHeartbeatService.shared.start()
// 2 秒后记录首次采集结果（用于诊断连接采集问题）
DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
    let snap = DashboardCollector.shared.currentSnapshot()
    let users = snap.shrimps.map { "\($0.username)(running=\($0.isRunning ?? false))" }.joined(separator: ", ")
    helperLog("[boot] managedUsers: [\(users)]", level: .debug, channel: .diagnostics)
    helperLog("[boot] connections: \(snap.connections.count)", level: .debug, channel: .diagnostics)
    helperLog("[boot] debugLog: \(snap.debugLog ?? "(nil)")", level: .debug, channel: .diagnostics)
}

// 开机自启：等系统稳定后，为所有被管理用户（UID≥500，非 admin）启动 gateway
// 使用 launchctl bootstrap user/<uid>，即使用户未登录也能在其 launchd 域中启动服务
// 若 /var/lib/clawdhome/gateway-autostart-disabled 存在则跳过（用户在设置中关闭了自启）
#if DEBUG
let debugEnableAutostartFlag = "/var/lib/clawdhome/debug-enable-boot-autostart"
if FileManager.default.fileExists(atPath: debugEnableAutostartFlag) {
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 8) {
        bootAutostartGatewaysIfNeeded()
    }
    helperLog("[boot] DEBUG: boot autostart enabled by flag \(debugEnableAutostartFlag)")
} else {
    helperLog("[boot] DEBUG: skip boot autostart (create \(debugEnableAutostartFlag) to enable)")
}

let debugEnableWatchdogFlag = "/var/lib/clawdhome/debug-enable-watchdog"
if FileManager.default.fileExists(atPath: debugEnableWatchdogFlag) {
    GatewayWatchdog.shared.start()
    helperLog("[boot] DEBUG: watchdog enabled by flag \(debugEnableWatchdogFlag)")
} else {
    helperLog("[boot] DEBUG: watchdog disabled (create \(debugEnableWatchdogFlag) to enable)")
}
#else
DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 8) {
    bootAutostartGatewaysIfNeeded()
}
GatewayWatchdog.shared.start()
BackupScheduler.shared.start()
#endif

RunLoop.main.run()
