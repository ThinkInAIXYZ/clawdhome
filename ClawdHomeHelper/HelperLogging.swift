// ClawdHomeHelper/HelperLogging.swift
// 日志工具（结构化 JSONL + 滚动归档）+ 自启配置 + 用户过滤

import Foundation

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
private let helperLogPath: String = {
    #if DEBUG
    return "/tmp/clawdhome-helper-dev.log"
    #else
    return "/tmp/clawdhome-helper.log"
    #endif
}()
private let helperLogQueue = DispatchQueue(label: "ai.clawdhome.helper.log", qos: .utility)

/// 创建日志文件并设置权限为 root:admin 0640（仅 admin 组用户可读）
private func createHelperLogFile(atPath path: String) {
    FileManager.default.createFile(atPath: path, contents: nil,
        attributes: [.posixPermissions: 0o640])
    // 设置 group 为 admin (gid 80)，确保运行 app 的管理员用户可读
    chown(path, 0, 80)
}

private var helperLogHandle: FileHandle? = {
    createHelperLogFile(atPath: helperLogPath)
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
    let username: String?
    let requestId: String?
    let component: String?
    let event: String?
    let fields: [String: String]?
}

func isHelperDebugLoggingEnabled() -> Bool {
    helperDebugLock.lock()
    defer { helperDebugLock.unlock() }
    return helperDebugEnabled
}

@discardableResult
func setHelperDebugLoggingEnabled(_ enabled: Bool) -> Bool {
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

func helperLog(
    _ message: String,
    level: LogLevel = .info,
    channel: LogChannel = .primary,
    username: String? = nil,
    requestID: String? = nil,
    component: String? = nil,
    event: String? = nil,
    fields: [String: String]? = nil
) {
    let safeMessage = LogRedactor.redact(message)
    func normalized(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
    let safeFields: [String: String]? = {
        guard let fields else { return nil }
        var output: [String: String] = [:]
        for (key, value) in fields {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = LogRedactor.redact(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty {
                output[k] = v
            }
        }
        return output.isEmpty ? nil : output
    }()

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
            createHelperLogFile(atPath: helperLogPath)
            helperLogHandle = FileHandle(forWritingAtPath: helperLogPath)
            helperLogHandle?.seekToEndOfFile()
        }
        let record = HelperLogRecord(
            ts: helperLogFmt.string(from: Date()),
            level: level.rawValue,
            channel: channel.tag,
            message: safeMessage,
            pid: getpid(),
            username: normalized(username),
            requestId: normalized(requestID),
            component: normalized(component),
            event: normalized(event),
            fields: safeFields
        )
        let lineData: Data
        if let encoded = try? helperLogEncoder.encode(record) {
            var d = encoded
            d.append(0x0A)
            lineData = d
        } else {
            var segments = ["[\(record.ts)]", "[\(record.level)]", "[\(record.channel)]"]
            if let username = record.username { segments.append("[user=\(username)]") }
            if let requestId = record.requestId { segments.append("[req=\(requestId)]") }
            if let component = record.component {
                if let event = record.event {
                    segments.append("[\(component).\(event)]")
                } else {
                    segments.append("[\(component)]")
                }
            }
            lineData = Data("\(segments.joined(separator: " ")) \(safeMessage)\n".utf8)
        }
        helperLogHandle?.write(lineData)

        helperLogWriteCount += 1
        if helperLogWriteCount >= helperLogCheckEvery {
            helperLogWriteCount = 0
            rotateHelperLogIfNeeded()
        }
    }
}

// MARK: - Gateway 主动停止记录

struct GatewayIntentionalStopRecord: Codable {
    let reason: String
    let createdAt: TimeInterval
    let ttlSeconds: TimeInterval?

    var expiresAt: TimeInterval? {
        guard let ttlSeconds else { return nil }
        return createdAt + ttlSeconds
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 >= expiresAt
    }
}

enum GatewayIntentionalStopStore {
    private static let baseDir = "/var/lib/clawdhome"

    static func mark(username: String, reason: String, ttlSeconds: TimeInterval? = nil) {
        let record = GatewayIntentionalStopRecord(
            reason: reason,
            createdAt: Date().timeIntervalSince1970,
            ttlSeconds: ttlSeconds
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            atPath: baseDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        FileManager.default.createFile(atPath: path(username: username), contents: data)
    }

    static func clear(username: String) {
        try? FileManager.default.removeItem(atPath: path(username: username))
    }

    static func activeRecord(username: String) -> GatewayIntentionalStopRecord? {
        let filePath = path(username: username)
        guard let data = FileManager.default.contents(atPath: filePath),
              let record = try? JSONDecoder().decode(GatewayIntentionalStopRecord.self, from: data) else {
            return nil
        }
        if record.isExpired {
            try? FileManager.default.removeItem(atPath: filePath)
            return nil
        }
        return record
    }

    private static func path(username: String) -> String {
        "\(baseDir)/\(username)-gateway-intentional-stop.json"
    }
}

// MARK: - 自启配置

func gatewayAutostartGloballyEnabled() -> Bool {
    !FileManager.default.fileExists(atPath: "/var/lib/clawdhome/gateway-autostart-disabled")
}

func userGatewayAutostartEnabled(username: String) -> Bool {
    !FileManager.default.fileExists(atPath: "/var/lib/clawdhome/\(username)-autostart-disabled")
}

func managedGatewayUsers() -> [(username: String, uid: Int)] {
    var adminNames = Set<String>()
    if let grp = getgrnam("admin") {
        var i = 0
        while let member = grp.pointee.gr_mem?[i] {
            adminNames.insert(String(cString: member))
            i += 1
        }
    }

    var users: [(username: String, uid: Int)] = []
    setpwent()
    defer { endpwent() }
    while let pw = getpwent() {
        let uid = pw.pointee.pw_uid
        let signedUID = Int32(bitPattern: uid)
        let name = String(cString: pw.pointee.pw_name)
        guard ManagedUserFilter.isEligibleManagedUser(
            username: name,
            uid: Int(signedUID),
            adminNames: adminNames
        ) else { continue }
        users.append((name, Int(uid)))
    }
    return users
}

func bootAutostartGatewaysIfNeeded() {
    guard gatewayAutostartGloballyEnabled() else { return }
    for user in managedGatewayUsers() {
        // 1. 检查 user 级总开关（sentinel 文件存在 = 整 user 禁用自启，含 hermes）
        guard userGatewayAutostartEnabled(username: user.username) else { continue }

        // 2. OpenClaw gateway 自启（现有逻辑保持不变）
        guard GatewayIntentionalStopStore.activeRecord(username: user.username) == nil else { continue }
        do {
            try GatewayManager.startGateway(username: user.username, uid: user.uid)
        } catch {
            helperLog("autostart gateway failed for @\(user.username): \(error.localizedDescription)", level: .warn)
        }

        // 3. Hermes gateway 自启（profile 白名单维度）
        bootAutostartHermesGatewaysIfNeeded(username: user.username, uid: user.uid)
    }
}

/// 为单个 user 按 hermes 自启白名单串行拉起各 profile 的 gateway。
/// 调用方已确认 user 级 autostart-disabled sentinel 不存在。
private func bootAutostartHermesGatewaysIfNeeded(username: String, uid: Int) {
    // 未安装 hermes 则跳过
    guard HermesInstaller.installedVersion(username: username) != nil else { return }

    let profiles = HermesAutostartList.load(username: username)
    guard !profiles.isEmpty else {
        helperLog("[autostart] hermes whitelist empty, skip @\(username)")
        return
    }

    helperLog("[autostart] hermes profiles to start: \(profiles.sorted()) @\(username)")
    for profileID in profiles.sorted() {
        do {
            try HermesGatewayManager.startGateway(username: username, profileID: profileID, uid: uid)
            helperLog("[autostart] hermes gateway started profile=\(profileID) @\(username)")
        } catch {
            // 单 profile 失败仅记 warn，不影响其他 profile
            helperLog(
                "[autostart] hermes gateway failed profile=\(profileID) @\(username): \(error.localizedDescription)",
                level: .warn
            )
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

    createHelperLogFile(atPath: helperLogPath)
    helperLogHandle = FileHandle(forWritingAtPath: helperLogPath)
    helperLogHandle?.seekToEndOfFile()
}
