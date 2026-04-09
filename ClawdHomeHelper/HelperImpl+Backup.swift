// ClawdHomeHelper/HelperImpl+Backup.swift
// 分层备份与恢复 XPC 方法实现 + 定时备份调度器

import Foundation

// MARK: - BackupScheduler

/// 定时备份调度器：按配置间隔自动执行全量备份 + 清理旧备份
final class BackupScheduler {
    static let shared = BackupScheduler()

    private let queue = DispatchQueue(label: "ai.clawdhome.helper.backup-scheduler", qos: .background)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    func start() {
        reconfigure()
    }

    /// 根据当前配置重建定时器
    func reconfigure() {
        lock.lock()
        timer?.cancel()
        timer = nil

        let config = BackupManager.loadConfig()
        guard config.schedule.enabled else {
            lock.unlock()
            helperLog("[backup-scheduler] 定时备份已关闭")
            return
        }

        let intervalSeconds = max(config.schedule.intervalHours, 1) * 3600

        // 计算距下次执行的时间
        var delaySeconds = intervalSeconds
        if let lastRunStr = config.schedule.lastRunAt {
            let fmt = ISO8601DateFormatter()
            if let lastRun = fmt.date(from: lastRunStr) {
                let elapsed = Int(Date().timeIntervalSince(lastRun))
                let remaining = intervalSeconds - elapsed
                delaySeconds = remaining > 0 ? remaining : 0
            }
        }

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(
            deadline: .now() + .seconds(delaySeconds),
            repeating: .seconds(intervalSeconds),
            leeway: .seconds(300) // 5 分钟容差，节能
        )
        newTimer.setEventHandler { [weak self] in
            self?.runScheduledBackup()
        }
        self.timer = newTimer
        lock.unlock()
        newTimer.resume()

        helperLog("[backup-scheduler] 定时备份已启动，间隔 \(config.schedule.intervalHours)h，首次执行在 \(delaySeconds)s 后")
    }

    private func runScheduledBackup() {
        let config = BackupManager.loadConfig()
        let dir = config.backupDir
        helperLog("[backup-scheduler] 开始定时备份 → \(dir)")

        let result = BackupManager.backupAll(destinationDir: dir)
        let pruned = BackupManager.pruneBackups(destinationDir: dir, maxCount: config.retention.maxCount)

        let now = ISO8601DateFormatter().string(from: Date())

        // 保存备份结果（供 App 读取显示告警）
        let backupResult = BackupResult(
            timestamp: now,
            succeeded: result.succeeded,
            failures: result.failures
        )
        BackupManager.saveResult(backupResult)

        // 更新 lastRunAt
        var updated = config
        updated.schedule.lastRunAt = now
        try? BackupManager.saveConfig(updated)

        helperLog("[backup-scheduler] 定时备份完成: 成功 \(result.succeeded) 个, 失败 \(result.failures.count) 个, 清理 \(pruned.count) 个旧备份")
        if !result.failures.isEmpty {
            helperLog("[backup-scheduler] 失败详情: \(result.failures.joined(separator: "; "))", level: .warn)
        }
    }
}

// MARK: - 备份与恢复 XPC 实现

extension ClawdHomeHelperImpl {

    // MARK: 分层备份与恢复（v2）

    func backupGlobal(destinationDir: String,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("全局备份 → \(destinationDir)")
        do {
            try BackupManager.backupGlobal(destinationDir: destinationDir)
            reply(true, nil)
        } catch {
            helperLog("全局备份失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func backupShrimp(username: String, destinationDir: String,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Shrimp 备份 @\(username) → \(destinationDir)")
        do {
            try BackupManager.backupShrimp(username: username, destinationDir: destinationDir)
            reply(true, nil)
        } catch {
            helperLog("Shrimp 备份失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func backupAll(destinationDir: String,
                   withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("全量备份 → \(destinationDir)")
        let result = BackupManager.backupAll(destinationDir: destinationDir)
        let config = BackupManager.loadConfig()
        let pruned = BackupManager.pruneBackups(destinationDir: destinationDir, maxCount: config.retention.maxCount)
        if !pruned.isEmpty {
            helperLog("全量备份后清理: 删除 \(pruned.count) 个旧备份")
        }
        if result.failures.isEmpty {
            reply(true, nil)
        } else {
            reply(false, result.failures.joined(separator: "\n"))
        }
    }

    func restoreGlobal(sourcePath: String,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("全局恢复 ← \(sourcePath)")
        // 校验路径：必须以 .tar.gz 结尾
        guard sourcePath.hasSuffix(".tar.gz") else {
            reply(false, "非法恢复路径: \(sourcePath)")
            return
        }
        do {
            try BackupManager.restoreGlobal(sourcePath: sourcePath)
            reply(true, nil)
        } catch {
            helperLog("全局恢复失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func restoreShrimp(username: String, sourcePath: String, backupBeforeRestore: Bool,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("Shrimp 恢复 @\(username) ← \(sourcePath) (备份=\(backupBeforeRestore))")
        // 校验路径
        guard sourcePath.hasSuffix(".tar.gz") else {
            reply(false, "非法恢复路径: \(sourcePath)")
            return
        }
        let config = BackupManager.loadConfig()

        // 恢复前备份
        if backupBeforeRestore {
            do {
                try BackupManager.backupShrimp(username: username, destinationDir: config.backupDir)
                helperLog("恢复前备份 @\(username) 完成")
            } catch {
                helperLog("恢复前备份失败 @\(username): \(error.localizedDescription)", level: .error)
                reply(false, "恢复前备份失败: \(error.localizedDescription)")
                return
            }
        }

        // 停止网关
        let uid = try? UserManager.uid(for: username)
        let wasRunning: Bool
        if let uid = uid {
            let status = GatewayManager.status(username: username, uid: uid)
            wasRunning = status.running
        } else {
            wasRunning = false
        }

        if wasRunning {
            helperLog("恢复前停止网关 @\(username)")
            if let uid = uid {
                do {
                    try GatewayManager.stopGateway(username: username, uid: uid)
                } catch {
                    helperLog("停止网关失败 @\(username): \(error.localizedDescription)", level: .warn)
                }
                // 等待网关退出（最多 10 秒）
                for _ in 0..<20 {
                    let s = GatewayManager.status(username: username, uid: uid)
                    if !s.running { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }

        // 执行恢复
        do {
            try BackupManager.restoreShrimp(username: username, sourcePath: sourcePath)
        } catch {
            helperLog("Shrimp 恢复失败 @\(username): \(error.localizedDescription)", level: .error)
            // 尝试重启网关
            if wasRunning, let uid = uid {
                try? GatewayManager.startGateway(username: username, uid: uid)
            }
            reply(false, error.localizedDescription)
            return
        }

        // 重启网关
        if wasRunning, let uid = uid {
            helperLog("恢复后重启网关 @\(username)")
            try? GatewayManager.startGateway(username: username, uid: uid)
        }

        reply(true, nil)
    }

    func getBackupConfig(withReply reply: @escaping (String?) -> Void) {
        let config = BackupManager.loadConfig()
        if let data = try? JSONEncoder().encode(config),
           let json = String(data: data, encoding: .utf8) {
            reply(json)
        } else {
            reply(nil)
        }
    }

    func setBackupConfig(configJSON: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        guard let data = configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(BackupConfig.self, from: data) else {
            reply(false, "无效的配置 JSON")
            return
        }
        do {
            try BackupManager.saveConfig(config)
            BackupScheduler.shared.reconfigure()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func listBackups(destinationDir: String,
                     withReply reply: @escaping (String?) -> Void) {
        let entries = BackupManager.listBackups(destinationDir: destinationDir)
        if let data = try? JSONEncoder().encode(entries),
           let json = String(data: data, encoding: .utf8) {
            reply(json)
        } else {
            reply(nil)
        }
    }

    func deleteBackup(filePath: String,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try BackupManager.deleteBackup(filePath: filePath)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func pruneBackups(destinationDir: String, maxCount: Int,
                      withReply reply: @escaping (Bool, String?) -> Void) {
        let pruned = BackupManager.pruneBackups(destinationDir: destinationDir, maxCount: maxCount)
        helperLog("清理旧备份: 删除 \(pruned.count) 个 — \(pruned.joined(separator: ", "))")
        reply(true, nil)
    }

    func getLastBackupResult(withReply reply: @escaping (String?) -> Void) {
        guard let result = BackupManager.loadResult(),
              let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else {
            reply(nil)
            return
        }
        reply(json)
    }
}
