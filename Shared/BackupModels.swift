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
