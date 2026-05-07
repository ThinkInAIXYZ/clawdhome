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

    /// 默认备份目录（App 侧的 Application Support）
    static var defaultBackupDir: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/ClawdHome/Backups"
    }
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
