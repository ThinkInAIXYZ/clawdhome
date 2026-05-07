// ClawdHomeHelper/GatewayWatchdog.swift
// Gateway 进程看门狗：定期检测异常退出并自动重启

import Foundation

final class GatewayWatchdog {
    static let shared = GatewayWatchdog()

    private let queue = DispatchQueue(label: "ai.clawdhome.helper.gateway-watchdog", qos: .background)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var retryAfter: [String: Date] = [:]

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.runSweep()
        }
        self.timer = timer
        timer.resume()
    }

    private func runSweep() {
        guard gatewayAutostartGloballyEnabled() else { return }

        for user in managedGatewayUsers() {
            guard userGatewayAutostartEnabled(username: user.username) else { continue }
            if let record = GatewayIntentionalStopStore.activeRecord(username: user.username) {
                helperLog("[watchdog] skip @\(user.username): intentional stop reason=\(record.reason)", level: .debug)
                continue
            }

            let now = Date()
            lock.lock()
            let nextRetry = retryAfter[user.username]
            lock.unlock()
            if let nextRetry, nextRetry > now { continue }

            // 新用户初始化期间 openclaw 可能尚未安装。
            // 此时自动重启一定失败，应直接跳过并延长重试间隔，避免误报与抖动。
            guard hasOpenclawBinary(username: user.username) else {
                helperLog("[watchdog] skip @\(user.username): openclaw not installed yet", level: .debug)
                setRetry(username: user.username, date: now.addingTimeInterval(120))
                continue
            }

            let status = GatewayManager.status(username: user.username, uid: user.uid)
            guard !status.running else {
                clearRetry(username: user.username)
                continue
            }

            helperLog("[watchdog] detected unexpected gateway exit @\(user.username); restarting", level: .error)
            GatewayLog.log("WATCHDOG_RESTART", username: user.username, detail: "unexpected exit detected; auto-restarting")
            do {
                try GatewayManager.startGateway(username: user.username, uid: user.uid)
                clearRetry(username: user.username)
            } catch {
                let retryInterval = retryIntervalForRestartFailure(error)
                let level: LogLevel = retryInterval >= 120 ? .warn : .error
                helperLog("[watchdog] restart failed @\(user.username): \(error.localizedDescription)", level: level)
                GatewayLog.log("WATCHDOG_RESTART_FAIL", username: user.username, detail: error.localizedDescription)
                setRetry(username: user.username, date: now.addingTimeInterval(retryInterval))
            }
        }
    }

    private func hasOpenclawBinary(username: String) -> Bool {
        (try? ConfigWriter.findOpenclawBinary(for: username)) != nil
    }

    private func retryIntervalForRestartFailure(_ error: Error) -> TimeInterval {
        if case GatewayError.openclawNotFound = error {
            return 300
        }
        let msg = error.localizedDescription
        if msg.contains("循环重启") || msg.contains("启动后校验失败") {
            return 120
        }
        return 30
    }

    private func clearRetry(username: String) {
        lock.lock()
        retryAfter.removeValue(forKey: username)
        lock.unlock()
    }

    private func setRetry(username: String, date: Date) {
        lock.lock()
        retryAfter[username] = date
        lock.unlock()
    }
}
