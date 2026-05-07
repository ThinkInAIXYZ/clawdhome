// ClawdHomeHelper/Operations/UserManager.swift
// 用 OpenDirectory / dscl 管理 macOS 标准用户账户（需要 root 权限）

import Foundation
import Darwin

struct UserManager {

    // MARK: - 创建用户

    /// 创建一个新的 macOS 标准用户账户
    static func createUser(username: String, fullName: String, password: String) throws {
        let homePath = "/Users/\(username)"
        let uid = try nextAvailableUID()

        // 1. 创建用户记录
        try dscl(["-create", "/Users/\(username)"])

        // 2. 设置各属性
        try dscl(["-create", "/Users/\(username)", "RealName",         fullName.isEmpty ? username : fullName])
        try dscl(["-create", "/Users/\(username)", "UniqueID",         "\(uid)"])
        try dscl(["-create", "/Users/\(username)", "PrimaryGroupID",   "20"])   // staff
        try dscl(["-create", "/Users/\(username)", "NFSHomeDirectory", homePath])
        try dscl(["-create", "/Users/\(username)", "UserShell",        "/bin/zsh"])

        // 3. 设置密码
        try dscl(["-passwd", "/Users/\(username)", password])

        // 4. 创建 home 目录，并限制权限为 700（仅所有者可访问）
        try run("/usr/sbin/createhomedir", args: ["-c", "-u", username])
        try run("/bin/chmod", args: ["700", homePath])
    }

    // MARK: - 删除用户

    /// 删除用户账户（可选保留 home）并完成关联清理
    static func deleteUser(username: String, keepHome: Bool, auth: DirectoryAdminAuth? = nil) throws {
        prepareDeleteUser(username: username)
        // Helper 作为 root 运行时，直接使用 root 身份执行目录操作更稳定；
        // 携带 -u/-P 在部分系统会触发无交互授权异常或权限错误。
        let commandAuth: DirectoryAdminAuth? = (geteuid() == 0) ? nil : auth

        // 用户已不存在时保持幂等：仅清理 helper 状态并返回成功
        guard userRecordExists(username: username) else {
            cleanupDeletedUser(username: username)
            return
        }

        var sysadminctlArgs = ["-deleteUser", username]
        if keepHome { sysadminctlArgs.append("-keepHome") }
        if let commandAuth {
            sysadminctlArgs = ["-adminUser", commandAuth.user, "-adminPassword", commandAuth.password] + sysadminctlArgs
        }

        func deleteViaDscl() throws {
            if let commandAuth {
                try dscl(auth: commandAuth, ["-delete", "/Users/\(username)"])
            } else {
                try dscl(["-delete", "/Users/\(username)"])
            }
        }

        do {
            // 优先走 sysadminctl（系统官方删除路径）。
            helperLog("用户删除执行 @\(username): 尝试 sysadminctl 删除")
            try run("/usr/sbin/sysadminctl", args: sysadminctlArgs)
        } catch {
            if isUnknownUserDeleteError(error) {
                helperLog("用户删除执行 @\(username): sysadminctl 报告 unknown user，按已删除处理")
                cleanupDeletedUser(username: username)
                return
            }

            // sysadminctl 失败时回退到 dscl，兼容不同系统状态。
            let redacted = redactSensitiveDeleteError(error.localizedDescription, auth: auth)
            helperLog("用户删除执行 @\(username): sysadminctl 失败，回退 dscl：\(redacted)", level: .warn)
            do {
                helperLog("用户删除执行 @\(username): 尝试 dscl -delete 兜底")
                try deleteViaDscl()
            } catch {
                throw UserManagerError.deleteCommandFailed(username, redactSensitiveDeleteError(error.localizedDescription, auth: auth))
            }
        }

        let removedAfterSysadminctl = waitForUserRecordRemoval(username: username, retries: 40, sleepMs: 250)
        if !removedAfterSysadminctl && userRecordExists(username: username) {
            helperLog("用户删除执行 @\(username): sysadminctl 返回后记录仍存在，等待后尝试 dscl 二次删除", level: .warn)
            do {
                try deleteViaDscl()
            } catch {
                if isDirectoryPermissionDeleteError(error) {
                    helperLog("用户删除执行 @\(username): dscl 返回权限拒绝，继续等待目录服务收敛", level: .warn)
                    if waitForUserRecordRemoval(username: username, retries: 20, sleepMs: 250) {
                        helperLog("用户删除执行 @\(username): 等待后记录已移除，跳过 dscl 错误")
                    } else if userRecordExists(username: username) {
                        throw UserManagerError.deleteCommandFailed(username, redactSensitiveDeleteError(error.localizedDescription, auth: auth))
                    }
                    // 继续执行后续统一校验与清理流程
                }
                if userRecordExists(username: username) {
                    throw UserManagerError.deleteCommandFailed(username, redactSensitiveDeleteError(error.localizedDescription, auth: auth))
                }
                helperLog("用户删除执行 @\(username): dscl 报错但记录已不存在，继续后续流程")
            }
        }

        if !waitForUserRecordRemoval(username: username) {
            let idProbe = (try? run("/usr/bin/id", args: [username])) ?? "(id 查询失败)"
            helperLog("用户删除校验仍存在 @\(username): \(idProbe)", level: .warn)
            throw UserManagerError.deleteNotConfirmed(username)
        }

        if !keepHome {
            let homePath = "/Users/\(username)"
            if FileManager.default.fileExists(atPath: homePath) {
                try FileManager.default.removeItem(atPath: homePath)
            }
        }

        cleanupDeletedUser(username: username)
    }

    private static func userRecordExists(username: String) -> Bool {
        (try? dscl(["-read", "/Users/\(username)", "UniqueID"])) != nil
    }

    private static func waitForUserRecordRemoval(username: String, retries: Int = 20, sleepMs: UInt32 = 250) -> Bool {
        for _ in 0..<retries {
            if !userRecordExists(username: username) { return true }
            _ = try? run("/usr/bin/dscacheutil", args: ["-flushcache"])
            usleep(sleepMs * 1_000)
        }
        return !userRecordExists(username: username)
    }

    private static func isUnknownUserDeleteError(_ error: Error) -> Bool {
        guard case let ShellError.nonZeroExit(_, _, stderr) = error else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("unknown user")
    }

    private static func redactSensitiveDeleteError(_ message: String, auth: DirectoryAdminAuth?) -> String {
        guard let auth, !auth.password.isEmpty else { return message }
        return message.replacingOccurrences(of: auth.password, with: "******")
    }

    private static func isDirectoryPermissionDeleteError(_ error: Error) -> Bool {
        guard case let ShellError.nonZeroExit(_, _, stderr) = error else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("edspermissionerror")
            || normalized.contains("ds error: -14120")
    }

    /// 删除前预清理：停止 gateway + 从所有群组中移除
    /// 必须在 sysadminctl -deleteUser **之前**调用（需读取用户 GeneratedUID）
    static func prepareDeleteUser(username: String) {
        if let uid = try? UserManager.uid(for: username) {
            helperLog("用户删除预清理 @\(username): 停止 Gateway (uid=\(uid))")
            do {
                try GatewayManager.stopGateway(username: username, uid: uid)
            } catch {
                helperLog("stopGateway failed during prepareDeleteUser @\(username): \(error.localizedDescription)", level: .warn)
            }
        }
        // 无论是否能读取到 uid，都按用户名卸载 launchd 服务与 plist，避免启动项残留
        do {
            try GatewayManager.uninstallGateway(username: username)
        } catch {
            helperLog("uninstallGateway failed during prepareDeleteUser @\(username): \(error.localizedDescription)", level: .warn)
        }
        removeFromAllGroups(username: username)
        VaultManager.teardownVault(username: username, archive: true)
    }

    /// 删除后清理：移除 Helper 侧状态文件
    /// 在 sysadminctl -deleteUser **之后**调用
    static func cleanupDeletedUser(username: String) {
        let initStatePath = "/var/lib/clawdhome/\(username)-init.json"
        try? FileManager.default.removeItem(atPath: initStatePath)
        helperLog("用户删除后清理 @\(username): 状态文件已删除")
    }

    /// 从所有本地群组中移除指定用户（GroupMembership + GroupMembers）
    /// macOS 群组用两套属性记录成员：
    ///   - GroupMembership：短用户名列表
    ///   - GroupMembers：GeneratedUID 列表
    /// sysadminctl -deleteUser 只删用户记录，不清理这两处，导致
    /// 系统设置 → 用户与群组中该用户仍出现在群组列表里
    private static func removeFromAllGroups(username: String) {
        // 1. 读取用户的 GeneratedUID（必须在账户删除前调用）
        let guid: String? = {
            guard let output = try? dscl(["-read", "/Users/\(username)", "GeneratedUID"]) else { return nil }
            return output.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        if let guid {
            helperLog("用户删除预清理 @\(username): GeneratedUID=\(guid)")
        } else {
            helperLog("用户删除预清理 @\(username): 无法读取 GeneratedUID", level: .warn)
        }

        // 2. 扫描 GroupMembership，移除用户名
        if let output = try? dscl(["-list", "/Groups", "GroupMembership"]) {
            for line in output.components(separatedBy: "\n") {
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let groupName = tokens.first,
                      Array(tokens.dropFirst()).contains(username) else { continue }
                if (try? dscl(["-delete", "/Groups/\(groupName)", "GroupMembership", username])) == nil {
                    helperLog("dscl -delete GroupMembership \(groupName) failed for @\(username)", level: .warn)
                }
                helperLog("用户删除预清理 @\(username): 从群组 \(groupName) 移除 (GroupMembership)")
            }
        }

        // 3. 扫描 GroupMembers，移除 GeneratedUID
        if let guid = guid, !guid.isEmpty,
           let output = try? dscl(["-list", "/Groups", "GroupMembers"]) {
            for line in output.components(separatedBy: "\n") {
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let groupName = tokens.first,
                      Array(tokens.dropFirst()).contains(guid) else { continue }
                if (try? dscl(["-delete", "/Groups/\(groupName)", "GroupMembers", guid])) == nil {
                    helperLog("dscl -delete GroupMembers \(groupName) failed for @\(username)", level: .warn)
                }
                helperLog("用户删除预清理 @\(username): 从群组 \(groupName) 移除 (GroupMembers)")
            }
        }
    }

    // MARK: - 查询

    /// 列出所有标准用户（UniqueID >= 501，排除系统账户）
    static func listStandardUsers() throws -> [(username: String, uid: Int)] {
        let output = try dscl(["-list", "/Users", "UniqueID"])
        return output
            .components(separatedBy: "\n")
            .compactMap { line -> (String, Int)? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let uid = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      uid >= 501
                else { return nil }
                return (parts[0], uid)
            }
    }

    /// 获取指定用户的 UID
    static func uid(for username: String) throws -> Int {
        let output = try dscl(["-read", "/Users/\(username)", "UniqueID"])
        // 格式：UniqueID: 501
        guard let uidStr = output.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces),
              let uid = Int(uidStr)
        else {
            throw UserManagerError.uidNotFound(username)
        }
        return uid
    }

    // MARK: - 内部工具

    /// 找到下一个可用 UID（>= 501）
    private static func nextAvailableUID() throws -> Int {
        let output = try dscl(["-list", "/Users", "UniqueID"])
        let usedUIDs = output
            .components(separatedBy: "\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: " ")
                return parts.last.flatMap { Int($0) }
            }
        let maxUID = usedUIDs.filter { $0 >= 501 }.max() ?? 500
        return maxUID + 1
    }
}

enum UserManagerError: LocalizedError {
    case uidNotFound(String)
    case deleteCommandFailed(String, String)
    case deleteNotConfirmed(String)

    var errorDescription: String? {
        switch self {
        case .uidNotFound(let user): return "无法获取用户 \(user) 的 UID"
        case .deleteCommandFailed(let user, let reason):
            return "删除用户 \(user) 失败：\(reason)"
        case .deleteNotConfirmed(let user): return "删除用户 \(user) 后校验失败：系统记录仍存在"
        }
    }
}
