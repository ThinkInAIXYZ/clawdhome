// ClawdHomeHelper/HelperImpl+Config.swift
// 向导进度持久化 + 仪表盘 + 网络策略 + 配置读取 / 模型命令 + 维护终端 XPC

import Foundation

extension ClawdHomeHelperImpl {

    // MARK: 向导进度持久化

    func saveInitState(username: String, json: String,
                       withReply reply: @escaping (Bool, String?) -> Void) {
        let dir = "/var/lib/clawdhome"
        let path = "\(dir)/\(username)-init.json"
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: path)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func loadInitState(username: String,
                       withReply reply: @escaping (String) -> Void) {
        let path = "/var/lib/clawdhome/\(username)-init.json"
        reply((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    // MARK: - 仪表盘

    func getDashboardSnapshot(withReply reply: @escaping (String) -> Void) {
        // 若机器指标仍为空（Collector 刚启动），立即补采（纯系统调用，微秒级）
        if DashboardCollector.shared.currentSnapshot().machine.memTotalMB == 0 {
            DashboardCollector.shared.collectMachineStatsNow()
        }
        var snap = DashboardCollector.shared.currentSnapshot()
        // 仪表盘主快照不返回连接明细，避免每秒大 JSON 传输和解码开销。
        // 连接明细由 getConnections() 按需单独获取。
        snap.connections = []
        snap.debugLog = nil
        let json = (try? JSONEncoder().encode(snap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func getCachedAppUpdateState(withReply reply: @escaping (String?) -> Void) {
        reply(AppUpdateHeartbeatService.shared.cachedStateJSON())
    }

    func getConnections(withReply reply: @escaping (String?) -> Void) {
        let conns = DashboardCollector.shared.currentSnapshot().connections
        let json = (try? JSONEncoder().encode(conns)).flatMap { String(data: $0, encoding: .utf8) }
        reply(json)
    }

    // MARK: - 网络策略

    func getShrimpNetworkPolicy(username: String, withReply reply: @escaping (String?) -> Void) {
        guard username.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,254}$"#, options: .regularExpression) != nil else {
            reply(nil); return
        }
        let path = "/var/lib/clawdhome/\(username)-netpolicy.json"
        let json = try? String(contentsOfFile: path, encoding: .utf8)
        reply(json)
    }

    func setShrimpNetworkPolicy(username: String, policyJSON: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard username.range(of: #"^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,254}$"#, options: .regularExpression) != nil else {
            reply(false, "invalid username"); return
        }
        let path = "/var/lib/clawdhome/\(username)-netpolicy.json"
        do {
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try policyJSON.write(toFile: path, atomically: true, encoding: .utf8)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func getGlobalNetworkConfig(withReply reply: @escaping (String?) -> Void) {
        let json = try? String(contentsOfFile: "/var/lib/clawdhome/global-netconfig.json", encoding: .utf8)
        reply(json)
    }

    func setGlobalNetworkConfig(configJSON: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        do {
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try configJSON.write(toFile: path, atomically: true, encoding: .utf8)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func enableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        var config = GlobalNetworkConfig()
        if let json = try? String(contentsOfFile: path, encoding: .utf8),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data) {
            config = decoded
        }
        config.pfEnabled = true
        do {
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else {
                reply(false, "序列化失败"); return
            }
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            reply(false, error.localizedDescription); return
        }
        reply(true, nil)
    }

    func disableNetworkPF(withReply reply: @escaping (Bool, String?) -> Void) {
        let path = "/var/lib/clawdhome/global-netconfig.json"
        var config = GlobalNetworkConfig()
        if let json = try? String(contentsOfFile: path, encoding: .utf8),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GlobalNetworkConfig.self, from: data) {
            config = decoded
        }
        config.pfEnabled = false
        do {
            guard let data = try? JSONEncoder().encode(config),
                  let json = String(data: data, encoding: .utf8) else {
                reply(false, "序列化失败"); return
            }
            try FileManager.default.createDirectory(
                atPath: "/var/lib/clawdhome", withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
            try json.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            reply(false, error.localizedDescription); return
        }
        reply(true, nil)
    }

    // MARK: - 配置读取 / 模型命令

    func getConfig(username: String, key: String, withReply reply: @escaping (String) -> Void) {
        let value = ConfigWriter.getConfig(username: username, key: key) ?? ""
        reply(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func getConfigJSON(username: String, withReply reply: @escaping (String) -> Void) {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let json = FileManager.default.contents(atPath: configPath)
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        reply(json)
    }

    func setConfigDirect(username: String, path: String, valueJSON: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("配置直写 @\(username) \(path)")
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default
        // 读取现有 JSON（不存在则空对象）
        var root: [String: Any]
        if let data = fm.contents(atPath: configPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = dict
        } else {
            root = [:]
        }
        // 解析 valueJSON 为 Any
        guard let valueData = valueJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: valueData,
                options: [.fragmentsAllowed]
              ) else {
            helperLog("配置直写失败 @\(username): valueJSON 解析失败", level: .error)
            reply(false, "valueJSON 解析失败：\(valueJSON)")
            return
        }
        // 按 dot-path 写入（深度合并）
        let keys = path.split(separator: ".").map(String.init)
        func set(_ dict: inout [String: Any], keys: ArraySlice<String>, value: Any) {
            guard let first = keys.first else { return }
            if keys.count == 1 {
                dict[first] = value
            } else {
                var nested = dict[first] as? [String: Any] ?? [:]
                set(&nested, keys: keys.dropFirst(), value: value)
                dict[first] = nested
            }
        }
        set(&root, keys: ArraySlice(keys), value: value)
        // 序列化写回
        do {
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // 确保目录存在
            let dir = "/Users/\(username)/.openclaw"
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            fm.createFile(atPath: configPath, contents: outData)
            // 修正所有权
            _ = try? run("/usr/sbin/chown", args: ["-R", username, dir])
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func applySystemProxyEnv(
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("系统代理环境注入 @\(username) enabled=\(enabled)")
        do {
            let trimmedProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNoProxy = noProxy.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = "/Users/\(username)"
            let zprofilePath = "\(home)/.zprofile"
            let zshrcPath = "\(home)/.zshrc"

            try rewriteProxyManagedBlock(
                path: zprofilePath,
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            try rewriteProxyManagedBlock(
                path: zshrcPath,
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            refreshLaunchctlProxyEnv(
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            reply(true, nil)
        } catch {
            helperLog("系统代理环境注入失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func applyProxySettings(
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String,
        restartGatewayIfRunning: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        helperLog("代理配置应用 @\(username) enabled=\(enabled) restart=\(restartGatewayIfRunning)")
        do {
            let trimmedProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNoProxy = noProxy.trimmingCharacters(in: .whitespacesAndNewlines)
            try writeProxyEnvToOpenclawConfig(
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            try rewriteProxyManagedBlock(
                path: "/Users/\(username)/.zprofile",
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            try rewriteProxyManagedBlock(
                path: "/Users/\(username)/.zshrc",
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            refreshLaunchctlProxyEnv(
                username: username,
                enabled: enabled,
                proxyURL: trimmedProxy,
                noProxy: trimmedNoProxy
            )
            if restartGatewayIfRunning {
                do {
                    let uid = try UserManager.uid(for: username)
                    let status = GatewayManager.status(username: username, uid: uid)
                    if status.running {
                        try GatewayManager.restartGateway(username: username, uid: uid)
                    }
                } catch {
                    helperLog("代理配置应用时重启 Gateway 失败 @\(username): \(error.localizedDescription)", level: .error)
                    reply(false, "重启 Gateway 失败：\(error.localizedDescription)")
                    return
                }
            }
            reply(true, nil)
        } catch {
            helperLog("代理配置应用失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    private func writeProxyEnvToOpenclawConfig(
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String
    ) throws {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default
        var root: [String: Any]
        if let data = fm.contents(atPath: configPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = dict
        } else {
            root = [:]
        }
        var env = root["env"] as? [String: Any] ?? [:]
        let proxyValue = enabled ? proxyURL : ""
        let noProxyValue = enabled ? noProxy : ""
        env["HTTP_PROXY"] = proxyValue
        env["HTTPS_PROXY"] = proxyValue
        env["ALL_PROXY"] = proxyValue
        env["http_proxy"] = proxyValue
        env["https_proxy"] = proxyValue
        env["all_proxy"] = proxyValue
        env["NO_PROXY"] = noProxyValue
        env["no_proxy"] = noProxyValue
        root["env"] = env

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = "/Users/\(username)/.openclaw"
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try outData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        _ = try? run("/usr/sbin/chown", args: [username, dir])
        _ = try? run("/usr/sbin/chown", args: [username, configPath])
    }

    private func rewriteProxyManagedBlock(
        path: String,
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String
    ) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let start = "# >>> CLAWDHOME_PROXY_START >>>"
        let end = "# <<< CLAWDHOME_PROXY_END <<<"
        let stripped = stripManagedBlock(content: existing, start: start, end: end)

        var finalContent = stripped
        if enabled, !proxyURL.isEmpty {
            let quotedProxy = shellSingleQuoted(proxyURL)
            let quotedNoProxy = shellSingleQuoted(noProxy)
            let block = """
                \(start)
                # Managed by ClawdHome. Do not edit manually.
                export HTTP_PROXY=\(quotedProxy)
                export HTTPS_PROXY=\(quotedProxy)
                export ALL_PROXY=\(quotedProxy)
                export http_proxy=\(quotedProxy)
                export https_proxy=\(quotedProxy)
                export all_proxy=\(quotedProxy)
                export NO_PROXY=\(quotedNoProxy)
                export no_proxy=\(quotedNoProxy)
                \(end)
                """
            if !finalContent.isEmpty, !finalContent.hasSuffix("\n") {
                finalContent += "\n"
            }
            if !finalContent.isEmpty {
                finalContent += "\n"
            }
            finalContent += block + "\n"
        } else {
            // disabled: 仅保留去除受管块后的内容
            if !finalContent.isEmpty, !finalContent.hasSuffix("\n") {
                finalContent += "\n"
            }
        }

        guard finalContent != existing else { return }
        try Data(finalContent.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try? run("/usr/sbin/chown", args: [username, path])
        _ = try? run("/bin/chmod", args: ["644", path])
    }

    private func stripManagedBlock(content: String, start: String, end: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var skipping = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == start {
                skipping = true
                continue
            }
            if skipping {
                if trimmed == end {
                    skipping = false
                }
                continue
            }
            result.append(line)
        }
        lines = result
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            _ = lines.popLast()
        }
        return lines.joined(separator: "\n")
    }

    private func refreshLaunchctlProxyEnv(
        username: String,
        enabled: Bool,
        proxyURL: String,
        noProxy: String
    ) {
        guard let uid = try? UserManager.uid(for: username) else { return }
        let proxyKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"]
        let noProxyKeys = ["NO_PROXY", "no_proxy"]

        if enabled, !proxyURL.isEmpty {
            for key in proxyKeys {
                do {
                    try run("/bin/launchctl", args: ["asuser", "\(uid)", "/bin/launchctl", "setenv", key, proxyURL])
                } catch {
                    helperLog("launchctl setenv 失败 @\(username) key=\(key): \(error.localizedDescription)", level: .warn)
                }
            }
            for key in noProxyKeys {
                do {
                    if noProxy.isEmpty {
                        try run("/bin/launchctl", args: ["asuser", "\(uid)", "/bin/launchctl", "unsetenv", key])
                    } else {
                        try run("/bin/launchctl", args: ["asuser", "\(uid)", "/bin/launchctl", "setenv", key, noProxy])
                    }
                } catch {
                    helperLog("launchctl no_proxy 同步失败 @\(username) key=\(key): \(error.localizedDescription)", level: .warn)
                }
            }
        } else {
            for key in proxyKeys + noProxyKeys {
                do {
                    try run("/bin/launchctl", args: ["asuser", "\(uid)", "/bin/launchctl", "unsetenv", key])
                } catch {
                    helperLog("launchctl unsetenv 失败 @\(username) key=\(key): \(error.localizedDescription)", level: .warn)
                }
            }
        }
    }

    func runModelCommand(username: String, argsJSON: String,
                         withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let shellArgs = (["models"] + args).map(shellSingleQuoted).joined(separator: " ")
        let shellCommand = "cd \"$HOME\" && \(shellSingleQuoted(openclawPath)) \(shellArgs)"
        do {
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "/bin/zsh",
                args: ["-lc", shellCommand]
            )
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runOpenclawCommand(username: String, argsJSON: String,
                            withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        // 先修复权限：防止之前的操作遗留 root 归属导致 openclaw 读取失败
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        let shellArgs = args.map(shellSingleQuoted).joined(separator: " ")
        let shellCommand = "cd \"$HOME\" && \(shellSingleQuoted(openclawPath))\(shellArgs.isEmpty ? "" : " \(shellArgs)")"
        do {
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "/bin/zsh",
                args: ["-lc", shellCommand]
            )
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runPairingCommand(username: String, argsJSON: String,
                           withReply reply: @escaping (Bool, String) -> Void) {
        guard let args = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)),
              let openclawPath = try? ConfigWriter.findOpenclawBinary(for: username) else {
            reply(false, "参数解析失败")
            return
        }
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        let shellArgs = (["pairing"] + args).map(shellSingleQuoted).joined(separator: " ")
        let shellCommand = "cd \"$HOME\" && \(shellSingleQuoted(openclawPath)) \(shellArgs)"
        do {
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "/bin/zsh",
                args: ["-lc", shellCommand]
            )
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func runFeishuOnboardCommand(username: String, argsJSON: String,
                                 withReply reply: @escaping (Bool, String) -> Void) {
        guard let requestedArgs = try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8)) else {
            reply(false, "参数解析失败")
            return
        }
        let commandArgs = ["-y", "@larksuite/openclaw-lark-tools", "install"]
        let shellCommand = "cd \"$HOME\" && npx \(commandArgs.joined(separator: " "))"
        let home = "/Users/\(username)"
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        if !requestedArgs.isEmpty {
            helperLog("[feishu] requested args ignored in install-only flow: \(requestedArgs.joined(separator: " "))", level: .info)
        }
        helperLog("[feishu] run start @\(username) args=npx \(commandArgs.joined(separator: " "))")
        do {
            let output = try runAsUser(
                username: username,
                nodePath: nodePath,
                command: "/bin/zsh",
                args: ["-lc", shellCommand]
            )
            helperLog("[feishu] run success @\(username) outputBytes=\(output.utf8.count)")
            reply(true, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            helperLog("[feishu] run failed @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - 维护终端 XPC 处理

    private func validateMaintenanceCommand(_ command: [String]) -> String? {
        guard let executable = command.first, !executable.isEmpty else {
            return "命令不能为空"
        }
        let allowed = Set(["openclaw", "npx", "zsh", "bash", "sh"])
        if !allowed.contains(executable) {
            return "不支持的维护命令：\(executable)"
        }
        return nil
    }

    func startMaintenanceTerminalSession(username: String,
                                         commandJSON: String,
                                         withReply reply: @escaping (Bool, String, String?) -> Void) {
        helperLog("[maintenance] start request user=\(username) commandJSON=\(commandJSON)")
        guard let command = try? JSONDecoder().decode([String].self, from: Data(commandJSON.utf8)) else {
            helperLog("[maintenance] start reject user=\(username): command JSON decode failed", level: .warn)
            reply(false, "", "参数解析失败")
            return
        }
        if let error = validateMaintenanceCommand(command) {
            helperLog("[maintenance] start reject user=\(username): \(error)", level: .warn)
            reply(false, "", error)
            return
        }
        let home = "/Users/\(username)"
        let openclawDir = "\(home)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        let nodePath = ConfigWriter.buildNodePath(username: username)

        do {
            let session = try MaintenanceTerminalSession(username: username, nodePath: nodePath, command: command)
            try session.start()
            maintenanceSessionLock.lock()
            maintenanceSessions[session.id] = session
            maintenanceSessionLock.unlock()
            helperLog("[maintenance] session start ok id=\(session.id) pid=\(session.process.processIdentifier) user=\(username) cmd=\(command.joined(separator: " "))")
            reply(true, session.id, nil)
        } catch {
            helperLog("[maintenance] session start failed user=\(username): \(error.localizedDescription)", level: .error)
            reply(false, "", error.localizedDescription)
        }
    }

    func pollMaintenanceTerminalSession(sessionID: String, fromOffset: Int64,
                                        withReply reply: @escaping (Bool, String, Int64, Bool, Int32, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "", fromOffset, true, -1, "会话不存在或已结束")
            return
        }
        let snapshot = session.poll(fromOffset: fromOffset)
        reply(true, snapshot.chunk, snapshot.nextOffset, snapshot.exited, snapshot.exitCode, nil)
    }

    func sendMaintenanceTerminalSessionInput(sessionID: String, inputBase64: String,
                                             withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "会话不存在或已结束")
            return
        }
        guard let data = Data(base64Encoded: inputBase64) else {
            reply(false, "输入数据无效")
            return
        }
        do {
            try session.sendInput(data)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func resizeMaintenanceTerminalSession(sessionID: String, cols: Int32, rows: Int32,
                                          withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions[sessionID]
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(false, "会话不存在或已结束")
            return
        }
        do {
            try session.resize(cols: Int(cols), rows: Int(rows))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func terminateMaintenanceTerminalSession(sessionID: String,
                                             withReply reply: @escaping (Bool, String?) -> Void) {
        maintenanceSessionLock.lock()
        let session = maintenanceSessions.removeValue(forKey: sessionID)
        maintenanceSessionLock.unlock()
        guard let session else {
            reply(true, nil)
            return
        }
        session.terminate()
        helperLog("[maintenance] session terminated by request id=\(sessionID)")
        reply(true, nil)
    }
}
