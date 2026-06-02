// Shared/BackupModels.swift
// 备份/恢复功能的共享数据模型（App 与 Helper 双方使用）

import Foundation

/// 备份配置（持久化到 /var/lib/clawdhome/backup-config.json）
struct BackupConfig: Codable, Sendable {
    var backupDir: String
    var schedule: BackupSchedule
    var retention: BackupRetention

    struct BackupSchedule: Codable, Sendable {
        var enabled: Bool
        var intervalHours: Int
        var lastRunAt: String?  // ISO8601
    }

    struct BackupRetention: Codable, Sendable {
        var maxCount: Int
    }

    static var `default`: BackupConfig {
        BackupConfig(
            backupDir: defaultBackupDir,
            schedule: .init(enabled: false, intervalHours: 24, lastRunAt: nil),
            retention: .init(maxCount: 7)
        )
    }

    /// 默认备份目录（当前用户 Documents 下）
    /// App 侧：NSHomeDirectory() 返回管理员 home，路径正确
    /// Helper 侧：loadConfig() 会用 resolveAdminHome 覆盖
    static var defaultBackupDir: String {
        "\(NSHomeDirectory())/Documents/ClawdHome-Backups"
    }
}

/// 最近一次定时备份的执行结果（持久化到 /var/lib/clawdhome/last-backup-result.json）
struct BackupResult: Codable, Sendable {
    let timestamp: String   // ISO8601
    let succeeded: Int
    let failures: [String]

    var isSuccess: Bool { failures.isEmpty }
}

/// 备份文件条目（Helper listBackups 返回）
struct BackupListEntry: Codable, Sendable, Identifiable {
    var id: String { filePath }
    let filename: String
    let filePath: String
    let fileSize: Int64
    let createdAt: String   // ISO8601
    let backupType: String  // "global" | "shrimp"
    let username: String?   // shrimp 备份时的用户名
}

/// 单个 Shrimp 备份中应包含的用户目录载荷。
struct BackupPayloadSpec: Equatable, Sendable {
    let relativePath: String
    let excludes: [String]
}

enum BackupPayloadPolicy {
    static let managedRelativePaths = [".clawdhome", ".openclaw", ".hermes"]

    static func payloads(existingRelativePaths: Set<String>) -> [BackupPayloadSpec] {
        managedRelativePaths.compactMap { relativePath in
            guard existingRelativePaths.contains(relativePath) else { return nil }
            return BackupPayloadSpec(relativePath: relativePath, excludes: excludes(for: relativePath))
        }
    }

    static func excludes(for relativePath: String) -> [String] {
        switch relativePath {
        case ".openclaw":
            return [
                "tools",
                "sandboxes",
                "logs",
                "restart-sentinel.json"
            ]
        case ".clawdhome":
            return [
                "tools",
                "browser/session.json"
            ]
        default:
            return []
        }
    }
}

enum BackupFilenamePolicy {
    static func username(fromShrimpFilename filename: String) -> String? {
        guard filename.hasPrefix("shrimp-") else { return nil }
        let basename = filename.replacingOccurrences(of: ".tar.gz", with: "")
        guard let range = basename.range(
            of: #"-\d{4}-\d{2}-\d{2}T\d{6}$"#,
            options: .regularExpression
        ) else {
            let fallback = basename.dropFirst("shrimp-".count).split(separator: "-").first.map(String.init)
            return fallback?.isEmpty == false ? fallback : nil
        }
        let start = basename.index(basename.startIndex, offsetBy: "shrimp-".count)
        let username = String(basename[start..<range.lowerBound])
        return username.isEmpty ? nil : username
    }
}
