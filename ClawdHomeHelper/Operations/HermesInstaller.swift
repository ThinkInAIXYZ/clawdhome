// ClawdHomeHelper/Operations/HermesInstaller.swift
// 以目标用户身份安装 Hermes Agent（https://github.com/NousResearch/hermes-agent）
//
// 安装策略：
//   1. 以目标用户身份执行官方 install.sh（非交互模式）
//   2. 官方脚本默认安装到 ~/.hermes/hermes-agent，并创建 ~/.local/bin/hermes
//   3. 同时兼容历史路径 ~/.hermes-venv（平滑升级）
//
// 运行时前置：目标用户可访问的 Python 3.11+ 解释器。
// 本阶段不负责自动安装 Python —— 前置条件不满足时直接报错，由用户通过 Homebrew
// （brew install python@3.11）或系统工具自行准备。

import Foundation

struct HermesInstaller {

    // MARK: - 路径契约

    /// 官方脚本默认安装目录：~/.hermes/hermes-agent
    static func installDir(for username: String) -> String {
        "\(hermesHome(for: username))/hermes-agent"
    }

    /// Hermes venv 目录（优先官方脚本路径；兼容旧版 ~/.hermes-venv）
    static func venvDir(for username: String) -> String {
        let preferred = "\(installDir(for: username))/venv"
        if FileManager.default.fileExists(atPath: "\(preferred)/pyvenv.cfg") {
            return preferred
        }
        return "/Users/\(username)/.hermes-venv"
    }

    /// venv 中的可执行文件目录
    static func venvBin(for username: String) -> String {
        "\(venvDir(for: username))/bin"
    }

    /// hermes 可执行文件完整路径
    static func hermesExecutable(for username: String) -> String {
        let home = "/Users/\(username)"
        let candidates = [
            "\(home)/.local/bin/hermes",
            "\(installDir(for: username))/venv/bin/hermes",
            "\(home)/.hermes-venv/bin/hermes", // 兼容历史安装
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        return candidates[0]
    }

    /// HERMES_HOME —— Hermes 的配置/会话/日志根目录
    static func hermesHome(for username: String) -> String {
        "/Users/\(username)/.hermes"
    }

    // MARK: - 兼容工具定位（历史路径）

    /// 按优先级查找目标用户可用的 Python 3.11+ 解释器
    /// 用户级 Homebrew 优先，再到系统级 Homebrew，再到系统 Python
    static func findPython(for username: String) throws -> String {
        let home = "/Users/\(username)"
        let userBrew = "\(home)/.brew"
        let candidates = [
            "\(userBrew)/opt/python@3.13/bin/python3.13",
            "\(userBrew)/opt/python@3.12/bin/python3.12",
            "\(userBrew)/opt/python@3.11/bin/python3.11",
            "\(userBrew)/bin/python3.13",
            "\(userBrew)/bin/python3.12",
            "\(userBrew)/bin/python3.11",
            "\(userBrew)/bin/python3",
            "/opt/homebrew/opt/python@3.13/bin/python3.13",
            "/opt/homebrew/opt/python@3.12/bin/python3.12",
            "/opt/homebrew/opt/python@3.11/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/opt/python@3.12/bin/python3.12",
            "/usr/local/opt/python@3.11/bin/python3.11",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw HermesInstallError.pythonNotFound
    }

    /// 查找可用的 uv（可选，未找到时 fallback 到 pip）
    static func findUV(for username: String) -> String? {
        let home = "/Users/\(username)"
        let candidates = [
            "\(home)/.local/bin/uv",
            "\(home)/.cargo/bin/uv",
            "\(home)/.brew/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Hermes 独立的 PATH（不含 npm/node 路径，与 OpenClaw 环境隔离）
    static func buildPath(for username: String) -> String {
        let home = "/Users/\(username)"
        return [
            venvBin(for: username),
            "\(home)/.local/bin",
            "\(home)/.brew/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
    }

    /// Hermes 运行时环境变量（有序 KV 对），用于维护终端 / LaunchDaemon 等场景。
    /// 与 UserEnvContract.orderedRuntimeEnvironment 对称但完全独立，不含 npm/node 相关变量。
    static func orderedRuntimeEnvironment(username: String) -> [(String, String)] {
        let home = "/Users/\(username)"
        let brew = "\(home)/.brew"
        return [
            ("HOME", home),
            ("USER", username),
            ("PATH", buildPath(for: username)),
            ("HERMES_HOME", hermesHome(for: username)),
            ("VIRTUAL_ENV", venvDir(for: username)),
            ("HOMEBREW_PREFIX", brew),
            ("HOMEBREW_CELLAR", "\(brew)/Cellar"),
            ("HOMEBREW_REPOSITORY", brew),
        ]
    }

    /// 以 sudo -u <user> 运行 hermes/pip/uv 时通用的环境变量前缀
    static func sudoRuntimeArgs(for username: String) -> [String] {
        orderedRuntimeEnvironment(username: username)
            .map { "\($0.0)=\($0.1)" }
    }

    // MARK: - 安装

    /// 为指定用户安装或升级 Hermes Agent
    /// - Parameters:
    ///   - username: macOS 账户名
    ///   - version: nil 表示最新版，否则安装指定版本（如 "0.1.0"）
    @discardableResult
    static func install(username: String, version: String?, logURL: URL? = nil) throws -> String {
        // 与 openclaw 安装流程对齐：先做用户级 Homebrew 修复（best-effort）。
        // 该步骤失败不阻断后续 Hermes 官方安装流程。
        do {
            try HomebrewRepairManager.repair(username: username, logURL: logURL)
        } catch {
            helperLog("Hermes 前置 Homebrew 修复失败（忽略继续） @\(username): \(error.localizedDescription)", level: .warn)
        }

        // 0. 前置检查：目标用户可用的 Python 3.11+
        _ = try findPython(for: username)

        let home = hermesHome(for: username)

        // 1. 确保 HERMES_HOME 存在且归属用户
        if !FileManager.default.fileExists(atPath: home) {
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true, attributes: nil
            )
        }
        try? FilePermissionHelper.chown(home, owner: username)

        // 2. 使用官方 install.sh（非交互），并保持目标用户环境隔离
        helperLog("[HermesInstaller] 使用官方脚本安装 @\(username)")
        let installScriptURL = "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
        var scriptCmd = "curl -fsSL \(installScriptURL) | /bin/bash -s -- --skip-setup --hermes-home \"$HERMES_HOME\""
        if let branch = sanitizeBranch(version) {
            scriptCmd += " --branch \(branch)"
        }

        let args = ["-u", username, "-H", "env", "-i"]
            + sudoRuntimeArgs(for: username)
            + ["/bin/bash", "-c", scriptCmd]
        let output = try runInstallStep("/usr/bin/sudo", args: args, logURL: logURL)

        // 3. 修正所有权（脚本内若触发 sudo/install 产生 root-owned 文件，做一次兜底）
        let venv = venvDir(for: username)
        try? FilePermissionHelper.chownRecursive(installDir(for: username), owner: username)
        try? FilePermissionHelper.chownRecursive(home, owner: username)
        try? FilePermissionHelper.chownRecursive(venv, owner: username)

        helperLog("[HermesInstaller] INSTALL_OK @\(username)")
        return output
    }

    /// 官方脚本的 --branch 参数只接受安全字符，避免注入
    private static func sanitizeBranch(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.contains("..") else {
            return nil
        }
        return trimmed
    }

    @discardableResult
    private static func runInstallStep(_ exe: String, args: [String], logURL: URL?) throws -> String {
        if let logURL {
            return try runLogging(exe, args: args, logURL: logURL)
        }
        return try run(exe, args: args)
    }

    // MARK: - 版本查询

    /// 查询已安装的 Hermes 版本（未安装返回 nil）
    /// 为避免启动 Python 解释器带来 ~1s 延迟，优先读取 venv 内 dist-info 里的 METADATA
    static func installedVersion(username: String) -> String? {
        let hermesBin = hermesExecutable(for: username)
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else { return nil }

        // 快速路径：扫 venv 下的 site-packages 找 hermes_agent-*.dist-info
        if let fastVersion = readVersionFromDistInfo(username: username) {
            return fastVersion
        }

        // fallback：调用 hermes --version（慢但准）
        let args = ["-u", username, "-H", "env", "-i"]
            + sudoRuntimeArgs(for: username)
            + [hermesBin, "--version"]
        let raw = (try? run("/usr/bin/sudo", args: args)) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 venv/lib/pythonX.Y/site-packages/hermes_agent-*.dist-info/METADATA 解析版本
    private static func readVersionFromDistInfo(username: String) -> String? {
        let libRoot = "\(venvDir(for: username))/lib"
        guard let pyDirs = try? FileManager.default.contentsOfDirectory(atPath: libRoot) else {
            return nil
        }
        for pyDir in pyDirs where pyDir.hasPrefix("python") {
            let sitePackages = "\(libRoot)/\(pyDir)/site-packages"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sitePackages) else {
                continue
            }
            for entry in entries where entry.hasPrefix("hermes_agent-") && entry.hasSuffix(".dist-info") {
                // 包名中的版本号：hermes_agent-0.1.0.dist-info
                let stripped = entry.dropFirst("hermes_agent-".count).dropLast(".dist-info".count)
                let version = String(stripped)
                if !version.isEmpty { return version }
            }
        }
        return nil
    }
}

enum HermesInstallError: LocalizedError {
    case pythonNotFound

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "未找到 Python 3.11+。请先为目标用户准备 Python，例如 `brew install python@3.12` 后重试。"
        }
    }
}
