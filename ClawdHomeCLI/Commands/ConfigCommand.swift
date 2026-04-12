// ClawdHomeCLI/Commands/ConfigCommand.swift
// config get/set 子命令

import Foundation

enum ConfigCommand {
    static func run(_ args: [String], client: CLIHelperClient) throws {
        guard let subcommand = args.first else {
            printUsage()
            exit(1)
        }

        let subArgs = Array(args.dropFirst())
        switch subcommand {
        case "get":
            try get(subArgs, client: client)
        case "set":
            try set(subArgs, client: client)
        default:
            Output.printError("未知子命令: config \(subcommand)")
            printUsage()
            exit(1)
        }
    }

    private static func get(_ args: [String], client: CLIHelperClient) throws {
        guard args.count >= 2 else {
            Output.printError("用法: clawdhome config get <shrimp> <key>")
            exit(1)
        }

        let username = args[0]
        let key = args[1]
        guard FileManager.default.fileExists(atPath: "/Users/\(username)") else {
            throw CLIError.operationFailed("虾 \(username) 不存在")
        }
        let proxy = try client.proxy()

        let value = syncCallString { proxy.getConfig(username: username, key: key, withReply: $0) }

        if Output.jsonMode {
            Output.printJSON(["key": key, "value": value])
        } else {
            if value.isEmpty {
                Output.printErr("(未设置)")
            } else {
                print(value)
            }
        }
    }

    private static func set(_ args: [String], client: CLIHelperClient) throws {
        guard args.count >= 3 else {
            Output.printError("用法: clawdhome config set <shrimp> <key> <value>")
            exit(1)
        }

        let username = args[0]
        let key = args[1]
        let value = args[2]
        let proxy = try client.proxy()

        // 尝试解析为 JSON 值；如果不是合法 JSON 则当作字符串处理
        let valueJSON: String
        if let _ = try? JSONSerialization.jsonObject(with: Data(value.utf8)) {
            valueJSON = value
        } else {
            // 当作字符串
            valueJSON = "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }

        let (ok, err) = syncCall2 {
            proxy.setConfigDirect(username: username, path: key, valueJSON: valueJSON, withReply: $0)
        }

        guard ok else {
            throw CLIError.operationFailed("设置失败: \(err ?? "")")
        }

        if Output.jsonMode {
            Output.printJSON(["key": key, "value": value, "success": true] as [String: Any])
        } else {
            Output.printSuccess("\(key) = \(value)")
        }
    }

    private static func printUsage() {
        Output.printErr("""
        用法: clawdhome config <command>

        Commands:
          get <shrimp> <key>           读取配置
          set <shrimp> <key> <value>   写入配置
        """)
    }
}
