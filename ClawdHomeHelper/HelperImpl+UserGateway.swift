// ClawdHomeHelper/HelperImpl+UserGateway.swift
// 用户管理 + Gateway 管理 + 自启设置

import Foundation
import SystemConfiguration

extension ClawdHomeHelperImpl {

    // MARK: 用户管理

    func createUser(username: String, fullName: String, password: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户创建 @\(username) (\(fullName))")
        do {
            try UserManager.createUser(username: username, fullName: fullName, password: password)
            // 新建虾默认关闭用户级自启：初始化完成后由用户手动启动，避免后台自动拉起。
            let autostartDisabledPath = ClawdHomeHelperImpl.userAutostartDisabledPath(username: username)
            try? FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome",
                withIntermediateDirectories: true,
                attributes: nil
            )
            FileManager.default.createFile(atPath: autostartDisabledPath, contents: nil)
            reply(true, nil)
        } catch {
            helperLog("用户创建失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func deleteUser(username: String, keepHome: Bool, adminUser: String, adminPassword: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户删除执行 @\(username) keepHome=\(keepHome)")
        var uid: uid_t = 0
        let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        if let consoleUser, consoleUser == username {
            helperLog("用户删除被拒绝 @\(username): 当前登录用户", level: .warn)
            reply(false, "无法删除当前登录的管理员账号 @\(username)")
            return
        }
        do {
            if let uid = try? UserManager.uid(for: username) {
                // 删除前先彻底退出目标用户域，避免 dscl 因活跃会话/进程拒绝删除。
                GatewayIntentionalStopStore.mark(username: username, reason: "delete-user")
                _ = try? GatewayManager.stopGateway(username: username, uid: uid)
                _ = try? ClawdHomeHelper.run("/bin/launchctl", args: ["bootout", "user/\(uid)"])
                Thread.sleep(forTimeInterval: 0.5)
                _ = try? ClawdHomeHelper.run("/usr/bin/pkill", args: ["-9", "-U", "\(uid)"])
            }
            let trimmedAdminUser = adminUser.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAdminPassword = adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            let auth: DirectoryAdminAuth? = (trimmedAdminUser.isEmpty || trimmedAdminPassword.isEmpty)
                ? nil
                : DirectoryAdminAuth(user: trimmedAdminUser, password: trimmedAdminPassword)
            try UserManager.deleteUser(username: username, keepHome: keepHome, auth: auth)
            reply(true, nil)
        } catch {
            helperLog("用户删除失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func prepareDeleteUser(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户删除预清理 @\(username)")
        var uid: uid_t = 0
        let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?
        if let consoleUser, consoleUser == username {
            helperLog("用户删除预清理被拒绝 @\(username): 当前登录用户", level: .warn)
            reply(false, "无法删除当前登录的管理员账号 @\(username)")
            return
        }
        UserManager.prepareDeleteUser(username: username)
        reply(true, nil)
    }

    func cleanupDeletedUser(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户删除后清理 @\(username)")
        UserManager.cleanupDeletedUser(username: username)
        GatewayIntentionalStopStore.clear(username: username)
        reply(true, nil)
    }

    // MARK: Gateway 管理

    func startGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Gateway 启动 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try GatewayManager.startGateway(username: username, uid: uid)
            GatewayIntentionalStopStore.clear(username: username)
            reply(true, nil)
        } catch {
            helperLog("Gateway 启动失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func stopGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Gateway 停止 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            GatewayIntentionalStopStore.mark(username: username, reason: "manual-stop")
            try GatewayManager.stopGateway(username: username, uid: uid)
            reply(true, nil)
        } catch {
            helperLog("Gateway 停止失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func restartGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Gateway 重启 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            GatewayIntentionalStopStore.mark(username: username, reason: "manual-restart", ttlSeconds: 20)
            try GatewayManager.restartGateway(username: username, uid: uid)
            GatewayIntentionalStopStore.clear(username: username)
            reply(true, nil)
        } catch {
            helperLog("Gateway 重启失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func logoutUser(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户注销 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            // 先停止 gateway（忽略错误，可能已停止）
            GatewayIntentionalStopStore.mark(username: username, reason: "logout")
            try? GatewayManager.stopGateway(username: username, uid: uid)
            // bootout 整个用户 launchd 域，关停所有 launchd 管理的服务
            _ = try? ClawdHomeHelper.run(
                "/bin/launchctl",
                args: ["bootout", "user/\(uid)"]
            )
            // 等待 launchd 完成清理，再 kill 残留进程（bootout 不处理非 launchd 进程）
            Thread.sleep(forTimeInterval: 0.5)
            _ = try? ClawdHomeHelper.run("/usr/bin/pkill", args: ["-9", "-U", "\(uid)"])
            reply(true, nil)
        } catch {
            helperLog("用户注销失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Gateway 开机自启设置

    /// 标志文件存在 = 已禁用；不存在 = 启用（默认）
    static let autostartDisabledPath = "/var/lib/clawdhome/gateway-autostart-disabled"

    func setGatewayAutostart(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("全局自启 \(enabled)")
        let path = ClawdHomeHelperImpl.autostartDisabledPath
        if enabled {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try? FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true, attributes: nil)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        reply(true, nil)
    }

    func getGatewayAutostart(withReply reply: @escaping (Bool) -> Void) {
        reply(!FileManager.default.fileExists(atPath: ClawdHomeHelperImpl.autostartDisabledPath))
    }

    func setHelperDebugLogging(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        if setHelperDebugLoggingEnabled(enabled) {
            helperLog("Helper DEBUG 日志开关: \(enabled ? "开启" : "关闭")")
            reply(true, nil)
        } else {
            reply(false, "写入日志调试开关失败")
        }
    }

    func getHelperDebugLogging(withReply reply: @escaping (Bool) -> Void) {
        reply(isHelperDebugLoggingEnabled())
    }

    // MARK: - 用户级自启开关

    static func userAutostartDisabledPath(username: String) -> String {
        "/var/lib/clawdhome/\(username)-autostart-disabled"
    }

    func setUserAutostart(username: String, enabled: Bool,
                          withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户自启 @\(username) \(enabled)")
        let path = ClawdHomeHelperImpl.userAutostartDisabledPath(username: username)
        if enabled {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try? FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true, attributes: nil)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        reply(true, nil)
    }

    func getUserAutostart(username: String, withReply reply: @escaping (Bool) -> Void) {
        reply(!FileManager.default.fileExists(
            atPath: ClawdHomeHelperImpl.userAutostartDisabledPath(username: username)))
    }

    func getGatewayStatus(username: String, withReply reply: @escaping (Bool, Int32) -> Void) {
        // 防止 DirectoryService / launchctl 异常阻塞导致 UI 长时间停留在"检查环境…"
        // 这里做一次硬超时兜底，超时后先返回未运行，后续刷新可再更新真实状态。
        let lock = NSLock()
        var hasReplied = false
        func replyOnce(_ running: Bool, _ pid: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasReplied else { return }
            hasReplied = true
            reply(running, pid)
        }

        let timeoutSeconds: TimeInterval = 6
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let uid = try UserManager.uid(for: username)
                let (running, pid) = GatewayManager.status(username: username, uid: uid)
                replyOnce(running, pid)
            } catch {
                replyOnce(false, -1)
            }
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            replyOnce(false, -1)
        }
    }
}
