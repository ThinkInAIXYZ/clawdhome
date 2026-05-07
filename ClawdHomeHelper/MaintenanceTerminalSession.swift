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
        let argvRest = Array(command.dropFirst())
        let effectivePath = nodePath
        let resolvedExecutable: String
        switch argv0 {
        case "openclaw":
            resolvedExecutable = "\(home)/.npm-global/bin/openclaw"
        case "zsh":
            resolvedExecutable = "/bin/zsh"
        case "bash":
            resolvedExecutable = "/bin/bash"
        case "sh":
            resolvedExecutable = "/bin/sh"
        default:
            resolvedExecutable = argv0
        }

        let bootstrapScript = "stty cols 120 rows 40 >/dev/null 2>&1 || true; exec \"$0\" \"$@\""

        var envArgs = UserEnvContract
            .orderedRuntimeEnvironment(username: username, nodePath: effectivePath)
            .map { "\($0.0)=\($0.1)" }
        envArgs.append(contentsOf: [
            "LANG=\(lang)",
            "LC_ALL=\(lcAll)",
            "LC_CTYPE=\(lcCType)",
            "TERM=xterm-256color",
        ])

        let commandArgs = [
            "-q", "/dev/null",
            "/usr/bin/sudo", "-n", "-u", username, "-H",
            "/usr/bin/env",
        ] + envArgs + [
            "/bin/sh", "-lc", bootstrapScript,
            resolvedExecutable,
        ] + argvRest

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

    func poll(fromOffset: Int64) -> (chunk: String, nextOffset: Int64, exited: Bool, exitCode: Int32) {
        lock.lock()
        defer { lock.unlock() }

        lastPollTime = Date()
        let start = max(0, min(Int(fromOffset), outputBuffer.count))
        let slice = outputBuffer.subdata(in: start..<outputBuffer.count)
        let text = String(decoding: slice, as: UTF8.self)
        return (text, Int64(outputBuffer.count), exited, exitCode)
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
}
