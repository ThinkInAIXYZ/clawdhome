// ClawdHome/Services/AppLogger.swift
// App 侧内存日志缓冲，供设置页展示

import Foundation
import os

private let osLogger = Logger(subsystem: "io.github.deepjerry.clawdhome.mac", category: "app")

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

@Observable
final class AppLogger {
    static let shared = AppLogger()

    private(set) var lines: [LogLine] = []
    private let lock = NSLock()
    private let maxLines = 500

    struct LogLine: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String

        enum Level: String {
            case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
        }

        var formatted: String {
            let ts = LogTimestampFormatter.string(from: date)
            return "[\(ts)] \(message)"
        }
    }

    private init() {}

    func log(_ message: String, level: LogLine.Level = .info) {
        let safeMessage = LogRedactor.redact(message)
        switch level {
        case .debug: osLogger.debug("\(safeMessage, privacy: .public)")
        case .info:  osLogger.info("\(safeMessage, privacy: .public)")
        case .warn:  osLogger.warning("\(safeMessage, privacy: .public)")
        case .error: osLogger.error("\(safeMessage, privacy: .public)")
        }
        let entry = LogLine(date: Date(), level: level, message: safeMessage)
        lock.lock()
        lines.append(entry)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func clear() {
        lock.lock(); lines = []; lock.unlock()
    }
}

// 全局便捷函数
func appLog(_ message: String, level: AppLogger.LogLine.Level = .info) {
    AppLogger.shared.log(message, level: level)
}
