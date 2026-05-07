// ClawdHomeHelper/HelperImpl+Files.swift
// 文件管理 + 记忆搜索 + Secrets 同步 + 密码管理 + 屏幕共享 + 本地 AI 服务 + 进程管理 + 角色定义 Git 管理

import Foundation
import SQLite3
import SystemConfiguration

extension ClawdHomeHelperImpl {

    // MARK: - 文件管理

    func listDirectory(username: String, relativePath: String, showHidden: Bool,
                       withReply reply: @escaping (String?, String?) -> Void) {
        helperLog("[FileManager] listDirectory user=\(username) path=\(relativePath) showHidden=\(showHidden)",
                  level: .debug, channel: .fileManager)
        do {
            let entries = try UserFileManager.listDirectory(username: username, relativePath: relativePath, showHidden: showHidden)
            let data = try JSONEncoder().encode(entries)
            guard let json = String(data: data, encoding: .utf8) else {
                reply(nil, "JSON 编码失败")
                return
            }
            reply(json, nil)
        } catch {
            let isNotFound = (error as? UserFileError) == .notFound
                || (error as NSError).code == NSFileReadNoSuchFileError
            helperLog("[FileManager] listDirectory error: \(error)",
                      level: isNotFound ? .warn : .error)
            reply(nil, error.localizedDescription)
        }
    }

    func readSystemLog(name: String, withReply reply: @escaping (Data?, String?) -> Void) {
        let allowed = ["gateway"]
        guard allowed.contains(name) else {
            reply(nil, "不支持的日志名称: \(name)")
            return
        }
        let path = "/var/log/clawdhome/\(name).log"
        helperLog("[AuditLog] readSystemLog name=\(name)", level: .debug, channel: .fileManager)
        do {
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = attrs[.size] as? Int ?? 0
            let maxBytes = 2 * 1024 * 1024  // 2MB
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            if size > maxBytes {
                // 只读尾部 2MB
                try fh.seek(toOffset: UInt64(size - maxBytes))
            }
            let data = fh.readDataToEndOfFile()
            reply(data, nil)
        } catch {
            helperLog("[AuditLog] readSystemLog error: \(error)", level: .warn)
            reply(Data(), nil)  // 文件不存在时返回空，不算错误
        }
    }

    func readFile(username: String, relativePath: String,
                  withReply reply: @escaping (Data?, String?) -> Void) {
        helperLog("[FileManager] readFile user=\(username) path=\(relativePath)",
                  level: .debug, channel: .fileManager)
        do {
            let data = try UserFileManager.readFile(username: username, relativePath: relativePath)
            helperLog("[FileManager] readFile ok bytes=\(data.count)", level: .debug, channel: .fileManager)
            reply(data, nil)
        } catch {
            let isNotFound = (error as? UserFileError) == .notFound
            helperLog("[FileManager] readFile error: \(error)",
                      level: isNotFound ? .warn : .error)
            reply(nil, error.localizedDescription)
        }
    }

    func readFileTail(username: String, relativePath: String, maxBytes: Int,
                      withReply reply: @escaping (Data?, String?) -> Void) {
        helperLog("[FileManager] readFileTail user=\(username) path=\(relativePath) max=\(maxBytes)",
                  level: .debug, channel: .fileManager)
        do {
            let data = try UserFileManager.readFileTail(
                username: username,
                relativePath: relativePath,
                maxBytes: maxBytes
            )
            helperLog("[FileManager] readFileTail ok bytes=\(data.count)", level: .debug, channel: .fileManager)
            reply(data, nil)
        } catch {
            let isNotFound = (error as? UserFileError) == .notFound
            helperLog("[FileManager] readFileTail error: \(error)",
                      level: isNotFound ? .warn : .error)
            reply(nil, error.localizedDescription)
        }
    }

    func writeFile(username: String, relativePath: String, data: Data,
                   withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[FileManager] writeFile user=\(username) path=\(relativePath) size=\(data.count)",
                  level: .debug, channel: .fileManager)
        do {
            try UserFileManager.writeFile(username: username, relativePath: relativePath, data: data)
            reply(true, nil)
        } catch {
            helperLog("[FileManager] writeFile error: \(error)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func deleteItem(username: String, relativePath: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[FileManager] deleteItem user=\(username) path=\(relativePath)",
                  level: .debug, channel: .fileManager)
        do {
            try UserFileManager.deleteItem(username: username, relativePath: relativePath)
            reply(true, nil)
        } catch {
            helperLog("[FileManager] deleteItem error: \(error)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func createDirectory(username: String, relativePath: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[FileManager] createDirectory user=\(username) path=\(relativePath)",
                  level: .debug, channel: .fileManager)
        do {
            try UserFileManager.createDirectory(username: username, relativePath: relativePath)
            reply(true, nil)
        } catch {
            helperLog("[FileManager] createDirectory error: \(error)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func renameItem(username: String, relativePath: String, newName: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[FileManager] renameItem user=\(username) path=\(relativePath) newName=\(newName)",
                  level: .debug, channel: .fileManager)
        do {
            try UserFileManager.renameItem(username: username, relativePath: relativePath, newName: newName)
            reply(true, nil)
        } catch {
            helperLog("[FileManager] renameItem error: \(error)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func extractArchive(username: String, relativePath: String,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[FileManager] extractArchive user=\(username) path=\(relativePath)",
                  level: .debug, channel: .fileManager)
        do {
            try UserFileManager.extractArchive(username: username, relativePath: relativePath)
            reply(true, nil)
        } catch {
            helperLog("[FileManager] extractArchive error: \(error)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 记忆搜索

    func searchMemory(username: String, query: String, limit: Int,
                      withReply reply: @escaping (String?, String?) -> Void) {
        helperLog("[Memory] searchMemory user=\(username) query=\(query)")
        let dbPath = "/Users/\(username)/.openclaw/memory/main.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            reply("[]", nil)
            return
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            reply(nil, "无法打开 memory 数据库")
            return
        }
        defer { sqlite3_close(db) }

        // 先检查 chunks_fts 表是否存在
        let checkSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks_fts'"
        var checkStmt: OpaquePointer?
        let hasFTS: Bool
        if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
            hasFTS = sqlite3_step(checkStmt) == SQLITE_ROW
        } else {
            hasFTS = false
        }
        sqlite3_finalize(checkStmt)

        var results: [[String: String]] = []
        let sql: String
        if hasFTS {
            // 使用 FTS5 全文搜索
            sql = """
                SELECT c.path, c.text FROM chunks c
                JOIN chunks_fts f ON c.id = f.id
                WHERE chunks_fts MATCH ?
                ORDER BY rank LIMIT ?
            """
        } else {
            // 回退：LIKE 模糊搜索
            sql = "SELECT path, text FROM chunks WHERE text LIKE '%' || ? || '%' LIMIT ?"
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (query as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                results.append(["path": path, "text": text])
            }
        }
        sqlite3_finalize(stmt)

        guard let json = try? JSONSerialization.data(withJSONObject: results, options: [.withoutEscapingSlashes]),
              let jsonStr = String(data: json, encoding: .utf8) else {
            reply("[]", nil)
            return
        }
        reply(jsonStr, nil)
    }

    // MARK: - Secrets 同步

    func syncSecrets(username: String, secretsJSON: String, authProfilesJSON: String,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("密钥同步 @\(username)")
        do {
            guard let pw = getpwnam(username) else {
                throw NSError(domain: "ClawdHomeHelper", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "用户不存在：\(username)"])
            }
            let uid = pw.pointee.pw_uid
            let gid = pw.pointee.pw_gid
            let homeDir = String(cString: pw.pointee.pw_dir)
            let openclawDir = "\(homeDir)/.openclaw"

            // 确保 ~/.openclaw 目录存在
            try FileManager.default.createDirectory(
                atPath: openclawDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // 写 secrets.json（权限 600，只允许用户本人读写）
            let secretsPath = "\(openclawDir)/secrets.json"
            guard let secretsData = secretsJSON.data(using: .utf8) else {
                throw NSError(domain: "ClawdHomeHelper", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "无效的 secretsJSON"])
            }
            try secretsData.write(to: URL(fileURLWithPath: secretsPath), options: .atomic)
            chmod(secretsPath, 0o600)
            chown(secretsPath, uid, gid)
            helperLog("密钥同步 @\(username): secrets.json 写入成功 (\(secretsData.count) bytes)")

            // 写 auth-profiles.json（权限 644）
            let authProfilesPath = "\(openclawDir)/auth-profiles.json"
            guard let authProfilesData = authProfilesJSON.data(using: .utf8) else {
                throw NSError(domain: "ClawdHomeHelper", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "无效的 authProfilesJSON"])
            }
            try authProfilesData.write(to: URL(fileURLWithPath: authProfilesPath), options: .atomic)
            chmod(authProfilesPath, 0o644)
            chown(authProfilesPath, uid, gid)
            helperLog("密钥同步 @\(username): auth-profiles.json 写入成功 (\(authProfilesData.count) bytes)")

            // 修正 .openclaw 目录所有权
            chown(openclawDir, uid, gid)

            reply(true, nil)
        } catch {
            helperLog("密钥同步失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func reloadSecrets(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("密钥重载 @\(username)")
        // openclaw secrets reload 让 gateway 进程热加载 secrets 文件
        // reload 失败不视为硬错误（gateway 可能未运行，下次启动时会读取新 secrets）
        if let output = try? ClawdHomeHelper.run(
            "/bin/su", args: ["-l", username, "-c", "openclaw secrets reload"]) {
            helperLog("密钥重载 @\(username): \(output)")
        } else {
            helperLog("密钥重载 @\(username): 未能执行（忽略，gateway 下次启动时将加载新 secrets）", level: .warn)
        }
        reply(true, nil)
    }

    // MARK: - 密码管理

    func changeUserPassword(username: String, newPassword: String,
                            withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("密码变更 @\(username)")
        do {
            try dscl(["-passwd", "/Users/\(username)", newPassword])
            reply(true, nil)
        } catch {
            helperLog("密码变更失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 屏幕共享

    func isScreenSharingEnabled(withReply reply: @escaping (Bool) -> Void) {
        // launchctl list 返回 exit 0 表示服务已加载（无论是否有 PID）
        // 返回非零 exit（try? → nil）表示服务未注册 / 未启用
        let output = try? ClawdHomeHelper.run(
            "/bin/launchctl", args: ["list", "com.apple.screensharing"])
        reply(output != nil)
    }

    func enableScreenSharing(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("启用屏幕共享")
        do {
            // 第一步：标记为 enabled（重启后仍生效）
            try ClawdHomeHelper.run(
                "/bin/launchctl",
                args: ["enable", "system/com.apple.screensharing"]
            )
            // 第二步：立即 bootstrap（若已 bootstrap 则幂等忽略错误）
            let plist = "/System/Library/LaunchDaemons/com.apple.screensharing.plist"
            _ = try? ClawdHomeHelper.run(
                "/bin/launchctl",
                args: ["bootstrap", "system", plist]
            )
            reply(true, nil)
        } catch {
            helperLog("启用屏幕共享失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 本地 AI 服务（omlx LLM）

    private func resolveConsoleUsername() -> String {
        var uid: uid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil), uid != 0 else {
            return ""
        }
        return (cfUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func installOmlx(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[omlx] XPC installOmlx")
        let admin = resolveConsoleUsername()
        guard !admin.isEmpty else {
            reply(false, LocalAIError.adminNotAvailable.localizedDescription)
            return
        }
        do {
            try LocalLLMManager.install(adminUsername: admin)
            reply(true, nil)
        } catch {
            helperLog("[omlx] 安装失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getLocalLLMStatus(withReply reply: @escaping (String) -> Void) {
        let status = LocalLLMManager.status()
        let json = (try? JSONEncoder().encode(status)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func listLocalModels(withReply reply: @escaping (String) -> Void) {
        let models = LocalLLMManager.listModels()
        let json = (try? JSONEncoder().encode(models)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        reply(json)
    }

    func startLocalLLM(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[omlx] XPC startLocalLLM")
        let admin = resolveConsoleUsername()
        guard !admin.isEmpty else {
            reply(false, LocalAIError.adminNotAvailable.localizedDescription)
            return
        }
        do {
            try LocalLLMManager.start(adminUsername: admin)
            reply(true, nil)
        } catch {
            helperLog("[omlx] 启动失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func stopLocalLLM(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[omlx] XPC stopLocalLLM")
        do {
            try LocalLLMManager.stop()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func downloadLocalModel(_ modelId: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[omlx] XPC downloadLocalModel \(modelId)")
        let admin = resolveConsoleUsername()
        guard !admin.isEmpty else {
            reply(false, LocalAIError.adminNotAvailable.localizedDescription)
            return
        }
        do {
            try LocalLLMManager.downloadModel(modelId: modelId, adminUsername: admin)
            reply(true, nil)
        } catch {
            helperLog("[omlx] 下载失败 \(modelId): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func deleteLocalModel(_ modelId: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[omlx] XPC deleteLocalModel \(modelId)")
        do {
            try LocalLLMManager.deleteModel(modelId: modelId)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 进程管理

    func getProcessList(username: String, withReply reply: @escaping (String) -> Void) {
        let entries = ProcessManager.listProcesses(username: username)
        let json = (try? JSONEncoder().encode(entries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        reply(json)
    }

    func getProcessListSnapshot(username: String, withReply reply: @escaping (String) -> Void) {
        let snapshot = ProcessManager.listProcessSnapshot(username: username)
        let json = (try? JSONEncoder().encode(snapshot))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"entries":[],"portsLoading":false,"updatedAt":0}"#
        reply(json)
    }

    func getProcessDetail(pid: Int32, withReply reply: @escaping (String) -> Void) {
        let json = ProcessManager.processDetail(pid: pid)
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func killProcess(pid: Int32, signal: Int32,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[proc] XPC killProcess pid=\(pid) signal=\(signal)")
        let ok = ProcessManager.killProcess(pid: pid, signal: signal)
        if ok {
            helperLog("[proc] kill ok pid=\(pid) signal=\(signal)", level: .debug, channel: .diagnostics)
            reply(true, nil)
        } else {
            let code = errno
            let msg = String(cString: strerror(code))
            helperLog("[proc] kill failed pid=\(pid) signal=\(signal) errno=\(code) msg=\(msg)",
                      level: .warn, channel: .diagnostics)
            reply(false, "kill(\(pid), \(signal)) 失败: \(msg)")
        }
    }

    // MARK: - 角色定义 Git 管理

    func initPersonaGitRepo(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let requestID = UUID().uuidString
        helperLog(
            "[PersonaGit] initRepo",
            level: .debug,
            username: username,
            requestID: requestID,
            component: "PersonaGit",
            event: "initRepo"
        )
        do {
            try PersonaGitManager.initRepo(username: username)
            reply(true, nil)
        } catch {
            helperLog(
                "[PersonaGit] initRepo error: \(error)",
                level: .error,
                username: username,
                requestID: requestID,
                component: "PersonaGit",
                event: "initRepo"
            )
            reply(false, error.localizedDescription)
        }
    }

    func commitPersonaFile(username: String, filename: String, message: String,
                           withReply reply: @escaping (Bool, String?) -> Void) {
        let requestID = UUID().uuidString
        helperLog(
            "[PersonaGit] commitFile",
            level: .debug,
            username: username,
            requestID: requestID,
            component: "PersonaGit",
            event: "commitFile",
            fields: ["filename": filename]
        )
        do {
            try PersonaGitManager.commitFile(username: username, filename: filename, message: message)
            reply(true, nil)
        } catch {
            helperLog(
                "[PersonaGit] commitFile error: \(error)",
                level: .error,
                username: username,
                requestID: requestID,
                component: "PersonaGit",
                event: "commitFile",
                fields: ["filename": filename]
            )
            reply(false, error.localizedDescription)
        }
    }

    func getPersonaFileHistory(username: String, filename: String,
                               withReply reply: @escaping (String?, String?) -> Void) {
        let requestID = UUID().uuidString
        helperLog(
            "[PersonaGit] getHistory",
            level: .debug,
            username: username,
            requestID: requestID,
            component: "PersonaGit",
            event: "getHistory",
            fields: ["filename": filename]
        )
        do {
            let commits = try PersonaGitManager.getHistory(username: username, filename: filename)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(commits)
            reply(String(data: data, encoding: .utf8), nil)
        } catch {
            helperLog(
                "[PersonaGit] getHistory error: \(error)",
                level: .error,
                username: username,
                requestID: requestID,
                component: "PersonaGit",
                event: "getHistory",
                fields: ["filename": filename]
            )
            reply(nil, error.localizedDescription)
        }
    }

    func getPersonaFileDiff(username: String, filename: String, commitHash: String,
                            withReply reply: @escaping (String?, String?) -> Void) {
        let requestID = UUID().uuidString
        helperLog(
            "[PersonaGit] getDiff",
            level: .debug,
            username: username,
            requestID: requestID,
            component: "PersonaGit",
            event: "getDiff",
            fields: ["filename": filename, "commitHash": commitHash]
        )
        do {
            let diff = try PersonaGitManager.getDiff(username: username, filename: filename, commitHash: commitHash)
            reply(diff, nil)
        } catch {
            helperLog(
                "[PersonaGit] getDiff error: \(error)",
                level: .error,
                username: username,
                requestID: requestID,
                component: "PersonaGit",
                event: "getDiff",
                fields: ["filename": filename, "commitHash": commitHash]
            )
            reply(nil, error.localizedDescription)
        }
    }

    func restorePersonaFileToCommit(username: String, filename: String, commitHash: String,
                                    withReply reply: @escaping (Bool, String?) -> Void) {
        let requestID = UUID().uuidString
        helperLog(
            "[PersonaGit] restoreToCommit",
            level: .debug,
            username: username,
            requestID: requestID,
            component: "PersonaGit",
            event: "restoreToCommit",
            fields: ["filename": filename, "commitHash": commitHash]
        )
        do {
            try PersonaGitManager.restoreToCommit(username: username, filename: filename, commitHash: commitHash)
            reply(true, nil)
        } catch {
            helperLog(
                "[PersonaGit] restoreToCommit error: \(error)",
                level: .error,
                username: username,
                requestID: requestID,
                component: "PersonaGit",
                event: "restoreToCommit",
                fields: ["filename": filename, "commitHash": commitHash]
            )
            reply(false, error.localizedDescription)
        }
    }
}
