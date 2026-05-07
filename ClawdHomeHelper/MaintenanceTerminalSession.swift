// ClawdHomeHelper/MaintenanceTerminalSession.swift
// 通用维护终端会话（Helper 侧 PTY）

import Foundation

// MARK: - 通用维护终端会话（Helper 侧 PTY）

final class MaintenanceTerminalSession {
    let id: String
    let username: String
    let process: Process
    let stdinPipe: Pipe
    private let outputPipe: Pipe
    private let lock = NSLock()
    private var outputBuffer = Data()
    private var ttyDevicePath: String?
    private var lastResize: (cols: Int, rows: Int)?
    private(set) var exited = false
    private(set) var exitCode: Int32 = -1
    /// 上次被 poll 的时间（用于自动清理空闲会话）
    private(set) var lastPollTime = Date()

    private static func ensureNpxShimDirectory(username: String) throws -> String {
        let shimDir = "/tmp/clawdhome-maintenance-shims/\(username)"
        let npxShim = "\(shimDir)/npx"

        try FileManager.default.createDirectory(
            atPath: shimDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let target = try? ConfigWriter.findIsolatedNpxBinary(for: username)
        let script: String
        if let target {
            script = """
                #!/bin/sh
                exec "\(target)" "$@"
                """
        } else {
            script = """
                #!/bin/sh
                echo "npx is restricted to the isolated user environment (~/.brew), but no isolated npx was found." >&2
                exit 127
                """
        }

        let existing = try? String(contentsOfFile: npxShim, encoding: .utf8)
        if existing != script {
            try Data(script.utf8).write(to: URL(fileURLWithPath: npxShim), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npxShim)
        }

        return shimDir
    }

    init(username: String, nodePath: String, command: [String]) throws {
        self.id = UUID().uuidString
        self.username = username
        self.process = Process()
        self.stdinPipe = Pipe()
        self.outputPipe = Pipe()

        let home = "/Users/\(username)"
        let inheritedEnv = ProcessInfo.processInfo.environment
        let lang = inheritedEnv["LANG"] ?? "en_US.UTF-8"
        let lcAll = inheritedEnv["LC_ALL"] ?? lang
        let lcCType = inheritedEnv["LC_CTYPE"] ?? lang
        let argv0 = command.first ?? ""
        let normalizedArgv0 = (argv0 as NSString).lastPathComponent.lowercased()
        let argvRest = Array(command.dropFirst())
        let isHermesCommand = (normalizedArgv0 == "hermes")
        let isHermesShellCommand = (normalizedArgv0 == "hermes-shell")
        let isZshCommand = (normalizedArgv0 == "zsh" || normalizedArgv0 == "hermes-shell")

        let resolvedExecutable: String
        switch normalizedArgv0 {
        case "openclaw":
            resolvedExecutable = "\(home)/.npm-global/bin/openclaw"
        case "hermes":
            resolvedExecutable = HermesInstaller.hermesExecutable(for: username)
        case "hermes-shell":
            resolvedExecutable = "/bin/zsh"
        case "zsh":
            resolvedExecutable = "/bin/zsh"
        case "bash":
            resolvedExecutable = "/bin/bash"
        case "sh":
            resolvedExecutable = "/bin/sh"
        default:
            resolvedExecutable = argv0
        }

        // hermes 命令：login shell (-l) 的初始化脚本可能通过 path_helper 覆盖 PATH，
        // 在 bootstrap 脚本里强制重新 export，确保 ~/.local/bin 始终可见。
        let bootstrapScript: String
        if isHermesCommand || isHermesShellCommand {
            let hermesPATH = HermesInstaller.buildPath(for: username)
                .replacingOccurrences(of: "'", with: "'\"'\"'")
            bootstrapScript = "export PATH='\(hermesPATH)'; stty cols 120 rows 40 >/dev/null 2>&1 || true; exec \"$0\" \"$@\""
        } else {
            bootstrapScript = "stty cols 120 rows 40 >/dev/null 2>&1 || true; exec \"$0\" \"$@\""
        }

        // Hermes / OpenClaw 使用完全独立的环境变量（PATH、HOME 等互不混用）
        let runtimeEnv: [(String, String)]
        if isHermesCommand || isHermesShellCommand {
            runtimeEnv = HermesInstaller.orderedRuntimeEnvironment(username: username)
        } else {
            runtimeEnv = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
        }
        var envArgs = runtimeEnv.map { "\($0.0)=\($0.1)" }
        envArgs.append(contentsOf: [
            "LANG=\(lang)",
            "LC_ALL=\(lcAll)",
            "LC_CTYPE=\(lcCType)",
            "TERM=xterm-256color",
        ])

        let executableArgs: [String]
        if isZshCommand {
            // 关闭 zsh 的 PROMPT_SP，避免终端中出现额外的 "%" 行尾标记。
            executableArgs = ["-o", "NO_PROMPT_SP"] + argvRest
        } else {
            executableArgs = argvRest
        }

        let commandArgs = [
            "-q", "/dev/null",
            "/usr/bin/sudo", "-n", "-u", username, "-H",
            "/usr/bin/env",
        ] + envArgs + [
            "/bin/sh", "-lc", bootstrapScript,
            resolvedExecutable,
        ] + executableArgs

        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = commandArgs
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
    }

    func start() throws {
        let reader = outputPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard let self else { return }
            if chunk.isEmpty { return }
            // 在 Helper 侧立即响应 CPR 查询（\033[6n），避免 TUI 应用因
            // XPC 轮询延迟（>250ms）等待超时后退化到无 CPR 模式。
            self.respondToCPRIfNeeded(chunk)
            self.lock.lock()
            self.outputBuffer.append(chunk)
            self.lock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            reader.readabilityHandler = nil
            let tail = reader.readDataToEndOfFile()
            self.lock.lock()
            if !tail.isEmpty {
                self.outputBuffer.append(tail)
            }
            self.exited = true
            self.exitCode = proc.terminationStatus
            self.ttyDevicePath = nil
            self.lock.unlock()
            helperLog("[maintenance] session terminated id=\(self.id) user=\(self.username) exit=\(proc.terminationStatus)")
        }

        try process.run()
        refreshTTYDevicePathIfNeeded()
        try? resize(cols: 120, rows: 40)
    }

    func poll(fromOffset: Int64) -> (chunk: Data, nextOffset: Int64, exited: Bool, exitCode: Int32) {
        lock.lock()
        defer { lock.unlock() }

        lastPollTime = Date()
        let start = max(0, min(Int(fromOffset), outputBuffer.count))
        let slice = outputBuffer.subdata(in: start..<outputBuffer.count)
        return (slice, Int64(outputBuffer.count), exited, exitCode)
    }

    func sendInput(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func resize(cols: Int, rows: Int) throws {
        guard cols > 0, rows > 0 else { return }

        lock.lock()
        let hasExited = exited
        let sameAsLast = (lastResize?.cols == cols && lastResize?.rows == rows)
        lock.unlock()
        guard !hasExited, !sameAsLast else { return }

        refreshTTYDevicePathIfNeeded()
        guard let ttyDevicePath else {
            throw NSError(domain: "MaintenanceTerminalSession",
                          code: 1001,
                          userInfo: [NSLocalizedDescriptionKey: "未找到会话终端设备"])
        }

        try run("/bin/stty", args: ["-f", ttyDevicePath, "cols", "\(cols)", "rows", "\(rows)"])

        lock.lock()
        lastResize = (cols, rows)
        lock.unlock()
    }

    private func refreshTTYDevicePathIfNeeded() {
        lock.lock()
        let existingPath = ttyDevicePath
        lock.unlock()
        if existingPath != nil { return }
        guard process.processIdentifier > 0 else { return }

        guard let rawTTY = try? run("/bin/ps", args: ["-o", "tty=", "-p", "\(process.processIdentifier)"]) else {
            return
        }
        let ttyName = rawTTY.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ttyName.isEmpty, ttyName != "?", ttyName != "??" else { return }
        let normalized = ttyName.hasPrefix("/dev/") ? ttyName : "/dev/\(ttyName)"
        guard FileManager.default.fileExists(atPath: normalized) else { return }

        lock.lock()
        ttyDevicePath = normalized
        lock.unlock()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - CPR 即时响应

    /// 扫描输出 chunk 中的 CPR 查询（\033[6n），立即通过 stdin 回写当前终端尺寸。
    /// TUI 应用（如 hermes）通常在启动时发出 CPR 并设置极短超时（~50ms）；
    /// 若依赖 app 侧 SwiftTerm 经 XPC 轮询（>250ms）响应，会直接超时并退化。
    private func respondToCPRIfNeeded(_ data: Data) {
        // 快路径：无 ESC 字节时跳过
        guard data.contains(0x1B) else { return }
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\u{1B}[6n") else { return }
        lock.lock()
        let size = lastResize ?? (cols: 120, rows: 40)
        lock.unlock()
        // 回报光标在终端左上角（1;1），让 TUI 应用知晓 CPR 可用并自行定位。
        // 注：script -q 不输出 banner，终端启动时光标确实在 (1,1)。
        _ = size
        let cpr = "\u{1B}[1;1R"
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(cpr.utf8))
    }
}
