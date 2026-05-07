// ClawdHomeHelper/Operations/GatewayLog.swift
// Gateway 操作审计日志：启动、停止、重启、错误、端口冲突等

import Foundation

struct GatewayLog {
    static let logPath = "/var/log/clawdhome/gateway.log"
    private static let lock = NSLock()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// 记录 gateway 操作日志
    /// - Parameters:
    ///   - event: 事件类型（START, STOP, RESTART, ERROR, PORT_CONFLICT 等）
    ///   - username: 目标用户
    ///   - detail: 详情描述
    static func log(_ event: String, username: String, detail: String = "") {
        let fm = FileManager.default
        let dir = (logPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir,
                withIntermediateDirectories: true, attributes: nil)
        }
        let ts = isoFormatter.string(from: Date())
        var line = "[\(ts)] \(event.uppercased()) | user=\(username)"
        if !detail.isEmpty { line += " | \(detail)" }
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        if fm.fileExists(atPath: logPath) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                defer { fh.closeFile() }
                fh.seekToEndOfFile()
                fh.write(data)
            }
        } else {
            fm.createFile(atPath: logPath, contents: data,
                attributes: [.posixPermissions: 0o644])
        }
    }
}
