// ClawdHomeHelper/Operations/ConfigWriter.swift
// 以目标用户身份执行 openclaw config set，写入 ~/.openclaw/ 配置
// 使用 sudo -u <username> 保证配置文件属于正确的用户

import Foundation

struct ConfigWriter {

    /// 写入指定用户的 openclaw 配置项
    /// 以目标用户身份运行（sudo -u），确保 Node.js os.homedir() 返回正确路径，
    /// 避免插件发现失败（root 进程的 os.homedir() 返回 /var/root 而非用户目录）
    /// - Parameter logURL: 非 nil 时将命令行及输出追加到该日志文件
    static func setConfig(username: String, key: String, value: String, logURL: URL? = nil) throws {
        let openclawPath = try findOpenclawBinary(for: username)
        let nodePath = buildNodePath(username: username)
        // sudo -n -u <username> -H: 以目标用户身份运行，-H 自动设置 HOME，-n 非交互（root 无需密码）
        // 注意：key 和 value 必须作为独立参数传递，不能合并为 key=value
        let args: [String] = [
            "-n", "-u", username, "-H",
            "/usr/bin/env", "PATH=\(nodePath)",
            openclawPath, "config", "set", key, value
        ]
        if let logURL {
            try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
        } else {
            try run("/usr/bin/sudo", args: args)
        }
        // 文件由目标用户进程创建，归属已正确，无需 chown
    }

    /// 读取指定用户的 openclaw 配置项（返回值字符串，未设置时返回 nil）
    /// 注意：CLI 对敏感字段（如 gateway.auth.token）会输出 __OPENCLAW_REDACTED__
    /// 如需读取敏感字段，请使用 getRawConfigValue(username:key:)
    static func getConfig(username: String, key: String) -> String? {
        guard let openclawPath = try? findOpenclawBinary(for: username) else { return nil }
        let path = buildNodePath(username: username)
        // 以目标用户身份运行，保证 os.homedir() 等 Node.js API 返回正确路径
        return try? run("/usr/bin/sudo", args: [
            "-n", "-u", username, "-H",
            "/usr/bin/env", "PATH=\(path)",
            openclawPath, "config", "get", key
        ])
    }

    /// 直接从 ~/.openclaw/openclaw.json 读取配置值（可读取被 CLI 脱敏的敏感字段）
    /// key 支持 dot-path，如 "gateway.auth.token"
    static func getRawConfigValue(username: String, key: String) -> String? {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 遍历 dot-path 取值
        let parts = key.split(separator: ".").map(String.init)
        var current: Any = json
        for part in parts {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current as? String
    }

    /// 修复 openclaw.json 中的非法字符（如智能引号 "" → ""）
    /// 损坏的配置会导致 `openclaw config set` 解析失败
    static func repairConfigIfNeeded(username: String) {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              var content = String(data: data, encoding: .utf8) else { return }

        let original = content
        // 智能引号 → 直引号
        content = content.replacingOccurrences(of: "\u{201C}", with: "\"")  // "
        content = content.replacingOccurrences(of: "\u{201D}", with: "\"")  // "
        content = content.replacingOccurrences(of: "\u{2018}", with: "'")   // '
        content = content.replacingOccurrences(of: "\u{2019}", with: "'")   // '

        guard content != original else { return }  // 无需修复
        // 验证修复后是合法 JSON 再写回
        guard let repaired = content.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: repaired)) != nil else { return }
        try? repaired.write(to: URL(fileURLWithPath: configPath))
        _ = try? run("/usr/sbin/chown", args: [username, configPath])
    }

    // MARK: - 内部工具

    /// 查找 openclaw 二进制：优先用户私有 npm-global，再找系统路径
    static func findOpenclawBinary(for username: String) throws -> String {
        let candidates = [
            "\(InstallManager.npmGlobalBin(for: username))/openclaw",  // npm 全局安装位置
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = try? run("/usr/bin/which", args: ["openclaw"]),
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ConfigError.openclawNotFound
    }

    /// 构建包含 node 的 PATH 环境变量（供 GatewayManager 等模块共用）
    static func buildNodePath(username: String) -> String {
        // 找到 node 所在目录（Homebrew arm64 / x86）
        let nodeDir: String
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/node") {
            nodeDir = "/opt/homebrew/bin"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/node") {
            nodeDir = "/usr/local/bin"
        } else {
            nodeDir = "/opt/homebrew/bin"  // 兜底
        }
        // 同时加入用户 npm-global/bin（openclaw 二进制位置）以及系统路径
        return [
            InstallManager.npmGlobalBin(for: username),
            "/Users/\(username)/.brew/bin",
            nodeDir,
            "/usr/bin", "/bin"
        ].joined(separator: ":")
    }
}

enum ConfigError: LocalizedError {
    case openclawNotFound
    var errorDescription: String? { "未找到 openclaw 二进制文件" }
}
