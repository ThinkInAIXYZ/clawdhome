// ClawdHomeHelper/Operations/HermesGatewayManager.swift
// 通过 LaunchDaemon 管理 hermes gateway 进程（与 openclaw GatewayManager 并列）
//
// 与 OpenClaw GatewayManager 的关键差异：
//   - Hermes gateway 默认不绑定 HTTP 端口，直接连消息平台，因此无需端口分配 / 冲突检测
//   - 进程启动命令：`hermes gateway`（参考 hermes-agent README）
//   - LaunchDaemon Label 使用独立命名空间：ai.clawdhome.hermes.<user>，避免与 openclaw 冲突

import Foundation

struct HermesGatewayManager {
    private static let gatewayLabel = "ai.clawdhome.hermes"

    /// /Library/LaunchDaemons/ai.clawdhome.hermes.<user>.plist
    static func launchDaemonPath(username: String) -> String {
        "/Library/LaunchDaemons/\(gatewayLabel).\(username).plist"
    }

    // MARK: - 启动

    /// 为指定用户写入 LaunchDaemon plist 并启动 hermes gateway（幂等）
    /// 注：`uid` 当前仅用于日志，保留参数以便后续对齐 openclaw 接口
    static func startGateway(username: String, uid: Int) throws {
        let label = "\(gatewayLabel).\(username)"
        let plistPath = launchDaemonPath(username: username)

        helperLog("[HermesGateway] START_BEGIN: uid=\(uid) @\(username)")

        // 1. 前置检查：hermes 可执行文件必须存在
        let hermesBin = HermesInstaller.hermesExecutable(for: username)
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else {
            let err = HermesGatewayError.hermesNotInstalled
            helperLog("[HermesGateway] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
            throw err
        }

        // 2. 确保日志目录存在（归属目标用户，权限 700）
        let logsDir = "\(HermesInstaller.hermesHome(for: username))/logs"
        if !FileManager.default.fileExists(atPath: logsDir) {
            try? FileManager.default.createDirectory(
                atPath: logsDir, withIntermediateDirectories: true, attributes: nil
            )
            _ = try? FilePermissionHelper.chown(logsDir, owner: username)
            _ = try? FilePermissionHelper.chmod(logsDir, mode: "700")
        }

        // 3. 生成期望的 plist 内容
        let newPlist = makePlist(username: username, hermesBin: hermesBin)

        // 4. 根据 launchd 注册状态选择操作
        let isRegistered = (try? run("/bin/launchctl", args: ["print", "system/\(label)"])) != nil
        if isRegistered {
            let existingPlist = (try? String(contentsOfFile: plistPath, encoding: .utf8)) ?? ""
            if existingPlist == newPlist {
                // 已注册 + plist 未变：kickstart 确保 job 处于运行态（幂等）
                helperLog("[HermesGateway] START_STEP: 已注册 + plist 未变，kickstart @\(username)")
                _ = try? run("/bin/launchctl", args: ["kickstart", "-k", "system/\(label)"])
            } else {
                // plist 变更：bootout → 写新 plist → bootstrap
                helperLog("[HermesGateway] START_STEP: plist 变更，bootout + bootstrap @\(username)")
                if (try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])) == nil {
                    helperLog("launchctl bootout system/\(label) failed for @\(username)", level: .warn)
                }
                Thread.sleep(forTimeInterval: 0.3)
                try writePlist(newPlist, to: plistPath)
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
            }
        } else {
            helperLog("[HermesGateway] START_STEP: 首次注册，bootstrap @\(username)")
            try writePlist(newPlist, to: plistPath)
            try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
        }

        helperLog("[HermesGateway] START_OK: label=\(label) @\(username)")
    }

    // MARK: - 停止

    static func stopGateway(username: String, uid: Int) throws {
        let label = "\(gatewayLabel).\(username)"
        helperLog("[HermesGateway] STOP: label=\(label) uid=\(uid) @\(username)")
        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) { throw error }
            helperLog("[HermesGateway] STOP_SKIP: job 不存在，视为已停止 @\(username)")
        }
        helperLog("[HermesGateway] STOP_OK @\(username)")
    }

    // MARK: - 卸载

    /// 移除 LaunchDaemon 注册并删除 plist
    static func uninstallGateway(username: String) throws {
        let label = "\(gatewayLabel).\(username)"
        let plistPath = launchDaemonPath(username: username)

        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) { throw error }
        }
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
        helperLog("[HermesGateway] UNINSTALL_OK: plist=\(plistPath) @\(username)")
    }

    // MARK: - 状态查询

    /// 查询 launchd 中 hermes gateway 的运行状态
    /// - Returns: (isRunning, pid) — pid 为 -1 表示未运行
    static func status(username: String) -> (running: Bool, pid: Int32) {
        let label = "\(gatewayLabel).\(username)"
        guard let output = try? run("/bin/launchctl", args: ["print", "system/\(label)"]) else {
            return (false, -1)
        }
        for line in output.components(separatedBy: "\n") where line.contains("pid = ") {
            if let pidStr = line.components(separatedBy: "=").last?
                .trimmingCharacters(in: .whitespaces),
               let pid = Int32(pidStr), pid > 0 {
                return (true, pid)
            }
        }
        return (false, -1)
    }

    // MARK: - plist 生成

    private static func makePlist(username: String, hermesBin: String) -> String {
        let label = "\(gatewayLabel).\(username)"
        let home = "/Users/\(username)"
        let hermesHome = HermesInstaller.hermesHome(for: username)
        let logPath = "\(hermesHome)/logs/gateway.log"
        let path = [
            HermesInstaller.venvBin(for: username),
            "\(home)/.local/bin",
            "\(home)/.brew/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
          "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>UserName</key>
            <string>\(username)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(hermesBin)</string>
                <string>gateway</string>
            </array>
            <key>WorkingDirectory</key>
            <string>\(home)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(home)</string>
                <key>USER</key>
                <string>\(username)</string>
                <key>PATH</key>
                <string>\(path)</string>
                <key>HERMES_HOME</key>
                <string>\(hermesHome)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    private static func writePlist(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FilePermissionHelper.setRootPlistPermissions(path)
    }
}

enum HermesGatewayError: LocalizedError {
    case hermesNotInstalled

    var errorDescription: String? {
        switch self {
        case .hermesNotInstalled:
            return "未找到 hermes 可执行文件。请先运行 `clawdhome hermes install <name>` 完成安装。"
        }
    }
}
