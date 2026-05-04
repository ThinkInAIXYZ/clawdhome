// ClawdHomeHelper/Operations/HermesAutostartList.swift
// Hermes profile 级开机自启白名单
//
// 文件路径：/var/lib/clawdhome/<username>-hermes-autostart.json
// 权限：root 写入，0644（所有人可读以便诊断）
// JSON schema：{ "schemaVersion": 1, "profiles": ["main", "coder"] }
//
// 兜底语义：文件不存在或损坏 → 返回 ["main"]（向后兼容老用户，重启后 main 仍自启）
// 注意：显式调用 save(profiles: []) 可清空列表（如用户禁用 main 自启后文件存在但 profiles=[]）

import Foundation

struct HermesAutostartList {

    // MARK: - 路径

    static func path(username: String) -> String {
        "/var/lib/clawdhome/\(username)-hermes-autostart.json"
    }

    // MARK: - 读取

    /// 读取白名单。文件不存在或损坏时返回 ["main"]（向后兼容）。
    /// 若文件存在且 profiles 为空，返回空集（尊重显式 disable 操作）。
    static func load(username: String) -> Set<String> {
        let filePath = path(username: username)
        guard FileManager.default.fileExists(atPath: filePath) else {
            // 文件不存在 → 向后兼容老用户，视为 ["main"]
            return ["main"]
        }
        guard let data = FileManager.default.contents(atPath: filePath),
              let decoded = try? JSONDecoder().decode(AutostartFile.self, from: data) else {
            // 文件存在但损坏 → 向后兼容，视为 ["main"]
            helperLog("[autostart] hermes whitelist 解析失败 @\(username)，fallback to [main]", level: .warn)
            return ["main"]
        }
        return Set(decoded.profiles)
    }

    // MARK: - 写入

    /// 将 profiles 集合原子写入白名单文件（写 .tmp → rename）。
    static func save(_ profiles: Set<String>, username: String) throws {
        let filePath = path(username: username)
        let dir = (filePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }

        let file = AutostartFile(schemaVersion: 1, profiles: profiles.sorted())
        let data = try JSONEncoder().encode(file)

        let tmp = filePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)

        // 设置权限 0644：root 可写，所有人可读
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp)

        // 原子 rename
        _ = try? fm.removeItem(atPath: filePath)
        try fm.moveItem(atPath: tmp, toPath: filePath)
    }

    // MARK: - 追加 / 移除

    /// 将 profileID 追加到白名单（已存在则幂等）。
    static func add(username: String, profileID: String) throws {
        var current = load(username: username)
        guard !current.contains(profileID) else { return }
        current.insert(profileID)
        try save(current, username: username)
        helperLog("[autostart] hermes whitelist add profile=\(profileID) @\(username)")
    }

    /// 从白名单移除 profileID（不存在则幂等）。
    /// 移除 main 会将文件持久化为 profiles=[]，确保下次 load 返回空集（而非 fallback 到 ["main"]）。
    static func remove(username: String, profileID: String) throws {
        var current = load(username: username)
        guard current.contains(profileID) else { return }
        current.remove(profileID)
        try save(current, username: username)
        helperLog("[autostart] hermes whitelist remove profile=\(profileID) @\(username)")
    }

    // MARK: - 查询

    /// 判断 profileID 是否在白名单内（基于当前磁盘状态）。
    static func contains(username: String, profileID: String) -> Bool {
        load(username: username).contains(profileID)
    }

    // MARK: - 内部 Codable

    private struct AutostartFile: Codable {
        var schemaVersion: Int
        var profiles: [String]
    }
}
