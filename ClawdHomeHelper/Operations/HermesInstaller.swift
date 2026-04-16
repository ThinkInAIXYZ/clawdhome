// ClawdHomeHelper/Operations/HermesInstaller.swift
// 以目标用户身份安装 Hermes Agent（https://github.com/NousResearch/hermes-agent）
//
// 安装策略：
//   1. 在用户目录创建独立 venv：~/.hermes-venv（隔离不同用户依赖）
//   2. 优先使用 uv pip install（快 10~100 倍），没有 uv 时 fallback 到标准 pip
//   3. 同时初始化 HERMES_HOME：~/.hermes
//
// 运行时前置：目标用户可访问的 Python 3.11+ 解释器。
// 本阶段不负责自动安装 Python —— 前置条件不满足时直接报错，由用户通过 Homebrew
// （brew install python@3.11）或系统工具自行准备。

import Foundation

struct HermesInstaller {

    // MARK: - 路径契约

    /// Hermes 独立 venv 目录（每用户隔离）
    static func venvDir(for username: String) -> String {
        "/Users/\(username)/.hermes-venv"
    }

    /// venv 中的可执行文件目录
    static func venvBin(for username: String) -> String {
        "\(venvDir(for: username))/bin"
    }

    /// hermes 可执行文件完整路径
    static func hermesExecutable(for username: String) -> String {
        "\(venvBin(for: username))/hermes"
    }

    /// HERMES_HOME —— Hermes 的配置/会话/日志根目录
    static func hermesHome(for username: String) -> String {
        "/Users/\(username)/.hermes"
    }

    // MARK: - Python / uv 定位

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

    /// 以 sudo -u <user> 运行 hermes/pip/uv 时通用的环境变量前缀
    static func sudoRuntimeArgs(for username: String) -> [String] {
        let home = "/Users/\(username)"
        let path = [
            venvBin(for: username),
            "\(home)/.local/bin",
            "\(home)/.brew/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        return [
            "HOME=\(home)",
            "USER=\(username)",
            "PATH=\(path)",
            "HERMES_HOME=\(hermesHome(for: username))",
        ]
    }

    // MARK: - 安装

    /// 为指定用户安装或升级 Hermes Agent
    /// - Parameters:
    ///   - username: macOS 账户名
    ///   - version: nil 表示最新版，否则安装指定版本（如 "0.1.0"）
    @discardableResult
    static func install(username: String, version: String?, logURL: URL? = nil) throws -> String {
        let python = try findPython(for: username)
        let venv = venvDir(for: username)
        let home = hermesHome(for: username)
        // hermes-agent 的 [all] extras 启用 messaging/voice/cli 等全部可选依赖
        let hermesSpec = version.map { "hermes-agent[all]==\($0)" } ?? "hermes-agent[all]"

        // 1. 确保 HERMES_HOME 存在且归属用户
        if !FileManager.default.fileExists(atPath: home) {
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true, attributes: nil
            )
        }
        try? FilePermissionHelper.chown(home, owner: username)

        // 2. 创建 venv（若已存在 pyvenv.cfg 就跳过，实现幂等升级）
        let venvCfg = "\(venv)/pyvenv.cfg"
        if !FileManager.default.fileExists(atPath: venvCfg) {
            helperLog("[HermesInstaller] 创建 venv python=\(python) dir=\(venv) @\(username)")
            let venvArgs = ["-u", username, "-H", "env"]
                + sudoRuntimeArgs(for: username)
                + [python, "-m", "venv", venv]
            try runInstallStep("/usr/bin/sudo", args: venvArgs, logURL: logURL)
        }

        // 3. 安装 hermes-agent（优先 uv）
        let args: [String]
        if let uv = findUV(for: username) {
            helperLog("[HermesInstaller] 使用 uv 安装 \(hermesSpec) @\(username)")
            args = ["-u", username, "-H", "env"]
                + sudoRuntimeArgs(for: username)
                + ["VIRTUAL_ENV=\(venv)"]
                + [uv, "pip", "install", "--python", "\(venv)/bin/python", "--upgrade", hermesSpec]
        } else {
            helperLog("[HermesInstaller] 未找到 uv，fallback 到 pip 安装 \(hermesSpec) @\(username)")
            let pip = "\(venv)/bin/pip"
            args = ["-u", username, "-H", "env"]
                + sudoRuntimeArgs(for: username)
                + [pip, "install", "--upgrade", hermesSpec]
        }
        let output = try runInstallStep("/usr/bin/sudo", args: args, logURL: logURL)

        // 4. 修正所有权（pip/uv 在 sudo 下可能产生 root-owned 文件）
        try? FilePermissionHelper.chownRecursive(venv, owner: username)
        try? FilePermissionHelper.chownRecursive(home, owner: username)

        helperLog("[HermesInstaller] INSTALL_OK @\(username)")
        return output
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
        let args = ["-u", username, "-H", "env"]
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
