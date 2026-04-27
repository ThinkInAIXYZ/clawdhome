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

    // MARK: - .clawdhome 运行时配置

    /// ~/.clawdhome/ 目录（per-shrimp ClawdHome 配置根目录）
    static func clawdhomeDir(for username: String) -> String {
        "/Users/\(username)/.clawdhome"
    }

    static func runtimeConfigPath(for username: String) -> String {
        "\(clawdhomeDir(for: username))/runtime.json"
    }

    static func readRuntimeConfig(username: String) -> ShrimpRuntimeConfig? {
        guard let data = FileManager.default.contents(atPath: runtimeConfigPath(for: username)) else { return nil }
        return try? JSONDecoder().decode(ShrimpRuntimeConfig.self, from: data)
    }

    /// 写入运行时声明（best-effort，失败仅记日志不抛出）
    static func writeRuntimeConfig(runtime: String, username: String) {
        let dir = clawdhomeDir(for: username)
        do {
            if !FileManager.default.fileExists(atPath: dir) {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true, attributes: nil
                )
            }
            let config = ShrimpRuntimeConfig(runtime: runtime)
            let data = try JSONEncoder().encode(config)
            let path = runtimeConfigPath(for: username)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            _ = try? FilePermissionHelper.chown(dir, owner: username)
            _ = try? FilePermissionHelper.chown(path, owner: username)
        } catch {
            helperLog("[ClawdhomeConfig] 写入运行时配置失败 runtime=\(runtime) @\(username): \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - PATH

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

        try cleanupAccidentalOpenClawDraftIfNeeded(username: username)

        let home = hermesHome(for: username)

        // 1. 确保 HERMES_HOME 存在且归属用户
        if !FileManager.default.fileExists(atPath: home) {
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true, attributes: nil
            )
        }
        _ = try? FilePermissionHelper.chown(home, owner: username)

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
        _ = try? FilePermissionHelper.chownRecursive(installDir(for: username), owner: username)
        _ = try? FilePermissionHelper.chownRecursive(home, owner: username)
        _ = try? FilePermissionHelper.chownRecursive(venv, owner: username)

        helperLog("[HermesInstaller] INSTALL_OK @\(username)")
        // 写入运行时声明，固定识别引擎（防止 hermes --version 并发失败导致实例识别抖动）
        writeRuntimeConfig(runtime: "hermes", username: username)
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

    private static func cleanupAccidentalOpenClawDraftIfNeeded(username: String) throws {
        let openclawDir = "/Users/\(username)/.openclaw"
        guard FileManager.default.fileExists(atPath: openclawDir) else { return }

        let hasOpenClawBinary = (try? ConfigWriter.findOpenclawBinary(for: username)) != nil
        let topLevelEntries = (try? FileManager.default.contentsOfDirectory(atPath: openclawDir)) ?? []
        guard AccidentalOpenClawDraftDetector.shouldDelete(
            topLevelEntries: topLevelEntries,
            hasOpenClawBinary: hasOpenClawBinary
        ) else { return }

        helperLog("[HermesInstaller] 检测到误生成的 .openclaw 草稿目录，安装前清理 @\(username)")
        try FileManager.default.removeItem(atPath: openclawDir)
    }

    // MARK: - 版本查询

    /// 查询已安装的 Hermes 版本（未安装返回 nil）
    /// 识别依据：先查 ~/.clawdhome/runtime.json，确认是 hermes 实例后再读 dist-info 版本号。
    /// 不再 fallback 到 hermes --version 子进程，防止并发执行时输出为空导致识别抖动。
    static func installedVersion(username: String) -> String? {
        // 1. 有运行时配置且明确声明为非 hermes → 快速返回 nil，防止误识别
        if let config = readRuntimeConfig(username: username), config.runtime != "hermes" {
            return nil
        }

        // 2. 可执行文件必须存在（向下兼容：无配置文件时也走此检查）
        let hermesBin = hermesExecutable(for: username)
        guard FileManager.default.isExecutableFile(atPath: hermesBin) else { return nil }

        // 3. 从 venv dist-info 读取版本（纯文件读取，无子进程）
        if let fastVersion = readVersionFromDistInfo(username: username) {
            return fastVersion
        }

        // 4. dist-info 暂时不可读（如安装中途）→ 有配置文件时返回占位版本避免识别翻转
        if readRuntimeConfig(username: username) != nil {
            return "unknown"
        }

        return nil
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
