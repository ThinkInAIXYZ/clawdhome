// ClawdHomeHelper/Operations/UserEnvContract.swift
// 统一维护用户隔离环境变量契约，避免多处手写导致漂移

import Foundation

enum UserEnvContract {
    private static let proxyKeys = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "all_proxy",
        "NO_PROXY", "no_proxy",
    ]

    private static let orderedBaseKeys = [
        "HOME",
        "PATH",
        "HOMEBREW_PREFIX",
        "HOMEBREW_CELLAR",
        "HOMEBREW_REPOSITORY",
        "NPM_CONFIG_PREFIX",
        "npm_config_prefix",
        "NPM_CONFIG_CACHE",
        "npm_config_cache",
        "NPM_CONFIG_USERCONFIG",
        "npm_config_userconfig",
    ]

    static func home(username: String) -> String {
        "/Users/\(username)"
    }

    static func brewRoot(username: String) -> String {
        "\(home(username: username))/.brew"
    }

    static func npmGlobalDir(username: String) -> String {
        "\(home(username: username))/.npm-global"
    }

    static func npmUserConfig(username: String) -> String {
        "\(home(username: username))/.npmrc"
    }

    static func npmSharedCacheDir() -> String {
        "/var/lib/clawdhome/cache/npm"
    }

    /// ~/.zprofile 里要求存在的关键 export（顺序即最终建议顺序）
    static func zprofileRequiredExports() -> [String] {
        [
            "export PATH=\"$HOME/.brew/bin:$PATH\"",
            "export HOMEBREW_PREFIX=\"$HOME/.brew\"",
            "export HOMEBREW_CELLAR=\"$HOME/.brew/Cellar\"",
            "export HOMEBREW_REPOSITORY=\"$HOME/.brew\"",
            "export NPM_CONFIG_PREFIX=\"$HOME/.npm-global\"",
            "export npm_config_prefix=\"$HOME/.npm-global\"",
            "export NPM_CONFIG_USERCONFIG=\"$HOME/.npmrc\"",
            "export npm_config_userconfig=\"$HOME/.npmrc\"",
            "export PATH=\"$HOME/.npm-global/bin:$PATH\"",
        ]
    }

    /// 构建运行时环境（sudo /usr/bin/env 与 launchd plist 共享）
    static func runtimeEnvironment(username: String, nodePath: String) -> [String: String] {
        let homeDir = home(username: username)
        let brew = brewRoot(username: username)
        let npmGlobal = npmGlobalDir(username: username)
        let npmCache = npmSharedCacheDir()
        let npmrc = npmUserConfig(username: username)
        var env: [String: String] = [
            "HOME": homeDir,
            "PATH": nodePath,
            "HOMEBREW_PREFIX": brew,
            "HOMEBREW_CELLAR": "\(brew)/Cellar",
            "HOMEBREW_REPOSITORY": brew,
            "NPM_CONFIG_PREFIX": npmGlobal,
            "npm_config_prefix": npmGlobal,
            "NPM_CONFIG_CACHE": npmCache,
            "npm_config_cache": npmCache,
            "NPM_CONFIG_USERCONFIG": npmrc,
            "npm_config_userconfig": npmrc,
        ]

        let proxy = normalizedProxyEnvironment(username: username)
        for (key, value) in proxy {
            env[key] = value
        }
        return env
    }

    /// 按稳定顺序输出环境变量键值对，便于 diff/诊断对比
    static func orderedRuntimeEnvironment(username: String, nodePath: String) -> [(String, String)] {
        let env = runtimeEnvironment(username: username, nodePath: nodePath)
        var result: [(String, String)] = []
        for key in orderedBaseKeys {
            if let value = env[key] {
                result.append((key, value))
            }
        }
        let proxyPart = env.keys
            .filter { proxyKeys.contains($0) }
            .sorted()
            .compactMap { key -> (String, String)? in
                guard let value = env[key] else { return nil }
                return (key, value)
            }
        result.append(contentsOf: proxyPart)
        return result
    }

    /// 在 `-lc` 场景前置 export，避免登录 shell 重写 PATH/HOMEBREW 等关键变量
    static func shellForcedExportPrefix(username: String, nodePath: String) -> String {
        let parts = orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { key, value in
                "export \(key)=\(shellSingleQuoted(value))"
            }
        return (parts + ["hash -r 2>/dev/null || true"]).joined(separator: "; ")
    }

    private static func normalizedProxyEnvironment(username: String) -> [String: String] {
        let raw = ConfigWriter.proxyEnvironment(username: username)
        var normalized: [String: String] = [:]
        for key in proxyKeys {
            guard let value = raw[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            normalized[key] = value
        }
        return normalized
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
