// ClawdHomeCLI/Commands/HermesCommand.swift
// Hermes Agent 引擎管理命令（与 InstanceCommand 并列）
//
// 设计要点：
//   - 复用已有的 InstanceCommand.requireInstance(name) 做实例存在性检查
//   - install/start/stop/status/version/ls 覆盖最小管理闭环
//   - 模型、频道等细粒度配置由后续命令负责（读写 ~/.hermes/config.yaml, .env）

import Foundation

enum HermesCommand {

    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard let sub = args.first else {
            printUsage(); exit(1)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "install":  try install(rest, client: client)
        case "start":    try start(rest, client: client)
        case "stop":     try stop(rest, client: client)
        case "status":   try status(rest, client: client)
        case "version":  try version(rest, client: client)
        case "ls":       try list(rest, client: client)
        case "-h", "--help":
            printUsage()
        default:
            Output.printError("未知 hermes 子命令: \(sub)")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        let usage = """
        ClawdHome Hermes — Hermes Agent 引擎管理

        用法: clawdhome hermes <command> [args]

        Commands:
          install <name> [--version <v>]   为指定实例安装 Hermes Agent
          start <name>                     启动 Hermes gateway
          stop <name>                      停止 Hermes gateway
          status <name>                    查询运行状态
          version <name>                   查询已安装版本
          ls                               列出所有已安装 Hermes 的实例

        示例:
          clawdhome hermes install alice
          clawdhome hermes start alice
          clawdhome hermes status alice
        """
        Output.printErr(usage)
    }

    // MARK: - install

    private static func install(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome hermes install <name> [--version <v>]")
            exit(1)
        }
        try InstanceCommand.requireInstance(username)

        var version: String?
        var i = 1
        while i < args.count {
            if args[i] == "--version", i + 1 < args.count {
                version = args[i + 1]; i += 2
            } else {
                i += 1
            }
        }

        Output.printErr("安装 Hermes Agent 到 @\(username)（可能耗时 1-3 分钟）...")
        let proxy = try client.proxy()
        let (ok, err) = syncCall2 {
            proxy.installHermes(username: username, version: version, withReply: $0)
        }
        guard ok else {
            throw CLIError.operationFailed("Hermes 安装失败: \(err ?? "")")
        }

        let installed = syncCallString {
            proxy.getHermesVersion(username: username, withReply: $0)
        }

        if Output.jsonMode {
            Output.printJSON([
                "name": username,
                "engine": "hermes",
                "installed": true,
                "version": installed,
            ] as [String: Any])
        } else {
            Output.printSuccess("Hermes 已安装 @\(username): \(installed.isEmpty ? "未知版本" : installed)")
        }
    }

    // MARK: - start / stop

    private static func start(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome hermes start <name>"); exit(1)
        }
        try InstanceCommand.requireInstance(username)

        let proxy = try client.proxy()
        let (ok, err) = syncCall2 {
            proxy.startHermesGateway(username: username, withReply: $0)
        }
        guard ok else {
            throw CLIError.operationFailed("启动失败: \(err ?? "")")
        }
        if Output.jsonMode {
            Output.printJSON([
                "name": username, "engine": "hermes",
                "action": "start", "success": true,
            ])
        } else {
            Output.printSuccess("Hermes gateway \(username) 已启动")
        }
    }

    private static func stop(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome hermes stop <name>"); exit(1)
        }
        try InstanceCommand.requireInstance(username)

        let proxy = try client.proxy()
        let (ok, err) = syncCall2 {
            proxy.stopHermesGateway(username: username, withReply: $0)
        }
        guard ok else {
            throw CLIError.operationFailed("停止失败: \(err ?? "")")
        }
        if Output.jsonMode {
            Output.printJSON([
                "name": username, "engine": "hermes",
                "action": "stop", "success": true,
            ])
        } else {
            Output.printSuccess("Hermes gateway \(username) 已停止")
        }
    }

    // MARK: - status / version

    private static func status(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome hermes status <name>"); exit(1)
        }
        try InstanceCommand.requireInstance(username)
        let proxy = try client.proxy()

        let sema = DispatchSemaphore(value: 0)
        var running = false
        var pid: Int32 = -1
        proxy.getHermesGatewayStatus(username: username) { r, p in
            running = r; pid = p; sema.signal()
        }
        sema.wait()

        let version = syncCallString {
            proxy.getHermesVersion(username: username, withReply: $0)
        }

        if Output.jsonMode {
            Output.printJSON([
                "name": username,
                "engine": "hermes",
                "status": running ? "running" : "stopped",
                "pid": running ? "\(pid)" : "",
                "version": version,
            ] as [String: String])
        } else {
            print("Name:    \(username)")
            print("Engine:  hermes")
            print("Status:  \(running ? "running" : "stopped")")
            if running { print("PID:     \(pid)") }
            print("Version: \(version.isEmpty ? "-" : version)")
        }
    }

    private static func version(_ args: [String], client: CLIHelperClient) throws {
        guard let username = args.first else {
            Output.printError("用法: clawdhome hermes version <name>"); exit(1)
        }
        try InstanceCommand.requireInstance(username)
        let proxy = try client.proxy()
        let version = syncCallString {
            proxy.getHermesVersion(username: username, withReply: $0)
        }
        if Output.jsonMode {
            Output.printJSON([
                "name": username, "engine": "hermes", "version": version,
            ])
        } else {
            print(version.isEmpty ? "-" : version)
        }
    }

    // MARK: - ls

    private static func list(_ args: [String], client: CLIHelperClient) throws {
        _ = args  // 目前不接受参数
        let proxy = try client.proxy()
        let snapshotJSON = syncCallString {
            proxy.getDashboardSnapshot(withReply: $0)
        }
        guard let data = snapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(DashboardSnapshot.self, from: data) else {
            Output.printError("无法获取实例列表")
            exit(1)
        }

        struct Row {
            let name: String
            let version: String
            let running: Bool
            let pid: Int32
        }

        // 仅枚举已安装 hermes 的实例（通过 venv/bin/hermes 可执行文件判断）
        let candidates = snapshot.shrimps.filter { s in
            FileManager.default.isExecutableFile(
                atPath: "/Users/\(s.username)/.hermes-venv/bin/hermes"
            )
        }

        if candidates.isEmpty {
            if Output.jsonMode {
                Output.printJSON([] as [String])
            } else {
                Output.printErr("暂无已安装 Hermes 的实例")
            }
            return
        }

        // 并行查询每个实例的 version + status
        let group = DispatchGroup()
        let lock = NSLock()
        var rows: [Row] = []

        for shrimp in candidates {
            let username = shrimp.username
            group.enter()
            proxy.getHermesVersion(username: username) { v in
                proxy.getHermesGatewayStatus(username: username) { running, pid in
                    lock.lock()
                    rows.append(Row(name: username, version: v, running: running, pid: pid))
                    lock.unlock()
                    group.leave()
                }
            }
        }
        group.wait()
        rows.sort { $0.name < $1.name }

        if Output.jsonMode {
            let items: [[String: Any]] = rows.map { r in
                [
                    "name": r.name,
                    "engine": "hermes",
                    "status": r.running ? "running" : "stopped",
                    "version": r.version,
                    "pid": r.running ? "\(r.pid)" : "",
                ]
            }
            Output.printJSON(items)
            return
        }

        let tableRows: [[String]] = rows.map { r in
            [
                r.name,
                r.running ? "running" : "stopped",
                r.version.isEmpty ? "-" : r.version,
                r.running ? "\(r.pid)" : "-",
            ]
        }
        Output.printTable(headers: ["NAME", "STATUS", "VERSION", "PID"], rows: tableRows)
    }
}
