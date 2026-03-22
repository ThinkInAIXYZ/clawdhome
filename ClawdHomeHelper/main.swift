// ClawdHomeHelper/main.swift
// ClawdHomeHelper LaunchDaemon — root 权限常驻服务
// 接受来自 ClawdHome.app 的 XPC 请求，代理执行跨用户操作

import Foundation
import Security
import SQLite3
import SystemConfiguration

// MARK: - 日志工具（结构化 JSONL + 滚动归档）

enum LogLevel: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }
enum LogChannel {
    case primary
    case fileManager
    case diagnostics

    var tag: String {
        switch self {
        case .primary: return "PRIMARY"
        case .fileManager: return "FILEIO"
        case .diagnostics: return "DIAG"
        }
    }
}

private extension LogLevel {
    var rank: Int {
        switch self {
        case .debug: return 10
        case .info:  return 20
        case .warn:  return 30
        case .error: return 40
        }
    }
}

private let helperLogFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()
private let helperLogEncoder = JSONEncoder()
private let helperLogCheckEvery = 300
private let helperLogMaxBytes = 2_000_000
private let helperLogRotateKeep = 3
private let helperLogPath = "/tmp/clawdhome-helper.log"
private let helperLogQueue = DispatchQueue(label: "ai.clawdhome.helper.log", qos: .utility)
private var helperLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: helperLogPath, contents: nil)
    let fh = FileHandle(forWritingAtPath: helperLogPath)
    fh?.seekToEndOfFile()
    return fh
}()
private var helperLogWriteCount = 0
private let helperDebugFlagPath = "/var/lib/clawdhome/helper-debug-logging-enabled"
private let helperDebugLock = NSLock()
private var helperDebugEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment["CLAWDHOME_HELPER_DEBUG"]?.lowercased() ?? ""
    if env == "1" || env == "true" || env == "yes" { return true }
    return FileManager.default.fileExists(atPath: helperDebugFlagPath)
}()

private enum LogRedactor {
    private static let compiledRules: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            (#"(#token=)[^\s"'&]+"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:token|api[_-]?key|password|secret)=)[^&\s]+"#, "$1[REDACTED]"),
            (#"(?i)("(?:token|api[_-]?key|password|secret|authorization)"\s*:\s*")[^"]*(")"#, "$1[REDACTED]$2"),
            (#"(?i)("--(?:token|api[-_]?key|password|secret)"\s*,\s*")[^"]*(")"#, "$1[REDACTED]$2"),
            (#"(?i)(--(?:token|api[-_]?key|password|secret)\s+)\S+"#, "$1[REDACTED]"),
            (#"(?i)(-P\s+)\S+"#, "$1[REDACTED]"),
            (#"(?i)(gateway\.auth\.token\s*=\s*)\S+"#, "$1[REDACTED]"),
            (#"(?i)((?:x-api-key|x-goog-api-key)\s*[:=]\s*)\S+"#, "$1[REDACTED]"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+\/=-]+"#, "$1[REDACTED]"),
        ]
        return rules.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ message: String) -> String {
        var text = message
        for (regex, replacement) in compiledRules {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        return text
    }
}

private struct HelperLogRecord: Codable {
    let ts: String
    let level: String
    let channel: String
    let message: String
    let pid: Int32
}

private func isHelperDebugLoggingEnabled() -> Bool {
    helperDebugLock.lock()
    defer { helperDebugLock.unlock() }
    return helperDebugEnabled
}

@discardableResult
private func setHelperDebugLoggingEnabled(_ enabled: Bool) -> Bool {
    helperDebugLock.lock()
    helperDebugEnabled = enabled
    helperDebugLock.unlock()

    do {
        try FileManager.default.createDirectory(
            atPath: "/var/lib/clawdhome",
            withIntermediateDirectories: true,
            attributes: nil
        )
        if enabled {
            if !FileManager.default.fileExists(atPath: helperDebugFlagPath) {
                FileManager.default.createFile(atPath: helperDebugFlagPath, contents: nil)
            }
        } else if FileManager.default.fileExists(atPath: helperDebugFlagPath) {
            try FileManager.default.removeItem(atPath: helperDebugFlagPath)
        }
        return true
    } catch {
        return false
    }
}

func helperLog(_ message: String, level: LogLevel = .info, channel: LogChannel = .primary) {
    let safeMessage = LogRedactor.redact(message)
    let debugEnabled = isHelperDebugLoggingEnabled()
    if !debugEnabled {
        // 非 DEBUG 模式下控制日志量：仅保留核心日志与警告/错误。
        switch channel {
        case .primary:
            if level == .debug { return }
        case .fileManager, .diagnostics:
            if level.rank < LogLevel.warn.rank { return }
        }
    }

    helperLogQueue.async {
        if helperLogHandle == nil {
            FileManager.default.createFile(atPath: helperLogPath, contents: nil)
            helperLogHandle = FileHandle(forWritingAtPath: helperLogPath)
            helperLogHandle?.seekToEndOfFile()
        }
        let record = HelperLogRecord(
            ts: helperLogFmt.string(from: Date()),
            level: level.rawValue,
            channel: channel.tag,
            message: safeMessage,
            pid: getpid()
        )
        let lineData: Data
        if let encoded = try? helperLogEncoder.encode(record) {
            var d = encoded
            d.append(0x0A)
            lineData = d
        } else {
            lineData = Data("[\(record.ts)] [\(record.level)] [\(record.channel)] \(safeMessage)\n".utf8)
        }
        helperLogHandle?.write(lineData)

        helperLogWriteCount += 1
        if helperLogWriteCount >= helperLogCheckEvery {
            helperLogWriteCount = 0
            rotateHelperLogIfNeeded()
        }
    }
}

/// 当文件超过阈值时滚动归档（仅在 helperLogQueue 中调用）
private func rotateHelperLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: helperLogPath),
          let size = attrs[.size] as? Int,
          size > helperLogMaxBytes else { return }

    helperLogHandle?.closeFile()
    helperLogHandle = nil

    let fm = FileManager.default
    for idx in stride(from: helperLogRotateKeep, through: 1, by: -1) {
        let src = idx == 1 ? helperLogPath : "\(helperLogPath).\(idx - 1)"
        let dst = "\(helperLogPath).\(idx)"
        guard fm.fileExists(atPath: src) else { continue }
        try? fm.removeItem(atPath: dst)
        try? fm.moveItem(atPath: src, toPath: dst)
    }

    fm.createFile(atPath: helperLogPath, contents: nil)
    helperLogHandle = FileHandle(forWritingAtPath: helperLogPath)
    helperLogHandle?.seekToEndOfFile()
}

// MARK: - 通用维护终端会话（Helper 侧 PTY）

private final class MaintenanceTerminalSession {
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

    init(username: String, nodePath: String, command: [String]) {
        self.id = UUID().uuidString
        self.username = username
        self.process = Process()
        self.stdinPipe = Pipe()
        self.outputPipe = Pipe()

        let home = "/Users/\(username)"
        let npmGlobalDir = "\(home)/.npm-global"
        let inheritedEnv = ProcessInfo.processInfo.environment
        let lang = inheritedEnv["LANG"] ?? "en_US.UTF-8"
        let lcAll = inheritedEnv["LC_ALL"] ?? lang
        let lcCType = inheritedEnv["LC_CTYPE"] ?? lang
        let argv0 = command.first ?? ""
        let argvRest = Array(command.dropFirst())
        let resolvedExecutable: String
        switch argv0 {
        case "openclaw":
            resolvedExecutable = "\(home)/.npm-global/bin/openclaw"
        default:
            resolvedExecutable = argv0
        }

        let bootstrapScript = "stty cols 120 rows 40 >/dev/null 2>&1 || true; exec \"$0\" \"$@\""

        let commandArgs = [
            "-q", "/dev/null",
            "/usr/bin/sudo", "-n", "-u", username, "-H",
            "/usr/bin/env",
            "HOME=\(home)",
            "PATH=\(nodePath)",
            "NPM_CONFIG_PREFIX=\(npmGlobalDir)",
            "npm_config_prefix=\(npmGlobalDir)",
            "LANG=\(lang)",
            "LC_ALL=\(lcAll)",
            "LC_CTYPE=\(lcCType)",
            "TERM=xterm-256color",
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

// MARK: - Helper 实现

final class ClawdHomeHelperImpl: NSObject, ClawdHomeHelperProtocol {
    private let maintenanceSessionLock = NSLock()
    private var maintenanceSessions: [String: MaintenanceTerminalSession] = [:]

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(kHelperVersion)
    }

    // MARK: 用户管理

    func createUser(username: String, fullName: String, password: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("用户创建 @\(username) (\(fullName))")
        do {
            try UserManager.createUser(username: username, fullName: fullName, password: password)
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
        reply(true, nil)
    }

    // MARK: Gateway 管理

    func startGateway(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Gateway 启动 @\(username)")
        do {
            let uid = try UserManager.uid(for: username)
            try GatewayManager.startGateway(username: username, uid: uid)
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
            try GatewayManager.restartGateway(username: username, uid: uid)
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
    private static let autostartDisabledPath = "/var/lib/clawdhome/gateway-autostart-disabled"

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

    private static func userAutostartDisabledPath(username: String) -> String {
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
        // 防止 DirectoryService / launchctl 异常阻塞导致 UI 长时间停留在“检查环境…”
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

    func setConfig(username: String, key: String, value: String,
                   withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("配置变更 @\(username) \(key)=\(value)")
        do {
            let logURL = initLogURL(username: username)
            try ConfigWriter.setConfig(username: username, key: key, value: value, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("配置变更失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func installOpenclaw(username: String, version: String?,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("安装 openclaw @\(username) v\(version ?? "latest")")
        let logURL = initLogURL(username: username)
        do {
            try InstallManager.install(username: username, version: version, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("安装 openclaw 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getOpenclawVersion(username: String, withReply reply: @escaping (String) -> Void) {
        reply(InstallManager.installedVersion(username: username) ?? "")
    }

    // MARK: 用户环境初始化

    /// 初始化日志路径，world-readable，供 app 实时读取
    private func initLogURL(username: String) -> URL {
        let path = "/tmp/clawdhome-init-\(username).log"
        // 确保文件存在且 world-readable（Helper 以 root 运行）
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                attributes: [.posixPermissions: 0o644])
        }
        return URL(fileURLWithPath: path)
    }

    func installNode(username: String, nodeDistURL: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let logURL = initLogURL(username: username)

        func appendLog(_ msg: String) {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(msg.utf8))
                fh.closeFile()
            }
        }

        // 检查 Node.js 是否已安装（直接下载路径）
        if NodeDownloader.isInstalled() {
            let version = (try? run("/usr/local/bin/node", args: ["--version"]))
                ?? "(version unknown)"
            appendLog("✓ Node.js 已安装：\(version)\n")
            reply(true, nil)
            return
        }

        do {
            try NodeDownloader.install(distBaseURL: nodeDistURL, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("安装 Node.js 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func isNodeInstalled(withReply reply: @escaping (Bool) -> Void) {
        reply(NodeDownloader.isInstalled())
    }

    func getXcodeEnvStatus(withReply reply: @escaping (String) -> Void) {
        let status = InstallManager.xcodeEnvStatus()
        let json = (try? JSONEncoder().encode(status)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func installXcodeCommandLineTools(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("触发 Xcode Command Line Tools 安装")
        do {
            try InstallManager.installXcodeCommandLineTools()
            reply(true, "已触发系统安装窗口，请按提示完成安装。")
        } catch {
            helperLog("触发 Xcode CLT 安装失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func acceptXcodeLicense(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("接受 Xcode license")
        do {
            try InstallManager.acceptXcodeLicense()
            reply(true, "已执行 license 接受。")
        } catch {
            helperLog("接受 Xcode license 失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func setupNpmEnv(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let logURL = initLogURL(username: username)
        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        let npmGlobalBin = InstallManager.npmGlobalBin(for: username)

        func appendLog(_ msg: String) {
            if let fh = FileHandle(forWritingAtPath: logURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(msg.utf8))
                fh.closeFile()
            }
        }

        do {
            // 1. 创建 ~/.npm-global 和 ~/.npm-global/bin 目录
            appendLog("$ mkdir -p \(npmGlobalBin)\n")
            try FileManager.default.createDirectory(
                atPath: npmGlobalBin,
                withIntermediateDirectories: true,
                attributes: [.ownerAccountName: username, .posixPermissions: 0o755]
            )
            try run("/usr/sbin/chown", args: ["-R", username, npmGlobal])
            appendLog("✓ 已创建 \(npmGlobal)\n")

            // 2. 将 npm 全局环境写入 ~/.zprofile（幂等）
            let profilePath = "/Users/\(username)/.zprofile"
            let existing = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
            let requiredExports = [
                "export NPM_CONFIG_PREFIX=\"$HOME/.npm-global\"",
                "export npm_config_prefix=\"$HOME/.npm-global\"",
                "export PATH=\"$HOME/.npm-global/bin:$PATH\"",
            ]
            let missingExports = requiredExports.filter { !existing.contains($0) }
            if !missingExports.isEmpty {
                var exportBlock = "\n"
                if !existing.contains("# npm global") {
                    exportBlock += "# npm global\n"
                }
                exportBlock += missingExports.joined(separator: "\n") + "\n"
                let data = Data(exportBlock.utf8)
                if FileManager.default.fileExists(atPath: profilePath) {
                    if let fh = FileHandle(forWritingAtPath: profilePath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try data.write(to: URL(fileURLWithPath: profilePath))
                    try run("/usr/sbin/chown", args: [username, profilePath])
                }
                appendLog("✓ 已将 npm global prefix/PATH 写入 ~/.zprofile\n")
            } else {
                appendLog("✓ ~/.zprofile 已包含 npm-global prefix + PATH 配置\n")
            }

            // 3. 确保 .zshrc 中 compinit 在 openclaw 补全脚本之前调用
            //    openclaw postinstall 会 append "source ~/.openclaw/completions/openclaw.zsh"，
            //    若 compinit 未事先初始化则 compdef 报错；此处提前写入，顺序正确
            let zshrcPath = "/Users/\(username)/.zshrc"
            let zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            if !zshrcContent.contains("compinit") {
                let compLine = "\n# zsh completion init (required before openclaw completions)\nautoload -Uz compinit && compinit\n"
                let data = Data(compLine.utf8)
                if FileManager.default.fileExists(atPath: zshrcPath) {
                    if let fh = FileHandle(forWritingAtPath: zshrcPath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        fh.closeFile()
                    }
                } else {
                    try data.write(to: URL(fileURLWithPath: zshrcPath))
                    try run("/usr/sbin/chown", args: [username, zshrcPath])
                }
                appendLog("✓ 已在 ~/.zshrc 中添加 compinit 初始化\n")
            } else {
                appendLog("✓ ~/.zshrc 已包含 compinit 配置\n")
            }

            // 4. 规范 openclaw completion 加载方式：仅在文件存在时 source，避免 reset 后报错
            var zshrcNormalized = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
            let lines = zshrcNormalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var filtered: [String] = []
            var skippingManagedBlock = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // 删除历史写入的 managed block，后续统一重建一份
                if trimmed == "# openclaw completion (safe-guarded)" {
                    skippingManagedBlock = true
                    continue
                }
                if skippingManagedBlock {
                    if trimmed == "fi" { skippingManagedBlock = false }
                    continue
                }

                // 删除旧的无保护 source（含绝对路径/波浪线两种）
                if trimmed == "source ~/.openclaw/completions/openclaw.zsh"
                    || trimmed == "source /Users/\(username)/.openclaw/completions/openclaw.zsh"
                    || (trimmed.hasPrefix("source ") && trimmed.contains(".openclaw/completions/openclaw.zsh")) {
                    continue
                }
                filtered.append(line)
            }

            zshrcNormalized = filtered.joined(separator: "\n")
            if !zshrcNormalized.hasSuffix("\n"), !zshrcNormalized.isEmpty {
                zshrcNormalized += "\n"
            }
            let completionBlock = """
                # openclaw completion (safe-guarded)
                if [ -f "$HOME/.openclaw/completions/openclaw.zsh" ]; then
                  source "$HOME/.openclaw/completions/openclaw.zsh"
                fi
                """
            if !zshrcNormalized.isEmpty { zshrcNormalized += "\n" }
            zshrcNormalized += completionBlock + "\n"

            if zshrcNormalized != zshrcContent {
                try Data(zshrcNormalized.utf8).write(to: URL(fileURLWithPath: zshrcPath))
                try run("/usr/sbin/chown", args: [username, zshrcPath])
                appendLog("✓ 已修复 openclaw 补全加载逻辑（文件不存在时不报错）\n")
            } else {
                appendLog("✓ openclaw 补全加载逻辑已是安全模式\n")
            }

            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func setNpmRegistry(username: String, registry: String,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("设置 npm 源 @\(username): \(registry)")
        if !NodeDownloader.isInstalled() {
            let message = "Node.js 未安装就绪，暂不允许切换 npm 源"
            helperLog("设置 npm 源失败 @\(username): \(message)", level: .warn)
            reply(false, message)
            return
        }
        let logURL = initLogURL(username: username)
        do {
            _ = try InstallManager.setNpmRegistry(username: username, registry: registry, logURL: logURL)
            reply(true, nil)
        } catch {
            helperLog("设置 npm 源失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func getNpmRegistry(username: String, withReply reply: @escaping (String) -> Void) {
        reply(InstallManager.getNpmRegistry(username: username))
    }

    func cancelInit(username: String, withReply reply: @escaping (Bool) -> Void) {
        let logPath = "/tmp/clawdhome-init-\(username).log"
        terminateManagedProcess(logPath: logPath)
        reply(true)
    }

    func resetUserEnv(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("环境重置 @\(username)")
        let home = "/Users/\(username)"
        let targets = [InstallManager.npmGlobalDir(for: username), "\(home)/.openclaw"]
        var errors: [String] = []
        for path in targets {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        if errors.isEmpty {
            reply(true, nil)
        } else {
            helperLog("环境重置失败 @\(username): \(errors.joined(separator: "; "))", level: .error)
            reply(false, errors.joined(separator: "\n"))
        }
    }

    func getGatewayURL(username: String, withReply reply: @escaping (String) -> Void) {
        guard let uid = try? UserManager.uid(for: username) else {
            reply(""); return
        }
        // 优先读配置文件中的实际端口（可能因冲突偏移），回退到 18000+uid 公式
        let port = GatewayManager.readConfiguredPort(username: username) ?? GatewayManager.port(for: uid)
        let base = "http://127.0.0.1:\(port)/"
        // 直接读取 JSON 文件获取 token（CLI config get 会脱敏敏感字段）
        if let token = ConfigWriter.getRawConfigValue(username: username, key: "gateway.auth.token"),
           !token.isEmpty {
            reply("\(base)#token=\(token)")
        } else {
            reply(base)
        }
    }

    func backupUser(username: String, destinationPath: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("备份 @\(username) → \(destinationPath)")
        let homeDir = "/Users/\(username)"
        let openclawDir = "\(homeDir)/.openclaw"
        guard FileManager.default.fileExists(atPath: openclawDir) else {
            helperLog("备份失败 @\(username): ~/.openclaw 不存在", level: .error)
            reply(false, "~/.openclaw 目录不存在，该用户可能未初始化")
            return
        }
        // 排除可自动再生的目录/文件
        let excludes = [
            ".openclaw/tools",
            ".openclaw/sandboxes",
            ".openclaw/logs",
            ".openclaw/restart-sentinel.json"
        ]
        var args = ["-czf", destinationPath, "-C", homeDir]
        for excl in excludes { args += ["--exclude=\(excl)"] }
        args.append(".openclaw")
        do {
            try run("/usr/bin/tar", args: args)
            reply(true, nil)
        } catch {
            helperLog("备份失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func restoreUser(username: String, sourcePath: String,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("恢复 @\(username) ← \(sourcePath)")
        let homeDir = "/Users/\(username)"
        let openclawDir = "\(homeDir)/.openclaw"
        let tmpDir     = "\(homeDir)/.openclaw.restore-tmp"
        let prevDir    = "\(homeDir)/.openclaw.prev"
        let fm = FileManager.default

        // 清理可能残留的临时目录
        try? fm.removeItem(atPath: tmpDir)
        try? fm.removeItem(atPath: prevDir)

        do {
            // 1. 先解压到临时目录，失败不影响现有配置
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try run("/usr/bin/tar", args: ["-xzf", sourcePath, "-C", tmpDir])

            // 2. 验证解压结果（至少要有 .openclaw 目录）
            let extracted = "\(tmpDir)/.openclaw"
            guard fm.fileExists(atPath: extracted) else {
                try? fm.removeItem(atPath: tmpDir)
                reply(false, "备份文件格式不正确，未找到 .openclaw 目录")
                return
            }

            // 3. 原子替换：先备份现有目录（rename 在同一文件系统上是原子的）
            if fm.fileExists(atPath: openclawDir) {
                try fm.moveItem(atPath: openclawDir, toPath: prevDir)
            }
            // 4. 将解压结果移入位置（原子操作）
            do {
                try fm.moveItem(atPath: extracted, toPath: openclawDir)
            } catch {
                // 恢复旧目录，保持原状
                if fm.fileExists(atPath: prevDir) {
                    try? fm.moveItem(atPath: prevDir, toPath: openclawDir)
                }
                try? fm.removeItem(atPath: tmpDir)
                throw error
            }

            // 5. 修正所有权（root 运行解压，文件归 root；只设 user，group 由系统默认 staff）
            try run("/usr/sbin/chown", args: ["-R", username, openclawDir])

            // 6. 清理临时文件
            try? fm.removeItem(atPath: tmpDir)
            try? fm.removeItem(atPath: prevDir)

            reply(true, nil)
        } catch {
            // 清理临时目录，不动 prevDir（保留现场方便调试）
            try? fm.removeItem(atPath: tmpDir)
            helperLog("恢复失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func scanCloneClaw(username: String,
                      withReply reply: @escaping (String, String?) -> Void) {
        helperLog("克隆扫描 @\(username)")
        do {
            let result = try CloneClawManager.scanCloneItems(sourceUsername: username)
            let json = try CloneClawManager.encodeScanResult(result)
            reply(json, nil)
        } catch {
            helperLog("克隆扫描失败 @\(username): \(error.localizedDescription)", level: .error)
            reply("", error.localizedDescription)
        }
    }

    func cloneClaw(requestJSON: String,
                   withReply reply: @escaping (Bool, String, String?) -> Void) {
        helperLog("克隆新虾执行")
        do {
            let request = try CloneClawManager.decodeRequest(requestJSON)
            let result = try executeCloneClaw(request)
            let json = try CloneClawManager.encodeResult(result)
            reply(true, json, nil)
        } catch {
            helperLog("克隆执行失败: \(error.localizedDescription)", level: .error)
            reply(false, "", error.localizedDescription)
        }
    }

    private func executeCloneClaw(_ request: CloneClawRequest) throws -> CloneClawResult {
        try CloneClawManager.validateUsername(request.targetUsername)
        guard !request.selectedItemIDs.isEmpty else { throw CloneClawManagerError.noItemsSelected }

        if getpwnam(request.targetUsername) != nil {
            throw CloneClawManagerError.targetUserExists(request.targetUsername)
        }

        let scan = try CloneClawManager.scanCloneItems(sourceUsername: request.sourceUsername)
        let itemMap = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.id, $0) })
        var selectedItems: [CloneScanItem] = []
        for itemID in request.selectedItemIDs {
            guard let item = itemMap[itemID] else {
                throw CloneClawManagerError.selectedItemNotFound(itemID)
            }
            guard item.selectable else {
                throw CloneClawManagerError.selectedItemDisabled(itemID)
            }
            selectedItems.append(item)
        }
        guard !selectedItems.isEmpty else { throw CloneClawManagerError.noItemsSelected }

        let password = request.targetPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.targetPassword!
            : generatedClonePassword()
        let sourceHome = try CloneClawManager.homeDirectory(for: request.sourceUsername)

        var createdTarget = false
        do {
            try UserManager.createUser(
                username: request.targetUsername,
                fullName: request.targetFullName,
                password: password
            )
            createdTarget = true

            let targetHome = try CloneClawManager.homeDirectory(for: request.targetUsername)
            let targetUID = try UserManager.uid(for: request.targetUsername)
            let targetGID = resolvedPrimaryGroupID(username: request.targetUsername)
            let shouldSanitizeConfig = selectedItems.contains(where: { $0.kind == .openclawConfig })
            let shouldEnsureShellInit = selectedItems.contains(where: { $0.kind == .envDirectory || $0.kind == .shellProfiles })
            for item in selectedItems {
                try copyCloneItem(item, sourceHome: sourceHome, targetHome: targetHome)
            }
            if shouldSanitizeConfig {
                try sanitizeClonedConfig(
                    username: request.targetUsername,
                    uid: targetUID,
                    gid: targetGID
                )
            }
            try fixCloneOwnership(
                username: request.targetUsername,
                uid: targetUID,
                gid: targetGID
            )
            if shouldEnsureShellInit {
                try ensureCloneShellInit(username: request.targetUsername)
            }

            try GatewayManager.startGateway(username: request.targetUsername, uid: targetUID)
            // Gateway 启动会执行 openclaw config set，部分字段可能被回写为绝对路径。
            // 这里再做一次归一化，确保最终 openclaw.json 保持 ~/ 相对 home 的写法。
            if shouldSanitizeConfig {
                try sanitizeClonedConfig(
                    username: request.targetUsername,
                    uid: targetUID,
                    gid: targetGID
                )
            }
            let gatewayURL = resolveCloneGatewayURL(username: request.targetUsername, uid: targetUID)

            return CloneClawResult(
                targetUsername: request.targetUsername,
                gatewayURL: gatewayURL,
                warnings: scan.warnings
            )
        } catch {
            if createdTarget {
                rollbackCloneUser(username: request.targetUsername)
            }
            throw error
        }
    }

    private func copyCloneItem(_ item: CloneScanItem, sourceHome: String, targetHome: String) throws {
        let fm = FileManager.default
        switch item.kind {
        case .envDirectory:
            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            guard fm.fileExists(atPath: sourcePath) else {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
            let targetPath = "\(targetHome)/.npm-global"
            if fm.fileExists(atPath: targetPath) {
                try fm.removeItem(atPath: targetPath)
            }
            try fm.copyItem(atPath: sourcePath, toPath: targetPath)
        case .openclawConfig:
            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            guard fm.fileExists(atPath: sourcePath) else {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
            try copyCloneFile(from: sourcePath, to: "\(targetHome)/.openclaw/openclaw.json")
        case .shellProfiles:
            let shellRelativePaths = [".zprofile", ".zshrc"]
            var copiedAny = false
            for relativePath in shellRelativePaths {
                let sourcePath = "\(sourceHome)/\(relativePath)"
                if fm.fileExists(atPath: sourcePath) {
                    try copyCloneFile(from: sourcePath, to: "\(targetHome)/\(relativePath)")
                    copiedAny = true
                }
            }
            if !copiedAny {
                throw CloneClawManagerError.sourceItemMissing(".zprofile/.zshrc")
            }
        case .secrets:
            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            guard fm.fileExists(atPath: sourcePath) else {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
            try copyCloneFile(from: sourcePath, to: "\(targetHome)/.openclaw/secrets.json")
        case .authProfiles:
            var copiedAny = false

            let sourcePath = "\(sourceHome)/\(item.sourceRelativePath)"
            if fm.fileExists(atPath: sourcePath) {
                try copyCloneFile(from: sourcePath, to: "\(targetHome)/.openclaw/auth-profiles.json")
                copiedAny = true
            }

            let agentAuthPaths = CloneClawManager.discoverAgentAuthProfileRelativePaths(sourceHome: sourceHome)
            for relativePath in agentAuthPaths {
                try copyCloneFile(
                    from: "\(sourceHome)/\(relativePath)",
                    to: "\(targetHome)/\(relativePath)"
                )
                copiedAny = true
            }

            if !copiedAny {
                throw CloneClawManagerError.sourceItemMissing(item.sourceRelativePath)
            }
        }
    }

    private func copyCloneFile(from sourcePath: String, to targetPath: String) throws {
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: targetPath)
        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: targetPath)
    }

    private func ensureCloneShellInit(username: String) throws {
        let profilePath = "/Users/\(username)/.zprofile"
        let zshrcPath = "/Users/\(username)/.zshrc"

        let existingProfile = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
        if !existingProfile.contains(".npm-global/bin") {
            let export = "\n# npm global\nexport PATH=\"$HOME/.npm-global/bin:$PATH\"\n"
            let data = Data(export.utf8)
            if FileManager.default.fileExists(atPath: profilePath) {
                if let fh = FileHandle(forWritingAtPath: profilePath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try data.write(to: URL(fileURLWithPath: profilePath))
            }
            try run("/usr/sbin/chown", args: [username, profilePath])
        }

        var zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        if !zshrcContent.contains("compinit") {
            let compLine = "\n# zsh completion init (required before openclaw completions)\nautoload -Uz compinit && compinit\n"
            let data = Data(compLine.utf8)
            if FileManager.default.fileExists(atPath: zshrcPath) {
                if let fh = FileHandle(forWritingAtPath: zshrcPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try data.write(to: URL(fileURLWithPath: zshrcPath))
            }
            try run("/usr/sbin/chown", args: [username, zshrcPath])
            zshrcContent = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        }

        var zshrcNormalized = zshrcContent
        let lines = zshrcNormalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var filtered: [String] = []
        var skippingManagedBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# openclaw completion (safe-guarded)" {
                skippingManagedBlock = true
                continue
            }
            if skippingManagedBlock {
                if trimmed == "fi" { skippingManagedBlock = false }
                continue
            }
            if trimmed == "source ~/.openclaw/completions/openclaw.zsh"
                || trimmed == "source /Users/\(username)/.openclaw/completions/openclaw.zsh"
                || (trimmed.hasPrefix("source ") && trimmed.contains(".openclaw/completions/openclaw.zsh")) {
                continue
            }
            filtered.append(line)
        }

        zshrcNormalized = filtered.joined(separator: "\n")
        if !zshrcNormalized.hasSuffix("\n"), !zshrcNormalized.isEmpty {
            zshrcNormalized += "\n"
        }
        let completionBlock = """
            # openclaw completion (safe-guarded)
            if [ -f "$HOME/.openclaw/completions/openclaw.zsh" ]; then
              source "$HOME/.openclaw/completions/openclaw.zsh"
            fi
            """
        if !zshrcNormalized.isEmpty { zshrcNormalized += "\n" }
        zshrcNormalized += completionBlock + "\n"
        if zshrcNormalized != zshrcContent {
            try Data(zshrcNormalized.utf8).write(to: URL(fileURLWithPath: zshrcPath))
            try run("/usr/sbin/chown", args: [username, zshrcPath])
        }
    }

    private func sanitizeClonedConfig(username: String, uid: Int, gid: Int) throws {
        let path = "\(try CloneClawManager.homeDirectory(for: username))/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: path),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        guard let object = jsonObject as? [String: Any] else {
            throw CloneClawManagerError.invalidConfigFormat
        }
        let cleaned = CloneClawManager.sanitizeOpenclawConfig(object)
        let outData = try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: URL(fileURLWithPath: path), options: .atomic)
        let owner = "\(uid):\(gid)"
        try run("/usr/sbin/chown", args: [owner, path])
        try run("/bin/chmod", args: ["644", path])
    }

    private func fixCloneOwnership(username: String, uid: Int, gid: Int) throws {
        let home = try CloneClawManager.homeDirectory(for: username)
        let openclawPath = "\(home)/.openclaw"
        let npmGlobalPath = "\(home)/.npm-global"
        let owner = "\(uid):\(gid)"

        try run("/usr/sbin/chown", args: [owner, home])
        try run("/bin/chmod", args: ["700", home])
        try assertOwnership(username: username, path: home)

        if FileManager.default.fileExists(atPath: openclawPath) {
            try run("/usr/sbin/chown", args: ["-R", owner, openclawPath])
            try run("/bin/chmod", args: ["700", openclawPath])
            try assertOwnership(username: username, path: openclawPath)
        }
        if FileManager.default.fileExists(atPath: npmGlobalPath) {
            try run("/usr/sbin/chown", args: ["-R", owner, npmGlobalPath])
            try assertOwnership(username: username, path: npmGlobalPath)
        }
    }

    private func resolvedPrimaryGroupID(username: String) -> Int {
        guard let pw = getpwnam(username) else { return 20 } // staff
        return Int(pw.pointee.pw_gid)
    }

    private func assertOwnership(username: String, path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let owner = attrs[.ownerAccountName] as? String
        if owner != username {
            throw CloneClawManagerError.ownershipFixFailed(path, "owner=\(owner ?? "unknown"), expected=\(username)")
        }
    }

    private func rollbackCloneUser(username: String) {
        let home = "/Users/\(username)"
        try? FileManager.default.removeItem(atPath: "\(home)/.openclaw")
        try? FileManager.default.removeItem(atPath: "\(home)/.npm-global")
        UserManager.prepareDeleteUser(username: username)
        _ = try? dscl(["-delete", "/Users/\(username)"])
        try? FileManager.default.removeItem(atPath: home)
        UserManager.cleanupDeletedUser(username: username)
    }

    private func generatedClonePassword() -> String {
        "clawd-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
    }

    private func resolveCloneGatewayURL(username: String, uid: Int) -> String {
        let port = GatewayManager.readConfiguredPort(username: username) ?? GatewayManager.port(for: uid)
        let base = "http://127.0.0.1:\(port)/"
        if let token = ConfigWriter.getRawConfigValue(username: username, key: "gateway.auth.token"),
           !token.isEmpty {
            return "\(base)#token=\(token)"
        }
        return base
    }

    // MARK: 向导进度持久化

    func saveInitState(username: String, json: String,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        let dir = "/var/lib/clawdhome"
        let path = "\(dir)/\(username)-init.json"
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: path)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func loadInitState(username: String,
                       withReply reply: @escaping (String) -> Void) {
        let path = "/var/lib/clawdhome/\(username)-init.json"
        reply((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    // MARK: - 仪表盘

    func getDashboardSnapshot(withReply reply: @escaping (String) -> Void) {
        // 若机器指标仍为空（Collector 刚启动），立即补采（纯系统调用，微秒级）
        if DashboardCollector.shared.currentSnapshot().machine.memTotalMB == 0 {
            DashboardCollector.shared.collectMachineStatsNow()
        }
        var snap = DashboardCollector.shared.currentSnapshot()
        // 仪表盘主快照不返回连接明细，避免每秒大 JSON 传输和解码开销。
        // 连接明细由 getConnections() 按需单独获取。
        snap.connections = []
        snap.debugLog = nil
        let json = (try? JSONEncoder().encode(snap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func getConnections(withReply reply: @escaping (String?) -> Void) {
        let conns = DashboardCollector.shared.currentSnapshot().connections
        let json = (try? JSONEncoder().encode(conns)).flatMap { String(data: $0, encoding: .utf8) }
        reply(json)
    }

    // MARK: - 网络策略

    func getShrimpNetworkPolicy(username: String, withReply reply: @escaping (String?) -> Void) {
        guard username.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,254}$"#, options: .regularExpression) != nil else {
            reply(nil); return
        }
        let path = "/var/lib/clawdhome/\(username)-netpolicy.json"
        let json = try? String(contentsOfFile: path, encoding: .utf8)
        reply(json)
    }

    func setShrimpNetworkPolicy(username: String, policyJSON: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard username.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,254}$"#, options: .regularExpression) != nil else {
            reply(false, "invalid username"); return
        }
        let path = "/var/lib/clawdhome/\(username)-netpolicy.json"
        do {
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try policyJSON.write(toFile: path, atomically: true, encoding: .utf8)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func getGlobalNetworkConfig(withReply reply: @escaping (String?) -> Void) {
        let json = try? String(contentsOfFile: "/var/lib/clawdhome/global-netconfig.json", encoding: .utf8)
        reply(json)
    }

    func setGlobalNetworkConfig(configJSON: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        do {
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try configJSON.write(toFile: path, atomically: true, encoding: .utf8)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func enableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        var config = GlobalNetworkConfig()
        if let json = try? String(contentsOfFile: path, encoding: .utf8),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data) {
            config = decoded
        }
        config.pfEnabled = true
        do {
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else {
                reply(false, "序列化失败"); return
            }
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            reply(false, error.localizedDescription); return
        }
        reply(true, nil)
    }

    func disableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        var config = GlobalNetworkConfig()
        if let json = try? String(contentsOfFile: path, encoding: .utf8),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data) {
            config = decoded
        }
        config.pfEnabled = false
        do {
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else {
                reply(false, "序列化失败"); return
            }
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            reply(false, error.localizedDescription); return
        }
        reply(true, nil)
    }

    // MARK: - 配置读取 / 模型命令

    func getConfig(username: String, key: String, withReply reply: @escaping (String) -> Void) {
        let value = ConfigWriter.getConfig(username: username, key: key) ?? ""
        reply(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func getConfigJSON(username: String, withReply reply: @escaping (String) -> Void) {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let json = FileManager.default.contents(atPath: configPath)
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func setConfigDirect(username: String, path: String, valueJSON: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("配置直写 @\(username) \(path)")
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default
        // 读取现有 JSON（不存在则空对象）
        var root: [String: Any]
        if let data = fm.contents(atPath: configPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = dict
        } else {
            root = [:]
        }
        // 解析 valueJSON 为 Any
        guard let valueData = valueJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: valueData,
                options: [.fragmentsAllowed]
              ) else {
            helperLog("配置直写失败 @\(username): valueJSON 解析失败", level: .error)
            reply(false, "valueJSON 解析失败：\(valueJSON)")
            return
        }
        // 按 dot-path 写入（深度合并）
        let keys = path.split(separator: ".").map(String.init)
        func set(_ dict: inout [String: Any], keys: ArraySlice<String>, value: Any) {
            guard let first = keys.first else { return }
            if keys.count == 1 {
                dict[first] = value
            } else {
                var nested = dict[first] as? [String: Any] ?? [:]
                set(&nested, keys: keys.dropFirst(), value: value)
                dict[first] = nested
            }
        }
        set(&root, keys: ArraySlice(keys), value: value)
        // 序列化写回
        do {
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // 确保目录存在
            let dir = "/Users/\(username)/.openclaw"
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            fm.createFile(atPath: configPath, contents: outData)
            // 修正所有权
            _ = try? run("/usr/sbin/chown", args: ["-R", username, dir])
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runModelCommand(username: String, argsJSON: String,
                         withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let fullArgs = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "models"] + args
        do {
            let output = try run("/usr/bin/sudo", args: fullArgs)
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runOpenclawCommand(username: String, argsJSON: String,
                            withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        // 先修复权限：防止之前的操作遗留 root 归属导致 openclaw 读取失败
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        // 以目标用户身份运行，确保 Node.js os.homedir() 返回正确路径（插件发现依赖此值）
        let fullArgs = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath] + args
        do {
            let output = try run("/usr/bin/sudo", args: fullArgs)
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runPairingCommand(username: String, argsJSON: String,
                           withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        let fullArgs = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "pairing"] + args
        do {
            let output = try run("/usr/bin/sudo", args: fullArgs)
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runFeishuOnboardCommand(username: String, argsJSON: String,
                                 withReply reply: @escaping (Bool, String) -> Void) {
        guard let requestedArgs = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)) else {
            reply(false, "参数解析失败")
            return
        }
        let commandArgs = ["-y", "@larksuite/openclaw-lark-tools", "install"]
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        if !requestedArgs.isEmpty {
            helperLog("[feishu] requested args ignored in install-only flow: \(requestedArgs.joined(separator: " "))", level: .info)
        }
        helperLog("[feishu] run start @\(username) args=npx \(commandArgs.joined(separator: " "))")
        do {
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "npx",
                args: commandArgs
            )
            helperLog("[feishu] run success @\(username) outputBytes=\(output.utf8.count)")
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            helperLog("[feishu] run failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    private func validateMaintenanceCommand(_ command: [String]) -> String? {
        guard let executable = command.first, !executable.isEmpty else {
            return "命令不能为空"
        }
        let allowed = Set(["openclaw", "npx", "zsh", "bash", "sh"])
        if !allowed.contains(executable) {
            return "不支持的维护命令：\(executable)"
        }
        return nil
    }

    func startMaintenanceTerminalSession(username: String,
                                         commandJSON: String,
                                         withReply reply: @escaping (Bool, String, String?) -> Void) {
        helperLog("[maintenance] start request user=\(username) commandJSON=\(commandJSON)")
        guard let command = try? JSONDecoder().decode([String].self, from: Data(commandJSON.utf8)) else {
            helperLog("[maintenance] start reject user=\(username): command JSON decode failed", level: .warn)
            reply(false, "", "参数解析失败")
            return
        }
        if let error = validateMaintenanceCommand(command) {
            helperLog("[maintenance] start reject user=\(username): \(error)", level: .warn)
            reply(false, "", error)
            return
        }
        let home = "/Users/\(username)"
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        let nodePath = ConfigWriter.buildNodePath(username: username)

        do {
            let session = MaintenanceTerminalSession(username: username, nodePath: nodePath, command: command)
            try session.start()
            maintenanceSessionLock.lock()
            maintenanceSessions[session.id] = session
            maintenanceSessionLock.unlock()
            helperLog("[maintenance] session start ok id=\(session.id) pid=\(session.process.processIdentifier) user=\(username) cmd=\(command.joined(separator: " "))")
            reply(true, session.id, nil)
        } catch {
            helperLog("[maintenance] session start failed user=\(username): \(error.localizedDescription)", level: .error)
            reply(false, "", error.localizedDescription)
        }
    }

    func pollMaintenanceTerminalSession(sessionID: String, fromOffset: Int64,
                                        withReply reply: @escaping (Bool, String, Int64, Bool, Int32, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "", fromOffset, true, -1, "会话不存在或已结束")
            return
        }
        let snapshot = session.poll(fromOffset: fromOffset)
        reply(true, snapshot.chunk, snapshot.nextOffset, snapshot.exited, snapshot.exitCode, nil)
    }

    func sendMaintenanceTerminalSessionInput(sessionID: String, inputBase64: String,
                                             withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "会话不存在或已结束")
            return
        }
        guard let data = Data(base64Encoded: inputBase64) else {
            reply(false, "输入数据无效")
            return
        }
        do {
            try session.sendInput(data)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func resizeMaintenanceTerminalSession(sessionID: String, cols: Int32, rows: Int32,
                                          withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "会话不存在或已结束")
            return
        }
        do {
            try session.resize(cols: Int(cols), rows: Int(rows))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func terminateMaintenanceTerminalSession(sessionID: String,
                                             withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions.removeValue(forKey: sessionID)
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(true, nil)
            return
        }
        session.terminate()
        helperLog("[maintenance] session terminated by request id=\(sessionID)")
        reply(true, nil)
    }

    private func runAsUser(username: String,
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

    // MARK: - 体检

    func runHealthCheck(username: String, fix: Bool,
                        withReply reply: @escaping (Bool, String) -> Void) {
        let home = "/Users/\(username)"
        var findings: [HealthFinding] = []

        // --- 环境隔离检查（FileManager.attributesOfItem，无子进程）---

        // 检查 1：家目录权限（应为 700，不应 group/world 可访问）
        // macOS 所有用户都在 staff 组（gid=20），750 等同于对所有用户开放，必须设为 700
        if let attrs = try? FileManager.default.attributesOfItem(atPath: home),
           let perms = attrs[.posixPermissions] as? Int {
            let groupOrOthersAccess = (perms & 0o077) != 0
            if groupOrOthersAccess {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["700", home]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "home-perms", source: "isolation", severity: "critical",
                    title: "家目录未隔离",
                    detail: "当前权限 \(String(format: "%o", perms))，所有用户均在 staff 组，必须设为 700 才能阻止其他用户浏览文件",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 2：.openclaw 目录权限（含 API Key 等敏感数据，不应 group/world 可访问）
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir),
           let attrs = try? FileManager.default.attributesOfItem(atPath: openclawDir),
           let perms = attrs[.posixPermissions] as? Int {
            let groupOrOthersAccess = (perms & 0o077) != 0
            if groupOrOthersAccess {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["-R", "go-rwx", openclawDir]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "openclaw-perms", source: "isolation", severity: "critical",
                    title: ".openclaw 目录权限过宽",
                    detail: "当前权限 \(String(format: "%o", perms))，API Key 等敏感数据对其他用户可见",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 3：npm-global 目录权限（包含可执行文件，不应 world-writable）
        let npmGlobal = InstallManager.npmGlobalDir(for: username)
        if FileManager.default.fileExists(atPath: npmGlobal),
           let attrs = try? FileManager.default.attributesOfItem(atPath: npmGlobal),
           let perms = attrs[.posixPermissions] as? Int {
            let worldWritable = (perms & 0o002) != 0
            if worldWritable {
                var fixed: Bool? = nil
                var fixError: String? = nil
                if fix {
                    do { try run("/bin/chmod", args: ["o-w", npmGlobal]); fixed = true }
                    catch { fixed = false; fixError = error.localizedDescription }
                }
                findings.append(HealthFinding(
                    id: "npm-global-writable", source: "isolation", severity: "critical",
                    title: "npm 全局目录可被任意用户写入",
                    detail: "当前权限 \(String(format: "%o", perms))，其他用户可替换可执行文件（潜在供应链风险）",
                    fixable: true, fixed: fixed, fixError: fixError))
            }
        }

        // 检查 4：家目录归属（Helper 以 root 运行，可能遗漏 chown）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: home),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: [username, home]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "home-owner", source: "isolation", severity: "critical",
                title: "家目录归属错误",
                detail: "家目录当前归属 \(owner)，应归属 \(username)，用户无法写入自己的家目录",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 5：.openclaw 目录归属（openclaw CLI 以用户身份运行，需要写权限）
        if FileManager.default.fileExists(atPath: openclawDir),
           let attrs = try? FileManager.default.attributesOfItem(atPath: openclawDir),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: ["-R", "\(username):\(username)", openclawDir]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "openclaw-owner", source: "isolation", severity: "critical",
                title: ".openclaw 目录归属错误",
                detail: ".openclaw 当前归属 \(owner)，应归属 \(username)，导致 openclaw CLI 无法读写配置",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 6：openclaw.json 配置文件归属（用户需要能写入，否则 config set 静默失败）
        let configFile = "\(openclawDir)/openclaw.json"
        if FileManager.default.fileExists(atPath: configFile),
           let attrs = try? FileManager.default.attributesOfItem(atPath: configFile),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: [username, configFile]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "config-owner", source: "isolation", severity: "critical",
                title: "配置文件归属错误",
                detail: "openclaw.json 当前归属 \(owner)，应归属 \(username)，导致 API Key 等配置无法保存",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // 检查 7：npm-global 目录归属（包含 openclaw 可执行文件，需要用户可执行）
        if FileManager.default.fileExists(atPath: npmGlobal),
           let attrs = try? FileManager.default.attributesOfItem(atPath: npmGlobal),
           let owner = attrs[.ownerAccountName] as? String, owner != username {
            var fixed: Bool? = nil
            var fixError: String? = nil
            if fix {
                do { try run("/usr/sbin/chown", args: ["-R", "\(username):\(username)", npmGlobal]); fixed = true }
                catch { fixed = false; fixError = error.localizedDescription }
            }
            findings.append(HealthFinding(
                id: "npm-global-owner", source: "isolation", severity: "critical",
                title: "npm 全局目录归属错误",
                detail: "~/.npm-global 当前归属 \(owner)，应归属 \(username)，openclaw 命令无法执行",
                fixable: true, fixed: fixed, fixError: fixError))
        }

        // --- 应用安全审计（openclaw security audit --json）---
        var auditSkipped = false
        var auditError: String? = nil

        guard let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            // openclaw 未安装，跳过审计
            auditSkipped = true
            let result = HealthCheckResult(username: username,
                checkedAt: Date().timeIntervalSince1970,
                findings: findings, auditSkipped: true, auditError: nil)
            encodeAndReply(result, reply)
            return
        }

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let auditEnv = ["-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "security", "audit", "--json"]

        if let output = try? run("/usr/bin/sudo", args: auditEnv) {
            let initialFindings = parseAuditOutput(output)

            if fix && !initialFindings.isEmpty {
                // 运行 openclaw doctor --repair 修复应用层问题
                _ = try? run("/usr/bin/sudo", args: [
                    "-n", "-u", username, "-H", "/usr/bin/env", "PATH=\(nodePath)", openclawPath, "doctor", "--repair"
                ])
                // 修复后重新审计，对比前后 id 差异
                if let postOutput = try? run("/usr/bin/sudo", args: auditEnv) {
                    let postFindings = parseAuditOutput(postOutput)
                    let postIDs      = Set(postFindings.map { $0.id })
                    let initialIDs   = Set(initialFindings.map { $0.id })
                    // 原有发现：消失的 = 已修复，仍在的 = 未修复
                    for f in initialFindings {
                        findings.append(HealthFinding(
                            id: f.id, source: f.source, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: !postIDs.contains(f.id), fixError: nil))
                    }
                    // 修复后新增的发现（防御性处理）
                    for f in postFindings where !initialIDs.contains(f.id) {
                        findings.append(f)
                    }
                } else {
                    // 重新审计失败，保留原始发现并标记修复状态未知
                    for f in initialFindings {
                        findings.append(HealthFinding(
                            id: f.id, source: f.source, severity: f.severity,
                            title: f.title, detail: f.detail,
                            fixable: true, fixed: false, fixError: "修复后重新检查失败"))
                    }
                }
            } else {
                findings += initialFindings
            }
        } else {
            auditError = "安全审计执行失败（openclaw security audit --json）"
        }

        let result = HealthCheckResult(username: username,
            checkedAt: Date().timeIntervalSince1970,
            findings: findings, auditSkipped: auditSkipped, auditError: auditError)
        encodeAndReply(result, reply)
    }

    /// 解析 `openclaw security audit --json` 输出
    /// 兼容 {"findings":[...]} / {"issues":[...]} / 直接数组 [...] 三种格式
    private func parseAuditOutput(_ output: String) -> [HealthFinding] {
        guard let data = output.data(using: .utf8) else { return [] }
        var rawList: [[String: Any]] = []
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawList = (obj["findings"] as? [[String: Any]])
                ?? (obj["issues"] as? [[String: Any]]) ?? []
        } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rawList = arr
        }
        return rawList.enumerated().map { i, raw in
            let id       = (raw["id"] as? String) ?? "\(i)"
            let severity = (raw["severity"] as? String) ?? "info"
            let title    = (raw["title"] as? String) ?? (raw["name"] as? String) ?? "安全建议"
            let detail   = (raw["detail"] as? String)
                ?? (raw["description"] as? String)
                ?? (raw["message"] as? String) ?? ""
            return HealthFinding(id: "audit-\(id)", source: "audit",
                severity: severity, title: title, detail: detail,
                fixable: true, fixed: nil, fixError: nil)
        }
    }

    private func encodeAndReply(_ result: HealthCheckResult,
                                 _ reply: (Bool, String) -> Void) {
        if let data = try? JSONEncoder().encode(result),
           let json = String(data: data, encoding: .utf8) {
            reply(true, json)
        } else {
            reply(false, "{}")
        }
    }

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
            helperLog("[FileManager] listDirectory error: \(error)", level: .error)
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
            helperLog("[FileManager] readFile error: \(error)", level: .error)
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
            helperLog("[FileManager] readFileTail error: \(error)", level: .error)
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

        guard let json = try? JSONSerialization.data(withJSONObject: results),
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
}

// MARK: - XPC 监听器

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        helperLog("[xpc] incoming connection pid=\(pid)")
        guard Self.isCallerAuthorized(connection) else {
            // 拒绝非 ClawdHome.app 发起的连接
            helperLog("[xpc] rejected connection pid=\(pid)", level: .warn)
            return false
        }
        connection.invalidationHandler = {
            helperLog("[xpc] invalidated pid=\(pid)")
        }
        connection.interruptionHandler = {
            helperLog("[xpc] interrupted pid=\(pid)", level: .warn)
        }
        connection.exportedInterface = NSXPCInterface(with: ClawdHomeHelperProtocol.self)
        connection.exportedObject = ClawdHomeHelperImpl()
        connection.resume()
        helperLog("[xpc] accepted connection pid=\(pid)")
        return true
    }

    /// 校验调用方是否有权使用 Helper
    /// 两道检查均须通过：
    ///   1. 调用方进程属于 admin 组（纯 sysctl + getgrouplist，无子进程，DEBUG + Release 均生效）
    ///   2. 代码签名为 ClawdHome.app（DEBUG 跳过，Release 用 auditToken 强制校验）
    private static func isCallerAuthorized(_ connection: NSXPCConnection) -> Bool {
        // 调用方必须属于 admin 组
        let pid = connection.processIdentifier
        guard let uid = Self.uid(ofPID: pid) else {
            helperLog("[xpc] auth reject pid=\(pid): uid lookup failed", level: .warn)
            return false
        }
        guard Self.isAdminUID(uid) else {
            helperLog("[xpc] auth reject pid=\(pid) uid=\(uid): not in admin group", level: .warn)
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

let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()

// 启动仪表盘数据采集（双频 Timer：1s 动态指标 / 60s 静态指标）
helperLog("Helper 启动")
DashboardCollector.shared.start()
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
DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 8) {
    guard !FileManager.default.fileExists(atPath: "/var/lib/clawdhome/gateway-autostart-disabled")
    else { return }
    var adminNames = Set<String>()
    if let grp = getgrnam("admin") {
        var i = 0
        while let member = grp.pointee.gr_mem?[i] {
            adminNames.insert(String(cString: member))
            i += 1
        }
    }
    setpwent()
    defer { endpwent() }
    while let pw = getpwent() {
        let uid = pw.pointee.pw_uid
        let name = String(cString: pw.pointee.pw_name)
        guard uid >= 500, !name.hasPrefix("_"), !adminNames.contains(name) else { continue }
        // 检查用户级自启开关
        let userDisabledPath = "/var/lib/clawdhome/\(name)-autostart-disabled"
        guard !FileManager.default.fileExists(atPath: userDisabledPath) else { continue }
        // 未安装 openclaw 的用户 startGateway 会失败，try? 静默跳过
        try? GatewayManager.startGateway(username: name, uid: Int(uid))
    }
}

RunLoop.main.run()
