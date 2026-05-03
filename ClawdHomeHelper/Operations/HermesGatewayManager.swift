// ClawdHomeHelper/Operations/HermesGatewayManager.swift
// 通过 LaunchDaemon 管理 hermes gateway 进程（与 openclaw GatewayManager 并列）
//
// 与 OpenClaw GatewayManager 的关键差异：
//   - Hermes gateway 默认不绑定 HTTP 端口，直接连消息平台，因此无需端口分配 / 冲突检测
//   - 进程启动命令：`hermes gateway`（参考 hermes-agent README）
//   - LaunchDaemon Label 使用独立命名空间：
//       main profile → ai.clawdhome.hermes.<user>（向后兼容）
//       named profile → ai.clawdhome.hermes.<user>.<profileID>

import Foundation

struct HermesGatewayManager {
    private static let gatewayLabel = "ai.clawdhome.hermes"

    // MARK: - Label / 路径计算

    /// 计算 launchd label
    /// - main profile → ai.clawdhome.hermes.<user>（向后兼容旧 label）
    /// - named profile → ai.clawdhome.hermes.<user>.<profileID>
    static func daemonLabel(username: String, profileID: String) -> String {
        if profileID == "main" {
            return "\(gatewayLabel).\(username)"
        }
        return "\(gatewayLabel).\(username).\(profileID)"
    }

    /// HERMES_HOME 环境变量路径
    /// - main → ~/.hermes
    /// - named → ~/.hermes/profiles/<profileID>
    static func hermesHomeForProfile(username: String, profileID: String) -> String {
        let base = HermesInstaller.hermesHome(for: username)
        if profileID == "main" {
            return base
        }
        return "\(base)/profiles/\(profileID)"
    }

    /// /Library/LaunchDaemons/<label>.plist
    static func launchDaemonPath(username: String, profileID: String) -> String {
        "/Library/LaunchDaemons/\(daemonLabel(username: username, profileID: profileID)).plist"
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func launchDaemonPath(username: String) -> String {
        launchDaemonPath(username: username, profileID: "main")
    }

    // MARK: - 启动

    /// 为指定用户的指定 profile 写入 LaunchDaemon plist 并启动 hermes gateway（幂等）
    /// 注：`uid` 当前仅用于日志，保留参数以便后续对齐 openclaw 接口
    static func startGateway(username: String, profileID: String, uid: Int) throws {
        let label = daemonLabel(username: username, profileID: profileID)
        let plistPath = launchDaemonPath(username: username, profileID: profileID)

        helperLog("[HermesGateway] START_BEGIN: uid=\(uid) profile=\(profileID) @\(username)")

        // 1. 前置检查：hermes 可执行文件必须存在
        let hermesBin = HermesInstaller.hermesExecutable(for: username)
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else {
            let err = HermesGatewayError.hermesNotInstalled
            helperLog("[HermesGateway] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
            throw err
        }

        // 2. 确保日志目录存在（归属目标用户，权限 700）
        let profileHome = hermesHomeForProfile(username: username, profileID: profileID)
        let logsDir = "\(profileHome)/logs"
        if !FileManager.default.fileExists(atPath: logsDir) {
            try? FileManager.default.createDirectory(
                atPath: logsDir, withIntermediateDirectories: true, attributes: nil
            )
            _ = try? FilePermissionHelper.chown(logsDir, owner: username)
            _ = try? FilePermissionHelper.chmod(logsDir, mode: "700")
        }

        // 3. 生成期望的 plist 内容
        let newPlist = makePlist(username: username, profileID: profileID, hermesBin: hermesBin)

        // 4. 根据 launchd 注册状态选择操作
        let isRegistered = (try? run("/bin/launchctl", args: ["print", "system/\(label)"])) != nil
        if isRegistered {
            let existingPlist = (try? String(contentsOfFile: plistPath, encoding: .utf8)) ?? ""
            if existingPlist == newPlist {
                // 已注册 + plist 未变：kickstart 确保 job 处于运行态（幂等）
                helperLog("[HermesGateway] START_STEP: 已注册 + plist 未变，kickstart profile=\(profileID) @\(username)")
                _ = try? run("/bin/launchctl", args: ["kickstart", "-k", "system/\(label)"])
            } else {
                // plist 变更：bootout → 写新 plist → bootstrap
                helperLog("[HermesGateway] START_STEP: plist 变更，bootout + bootstrap profile=\(profileID) @\(username)")
                if (try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])) == nil {
                    helperLog("launchctl bootout system/\(label) failed for @\(username)", level: .warn)
                }
                Thread.sleep(forTimeInterval: 0.3)
                try writePlist(newPlist, to: plistPath)
                try bootstrapSystem(label: label, plistPath: plistPath)
            }
        } else {
            helperLog("[HermesGateway] START_STEP: 首次注册，bootstrap profile=\(profileID) @\(username)")
            try writePlist(newPlist, to: plistPath)
            try bootstrapSystem(label: label, plistPath: plistPath)
        }

        helperLog("[HermesGateway] START_OK: label=\(label) @\(username)")
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func startGateway(username: String, uid: Int) throws {
        try startGateway(username: username, profileID: "main", uid: uid)
    }

    // MARK: - 停止

    static func stopGateway(username: String, profileID: String, uid: Int) throws {
        let label = daemonLabel(username: username, profileID: profileID)
        helperLog("[HermesGateway] STOP: label=\(label) uid=\(uid) profile=\(profileID) @\(username)")
        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) { throw error }
            helperLog("[HermesGateway] STOP_SKIP: job 不存在，视为已停止 profile=\(profileID) @\(username)")
        }
        helperLog("[HermesGateway] STOP_OK profile=\(profileID) @\(username)")
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func stopGateway(username: String, uid: Int) throws {
        try stopGateway(username: username, profileID: "main", uid: uid)
    }

    // MARK: - 卸载

    /// 移除 LaunchDaemon 注册并删除 plist
    static func uninstallGateway(username: String, profileID: String) throws {
        let label = daemonLabel(username: username, profileID: profileID)
        let plistPath = launchDaemonPath(username: username, profileID: profileID)

        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) { throw error }
        }
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
        helperLog("[HermesGateway] UNINSTALL_OK: plist=\(plistPath) profile=\(profileID) @\(username)")
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func uninstallGateway(username: String) throws {
        try uninstallGateway(username: username, profileID: "main")
    }

    // MARK: - 状态查询

    /// 查询 launchd 中指定 profile 的 hermes gateway 运行状态
    /// - Returns: (isRunning, pid) — pid 为 -1 表示未运行
    static func status(username: String, profileID: String) -> (running: Bool, pid: Int32) {
        let label = daemonLabel(username: username, profileID: profileID)
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
        if output.contains("state = running") {
            // 兜底：launchctl print 短暂缺失 pid 字段时，按 username 维度扫进程
            // （多 profile 进程都会匹配 hermes + gateway，无法按 profileID 区分，属降级路径）
            if let pid = hermesProcessPIDs(username: username).first {
                return (true, pid)
            }
            return (true, -1)
        }
        return (false, -1)
    }

    /// 向后兼容重载：profileID 默认为 "main"
    static func status(username: String) -> (running: Bool, pid: Int32) {
        status(username: username, profileID: "main")
    }

    // MARK: - plist 生成

    private static func makePlist(username: String, profileID: String, hermesBin: String) -> String {
        let label = daemonLabel(username: username, profileID: profileID)
        let home = "/Users/\(username)"
        let profileHome = hermesHomeForProfile(username: username, profileID: profileID)
        let logPath = "\(profileHome)/logs/gateway.log"
        let path = HermesInstaller.buildPath(for: username)
        let browserCommand = "\(home)/.clawdhome/tools/clawdhome-browser/clawdhome-browser open %s"

        // named profile 需要在 ProgramArguments 中追加 --profile <id>
        let programArgumentsXML: String
        if profileID == "main" {
            programArgumentsXML = """
                    <string>\(hermesBin)</string>
                    <string>gateway</string>
            """
        } else {
            programArgumentsXML = """
                    <string>\(hermesBin)</string>
                    <string>--profile</string>
                    <string>\(profileID)</string>
                    <string>gateway</string>
            """
        }

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
        \(programArgumentsXML)
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
                <key>BROWSER</key>
                <string>\(browserCommand)</string>
                <key>HERMES_HOME</key>
                <string>\(profileHome)</string>
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

    private static func bootstrapSystem(label: String, plistPath: String) throws {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
                return
            } catch {
                lastError = error
                guard shouldRetryBootstrap(error), attempt < 3 else { throw error }

                let lintResult = (try? run("/usr/bin/plutil", args: ["-lint", plistPath])) ?? "(plutil failed)"
                let printResult = (try? run("/bin/launchctl", args: ["print", "system/\(label)"])) ?? "(service not found)"
                helperLog(
                    "[HermesGateway] START_WARN: bootstrap attempt \(attempt)/3 失败，准备重试 label=\(label) plist=\(plistPath) lint=\(clampLog(lintResult)) print=\(clampLog(printResult))",
                    level: .warn
                )

                _ = try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])
                Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
            }
        }
        if let lastError { throw lastError }
    }

    private static func shouldRetryBootstrap(_ error: Error) -> Bool {
        guard case let ShellError.nonZeroExit(command, status, _) = error else { return false }
        return status == 5 && command.contains("/bin/launchctl bootstrap system ")
    }

    private static func clampLog(_ text: String, max: Int = 240) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max)) + "...(truncated)"
    }

    /// 兜底扫描 Hermes gateway 进程，防止 launchctl print 短暂缺失 pid 字段导致状态抖动
    private static func hermesProcessPIDs(username: String) -> [Int32] {
        guard let output = try? run("/bin/ps", args: ["-axo", "pid=,user=,command="]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .compactMap { rawLine -> Int32? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count == 3 else { return nil }
                guard let pid = Int32(fields[0]) else { return nil }
                let userField = String(fields[1])
                let commandField = String(fields[2])
                guard userField == username else { return nil }
                guard commandField.contains("hermes"), commandField.contains(" gateway") else { return nil }
                return pid
            }
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
