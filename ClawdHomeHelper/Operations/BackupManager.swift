// ClawdHomeHelper/Operations/BackupManager.swift
// 分层备份与恢复核心逻辑（Helper 侧，以 root 权限执行）

import Foundation

enum BackupManager {

    // MARK: - 路径常量

    private static let configPath = "/var/lib/clawdhome/backup-config.json"
    private static let resultPath = "/var/lib/clawdhome/last-backup-result.json"
    private static let stateDir = "/var/lib/clawdhome"

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()

    /// .openclaw 内排除列表（可自动再生的目录/文件）
    private static let openclawExcludes = [
        ".openclaw/tools",
        ".openclaw/sandboxes",
        ".openclaw/logs",
        ".openclaw/restart-sentinel.json"
    ]

    // MARK: - 配置读写

    static func loadConfig() -> BackupConfig {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(BackupConfig.self, from: data) else {
            // 无已保存配置：构建默认值，Helper 侧需解析管理员 home
            var config = BackupConfig.default
            let home = NSHomeDirectory()
            if home == "/var/root" || home.hasPrefix("/var/root") {
                let adminHome = resolveAdminHome()
                config.backupDir = "\(adminHome)/Documents/ClawdHome-Backups"
            }
            return config
        }
        return config
    }

    /// 解析管理员用户的 home 目录（Helper 以 root 运行时使用）
    private static func resolveAdminHome() -> String {
        if let adminGroup = getgrnam("admin") {
            var i = 0
            while let member = adminGroup.pointee.gr_mem?[i] {
                let name = String(cString: member)
                if !ManagedUserFilter.isExcludedUsername(name) {
                    if let pw = getpwnam(name), pw.pointee.pw_uid >= 500 {
                        return String(cString: pw.pointee.pw_dir)
                    }
                }
                i += 1
            }
        }
        return "/Users/Shared"
    }

    static func saveConfig(_ config: BackupConfig) throws {
        try FileManager.default.createDirectory(
            atPath: stateDir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    // MARK: - 全局备份

    /// 备份全局配置文件到 destinationDir/global/global-<timestamp>.tar.gz
    static func backupGlobal(destinationDir: String) throws {
        let globalDir = "\(destinationDir)/global"
        try FileManager.default.createDirectory(
            atPath: globalDir,
            withIntermediateDirectories: true
        )

        let timestamp = fileDateFormatter.string(from: Date())
        let archivePath = "\(globalDir)/global-\(timestamp).tar.gz"

        // 使用临时暂存目录打包跨目录文件
        let tmpStaging = "/tmp/clawdhome-backup-global-\(timestamp)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmpStaging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpStaging) }

        // App Support 文件
        let appSupport = resolveAdminAppSupportDir()
        let appSupportFiles = ["global-models.json", "secrets.json", "device-identity-v1.json"]
        let appSupportStaging = "\(tmpStaging)/app-support"
        try fm.createDirectory(atPath: appSupportStaging, withIntermediateDirectories: true)
        for file in appSupportFiles {
            let src = "\(appSupport)/\(file)"
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: "\(appSupportStaging)/\(file)")
            }
        }

        // /var/lib/clawdhome 全局文件
        let helperStateStaging = "\(tmpStaging)/helper-state"
        try fm.createDirectory(atPath: helperStateStaging, withIntermediateDirectories: true)
        let globalStateFiles = ["global-netconfig.json", "gateway-autostart-disabled"]
        for file in globalStateFiles {
            let src = "\(stateDir)/\(file)"
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: "\(helperStateStaging)/\(file)")
            }
        }

        // 打包
        try run("/usr/bin/tar", args: ["-czf", archivePath, "-C", tmpStaging, "."])
    }

    // MARK: - Shrimp 备份

    /// 备份单个 Shrimp 到 destinationDir/shrimps/<username>/shrimp-<username>-<timestamp>.tar.gz
    static func backupShrimp(username: String, destinationDir: String) throws {
        let homeDir = "/Users/\(username)"
        let openclawDir = "\(homeDir)/.openclaw"
        guard FileManager.default.fileExists(atPath: openclawDir) else {
            throw BackupError.openclawNotFound(username)
        }

        let shrimpDir = "\(destinationDir)/shrimps/\(username)"
        try FileManager.default.createDirectory(
            atPath: shrimpDir,
            withIntermediateDirectories: true
        )

        let timestamp = fileDateFormatter.string(from: Date())
        let archivePath = "\(shrimpDir)/shrimp-\(username)-\(timestamp).tar.gz"

        // 使用临时暂存目录，将 .openclaw + helper 状态文件合并打包
        let tmpStaging = "/tmp/clawdhome-backup-\(username)-\(timestamp)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmpStaging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpStaging) }

        // 1. 用 rsync 复制 .openclaw（带排除项），避免双重 tar
        var rsyncArgs = ["-a"]
        for excl in openclawExcludes {
            // 排除项格式：.openclaw/xxx → 取 xxx 部分
            let relative = excl.replacingOccurrences(of: ".openclaw/", with: "")
            rsyncArgs += ["--exclude=\(relative)"]
        }
        rsyncArgs += ["\(openclawDir)/", "\(tmpStaging)/.openclaw/"]
        try run("/usr/bin/rsync", args: rsyncArgs)

        // 2. 复制 helper 状态文件
        let helperStateStaging = "\(tmpStaging)/helper-state"
        try fm.createDirectory(atPath: helperStateStaging, withIntermediateDirectories: true)
        let perUserFiles = [
            "\(username)-init.json",
            "\(username)-netpolicy.json",
            "\(username)-autostart-disabled"
        ]
        for file in perUserFiles {
            let src = "\(stateDir)/\(file)"
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: "\(helperStateStaging)/\(file)")
            }
        }

        // 3. 最终打包
        try run("/usr/bin/tar", args: ["-czf", archivePath, "-C", tmpStaging, "."])
    }

    // MARK: - 全量备份

    /// 备份全局 + 所有 Shrimp，返回 (成功数, 失败描述列表)
    static func backupAll(destinationDir: String) -> (succeeded: Int, failures: [String]) {
        var succeeded = 0
        var failures: [String] = []

        // 全局
        do {
            try backupGlobal(destinationDir: destinationDir)
            succeeded += 1
        } catch {
            failures.append("全局配置: \(error.localizedDescription)")
        }

        // 每个 Shrimp
        for user in managedGatewayUsers() {
            do {
                try backupShrimp(username: user.username, destinationDir: destinationDir)
                succeeded += 1
            } catch {
                failures.append("@\(user.username): \(error.localizedDescription)")
            }
        }

        return (succeeded, failures)
    }

    // MARK: - 全局恢复

    static func restoreGlobal(sourcePath: String) throws {
        let fm = FileManager.default
        let tmpDir = "/tmp/clawdhome-restore-global-\(UUID().uuidString)"
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        try run("/usr/bin/tar", args: ["-xzf", sourcePath, "-C", tmpDir])

        // 恢复 App Support 文件
        let appSupport = resolveAdminAppSupportDir()
        try fm.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        let appSupportSrc = "\(tmpDir)/app-support"
        if fm.fileExists(atPath: appSupportSrc) {
            for file in ["global-models.json", "secrets.json", "device-identity-v1.json"] {
                let src = "\(appSupportSrc)/\(file)"
                let dst = "\(appSupport)/\(file)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try fm.copyItem(atPath: src, toPath: dst)
                    // secrets.json 权限修复
                    if file == "secrets.json" {
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst)
                    }
                }
            }
        }

        // 恢复 helper 全局状态
        let helperSrc = "\(tmpDir)/helper-state"
        if fm.fileExists(atPath: helperSrc) {
            for file in ["global-netconfig.json", "gateway-autostart-disabled"] {
                let src = "\(helperSrc)/\(file)"
                let dst = "\(stateDir)/\(file)"
                if fm.fileExists(atPath: src) {
                    try? fm.removeItem(atPath: dst)
                    try fm.copyItem(atPath: src, toPath: dst)
                } else {
                    // 备份中不存在 → 当时没此配置，删除目标
                    try? fm.removeItem(atPath: dst)
                }
            }
        }
    }

    // MARK: - Shrimp 恢复

    /// 恢复 Shrimp 数据（调用方须确保网关已停止）
    static func restoreShrimp(username: String, sourcePath: String) throws {
        let fm = FileManager.default
        let homeDir = "/Users/\(username)"
        let openclawDir = "\(homeDir)/.openclaw"
        let tmpDir = "\(homeDir)/.openclaw.restore-tmp"
        let prevDir = "\(homeDir)/.openclaw.prev"

        try? fm.removeItem(atPath: tmpDir)
        try? fm.removeItem(atPath: prevDir)

        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        do {
            // 1. 解压
            try run("/usr/bin/tar", args: ["-xzf", sourcePath, "-C", tmpDir])

            // 2. 验证
            let extracted = "\(tmpDir)/.openclaw"
            guard fm.fileExists(atPath: extracted) else {
                throw BackupError.invalidArchive("未找到 .openclaw 目录")
            }

            // 3. 原子替换 .openclaw
            if fm.fileExists(atPath: openclawDir) {
                try fm.moveItem(atPath: openclawDir, toPath: prevDir)
            }

            do {
                try fm.moveItem(atPath: extracted, toPath: openclawDir)
            } catch {
                if fm.fileExists(atPath: prevDir) {
                    try? fm.moveItem(atPath: prevDir, toPath: openclawDir)
                }
                throw error
            }

            // 4. 修正所有权
            try run("/usr/sbin/chown", args: ["-R", username, openclawDir])

            // 5. 恢复 helper 状态文件
            let helperSrc = "\(tmpDir)/helper-state"
            if fm.fileExists(atPath: helperSrc) {
                let perUserFiles = [
                    "\(username)-init.json",
                    "\(username)-netpolicy.json",
                    "\(username)-autostart-disabled"
                ]
                for file in perUserFiles {
                    let src = "\(helperSrc)/\(file)"
                    let dst = "\(stateDir)/\(file)"
                    if fm.fileExists(atPath: src) {
                        try? fm.removeItem(atPath: dst)
                        try fm.copyItem(atPath: src, toPath: dst)
                    }
                }
            }

            // 6. 清理
            try? fm.removeItem(atPath: tmpDir)
            try? fm.removeItem(atPath: prevDir)

        } catch {
            try? fm.removeItem(atPath: tmpDir)
            throw error
        }
    }

    // MARK: - 列出备份

    static func listBackups(destinationDir: String) -> [BackupListEntry] {
        let fm = FileManager.default
        var entries: [BackupListEntry] = []

        // 全局备份
        let globalDir = "\(destinationDir)/global"
        let globalExists = fm.fileExists(atPath: globalDir)
        helperLog("[listBackups] globalDir=\(globalDir) exists=\(globalExists)")
        if let files = try? fm.contentsOfDirectory(atPath: globalDir) {
            helperLog("[listBackups] global files: \(files)")
            for file in files where file.hasSuffix(".tar.gz") {
                let path = "\(globalDir)/\(file)"
                if let entry = makeEntry(path: path, filename: file, type: "global", username: nil) {
                    entries.append(entry)
                } else {
                    helperLog("[listBackups] makeEntry failed for \(path)", level: .warn)
                }
            }
        } else {
            helperLog("[listBackups] contentsOfDirectory failed for globalDir", level: .warn)
        }

        // Shrimp 备份
        let shrimpsDir = "\(destinationDir)/shrimps"
        let shrimpsExists = fm.fileExists(atPath: shrimpsDir)
        helperLog("[listBackups] shrimpsDir=\(shrimpsDir) exists=\(shrimpsExists)")
        if let userDirs = try? fm.contentsOfDirectory(atPath: shrimpsDir) {
            helperLog("[listBackups] shrimp userDirs: \(userDirs)")
            for userDir in userDirs {
                let userPath = "\(shrimpsDir)/\(userDir)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: userPath, isDirectory: &isDir), isDir.boolValue else { continue }
                if let files = try? fm.contentsOfDirectory(atPath: userPath) {
                    for file in files where file.hasSuffix(".tar.gz") {
                        let path = "\(userPath)/\(file)"
                        if let entry = makeEntry(path: path, filename: file, type: "shrimp", username: userDir) {
                            entries.append(entry)
                        }
                    }
                }
            }
        } else {
            helperLog("[listBackups] contentsOfDirectory failed for shrimpsDir", level: .warn)
        }

        helperLog("[listBackups] 总计 \(entries.count) 个条目")
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 删除备份

    static func deleteBackup(filePath: String) throws {
        let config = loadConfig()
        try validateBackupPath(filePath, within: config.backupDir)
        try FileManager.default.removeItem(atPath: filePath)
    }

    // MARK: - 备份结果持久化

    /// 保存最近一次备份结果
    static func saveResult(_ result: BackupResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) {
            try? data.write(to: URL(fileURLWithPath: resultPath))
        }
    }

    /// 读取最近一次备份结果
    static func loadResult() -> BackupResult? {
        guard let data = FileManager.default.contents(atPath: resultPath),
              let result = try? JSONDecoder().decode(BackupResult.self, from: data) else {
            return nil
        }
        return result
    }

    // MARK: - 路径安全校验

    /// 校验文件路径在备份目录内且为 .tar.gz 文件，防止路径遍历
    static func validateBackupPath(_ path: String, within baseDir: String) throws {
        let resolved = (path as NSString).standardizingPath
        let base = (baseDir as NSString).standardizingPath
        guard resolved.hasPrefix(base + "/"),
              resolved.hasSuffix(".tar.gz") else {
            throw BackupError.invalidPath(path)
        }
    }

    // MARK: - 保留策略清理

    /// 按 type + username 分组，每组保留最近 maxCount 个
    static func pruneBackups(destinationDir: String, maxCount: Int) -> [String] {
        let all = listBackups(destinationDir: destinationDir)
        var pruned: [String] = []

        // 按 (backupType, username ?? "") 分组
        var groups: [String: [BackupListEntry]] = [:]
        for entry in all {
            let key = "\(entry.backupType):\(entry.username ?? "")"
            groups[key, default: []].append(entry)
        }

        for (_, entries) in groups {
            let sorted = entries.sorted { $0.createdAt > $1.createdAt }
            if sorted.count > maxCount {
                for entry in sorted.dropFirst(maxCount) {
                    try? FileManager.default.removeItem(atPath: entry.filePath)
                    pruned.append(entry.filename)
                }
            }
        }

        return pruned
    }

    // MARK: - 私有工具

    private static func makeEntry(path: String, filename: String, type: String, username: String?) -> BackupListEntry? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int64) ?? Int64(attrs[.size] as? UInt64 ?? 0)
        let date = (attrs[.creationDate] as? Date) ?? Date()
        return BackupListEntry(
            filename: filename,
            filePath: path,
            fileSize: size,
            createdAt: iso8601.string(from: date),
            backupType: type,
            username: username
        )
    }

    /// 找到运行 App 的管理员用户的 Application Support 目录
    static func resolveAdminAppSupportDir() -> String {
        "\(resolveAdminHome())/Library/Application Support/ClawdHome"
    }

    enum BackupError: LocalizedError {
        case openclawNotFound(String)
        case invalidArchive(String)
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .openclawNotFound(let user): return "@\(user) 的 ~/.openclaw 目录不存在"
            case .invalidArchive(let msg): return "备份文件格式错误: \(msg)"
            case .invalidPath(let path): return "非法备份路径: \(path)"
            }
        }
    }
}
