// ClawdHomeHelper/Operations/VaultManager.swift
// 安全文件夹与公共文件夹的组/目录管理
// 基于 macOS 权限组（dseditgroup）实现虾之间的文件隔离

import Foundation
import SystemConfiguration

enum VaultManager {

    /// 共享空间根目录
    private static let sharedRoot  = "/Users/Shared/ClawdHome"
    /// 安全文件夹父目录
    private static let vaultsRoot  = "\(sharedRoot)/vaults"
    /// 公共文件夹路径
    private static let publicDir   = "\(sharedRoot)/public"
    /// 全局共享组名
    private static let globalGroup = "clawdhome-all"

    /// 生成虾专属组名
    private static func perShrimpGroup(_ username: String) -> String {
        "clawdhome-\(username)"
    }

    // MARK: - 初始化（幂等）

    /// 为指定虾初始化安全文件夹和公共文件夹
    /// 可重复调用，所有操作均为幂等
    static func setupVault(username: String) throws {
        let adminUsers = resolveAdminUsers()
        let group = perShrimpGroup(username)

        // 1. 创建虾专属组，加入管理员和虾
        try createGroupIfNeeded(group)
        for admin in adminUsers {
            try addMemberIfNeeded(admin, to: group)
        }
        try addMemberIfNeeded(username, to: group)

        // 2. 全局共享组
        try createGroupIfNeeded(globalGroup)
        for admin in adminUsers {
            try addMemberIfNeeded(admin, to: globalGroup)
        }
        try addMemberIfNeeded(username, to: globalGroup)

        // 3. 创建安全文件夹目录
        let vaultPath = "\(vaultsRoot)/\(username)"
        try ensureDirectory(vaultPath)
        try FilePermissionHelper.chown(vaultPath, owner: username, group: group)
        try FilePermissionHelper.chmod(vaultPath, mode: "2770")
        applyAdminACLs(adminUsers, to: vaultPath)

        // 4. 创建公共文件夹目录
        try ensureDirectory(publicDir)
        try FilePermissionHelper.chown(publicDir, owner: "root", group: globalGroup)
        try FilePermissionHelper.chmod(publicDir, mode: "2775")
        applyAdminACLs(adminUsers, to: publicDir)

        // 5. 确保上层目录可遍历
        try ensureDirectory(sharedRoot)
        try FilePermissionHelper.chmod(sharedRoot, mode: "755")

        // 6. 在虾 home 下创建符号链接 ~/clawdhome_shared/
        //    skill/agent 统一通过 ~/clawdhome_shared/ 访问，底层存储路径是平台实现细节
        //    macOS: /Users/Shared/ClawdHome/  Linux: /var/shared/clawdhome/ 等
        createHomeSymlinks(username: username, vaultPath: vaultPath)

        helperLog("Vault 初始化完成 @\(username): group=\(group), admins=\(adminUsers.joined(separator: ","))")
    }

    // MARK: - 清理

    /// 删除虾时清理组和文件夹
    /// archive=true 时将 vault 目录重命名保留，否则直接删除
    static func teardownVault(username: String, archive: Bool = true) {
        let group = perShrimpGroup(username)
        let vaultPath = "\(vaultsRoot)/\(username)"

        // 1. 从全局组移除
        removeMemberSilently(username, from: globalGroup)

        // 2. 删除专属组
        deleteGroupSilently(group)

        // 3. 处理 vault 目录
        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultPath) else { return }

        if archive {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withFullTime]
            let ts = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let archivedPath = "\(vaultsRoot)/\(username)-archived-\(ts)"
            do {
                try fm.moveItem(atPath: vaultPath, toPath: archivedPath)
                helperLog("Vault 已归档 @\(username) → \(archivedPath)")
            } catch {
                helperLog("Vault 归档失败 @\(username): \(error.localizedDescription)", level: .warn)
            }
        } else {
            do {
                try fm.removeItem(atPath: vaultPath)
                helperLog("Vault 已删除 @\(username)")
            } catch {
                helperLog("Vault 删除失败 @\(username): \(error.localizedDescription)", level: .warn)
            }
        }
    }

    // MARK: - 组操作（幂等）

    private static func createGroupIfNeeded(_ groupName: String) throws {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "create", groupName])
        } catch let error as ShellError {
            // 有些系统在“组已存在”时不会返回稳定文案，改为状态验证。
            if groupExists(groupName) {
                return
            }
            if case .nonZeroExit(_, _, let stderr) = error {
                let lower = stderr.lowercased()
                if lower.contains("already exists")
                    || lower.contains("record could not be replaced") {
                    return
                }
            }
            throw error
        }
    }

    private static func addMemberIfNeeded(_ user: String, to group: String) throws {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "edit", "-a", user, "-t", "user", group])
        } catch let error as ShellError {
            // 成员可能已存在；优先用目录状态判定，避免依赖 stderr 文案。
            if isUser(user, memberOf: group) {
                return
            }
            if case .nonZeroExit(_, _, let stderr) = error {
                let lower = stderr.lowercased()
                if lower.contains("already a member")
                    || lower.contains("record could not be replaced") {
                    return
                }
            }
            throw error
        }
    }

    private static func removeMemberSilently(_ user: String, from group: String) {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "edit", "-d", user, "-t", "user", group])
        } catch {
            helperLog("从组 \(group) 移除 \(user) 失败（可忽略）: \(error.localizedDescription)", level: .warn)
        }
    }

    private static func deleteGroupSilently(_ groupName: String) {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "delete", groupName])
            helperLog("已删除组 \(groupName)")
        } catch {
            helperLog("删除组 \(groupName) 失败（可忽略）: \(error.localizedDescription)", level: .warn)
        }
    }

    private static func groupExists(_ groupName: String) -> Bool {
        (try? run("/usr/bin/dscl", args: ["/Local/Default", "-read", "/Groups/\(groupName)", "RecordName"])) != nil
    }

    private static func isUser(_ user: String, memberOf group: String) -> Bool {
        guard let output = try? run("/usr/sbin/dseditgroup", args: ["-o", "checkmember", "-m", user, group]) else {
            return false
        }
        return output.lowercased().contains("yes")
    }

    // MARK: - 工具

    /// 虾 home 下的共享入口目录名
    private static let homeLinkDir = "clawdhome_shared"

    /// 在虾的 home 下创建 ~/clawdhome_shared/ 目录，包含两个符号链接：
    ///   private → 该虾自己的 vault（其他虾不可见）
    ///   public  → 公共文件夹
    /// skill/agent 统一通过 ~/clawdhome_shared/private 和 ~/clawdhome_shared/public 访问
    private static func createHomeSymlinks(username: String, vaultPath: String) {
        guard let home = resolveHomeDir(username: username) else { return }

        let linkDir = "\(home)/\(homeLinkDir)"
        let fm = FileManager.default

        // 兼容旧版：如果 ~/clawdhome_shared 是一个符号链接（指向 sharedRoot），先删除
        if let dest = try? fm.destinationOfSymbolicLink(atPath: linkDir) {
            if dest == sharedRoot {
                try? fm.removeItem(atPath: linkDir)
            }
        }

        try? fm.createDirectory(atPath: linkDir, withIntermediateDirectories: true, attributes: nil)
        try? FilePermissionHelper.chown(linkDir, owner: username)
        try? FilePermissionHelper.chmod(linkDir, mode: "755")

        ensureSymlink(at: "\(linkDir)/private", target: vaultPath)
        ensureSymlink(at: "\(linkDir)/public", target: publicDir)
    }

    /// 创建符号链接（幂等：已存在则跳过）
    private static func ensureSymlink(at linkPath: String, target: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
            return
        }
        do {
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        } catch {
            helperLog("创建符号链接失败 \(linkPath) → \(target): \(error.localizedDescription)", level: .warn)
        }
    }

    /// 解析虾的 home 目录
    private static func resolveHomeDir(username: String) -> String? {
        guard let home = try? run("/usr/bin/dscl", args: ["/Local/Default", "-read", "/Users/\(username)", "NFSHomeDirectory"])
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !home.isEmpty else {
            helperLog("无法获取 @\(username) home 目录", level: .warn)
            return nil
        }
        return home
    }

    private static func ensureDirectory(_ path: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
    }

    /// 解析可访问共享目录的管理员用户集合（去重，幂等）
    /// 优先包含当前控制台用户，同时补齐 admin 组成员，避免仅靠控制台用户导致权限遗漏。
    private static func resolveAdminUsers() -> [String] {
        var users = Set<String>()

        let console = resolveConsoleAdmin()
        if !console.isEmpty {
            users.insert(console)
        }

        if let output = try? run("/usr/bin/dscl", args: ["/Local/Default", "-read", "/Groups/admin", "GroupMembership"]) {
            let list = output
                .components(separatedBy: ":")
                .dropFirst()
                .joined(separator: ":")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "root" && !$0.hasPrefix("_") }
            list.forEach { users.insert($0) }
        }

        if users.isEmpty {
            helperLog("未解析到管理员用户，Vault 组将仅包含虾用户", level: .warn)
        }
        return users.sorted()
    }

    /// 获取当前控制台用户名（可能是管理员，也可能为空）
    private static func resolveConsoleAdmin() -> String {
        var uid: uid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil), uid != 0 else {
            return ""
        }
        return (cfUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 给管理员账户补充 ACL，避免“会话附加组未刷新”导致的临时写权限缺失。
    private static func applyAdminACLs(_ adminUsers: [String], to path: String) {
        for admin in adminUsers {
            do {
                try FilePermissionHelper.grantDirectoryWriteACL(path, username: admin)
            } catch {
                helperLog("为 \(path) 添加管理员 ACL 失败 @\(admin): \(error.localizedDescription)", level: .warn)
            }
        }
    }
}
