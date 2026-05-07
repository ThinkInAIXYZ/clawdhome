// ClawdHomeCLI/Commands/InstanceCommand.swift
// 实例生命周期命令：ps / run / start / stop / restart / rm / inspect / doctor

import Foundation

enum InstanceCommand {

    // MARK: - ps（列出所有实例）

    static func ps(client: CLIHelperClient) throws {
        let proxy = try client.proxy()

        let snapshotJSON = syncCallString { proxy.getDashboardSnapshot(withReply: $0) }
        guard let data = snapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) else {
            Output.printError("无法获取实例列表")
            exit(1)
        }

        let shrimps = snapshot.shrimps
        if shrimps.isEmpty {
            if Output.jsonMode {
                Output.printJSON([] as [String])
            } else {
                Output.printErr("暂无实例")
            }
            return
        }

        // 并行查询每个实例的版本和 URL
        struct InstanceInfo {
            var username: String
            var isRunning: Bool
            var port: Int
            var version: String = ""
            var url: String = ""
        }

        var infos = shrimps.map { InstanceInfo(username: $0.username, isRunning: $0.isRunning ?? false, port: $0.gatewayPort) }
        let group = DispatchGroup()

        for i in infos.indices {
            let username = infos[i].username

            group.enter()
            proxy.getOpenclawVersion(username: username) { v in
                infos[i].version = v; group.leave()
            }

            group.enter()
            proxy.getGatewayURL(username: username) { u in
                infos[i].url = u; group.leave()
            }
        }
        group.wait()

        if Output.jsonMode {
            let items: [[String: Any]] = infos.map { info in
                [
                    "name": info.username,
                    "status": info.isRunning ? "running" : "stopped",
                    "version": info.version,
                    "url": info.url,
                    "port": info.port,
                ]
            }
            Output.printJSON(items)
            return
        }

        var rows: [[String]] = []
        for info in infos {
            rows.append([
                info.username,
                info.isRunning ? "running" : "stopped",
                info.version.isEmpty ? "-" : info.version,
                info.isRunning ? info.url : "-",
                info.isRunning ? "\(info.port)" : "-",
            ])
        }
        Output.printTable(
            headers: ["NAME", "STATUS", "VERSION", "URL", "PORT"],
            rows: rows
        )
    }

    // MARK: - run（创建并启动实例）

    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome run <name> [--full-name <name>] [--password <pw>]")
            exit(1)
        }

        var fullName = username
        var password = UUID().uuidString
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--full-name" where i + 1 < args.count:
                fullName = args[i + 1]; i += 2
            case "--password" where i + 1 < args.count:
                password = args[i + 1]; i += 2
            default:
                i += 1
            }
        }

        let proxy = try client.proxy()

        // 步骤 1: 创建用户
        Output.printErr("创建用户 \(username)...")
        let (createOK, createErr) = syncCall2 { proxy.createUser(username: username, fullName: fullName, password: password, withReply: $0) }
        guard createOK else {
            throw CLIError.operationFailed("创建用户失败: \(createErr ?? "未知错误")")
        }

        // 步骤 2: 初始化 npm 环境
        Output.printErr("初始化 npm 环境...")
        let (npmOK, npmErr) = syncCall2 { proxy.setupNpmEnv(username: username, withReply: $0) }
        if !npmOK {
            Output.printErr("警告: npm 环境初始化失败: \(npmErr ?? "")")
        }

        // 步骤 3: 安装 Node.js
        Output.printErr("检查 Node.js...")
        let nodeInstalled = syncCallBool { proxy.isNodeInstalled(username: username, withReply: $0) }
        if !nodeInstalled {
            Output.printErr("安装 Node.js...")
            let (nodeOK, nodeErr) = syncCall2 { proxy.installNode(username: username, nodeDistURL: "", withReply: $0) }
            if !nodeOK {
                Output.printErr("警告: Node.js 安装失败: \(nodeErr ?? "")")
            }
        }

        // 步骤 4: 安装 OpenClaw
        Output.printErr("安装 OpenClaw...")
        let (installOK, installErr) = syncCall2 { proxy.installOpenclaw(username: username, version: nil, withReply: $0) }
        if !installOK {
            Output.printErr("警告: OpenClaw 安装失败: \(installErr ?? "")")
        }

        // 步骤 5: 启动 Gateway
        Output.printErr("启动 Gateway...")
        let (startOK, startErr) = syncCall2 { proxy.startGateway(username: username, withReply: $0) }
        if !startOK {
            Output.printErr("警告: Gateway 启动失败: \(startErr ?? "")")
        }

        if Output.jsonMode {
            Output.printJSON(["name": username, "created": true, "password": password])
        } else {
            Output.printSuccess("实例 \(username) 创建完成")
            Output.printErr("密码: \(password)")
        }
    }

    // MARK: - rm（删除实例）

    static func rm(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome rm <name> [--keep-home] [--admin-user <u>] [--admin-password <pw>]")
            exit(1)
        }

        var keepHome = false
        var adminUser = ""
        var adminPassword = ""
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--keep-home":
                keepHome = true; i += 1
            case "--admin-user" where i + 1 < args.count:
                adminUser = args[i + 1]; i += 2
            case "--admin-password" where i + 1 < args.count:
                adminPassword = args[i + 1]; i += 2
            default:
                i += 1
            }
        }

        if adminUser.isEmpty {
            adminUser = NSUserName()
        }
        if adminPassword.isEmpty {
            Output.printErr("请输入管理员密码: ")
            if let pw = readLine(strippingNewline: true) {
                adminPassword = pw
            }
        }

        let proxy = try client.proxy()

        // 1. prepareDeleteUser
        Output.printErr("准备删除 \(username)...")
        let (prepOK, prepErr) = syncCall2 { proxy.prepareDeleteUser(username: username, withReply: $0) }
        guard prepOK else {
            throw CLIError.operationFailed("预清理失败: \(prepErr ?? "")")
        }

        // 2. deleteUser
        Output.printErr("删除用户 \(username)...")
        let (delOK, delErr) = syncCall2 {
            proxy.deleteUser(username: username, keepHome: keepHome,
                           adminUser: adminUser, adminPassword: adminPassword, withReply: $0)
        }
        guard delOK else {
            throw CLIError.operationFailed("删除失败: \(delErr ?? "")")
        }

        // 3. cleanupDeletedUser
        let (cleanOK, _) = syncCall2 { proxy.cleanupDeletedUser(username: username, withReply: $0) }
        if !cleanOK {
            Output.printErr("警告: 后清理未完全完成")
        }

        if Output.jsonMode {
            Output.printJSON(["name": username, "deleted": true])
        } else {
            Output.printSuccess("实例 \(username) 已删除")
        }
    }

    // MARK: - start / stop / restart

    static func start(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome start <name>")
            exit(1)
        }
        try requireInstance(username)
        let proxy = try client.proxy()
        let (ok, err) = syncCall2 { proxy.startGateway(username: username, withReply: $0) }
        guard ok else { throw CLIError.operationFailed("启动失败: \(err ?? "")") }
        if Output.jsonMode {
            Output.printJSON(["name": username, "action": "start", "success": true])
        } else {
            Output.printSuccess("Gateway \(username) 已启动")
        }
    }

    static func stop(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome stop <name>")
            exit(1)
        }
        try requireInstance(username)
        let proxy = try client.proxy()
        let (ok, err) = syncCall2 { proxy.stopGateway(username: username, withReply: $0) }
        guard ok else { throw CLIError.operationFailed("停止失败: \(err ?? "")") }
        if Output.jsonMode {
            Output.printJSON(["name": username, "action": "stop", "success": true])
        } else {
            Output.printSuccess("Gateway \(username) 已停止")
        }
    }

    static func restart(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome restart <name>")
            exit(1)
        }
        try requireInstance(username)
        let proxy = try client.proxy()
        let (ok, err) = syncCall2 { proxy.restartGateway(username: username, withReply: $0) }
        guard ok else { throw CLIError.operationFailed("重启失败: \(err ?? "")") }
        if Output.jsonMode {
            Output.printJSON(["name": username, "action": "restart", "success": true])
        } else {
            Output.printSuccess("Gateway \(username) 已重启")
        }
    }

    // MARK: - inspect（查看实例详情）

    static func inspect(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome inspect <name>")
            exit(1)
        }

        try requireInstance(username)
        let proxy = try client.proxy()

        // 并行收集信息
        let group = DispatchGroup()
        var running = false
        var pid: Int32 = 0
        var version = ""
        var url = ""

        group.enter()
        proxy.getGatewayStatus(username: username) { isRunning, gatewayPID in
            running = isRunning; pid = gatewayPID; group.leave()
        }

        group.enter()
        proxy.getOpenclawVersion(username: username) { v in
            version = v; group.leave()
        }

        group.enter()
        proxy.getGatewayURL(username: username) { u in
            url = u; group.leave()
        }

        group.wait()

        if Output.jsonMode {
            Output.printJSON([
                "name": username,
                "status": running ? "running" : "stopped",
                "pid": running ? "\(pid)" : "",
                "version": version,
                "url": url,
            ] as [String: String])
        } else {
            print("Name:     \(username)")
            print("Status:   \(running ? "running" : "stopped")")
            if running { print("PID:      \(pid)") }
            print("Version:  \(version.isEmpty ? "-" : version)")
            print("URL:      \(url.isEmpty ? "-" : url)")
        }
    }

    // MARK: - doctor（诊断检查）

    static func doctor(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome doctor <name> [--fix] [--engine <openclaw|hermes>]")
            exit(1)
        }

        try requireInstance(username)
        var fix = false
        var engine: String?
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--fix":
                fix = true
                i += 1
            case "--engine":
                guard i + 1 < args.count else {
                    Output.printError("用法: clawdhome doctor <name> [--fix] [--engine <openclaw|hermes>]")
                    exit(1)
                }
                let value = args[i + 1].lowercased()
                guard value == "openclaw" || value == "hermes" else {
                    Output.printError("无效 --engine 值: \(args[i + 1])（仅支持 openclaw 或 hermes）")
                    exit(1)
                }
                engine = value
                i += 2
            default:
                Output.printError("未知参数: \(arg)")
                Output.printError("用法: clawdhome doctor <name> [--fix] [--engine <openclaw|hermes>]")
                exit(1)
            }
        }
        let proxy = try client.proxy()

        if !fix {
            Output.printErr("诊断 \(username)...")
        } else {
            Output.printErr("诊断并修复 \(username)...")
        }

        let sema = DispatchSemaphore(value: 0)
        var success = false
        var resultJSON = ""

        if let engine {
            proxy.runDiagnosticsForEngine(username: username, fix: fix, engine: engine) { ok, json in
                success = ok; resultJSON = json; sema.signal()
            }
        } else {
            proxy.runDiagnostics(username: username, fix: fix) { ok, json in
                success = ok; resultJSON = json; sema.signal()
            }
        }
        sema.wait()

        guard success,
              let data = resultJSON.data(using: .utf8),
              let result = try? JSONDecoder().decode(DiagnosticsResult.self, from: data) else {
            throw CLIError.operationFailed("诊断失败: \(resultJSON)")
        }

        if Output.jsonMode {
            print(resultJSON)
            return
        }

        // 按分组输出
        for group in DiagnosticGroup.allCases {
            let items = result.items(for: group)
            if items.isEmpty { continue }

            print("\n[\(group.title)]")
            for item in items {
                let icon: String
                switch item.severity {
                case "ok":       icon = "  ok"
                case "info":     icon = "info"
                case "warn":     icon = "WARN"
                case "critical": icon = "CRIT"
                default:         icon = "  ??"
                }

                var line = "  \(icon)  \(item.title)"
                if let fixed = item.fixed {
                    line += fixed ? " (已修复)" : " (修复失败)"
                } else if item.fixable && (item.severity == "warn" || item.severity == "critical") {
                    line += " (可修复)"
                }
                print(line)

                if !item.detail.isEmpty && item.severity != "ok" {
                    for detailLine in item.detail.split(separator: "\n") {
                        print("        \(detailLine)")
                    }
                }
                if let fixErr = item.fixError, !fixErr.isEmpty {
                    print("        修复错误: \(fixErr)")
                }
                if let ms = item.latencyMs {
                    print("        延迟: \(ms)ms")
                }
            }
        }

        // 摘要
        print("")
        let total = result.items.count
        let fixedCount = result.items.filter { $0.fixed == true }.count

        if result.hasIssues {
            var summary = "\(total) 项检查，\(result.criticalCount) 严重，\(result.warnCount) 警告"
            if fixedCount > 0 {
                summary += "，\(fixedCount) 已修复"
            }
            if !fix && result.fixableIssueCount > 0 {
                summary += "\n提示: 运行 clawdhome doctor \(username) --fix 自动修复 \(result.fixableIssueCount) 项"
            }
            Output.printErr(summary)
        } else {
            Output.printSuccess("\(total) 项检查全部通过")
        }
    }

    // MARK: - 实例存在性检查

    @discardableResult
    static func requireInstance(_ username: String) throws -> Bool {
        let home = "/Users/\(username)"
        guard FileManager.default.fileExists(atPath: home) else {
            throw CLIError.operationFailed("实例 \(username) 不存在")
        }
        return true
    }
}

// MARK: - 同步 XPC 调用辅助

func syncCall2(_ block: @escaping (@escaping (Bool, String?) -> Void) -> Void) -> (Bool, String?) {
    let sema = DispatchSemaphore(value: 0)
    var ok = false
    var err: String?
    block { success, error in
        ok = success; err = error; sema.signal()
    }
    sema.wait()
    return (ok, err)
}

func syncCallBool(_ block: @escaping (@escaping (Bool) -> Void) -> Void) -> Bool {
    let sema = DispatchSemaphore(value: 0)
    var result = false
    block { value in
        result = value; sema.signal()
    }
    sema.wait()
    return result
}

func syncCallString(_ block: @escaping (@escaping (String) -> Void) -> Void) -> String {
    let sema = DispatchSemaphore(value: 0)
    var result = ""
    block { value in
        result = value; sema.signal()
    }
    sema.wait()
    return result
}
