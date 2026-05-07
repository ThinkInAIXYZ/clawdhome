// ClawdHomeHelper/Operations/InstallManager.swift
// 以目标用户身份安装或升级 openclaw（sudo -u <user> npm install -g）
// 注意：npm install 可能耗时较长

import Foundation

struct InstallManager {

    /// sudo -H 会 reset PATH；openclaw 是 node shebang 脚本，需要显式传 PATH
    /// 优先 /usr/local/bin（NodeDownloader 安装路径），再回退 Homebrew
    static let sudoNodePath = "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

    /// 用户 npm 全局目录（结构：bin/ lib/node_modules/）
    static func npmGlobalDir(for username: String) -> String {
        "/Users/\(username)/.npm-global"
    }

    /// openclaw 二进制位于 ~/.npm-global/bin/
    static func npmGlobalBin(for username: String) -> String {
        "\(npmGlobalDir(for: username))/bin"
    }

    /// 为指定用户安装或升级 openclaw
    /// - Parameters:
    ///   - username: macOS 账户名
    ///   - version: nil 表示安装最新版，否则安装指定版本（如 "2026.2.23"）
    @discardableResult
    static func install(username: String, version: String?, logURL: URL? = nil) throws -> String {
        let npmPath = try findNpmBinary()
        let packageArg = version.map { "openclaw@\($0)" } ?? "openclaw@latest"
        let prefix = npmGlobalDir(for: username)
        // 安装前预修正 .openclaw 所有权，避免存量 root-owned 文件阻断新版本启动
        let openclawDirPre = "/Users/\(username)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDirPre) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDirPre])
        }
        let args = ["-u", username, "-H",
                    "env", sudoNodePath,
                    npmPath, "install", "-g", "--prefix", prefix,
                    "--loglevel", "verbose",
                    packageArg]
        let output: String
        if let logURL {
            output = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
        } else {
            output = try run("/usr/bin/sudo", args: args)
        }
        // 修正 ~/.openclaw 所有权：npm lifecycle 脚本或 openclaw 初始化
        // 可能以 root 身份写入配置文件，导致 gateway 进程无法读取
        let openclawDir = "/Users/\(username)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDir) {
            _ = try? run("/usr/sbin/chown", args: ["-R", username, openclawDir])
        }
        // 修正 npm-global 归属，确保用户可执行
        _ = try? run("/usr/sbin/chown", args: ["-R", username, prefix])
        return output
    }

    /// 为指定用户设置 npm 安装源（写入用户级 ~/.npmrc）
    @discardableResult
    static func setNpmRegistry(username: String, registry: String, logURL: URL? = nil) throws -> String {
        guard let option = NpmRegistryOption.fromRegistryURL(registry) else {
            throw InstallError.unsupportedNpmRegistry(registry)
        }
        let npmPath = try findNpmBinary()
        let args = ["-u", username, "-H",
                    "env", sudoNodePath,
                    npmPath, "config", "set", "registry", option.rawValue, "--location=user"]
        if let logURL {
            _ = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
        } else {
            _ = try run("/usr/bin/sudo", args: args)
        }
        return option.rawValue
    }

    /// 获取指定用户当前 npm 安装源（优先用户级配置）
    static func getNpmRegistry(username: String) -> String {
        guard let npmPath = try? findNpmBinary() else {
            return NpmRegistryOption.npmOfficial.rawValue
        }
        let args = ["-u", username, "-H",
                    "env", sudoNodePath,
                    npmPath, "config", "get", "registry", "--location=user"]
        let raw = (try? run("/usr/bin/sudo", args: args)) ?? NpmRegistryOption.npmOfficial.rawValue
        if let option = NpmRegistryOption.fromRegistryURL(raw) {
            return option.rawValue
        }
        let normalized = NpmRegistryOption.normalize(raw)
        return normalized.isEmpty ? NpmRegistryOption.npmOfficial.rawValue : normalized
    }

    /// 查询指定用户当前安装的 openclaw 版本（未安装返回 nil）
    /// 优先从 package.json 读取版本（毫秒级），避免启动 Node 子进程（2~3s 延迟）
    static func installedVersion(username: String) -> String? {
        // 1. 优先读 npm 全局包的 package.json（~/.npm-global/lib/node_modules/openclaw/package.json）
        let pkgPath = "\(npmGlobalDir(for: username))/lib/node_modules/openclaw/package.json"
        if let data = FileManager.default.contents(atPath: pkgPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String, !version.isEmpty {
            return version
        }

        // 2. fallback：openclaw 二进制存在但 package.json 不可读时，跑子进程
        //    仅检查用户私有目录，不检查系统全局路径（/opt/homebrew 等），
        //    避免将管理机上的全局安装版本错误地报告为用户已安装版本
        let userBin = "\(npmGlobalBin(for: username))/openclaw"
        if FileManager.default.isExecutableFile(atPath: userBin) {
            return try? run("/usr/bin/sudo", args: ["-u", username, "-H", "env", sudoNodePath, userBin, "--version"])
        }
        return nil
    }

    // MARK: - 内部工具

    static func findNpmBinary() throws -> String {
        let candidates = ["/usr/local/bin/npm", "/opt/homebrew/bin/npm", "/usr/bin/npm"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = try? run("/usr/bin/which", args: ["npm"]), !path.isEmpty {
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw InstallError.npmNotFound
    }
}

enum InstallError: LocalizedError {
    case npmNotFound
    case unsupportedNpmRegistry(String)

    var errorDescription: String? {
        switch self {
        case .npmNotFound: return "未找到 npm，请先完成 Node.js 安装步骤"
        case .unsupportedNpmRegistry(let registry):
            return "不支持的 npm 源：\(registry)。仅支持淘宝加速与 npm 官方。"
        }
    }
}
