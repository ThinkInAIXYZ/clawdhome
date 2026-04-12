// ClawdHomeCLI/main.swift
// clawdhome CLI 入口 — 命令路由与全局 flag 解析

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

// MARK: - 命令路由

let command = args.removeFirst()
do {
    let client = CLIHelperClient()

    switch command {
    case "shrimp":
        try ShrimpCommand.run(args, client: client)
    case "shell":
        try ShellCommand.run(args, client: client)
    case "config":
        try ConfigCommand.run(args, client: client)
    case "chat":
        try ChatCommand.run(args, client: client)
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
    ClawdHome CLI — OpenClaw 虾群管理命令行工具

    用法: clawdhome <command> [options]

    Commands:
      shrimp <subcommand>     虾管理（list/create/delete/start/stop/restart/status/doctor）
      shell <name>            进入虾的交互式终端
      config <subcommand>     配置管理（get/set）
      chat <name> <message>   给虾发消息并等待回复
      version                 显示版本信息

    Global Flags:
      --json                  JSON 格式输出
      --help, -h              帮助信息
      --version, -v           版本号
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
