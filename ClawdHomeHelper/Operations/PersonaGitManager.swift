// ClawdHomeHelper/Operations/PersonaGitManager.swift
// 角色定义文件的 git 操作封装（在 Shrimp 用户的 workspace 目录下维护 git 仓库）
//
// 设计要点：
//   - 所有 git 命令以 sudo -u <shrimp> /usr/bin/git 执行，确保 .git/ owner 是 Shrimp 用户
//   - 无 amend 逻辑，每次保存均新建 commit（简单、安全、历史完整）
//   - git log/diff 加 10 秒超时，防止 CLT license 未 accept 等情况导致永久阻塞
//   - workdir 通过 Process.currentDirectoryURL 设置，无需拼接路径到 git 参数

import Foundation

// MARK: - PersonaGitManager

struct PersonaGitManager {

    // MARK: - 常量

    private static let workspacePath = ".openclaw/workspace"

    // MARK: - 初始化 git repo（幂等）

    /// 初始化 workspace git repo
    /// 实现顺序：mkdir -p → git init → git config user.name/email
    /// 对已初始化 repo 是 no-op（git init 幂等）
    static func initRepo(username: String) throws {
        let workdir = homeDir(username) + "/" + workspacePath

        // 确保目录存在
        try FileManager.default.createDirectory(
            atPath: workdir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 修正目录所有权（mkdir 由 root 执行，需归还给虾用户）
        // macOS 上普通用户的主 group 是 staff，不能用 username 作为 group name
        try run("/usr/sbin/chown", args: ["-R", "\(username):staff", workdir])

        // git init（幂等）
        try gitRun(username: username, workdir: workdir, args: ["init"])

        // 配置 git 身份（本地 repo 级别，commit author）
        try gitRun(username: username, workdir: workdir,
                   args: ["config", "user.name", username])
        try gitRun(username: username, workdir: workdir,
                   args: ["config", "user.email", "\(username)@localhost"])
    }

    // MARK: - 提交单个文件

    /// 将指定文件的当前内容提交到 git
    /// - 前置条件：调用方须先确认 writeFile XPC 已成功
    /// - 文件不存在时 git add 会静默失败，此时返回 error
    static func commitFile(username: String, filename: String, message: String) throws {
        let workdir = homeDir(username) + "/" + workspacePath

        // git add <filename>
        try gitRun(username: username, workdir: workdir, args: ["add", filename])

        // git commit（每次新建 commit，无 amend）
        do {
            try gitRun(username: username, workdir: workdir, args: ["commit", "-m", message])
        } catch let e as ShellError {
            // "nothing to commit" 不视为错误（文件内容未变化时保存）
            if case .nonZeroExit(_, _, let stderr) = e,
               isNothingToCommitMessage(stderr) {
                return
            }
            throw e
        }
    }

    // MARK: - 读取文件历史

    /// 获取指定文件的 git 提交历史（仅该文件）
    /// 返回按时间倒序排列的 [PersonaCommit]
    static func getHistory(username: String, filename: String) throws -> [PersonaCommit] {
        let workdir = homeDir(username) + "/" + workspacePath

        // 分隔符用 \u{01}（ASCII SOH）避免与 commit message 内容冲突
        let sep = "\u{01}"
        let output: String
        do {
            output = try gitRunWithTimeout(
                username: username,
                workdir: workdir,
                args: ["log", "--format=%h\u{01}%aI\u{01}%s", "--", filename],
                timeout: 10
            )
        } catch let e as ShellError {
            // git init 后尚无 commit：正常情况，返回空历史
            if case .nonZeroExit(_, _, let stderr) = e,
               stderr.contains("does not have any commits yet") || stderr.contains("bad default revision") {
                return []
            }
            throw e
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        var commits: [PersonaCommit] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: sep)
            guard parts.count >= 3 else { continue }
            let hash = parts[0]
            let dateStr = parts[1]
            let msg = parts[2...].joined(separator: sep)
            let date = isoFormatter.date(from: dateStr)
                    ?? isoFormatterNoFraction.date(from: dateStr)
                    ?? Date(timeIntervalSince1970: 0)
            commits.append(PersonaCommit(hash: hash, message: msg, timestamp: date))
        }
        return commits
    }

    // MARK: - 读取 diff

    /// 获取某 commit 相对父 commit 的 diff（unified diff 字符串）
    /// 初始 commit（无父）使用 git show <hash> -- <filename>
    static func getDiff(username: String, filename: String, commitHash: String) throws -> String {
        let workdir = homeDir(username) + "/" + workspacePath

        // 检查是否是初始 commit（无父）
        let isInitial: Bool
        do {
            _ = try gitRunWithTimeout(
                username: username,
                workdir: workdir,
                args: ["rev-parse", "--verify", "\(commitHash)^"],
                timeout: 10
            )
            isInitial = false
        } catch {
            isInitial = true
        }

        if isInitial {
            return try gitRunWithTimeout(
                username: username,
                workdir: workdir,
                args: ["show", commitHash, "--", filename],
                timeout: 10
            )
        } else {
            return try gitRunWithTimeout(
                username: username,
                workdir: workdir,
                args: ["diff", "\(commitHash)^", commitHash, "--", filename],
                timeout: 10
            )
        }
    }

    // MARK: - 回滚文件

    /// 将单文件恢复到指定 commit 的内容，并产生新 commit
    /// 若内容已与目标一致（nothing to commit），视为成功
    static func restoreToCommit(username: String, filename: String, commitHash: String) throws {
        let workdir = homeDir(username) + "/" + workspacePath
        let shortHash = String(commitHash.prefix(7))
        let isoDate = ISO8601DateFormatter().string(from: Date())

        // git checkout <hash> -- <filename>（恢复工作区文件）
        try gitRun(username: username, workdir: workdir,
                   args: ["checkout", commitHash, "--", filename])

        // 修正文件所有权（checkout 由 root 通过 sudo 执行，owner 已是 shrimp，但以防万一）
        let filePath = workdir + "/" + filename
        try? run("/usr/sbin/chown", args: ["\(username):staff", filePath])

        // git add + commit
        try gitRun(username: username, workdir: workdir, args: ["add", filename])

        do {
            try gitRun(username: username, workdir: workdir,
                       args: ["commit", "-m", "回滚 \(filename) 到 \(shortHash) — \(isoDate)"])
        } catch let e as ShellError {
            // 内容已与目标一致（nothing to commit）→ 视为成功
            if case .nonZeroExit(_, _, let stderr) = e,
               isNothingToCommitMessage(stderr) {
                return
            }
            throw e
        }
    }

    // MARK: - 私有工具

    private static func homeDir(_ username: String) -> String {
        "/Users/\(username)"
    }

    private static func isNothingToCommitMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("nothing to commit") || normalized.contains("nothing added to commit")
    }

    /// 以 sudo -u <username> /usr/bin/git 执行 git 命令
    @discardableResult
    private static func gitRun(username: String, workdir: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-u", username, "/usr/bin/git"] + args
        proc.currentDirectoryURL = URL(fileURLWithPath: workdir)

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.nonZeroExit(
                command: (["/usr/bin/sudo", "-u", username, "/usr/bin/git"] + args).joined(separator: " "),
                status: proc.terminationStatus,
                // git 有些失败信息（如 nothing to commit）会写到 stdout
                stderr: trimmedErr.isEmpty ? trimmedOut : trimmedErr
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 带超时保护的 git 命令执行（超时后强制终止进程）
    @discardableResult
    private static func gitRunWithTimeout(
        username: String,
        workdir: String,
        args: [String],
        timeout: TimeInterval
    ) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-u", username, "/usr/bin/git"] + args
        proc.currentDirectoryURL = URL(fileURLWithPath: workdir)

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()

        // 超时监控：在后台线程等待超时后强制终止
        let timeoutTimer = DispatchWorkItem {
            if proc.isRunning {
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTimer)

        proc.waitUntilExit()
        timeoutTimer.cancel()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // 超时时 terminationReason 为 .uncaughtSignal
        if proc.terminationReason == .uncaughtSignal {
            throw ShellError.nonZeroExit(
                command: "git " + args.joined(separator: " "),
                status: proc.terminationStatus,
                stderr: "git 命令超时（>\(Int(timeout))秒），已强制终止"
            )
        }

        guard proc.terminationStatus == 0 else {
            let trimmedErr = err.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError.nonZeroExit(
                command: (["/usr/bin/sudo", "-u", username, "/usr/bin/git"] + args).joined(separator: " "),
                status: proc.terminationStatus,
                // git 有些失败信息（如 nothing to commit）会写到 stdout
                stderr: trimmedErr.isEmpty ? trimmedOut : trimmedErr
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
