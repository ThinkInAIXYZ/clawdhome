// ClawdHomeCLI/main.swift
// clawdhome CLI 入口 — Docker 风格命令路由与全局 flag 解析

import Foundation

// MARK: - 版本信息

let cliVersion = "1.0.0"

// MARK: - 全局 flag 解析

var args = Array(CommandLine.arguments.dropFirst()) // 去掉可执行文件路径

// 提取全局 flag
if args.contains("--json") {
    Output.jsonMode = true
    args.removeAll { $0 == "--json" }
}

if args.contains("--version") || args.contains("-v") {
    print("clawdhome \(cliVersion)")
    exit(0)
}

if args.isEmpty || args.contains("--help") || args.contains("-h") {
    printGlobalUsage()
    exit(0)
}

// MARK: - 命令路由（Docker 风格：顶层动词）

let command = args.removeFirst()
do {
    let client = CLIHelperClient()

    switch command {
    // 实例生命周期
    case "ps":
        try InstanceCommand.ps(client: client)
    case "run":
        try InstanceCommand.run(args, client: client)
    case "start":
        try InstanceCommand.start(args, client: client)
    case "stop":
        try InstanceCommand.stop(args, client: client)
    case "restart":
        try InstanceCommand.restart(args, client: client)
    case "rm":
        try InstanceCommand.rm(args, client: client)
    case "inspect":
        try InstanceCommand.inspect(args, client: client)
    case "doctor":
        try InstanceCommand.doctor(args, client: client)

    // 交互
    case "exec":
        try ExecCommand.run(args, client: client)
    case "chat":
        try ChatCommand.run(args, client: client)

    // 引擎特定
    case "hermes":
        try HermesCommand.run(args, client: client)

    // 配置与系统
    case "config":
        try ConfigCommand.run(args, client: client)
    case "version":
        try printVersion(client: client)

    default:
        Output.printError("未知命令: \(command)")
        printGlobalUsage()
        exit(1)
    }
} catch {
    if Output.jsonMode {
        Output.printJSON(["error": error.localizedDescription])
    } else {
        Output.printError(error.localizedDescription)
    }
    exit(1)
}

// MARK: - 辅助

func printGlobalUsage() {
    let usage = """
    ClawdHome CLI — 智能体实例管理

    用法: clawdhome <command> [options]

    Commands:
      ps                          列出所有实例
      run <name> [options]        创建并启动实例
      start <name>                启动实例
      stop <name>                 停止实例
      restart <name>              重启实例
      rm <name> [options]         删除实例
      exec <name>                 进入实例终端
      inspect <name>              查看实例详情
      chat <name> <message>       发送消息
      doctor <name> [--fix]       诊断检查
      hermes <subcommand>         Hermes 引擎管理（install/start/stop/status/ls）
      config <get|set> [args]     配置管理
      version                     版本信息

    Global Flags:
      --json                      JSON 格式输出
      --help, -h                  帮助信息
      --version, -v               版本号
    """
    Output.printErr(usage)
}

func printVersion(client: CLIHelperClient) throws {
    let proxy = try client.proxy()
    let helperVersion = syncCallString { proxy.getVersion(withReply: $0) }

    if Output.jsonMode {
        Output.printJSON([
            "cli": cliVersion,
            "helper": helperVersion,
        ])
    } else {
        print("CLI:    \(cliVersion)")
        print("Helper: \(helperVersion)")
    }
}
