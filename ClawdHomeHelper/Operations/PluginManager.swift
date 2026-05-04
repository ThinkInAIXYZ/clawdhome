// ClawdHomeHelper/Operations/PluginManager.swift
// 封装 openclaw plugins install/list/remove 操作（v2）
//
// 设计原则：
// - 仅负责插件安装（npm exec openclaw plugins install <pkg>），不执行 bot 绑定
// - bot 绑定由上层 IMBotProvisioner 协议的各具体实现负责（App 层 Swift URLSession）
// - 通过 sudo -u <username> 以目标用户身份运行，保持隔离性

import Foundation

struct PluginManager {

    // MARK: - installPlugin

    /// 安装 openclaw plugin（plugins install <packageSpec>）
    /// packageSpec 示例："@larksuite/openclaw-lark"
    /// 本函数只做插件安装，不调用 install 流程中的 bot 绑定部分。
    @discardableResult
    static func installPlugin(
        username: String,
        packageSpec: String,
        logURL: URL? = nil
    ) throws -> String {
        guard !packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManagerError.invalidPackageSpec
        }
        let sanitized = sanitizePackageSpec(packageSpec)
        let openclawPath = try ConfigWriter.findOpenclawBinary(for: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let shellCommand = "cd \"$HOME\" && '\(openclawPath)' plugins install \(sanitized)"
        return try runAsUserInternal(
            username: username,
            nodePath: nodePath,
            shellCommand: shellCommand,
            logURL: logURL
        )
    }

    // MARK: - listPlugins

    /// 列出已安装 plugins（openclaw plugins --json）
    /// 返回 JSON 编码的 [String]（plugin 名称列表）
    static func listPlugins(username: String) throws -> String {
        let openclawPath = try ConfigWriter.findOpenclawBinary(for: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let shellCommand = "cd \"$HOME\" && '\(openclawPath)' plugins --json 2>/dev/null || echo '[]'"
        let raw = try runAsUserInternal(
            username: username,
            nodePath: nodePath,
            shellCommand: shellCommand,
            logURL: nil
        )
        // 尝试提取 JSON 部分（命令可能输出额外行）
        return extractJSONFragment(from: raw) ?? "[]"
    }

    // MARK: - removePlugin

    /// 移除已安装 plugin
    @discardableResult
    static func removePlugin(
        username: String,
        packageSpec: String,
        logURL: URL? = nil
    ) throws -> String {
        guard !packageSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManagerError.invalidPackageSpec
        }
        let sanitized = sanitizePackageSpec(packageSpec)
        let openclawPath = try ConfigWriter.findOpenclawBinary(for: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let shellCommand = "cd \"$HOME\" && '\(openclawPath)' plugins remove \(sanitized)"
        return try runAsUserInternal(
            username: username,
            nodePath: nodePath,
            shellCommand: shellCommand,
            logURL: logURL
        )
    }

    // MARK: - runChannelLogin

    /// 执行 openclaw channels login —— 用于标准通道登录（微信/WhatsApp/Tlon）
    /// args 示例：["--channel", "openclaw-weixin", "--account", "wechat-work"]
    /// 返回命令全部输出（含二维码 ASCII 图像）
    @discardableResult
    static func runChannelLogin(
        username: String,
        args: [String],
        logURL: URL? = nil
    ) throws -> String {
        let openclawPath = try ConfigWriter.findOpenclawBinary(for: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let escapedArgs = args.map { shellSingleQuoted($0) }.joined(separator: " ")
        let shellCommand = "cd \"$HOME\" && '\(openclawPath)' channels login \(escapedArgs)"
        return try runAsUserInternal(
            username: username,
            nodePath: nodePath,
            shellCommand: shellCommand,
            logURL: logURL
        )
    }

    // MARK: - Private helpers

    /// 安全化 packageSpec：只允许 npm 包名合法字符，防止 shell 注入
    /// 合法格式：@scope/name 或 name（可含 @版本）
    private static func sanitizePackageSpec(_ spec: String) -> String {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用单引号包裹，escaping 内部单引号
        return shellSingleQuoted(trimmed)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    /// 在目标用户的 shell 环境下同步执行脚本
    private static func runAsUserInternal(
        username: String,
        nodePath: String,
        shellCommand: String,
        logURL: URL?
    ) throws -> String {
        let envPairs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
        let envArgs = envPairs.map { "\($0.0)=\($0.1)" }
        let forcedEnvPrefix = UserEnvContract.shellForcedExportPrefix(username: username, nodePath: nodePath)
        let fullScript = "\(forcedEnvPrefix); \(shellCommand)"

        let fullArgs: [String] = ["-n", "-u", username, "-H", "/usr/bin/env"]
            + envArgs
            + ["/bin/zsh", "-lc", fullScript]

        if let logURL {
            return try runLogging("/usr/bin/sudo", args: fullArgs, logURL: logURL)
        } else {
            return try run("/usr/bin/sudo", args: fullArgs)
        }
    }

    /// 从混合输出中提取第一段合法 JSON 数组片段
    private static func extractJSONFragment(from raw: String) -> String? {
        guard let start = raw.range(of: "["),
              let end = raw.range(of: "]", options: .backwards) else { return nil }
        guard start.lowerBound <= end.upperBound else { return nil }
        let fragment = String(raw[start.lowerBound...end.upperBound])
        if let data = fragment.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return fragment
        }
        return nil
    }
}

// MARK: - Error

enum PluginManagerError: LocalizedError {
    case invalidPackageSpec
    case openclawNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackageSpec:
            return "插件包名不能为空"
        case .openclawNotFound(let username):
            return "未找到 openclaw 二进制：@\(username)"
        }
    }
}
