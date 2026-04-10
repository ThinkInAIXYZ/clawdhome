// ClawdHomeHelper/Operations/GatewayManager.swift
// 通过 LaunchDaemon + UserName 机制管理各标准用户的 openclaw-gateway 进程
// plist 写入 /Library/LaunchDaemons/，无需用户登录即可运行

import Foundation

struct GatewayManager {
    private static let gatewayLabel = "ai.clawdhome.gateway"

    // MARK: - 启动

    /// 根据 uid 计算该用户专属的 gateway 端口（18000 + uid）
    static func port(for uid: Int) -> Int { 18000 + uid }

    /// 为指定用户写入 LaunchDaemon plist 并启动 gateway（幂等）
    /// - 已注册且已运行：no-op（避免重复启动竞争端口）
    /// - 已注册但未运行：kickstart 让 launchd 重启
    /// - plist 内容变更（路径/端口变化）：bootout → 写新 plist → bootstrap
    /// - 未注册：写 plist → bootstrap
    static func startGateway(username: String, uid: Int) throws {
        let plistPath = launchDaemonPath(username: username)
        let label = "\(gatewayLabel).\(username)"

        // 先读配置文件中的现有端口（用户可能手动修改过），没有则用公式兜底
        let preferredPort = readConfiguredPort(username: username) ?? port(for: uid)

        helperLog("[GatewayManager] START_BEGIN: uid=\(uid) preferred_port=\(preferredPort) @\(username)")

        let initialPrintOutput = try? run("/bin/launchctl", args: ["print", "system/\(label)"])
        let launchdProtectedPIDs: Set<Int32> = {
            guard let pid = initialPrintOutput.flatMap(parseLaunchdPID), pid > 0 else { return [] }
            return [pid]
        }()

        // 1. 找到 openclaw 二进制路径
        let openclawPath: String
        do {
            openclawPath = try ConfigWriter.findOpenclawBinary(for: username)
            helperLog("[GatewayManager] START_STEP: binary=\(openclawPath) @\(username)")
        } catch {
            helperLog("[GatewayManager] START_FAIL: 找不到 openclaw: \(error.localizedDescription) @\(username)", level: .error)
            throw error
        }

        // 2. 清理 OpenClaw 原生 LaunchAgent（避免双重注册抢端口）
        let agentPlist = "/Users/\(username)/Library/LaunchAgents/ai.openclaw.gateway.plist"
        if FileManager.default.fileExists(atPath: agentPlist) {
            helperLog("[GatewayManager] START_STEP: 清理冲突 LaunchAgent: \(agentPlist) @\(username)")
            if (try? run("/bin/launchctl", args: ["bootout", "gui/\(uid)/ai.openclaw.gateway"])) == nil {
                helperLog("launchctl bootout gui/\(uid)/ai.openclaw.gateway failed for @\(username)", level: .warn)
            }
            if (try? run("/bin/launchctl", args: ["unload", agentPlist])) == nil {
                helperLog("launchctl unload \(agentPlist) failed for @\(username)", level: .warn)
            }
            do {
                try FileManager.default.removeItem(atPath: agentPlist)
            } catch {
                helperLog("removeItem \(agentPlist) failed: \(error.localizedDescription)", level: .warn)
            }
        }

        // 3. 修复可能损坏的配置文件（智能引号等非法字符）
        ConfigWriter.repairConfigIfNeeded(username: username)

        // 4. 端口选定：优先使用首选端口，被占用时自动找备用（向后最多 20 个）
        let resolvedPort: Int
        if let occupant = portOccupant(port: preferredPort, ignorePIDs: launchdProtectedPIDs) {
            helperLog("[GatewayManager] START_STEP: 首选端口 \(preferredPort) 被 \(occupant) 占用，寻找备用端口 @\(username)")
            guard let alt = findAvailablePort(
                preferred: preferredPort + 1,
                ignorePIDs: launchdProtectedPIDs
            ) else {
                let err = GatewayError.portConflict(port: preferredPort, occupant: occupant)
                helperLog("[GatewayManager] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
                throw err
            }
            resolvedPort = alt
            helperLog("[GatewayManager] START_STEP: 切换到备用端口 \(resolvedPort)（首选 \(preferredPort) 被占用） @\(username)")
        } else {
            resolvedPort = preferredPort
        }

        // 5. 同步 client 配置（gateway.mode 必须成功，否则 gateway 拒绝启动）
        do {
            try ConfigWriter.setConfig(username: username, key: "gateway.port", value: String(resolvedPort))
            try ConfigWriter.setConfig(username: username, key: "gateway.mode", value: "local")
            // 允许 ClawdHome（本地 Control UI）以 token auth 连接而无需 device identity
            // gateway 默认会清空无 device identity 客户端的 scopes，此配置保留 localhost 客户端的 scopes
            try ConfigWriter.setConfig(username: username, key: "gateway.controlUi.allowInsecureAuth", value: "true")
            helperLog("[GatewayManager] START_STEP: config 写入成功: port=\(resolvedPort) mode=local allowInsecureAuth=true @\(username)")
        } catch {
            helperLog("[GatewayManager] START_FAIL: config 写入失败: \(error.localizedDescription) @\(username)", level: .error)
            throw error
        }

        // 5b. 验证端口配置实际写入成功（防止 openclaw 使用默认端口与其他用户冲突）
        let actualPortRaw = ConfigWriter.getConfig(username: username, key: "gateway.port") ?? ""
        let actualPort = parsePortFromCLIOutput(actualPortRaw)
        if actualPort != resolvedPort {
            let err = GatewayError.portConfigMismatch(expected: resolvedPort, actualRaw: actualPortRaw, normalized: actualPort)
            helperLog("[GatewayManager] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
            throw err
        }

        // 6. 确保日志目录存在（归属目标用户，权限 700）
        let logsDir = "/Users/\(username)/.openclaw/logs"
        if !FileManager.default.fileExists(atPath: logsDir) {
            try? FileManager.default.createDirectory(atPath: logsDir,
                withIntermediateDirectories: true, attributes: nil)
            _ = try? FilePermissionHelper.chown(logsDir, owner: username)
            _ = try? FilePermissionHelper.chmod(logsDir, mode: "700")
        }

        // 7. 生成期望的 plist 内容
        let newPlist = makePlist(username: username, uid: uid, openclawPath: openclawPath,
                                 gatewayPort: resolvedPort)

        // 8. 检查 launchd 注册状态
        let printOutput = initialPrintOutput
        let isRegistered = printOutput != nil

        if isRegistered {
            let (running, existingPid) = status(username: username, uid: uid)
            let existingPlist = (try? String(contentsOfFile: plistPath, encoding: .utf8)) ?? ""
            if running {
                if existingPlist == newPlist {
                    // 端口一致，真正的 no-op
                    helperLog("[GatewayManager] START_SKIP: 已在运行 pid=\(existingPid) port=\(resolvedPort) @\(username)")
                    return
                }
                // 配置变更（含端口）→ launchd 不会重读 plist，kickstart -k 无效
                // 必须 bootout + bootstrap 才能让新 plist 生效
                helperLog("[GatewayManager] START_STEP: 配置变更（正在运行），bootout + bootstrap 更新端口 pid=\(existingPid) @\(username)")
                if (try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])) == nil {
                    helperLog("launchctl bootout system/\(label) failed during config change for @\(username)", level: .warn)
                }
                Thread.sleep(forTimeInterval: 0.5)
                try writePlist(newPlist, to: plistPath)
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
            } else if existingPlist != newPlist {
                helperLog("[GatewayManager] START_STEP: plist 变更，bootout 后重新 bootstrap @\(username)")
                if (try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])) == nil {
                    helperLog("launchctl bootout system/\(label) failed during plist change for @\(username)", level: .warn)
                }
                Thread.sleep(forTimeInterval: 0.5)
                try writePlist(newPlist, to: plistPath)
                try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
            } else {
                helperLog("[GatewayManager] START_STEP: plist 未变，kickstart 重启 @\(username)")
                if (try? run("/bin/launchctl", args: ["kickstart", "system/\(label)"])) == nil {
                    helperLog("launchctl kickstart system/\(label) failed for @\(username)", level: .warn)
                }
            }
        } else {
            helperLog("[GatewayManager] START_STEP: 首次注册，bootstrap @\(username)")
            try writePlist(newPlist, to: plistPath)
            try run("/bin/launchctl", args: ["bootstrap", "system", plistPath])
        }

        guard let startedPID = waitForGatewayRunning(username: username, uid: uid, timeout: 8) else {
            let err = GatewayError.startVerificationFailed(reason: "启动后 8 秒内未获得运行中的 PID")
            helperLog("[GatewayManager] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
            throw err
        }

        cleanupOrphanGateways(username: username, keepPID: startedPID)
        Thread.sleep(forTimeInterval: 0.8)
        let stabilizedStatus = status(username: username, uid: uid)
        if !stabilizedStatus.running || stabilizedStatus.pid <= 0 {
            let err = GatewayError.startVerificationFailed(reason: "启动后进程未保持存活，疑似循环重启")
            helperLog("[GatewayManager] START_FAIL: \(err.localizedDescription) @\(username)", level: .error)
            throw err
        }

        helperLog("[GatewayManager] START_OK: port=\(resolvedPort) label=\(label) pid=\(stabilizedStatus.pid) @\(username)")
    }

    private static func writePlist(_ content: String, to path: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FilePermissionHelper.setRootPlistPermissions(path)
    }

    // MARK: - 停止

    static func stopGateway(username: String, uid: Int) throws {
        let label = "\(gatewayLabel).\(username)"
        helperLog("[GatewayManager] STOP: label=\(label) @\(username)")
        var bootoutError: Error? = nil
        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if isIgnorableLaunchctlBootoutError(error) {
                helperLog("[GatewayManager] STOP_SKIP: job 不存在，视为已停止 @\(username)")
            } else {
                bootoutError = error
            }
        }

        // 停止语义必须“停稳”：即使 bootout 返回错误，也要尝试收敛到已停止状态。
        if !waitForGatewayStopped(username: username, uid: uid, timeout: 6) {
            helperLog("[GatewayManager] STOP_STEP: bootout 后仍有残留 gateway，强制清理 @\(username)")
            forceStopGatewayProcesses(username: username)
            // 再尝试一次 bootout，清除 launchd 注册态（忽略 no such process）
            do {
                try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
            } catch {
                if !isIgnorableLaunchctlBootoutError(error) {
                    bootoutError = bootoutError ?? error
                }
            }
            if !waitForGatewayStopped(username: username, uid: uid, timeout: 4) {
                let err = bootoutError ?? GatewayError.stopVerificationFailed(reason: "bootout 后仍存在 gateway 残留进程")
                helperLog("[GatewayManager] STOP_FAIL: \(err.localizedDescription) @\(username)", level: .error)
                throw err
            }
        }

        if let bootoutError {
            helperLog("[GatewayManager] STOP_WARN: bootout 返回异常但已停稳：\(bootoutError.localizedDescription) @\(username)", level: .warn)
        }
        helperLog("[GatewayManager] STOP_OK @\(username)")
    }

    /// 卸载 gateway launchd 服务：
    /// 1) 尝试 bootout 移除注册态
    /// 2) 删除 /Library/LaunchDaemons 下的对应 plist，避免“删除用户后启动项残留”
    static func uninstallGateway(username: String) throws {
        let label = "\(gatewayLabel).\(username)"
        let plistPath = launchDaemonPath(username: username)

        helperLog("[GatewayManager] UNINSTALL: label=\(label) @\(username)")
        do {
            try run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        } catch {
            if !isIgnorableLaunchctlBootoutError(error) {
                throw error
            }
        }

        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
        helperLog("[GatewayManager] UNINSTALL_OK: plist=\(plistPath) @\(username)")
    }

    // MARK: - 原子重启

    /// 重启 gateway：先 bootout 清除旧注册（含内存中的旧 job spec），再走 startGateway 流程。
    /// 必须经过 bootout 才能让 openclaw.json 中最新的端口配置生效；
    /// 直接 kickstart -k 只会用 launchd 内存里的旧 spec，不会重读 plist 文件。
    static func restartGateway(username: String, uid: Int) throws {
        let label = "\(gatewayLabel).\(username)"
        helperLog("[GatewayManager] RESTART @\(username)")
        // bootout 清除旧注册（忽略错误，可能本来就未注册）
        _ = try? run("/bin/launchctl", args: ["bootout", "system/\(label)"])
        if !waitForGatewayStopped(username: username, uid: uid, timeout: 8) {
            helperLog("[GatewayManager] RESTART_STEP: bootout 后仍有残留 gateway，强制清理 @\(username)")
            forceStopGatewayProcesses(username: username)
            if !waitForGatewayStopped(username: username, uid: uid, timeout: 4) {
                let err = GatewayError.restartVerificationFailed(reason: "旧 gateway 进程未能停止")
                helperLog("[GatewayManager] RESTART_FAIL: \(err.localizedDescription) @\(username)", level: .error)
                throw err
            }
        }
        // startGateway 读取最新 openclaw.json 端口，重写 plist，bootstrap
        try startGateway(username: username, uid: uid)
        helperLog("[GatewayManager] RESTART_OK: bootout + startGateway @\(username)")
    }

    // MARK: - 状态查询

    /// - Returns: (isRunning, pid) — pid 为 -1 表示未运行
    static func status(
        username: String,
        uid: Int,
        includeProcessFallback: Bool = true
    ) -> (running: Bool, pid: Int32) {
        let label = "\(gatewayLabel).\(username)"
        guard let output = try? run("/bin/launchctl", args: ["print", "system/\(label)"]) else {
            // service 未注册
            return (false, -1)
        }
        let launchdPID = parseLaunchdPID(from: output)
        if !includeProcessFallback {
            if let launchdPID, launchdPID > 0 {
                return (true, launchdPID)
            }
            return (false, -1)
        }
        return GatewayStatusResolver.resolve(
            launchdPID: launchdPID,
            processes: ProcessManager.listProcesses(username: username)
        )
    }

    /// 从 launchctl print 输出解析 pid。
    /// 无活跃 pid（crashed/throttled）时返回 nil，交给进程树 fallback 再确认一次。
    private static func parseLaunchdPID(from output: String) -> Int32? {
        let lines = output.components(separatedBy: "\n")
        if let pidLine = lines.first(where: { $0.contains("pid = ") }),
           let pidStr = pidLine.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces),
           let pid = Int32(pidStr), pid > 0 {
            return pid
        }
        return nil
    }

    // MARK: - 端口冲突检测

    /// 检查端口是否被其他进程占用（可排除已知受管 PID）
    /// - Returns: 占用者描述（如 "test5(pid=12345)"），未占用返回 nil
    static func portOccupant(port: Int, ignorePIDs: Set<Int32> = []) -> String? {
        // lsof -iTCP:<port> -sTCP:LISTEN -nP -Fp -Fu
        guard let output = try? run("/usr/sbin/lsof", args: [
            "-iTCP:\(port)", "-sTCP:LISTEN", "-nP", "-Fp", "-Fu"
        ]) else { return nil }

        // 解析 lsof 输出：p<pid>\nu<user>（可能有多组）
        var currentPID: Int32?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
                continue
            }
            if line.hasPrefix("u"), let pid = currentPID {
                if ignorePIDs.contains(pid) {
                    currentPID = nil
                    continue
                }
                let user = String(line.dropFirst())
                return "\(user)(pid=\(pid))"
            }
        }
        return nil
    }

    /// 审计所有用户的端口分配，返回冲突列表
    /// - Parameter users: (username, uid) 列表
    /// - Returns: 冲突描述数组，为空表示无冲突
    static func auditPorts(users: [(username: String, uid: Int)]) -> [String] {
        var portMap: [Int: [String]] = [:]  // port → [username]
        for (username, uid) in users {
            // 用配置文件中的实际端口，回退到公式
            let p = readConfiguredPort(username: username) ?? port(for: uid)
            portMap[p, default: []].append(username)
        }
        // 检查分配冲突（同端口分配给多个用户）
        var conflicts: [String] = []
        for (p, usernames) in portMap where usernames.count > 1 {
            conflicts.append("端口 \(p) 分配给了多个用户：\(usernames.joined(separator: ", "))")
        }
        // 检查实际占用冲突（端口被非预期进程占用）
        for (username, uid) in users {
            let p = readConfiguredPort(username: username) ?? port(for: uid)
            if let occupant = portOccupant(port: p) {
                conflicts.append("@\(username) 的端口 \(p) 被 \(occupant) 占用")
            }
        }
        return conflicts
    }

    // MARK: - 内部工具

    /// 直接从 openclaw.json 读取 gateway.port（不启动子进程）
    /// 返回 nil 表示配置文件不存在或未设置端口
    static func readConfiguredPort(username: String) -> Int? {
        let path = "/Users/\(username)/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any]
        else { return nil }
        if let p = gateway["port"] as? Int { return p }
        if let s = gateway["port"] as? String, let p = Int(s) { return p }
        return nil
    }

    private static func launchDaemonPath(username: String) -> String {
        "/Library/LaunchDaemons/\(gatewayLabel).\(username).plist"
    }

    /// 从 preferred 开始找第一个未被占用的端口（向后最多 maxTries 个）
    static func findAvailablePort(preferred: Int, ignorePIDs: Set<Int32> = [], maxTries: Int = 20) -> Int? {
        for offset in 0..<maxTries {
            let candidate = preferred + offset
            guard candidate < 65536 else { break }
            if portOccupant(port: candidate, ignorePIDs: ignorePIDs) == nil {
                return candidate
            }
        }
        return nil
    }

    /// 清理同用户下非 launchd 管理的遗留 gateway 进程，避免一只虾出现多个 gateway。
    private static func cleanupOrphanGateways(username: String, keepPID: Int32) {
        guard keepPID > 0 else { return }
        let orphanPIDs = gatewayProcessPIDs(username: username, excluding: [keepPID])
        guard !orphanPIDs.isEmpty else { return }

        helperLog("[GatewayManager] START_STEP: 清理遗留 gateway 进程 keep=\(keepPID) orphans=\(orphanPIDs) @\(username)")

        for pid in orphanPIDs {
            _ = try? run("/bin/kill", args: ["-TERM", "\(pid)"])
        }
        Thread.sleep(forTimeInterval: 0.3)

        let stillAlive = gatewayProcessPIDs(username: username, excluding: [keepPID])
        for pid in stillAlive {
            _ = try? run("/bin/kill", args: ["-KILL", "\(pid)"])
        }
    }

    private static func forceStopGatewayProcesses(username: String) {
        let pids = gatewayProcessPIDs(username: username)
        guard !pids.isEmpty else { return }
        helperLog("[GatewayManager] RESTART_STEP: 强制终止残留 gateway pids=\(pids) @\(username)")
        for pid in pids {
            _ = try? run("/bin/kill", args: ["-TERM", "\(pid)"])
        }
        Thread.sleep(forTimeInterval: 0.3)
        let stillAlive = gatewayProcessPIDs(username: username)
        for pid in stillAlive {
            _ = try? run("/bin/kill", args: ["-KILL", "\(pid)"])
        }
    }

    private static func gatewayProcessPIDs(username: String, excluding excluded: Set<Int32> = []) -> [Int32] {
        ProcessManager.listProcesses(username: username)
            .filter { entry in
                entry.pid > 1
                && !excluded.contains(entry.pid)
                && GatewayProcessCommandMatcher.isGatewayCommand(entry.cmdline)
            }
            .map(\.pid)
            .sorted()
    }

    private static func waitForGatewayStopped(username: String, uid: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let st = status(username: username, uid: uid)
            let runningPIDs = gatewayProcessPIDs(username: username)
            if !st.running && runningPIDs.isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private static func waitForGatewayRunning(username: String, uid: Int, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let st = status(username: username, uid: uid)
            if st.running, st.pid > 0 {
                return st.pid
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// 生成 LaunchDaemon plist：UserName 让 launchd 以目标用户身份运行，无需用户登录
    private static func makePlist(username: String, uid: Int, openclawPath: String, gatewayPort: Int) -> String {
        let label = "\(gatewayLabel).\(username)"
        let logPath = "/Users/\(username)/.openclaw/logs/gateway.log"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envXML = UserEnvContract
            .orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { key, value in
                """
                            <key>\(xmlEscaped(key))</key>
                            <string>\(xmlEscaped(value))</string>
                """
            }
            .joined(separator: "\n")
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
                <string>\(openclawPath)</string>
                <string>gateway</string>
                <string>run</string>
                <string>--force</string>
                <string>--bind</string>
                <string>loopback</string>
                <string>--port</string>
                <string>\(gatewayPort)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
        \(envXML)
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

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// openclaw CLI 可能包含 ANSI 控制码或包裹文本，这里做鲁棒解析。
    private static func parsePortFromCLIOutput(_ raw: String) -> Int? {
        let withoutAnsi = raw.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        let trimmed = withoutAnsi.trimmingCharacters(in: .whitespacesAndNewlines)
        let dequoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let exact = Int(dequoted) {
            return exact
        }
        if let range = dequoted.range(of: #"\d{1,5}"#, options: .regularExpression) {
            return Int(dequoted[range])
        }
        return nil
    }
}

enum GatewayError: LocalizedError {
    case openclawNotFound
    case portConflict(port: Int, occupant: String)
    case portConfigMismatch(expected: Int, actualRaw: String, normalized: Int?)
    case stopVerificationFailed(reason: String)
    case startVerificationFailed(reason: String)
    case restartVerificationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .openclawNotFound:
            return "未找到 openclaw 二进制文件。请确认已通过 npm install -g openclaw 安装。"
        case .portConflict(let port, let occupant):
            return "端口 \(port) 已被占用（\(occupant)）。请先停止占用进程或检查端口分配。"
        case .portConfigMismatch(let expected, let actualRaw, let normalized):
            let raw = actualRaw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            let parsed = normalized.map(String.init) ?? "无法解析"
            return "端口配置写入异常：期望 \(expected)，解析值 \(parsed)，原始输出「\(raw)」。请检查 openclaw.json 是否损坏。"
        case .stopVerificationFailed(let reason):
            return "Gateway 停止失败：\(reason)"
        case .startVerificationFailed(let reason):
            return "Gateway 启动后校验失败：\(reason)"
        case .restartVerificationFailed(let reason):
            return "Gateway 重启失败：\(reason)"
        }
    }
}
