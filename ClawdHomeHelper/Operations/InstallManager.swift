// ClawdHomeHelper/Operations/InstallManager.swift
// 以目标用户身份安装或升级 openclaw（sudo -u <user> npm install -g）
// 注意：npm install 可能耗时较长

import Foundation
import SystemConfiguration

struct InstallManager {

    /// sudo -H 会 reset PATH；openclaw 是 node shebang 脚本，需要显式传 PATH
    /// 必须优先使用目标用户隔离环境（~/.brew + ~/.npm-global），避免全局 Node/npm 串用。
    static func sudoNodePath(for username: String) -> String {
        "PATH=\(ConfigWriter.buildNodePath(username: username))"
    }

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
        try ensureNpmBuildToolchainReady()
        try normalizeNpmUserOwnership(username: username)
        let npmPath = try findNpmBinary(for: username)
        let packageArg = version.map { "openclaw@\($0)" } ?? "openclaw@latest"
        let prefix = npmGlobalDir(for: username)
        // 安装前预修正 .openclaw 所有权，避免存量 root-owned 文件阻断新版本启动
        let openclawDirPre = "/Users/\(username)/.openclaw"
        if FileManager.default.fileExists(atPath: openclawDirPre) {
            do {
                try FilePermissionHelper.chownRecursive(openclawDirPre, owner: username)
            } catch {
                helperLog("chownRecursive pre-install \(openclawDirPre) failed for @\(username): \(error.localizedDescription)", level: .warn)
            }
        }
        let args = ["-u", username, "-H",
                    "env", sudoNodePath(for: username),
                    npmPath, "install", "-g", "--prefix", prefix,
                    "--include=optional",
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
            do {
                try FilePermissionHelper.chownRecursive(openclawDir, owner: username)
            } catch {
                helperLog("chownRecursive post-install \(openclawDir) failed for @\(username): \(error.localizedDescription)", level: .warn)
            }
        }
        // 修正 npm-global 归属，确保用户可执行
        do {
            try FilePermissionHelper.chownRecursive(prefix, owner: username)
        } catch {
            helperLog("chownRecursive npm prefix \(prefix) failed for @\(username): \(error.localizedDescription)", level: .warn)
        }
        return output
    }

    /// 为指定用户设置 npm 安装源（写入用户级 ~/.npmrc）
    @discardableResult
    static func setNpmRegistry(username: String, registry: String, logURL: URL? = nil) throws -> String {
        guard let option = NpmRegistryOption.fromRegistryURL(registry) else {
            throw InstallError.unsupportedNpmRegistry(registry)
        }
        try normalizeNpmUserOwnership(username: username)
        let npmPath = try findNpmBinary(for: username)
        let args = ["-u", username, "-H",
                    "env", sudoNodePath(for: username),
                    npmPath, "config", "set", "registry", option.rawValue, "--location=user"]
        do {
            if let logURL {
                _ = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
            } else {
                _ = try run("/usr/bin/sudo", args: args)
            }
        } catch {
            if isNpmPermissionError(error) {
                // 历史 npm 版本会留下 root-owned ~/.npm 或 ~/.npmrc，修复后重试一次。
                try normalizeNpmUserOwnership(username: username)
                if let logURL {
                    _ = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
                } else {
                    _ = try run("/usr/bin/sudo", args: args)
                }
            } else {
                throw error
            }
        }
        return option.rawValue
    }

    /// 获取指定用户当前 npm 安装源（优先用户级配置）
    static func getNpmRegistry(username: String) -> String {
        guard let npmPath = try? findNpmBinary(for: username) else {
            return NpmRegistryOption.npmOfficial.rawValue
        }
        let args = ["-u", username, "-H",
                    "env", sudoNodePath(for: username),
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
            return try? run("/usr/bin/sudo", args: ["-u", username, "-H", "env", sudoNodePath(for: username), userBin, "--version"])
        }
        return nil
    }

    // MARK: - 内部工具

    static func findNpmBinary(for username: String) throws -> String {
        let home = "/Users/\(username)"
        let brewRoot = "\(home)/.brew"
        var candidates = [
            "\(brewRoot)/bin/npm",
            "\(brewRoot)/opt/node/bin/npm",
            "\(brewRoot)/opt/node@24/bin/npm",
            "\(brewRoot)/opt/node@22/bin/npm",
            "\(brewRoot)/opt/node@20/bin/npm",
            "\(brewRoot)/opt/node@18/bin/npm",
        ]
        let cellar = "\(brewRoot)/Cellar"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            let nodeFormulae = entries.filter { $0 == "node" || $0.hasPrefix("node@") }.sorted()
            for formula in nodeFormulae {
                let formulaDir = "\(cellar)/\(formula)"
                if let versions = try? FileManager.default.contentsOfDirectory(atPath: formulaDir).sorted(by: >) {
                    for version in versions {
                        candidates.append("\(formulaDir)/\(version)/bin/npm")
                    }
                }
            }
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw InstallError.npmNotFound
    }

    /// 某些 npm 包会触发本地编译（node-gyp），需要 Xcode CLT + 可用 clang。
    /// 在安装前尽早给出明确修复指引，避免用户只看到 npm 的长日志失败。
    static func ensureNpmBuildToolchainReady() throws {
        let status = xcodeEnvStatus()
        if !status.commandLineToolsInstalled {
            throw InstallError.xcodeCommandLineToolsMissing
        }
        if !status.licenseAccepted {
            throw InstallError.xcodeLicenseNotAccepted
        }
        if !status.clangAvailable {
            throw InstallError.xcodeToolchainNotReady(details: status.detail)
        }
    }

    private static func normalizeNpmUserOwnership(username: String) throws {
        let home = "/Users/\(username)"
        let npmCacheDir = "\(home)/.npm"
        let npmrcPath = "\(home)/.npmrc"
        let npmGlobal = npmGlobalDir(for: username)

        if !FileManager.default.fileExists(atPath: npmCacheDir) {
            try FileManager.default.createDirectory(
                atPath: npmCacheDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        if FileManager.default.fileExists(atPath: npmCacheDir) {
            try FilePermissionHelper.chownRecursive(npmCacheDir, owner: username)
        }
        if FileManager.default.fileExists(atPath: npmrcPath) {
            try FilePermissionHelper.chown(npmrcPath, owner: username)
        }
        if FileManager.default.fileExists(atPath: npmGlobal) {
            try FilePermissionHelper.chownRecursive(npmGlobal, owner: username)
        }

        // .brew 目录也需修正：NodeDownloader 以 root 解压 tarball 后虽然会
        // chown -R，但在 setNpmRegistry / install 时若 chown 曾静默失败，
        // 或后续 root 操作污染了归属，此处补偿修正以确保 sudo -u 能正常执行 npm。
        let brewRoot = "\(home)/.brew"
        if FileManager.default.fileExists(atPath: brewRoot) {
            try? FilePermissionHelper.chownRecursive(brewRoot, owner: username)
            // 确保 owner 对目录有 traverse 权限、对可执行文件有执行权限
            try? FilePermissionHelper.chmodSymbolicRecursive(brewRoot, expr: "u+rwX")
        }
    }

    private static func isNpmPermissionError(_ error: Error) -> Bool {
        guard case let ShellError.nonZeroExit(_, _, stderr) = error else { return false }
        let normalized = stderr.lowercased()
        return normalized.contains("eacces")
            || normalized.contains("errno -13")
            || normalized.contains("permission denied")
    }

    /// 查询 Xcode/CLT 状态，用于 UI 展示和安装前预检。
    static func xcodeEnvStatus() -> XcodeEnvStatus {
        var cltInstalled = false
        var clangAvailable = false
        var licenseAccepted = true
        var detail = ""

        do {
            _ = try run("/usr/bin/xcode-select", args: ["-p"])
            cltInstalled = true
        } catch {
            detail = error.localizedDescription
            return XcodeEnvStatus(
                commandLineToolsInstalled: false,
                clangAvailable: false,
                licenseAccepted: true,
                detail: detail
            )
        }

        do {
            _ = try run("/usr/bin/xcrun", args: ["--find", "clang"])
            clangAvailable = true
        } catch let shell as ShellError {
            let msg: String
            if case .nonZeroExit(_, _, let stderr) = shell {
                msg = stderr.lowercased()
            } else {
                msg = ""
            }

            if msg.contains("license") || msg.contains("agreeing to the xcode") {
                licenseAccepted = false
            }
            detail = shell.localizedDescription
        } catch {
            detail = error.localizedDescription
        }

        return XcodeEnvStatus(
            commandLineToolsInstalled: cltInstalled,
            clangAvailable: clangAvailable,
            licenseAccepted: licenseAccepted,
            detail: detail
        )
    }

    /// 触发 Xcode Command Line Tools 安装（会弹系统安装窗口）。
    static func installXcodeCommandLineTools() throws {
        let (consoleUser, consoleUID) = try resolveConsoleSession()
        do {
            _ = try run("/bin/launchctl", args: [
                "asuser", "\(consoleUID)",
                "/usr/bin/sudo", "-u", consoleUser, "-H",
                "/usr/bin/xcode-select", "--install",
            ])
        } catch let shell as ShellError {
            if case .nonZeroExit(_, _, let stderr) = shell {
                let msg = stderr.lowercased()
                if msg.contains("already installed")
                    || msg.contains("install requested")
                    || msg.contains("command line tools are already installed") {
                    return
                }
            }
            throw InstallError.xcodeToolchainNotReady(details: shell.localizedDescription)
        } catch {
            throw InstallError.xcodeToolchainNotReady(details: error.localizedDescription)
        }
    }

    /// 以 root 接受 Xcode license（非交互）。
    static func acceptXcodeLicense() throws {
        do {
            _ = try run("/usr/bin/xcodebuild", args: ["-license", "accept"])
        } catch let shell as ShellError {
            throw InstallError.xcodeToolchainNotReady(details: shell.localizedDescription)
        } catch {
            throw InstallError.xcodeToolchainNotReady(details: error.localizedDescription)
        }
    }

    // MARK: - 环境验证与修复

    /// 验证 openclaw 安装环境完整性，返回问题列表（空 = 全部正常）
    struct EnvIssue {
        let id: String
        let title: String
        let detail: String
        let fixable: Bool
    }

    /// 验证指定用户的 openclaw 运行环境，返回发现的问题列表
    static func verifyEnvironment(username: String) -> [EnvIssue] {
        var issues: [EnvIssue] = []
        let home = UserEnvContract.home(username: username)
        let openclawBin = "\(npmGlobalBin(for: username))/openclaw"
        let brewBin = "\(UserEnvContract.brewRoot(username: username))/bin"

        // 1. openclaw 二进制存在且可执行
        if !FileManager.default.fileExists(atPath: openclawBin) {
            issues.append(EnvIssue(
                id: "openclaw-missing",
                title: "openclaw 二进制文件不存在",
                detail: "\(openclawBin) 不存在",
                fixable: true))
        } else if !FileManager.default.isExecutableFile(atPath: openclawBin) {
            issues.append(EnvIssue(
                id: "openclaw-not-exec",
                title: "openclaw 二进制不可执行",
                detail: "\(openclawBin) 存在但无执行权限",
                fixable: true))
        } else {
            // 2. openclaw --version 能正常输出
            let versionResult = try? run("/usr/bin/sudo", args: [
                "-u", username, "-H", "env", sudoNodePath(for: username),
                openclawBin, "--version"
            ])
            if versionResult == nil || versionResult!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(EnvIssue(
                    id: "openclaw-not-runnable",
                    title: "openclaw 无法运行",
                    detail: "执行 openclaw --version 失败，可能 node 环境损坏",
                    fixable: true))
            }
        }

        // 3. node 符号链接完整性
        let nodeBin = "\(brewBin)/node"
        let brewRoot = UserEnvContract.brewRoot(username: username)
        if FileManager.default.fileExists(atPath: brewRoot) {
            if !FileManager.default.isExecutableFile(atPath: nodeBin) {
                let hasNodeElsewhere = FileManager.default.isExecutableFile(atPath: "\(brewRoot)/opt/node/bin/node")
                    || hasNodeInLib(username: username)
                issues.append(EnvIssue(
                    id: "node-symlink-broken",
                    title: "node 符号链接缺失",
                    detail: hasNodeElsewhere
                        ? "\(nodeBin) 不可用，但在 .brew/opt 或 .brew/lib 下找到了 node"
                        : "\(nodeBin) 不可用，Node.js 可能需要重装",
                    fixable: hasNodeElsewhere))
            }

            // 4. npm 符号链接完整性
            let npmBin = "\(brewBin)/npm"
            if !FileManager.default.isExecutableFile(atPath: npmBin) {
                issues.append(EnvIssue(
                    id: "npm-symlink-broken",
                    title: "npm 符号链接缺失",
                    detail: "\(npmBin) 不可用",
                    fixable: true))
            }
        }

        // 5. .zprofile PATH 导出完整性（利用 UserEnvContract）
        let profilePath = "\(home)/.zprofile"
        let profileContent = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
        let requiredExports = UserEnvContract.zprofileRequiredExports()
        let missingExports = requiredExports.filter { !profileContent.contains($0) }
        if !missingExports.isEmpty {
            issues.append(EnvIssue(
                id: "zprofile-path-incomplete",
                title: ".zprofile PATH 导出不完整",
                detail: "缺少 \(missingExports.count) 项环境变量导出",
                fixable: true))
        }

        return issues
    }

    /// 尝试修复环境问题，返回修复结果（成功/失败的 id 列表）
    static func repairEnvironment(username: String, issues: [EnvIssue]) -> (fixed: [String], failed: [String]) {
        var fixed: [String] = []
        var failed: [String] = []
        let home = UserEnvContract.home(username: username)
        let openclawBin = "\(npmGlobalBin(for: username))/openclaw"

        for issue in issues where issue.fixable {
            switch issue.id {
            case "openclaw-not-exec":
                do {
                    try FilePermissionHelper.chmod(openclawBin, mode: "755")
                    fixed.append(issue.id)
                } catch {
                    failed.append(issue.id)
                }

            case "openclaw-missing", "openclaw-not-runnable":
                // 需要重装，此处标记为需要重装（调用方决定是否执行）
                failed.append(issue.id)

            case "node-symlink-broken", "npm-symlink-broken":
                let target = issue.id == "node-symlink-broken" ? "node" : "npm"
                let symlinkPath = "\(UserEnvContract.brewRoot(username: username))/bin/\(target)"
                if let realPath = findActualBinary(username: username, name: target) {
                    do {
                        try? FileManager.default.removeItem(atPath: symlinkPath)
                        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realPath)
                        try FilePermissionHelper.chown(symlinkPath, owner: username)
                        fixed.append(issue.id)
                        helperLog("[env-repair] 修复符号链接 \(symlinkPath) → \(realPath) @\(username)")
                    } catch {
                        failed.append(issue.id)
                        helperLog("[env-repair] 修复符号链接失败 \(symlinkPath): \(error.localizedDescription) @\(username)", level: .warn)
                    }
                } else {
                    failed.append(issue.id)
                }

            case "zprofile-path-incomplete":
                let profilePath = "\(home)/.zprofile"
                let existing = (try? String(contentsOfFile: profilePath, encoding: .utf8)) ?? ""
                let requiredExports = UserEnvContract.zprofileRequiredExports()
                let missing = requiredExports.filter { !existing.contains($0) }
                if !missing.isEmpty {
                    var block = "\n"
                    if !existing.contains("# npm global") { block += "# npm global\n" }
                    block += missing.joined(separator: "\n") + "\n"
                    do {
                        let data = Data(block.utf8)
                        if FileManager.default.fileExists(atPath: profilePath) {
                            if let fh = FileHandle(forWritingAtPath: profilePath) {
                                fh.seekToEndOfFile()
                                fh.write(data)
                                fh.closeFile()
                            }
                        } else {
                            try data.write(to: URL(fileURLWithPath: profilePath))
                        }
                        try FilePermissionHelper.chown(profilePath, owner: username)
                        fixed.append(issue.id)
                        helperLog("[env-repair] 修复 .zprofile PATH 导出 @\(username)")
                    } catch {
                        failed.append(issue.id)
                    }
                }

            default:
                failed.append(issue.id)
            }
        }
        return (fixed, failed)
    }

    /// 在 .brew 下查找实际的 node/npm 二进制路径
    private static func findActualBinary(username: String, name: String) -> String? {
        let brewRoot = UserEnvContract.brewRoot(username: username)
        var candidates = [
            "\(brewRoot)/opt/node/bin/\(name)",
            "\(brewRoot)/opt/node@24/bin/\(name)",
            "\(brewRoot)/opt/node@22/bin/\(name)",
            "\(brewRoot)/opt/node@20/bin/\(name)",
            "\(brewRoot)/opt/node@18/bin/\(name)",
        ]
        // 扫描 .brew/lib/nodejs
        let libNodeRoot = "\(brewRoot)/lib/nodejs"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: libNodeRoot).sorted(by: >) {
            for entry in entries where entry.hasPrefix("node-") {
                candidates.append("\(libNodeRoot)/\(entry)/bin/\(name)")
            }
        }
        // 扫描 Cellar
        let cellar = "\(brewRoot)/Cellar"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            for formula in entries.filter({ $0 == "node" || $0.hasPrefix("node@") }).sorted() {
                let formulaDir = "\(cellar)/\(formula)"
                if let versions = try? FileManager.default.contentsOfDirectory(atPath: formulaDir).sorted(by: >) {
                    for version in versions {
                        candidates.append("\(formulaDir)/\(version)/bin/\(name)")
                    }
                }
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 检查 .brew/lib/nodejs 下是否有可用的 node
    private static func hasNodeInLib(username: String) -> Bool {
        let libNodeRoot = "\(UserEnvContract.brewRoot(username: username))/lib/nodejs"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: libNodeRoot) else { return false }
        return entries.contains { entry in
            entry.hasPrefix("node-") &&
            FileManager.default.isExecutableFile(atPath: "\(libNodeRoot)/\(entry)/bin/node")
        }
    }

    private static func resolveConsoleSession() throws -> (username: String, uid: uid_t) {
        var uid: uid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil),
              uid != 0 else {
            throw InstallError.xcodeToolchainNotReady(
                details: "未检测到可用的桌面登录会话。请先登录 macOS 桌面后再点击“安装开发工具”。"
            )
        }
        let username = (cfUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != "loginwindow" else {
            throw InstallError.xcodeToolchainNotReady(
                details: "当前不在可交互桌面会话中。请进入桌面后重试“安装开发工具”。"
            )
        }
        return (username, uid)
    }
}

enum InstallError: LocalizedError {
    case npmNotFound
    case unsupportedNpmRegistry(String)
    case xcodeCommandLineToolsMissing
    case xcodeLicenseNotAccepted
    case xcodeToolchainNotReady(details: String)

    var errorDescription: String? {
        switch self {
        case .npmNotFound: return "未找到 npm，请先完成 Node.js 安装步骤"
        case .unsupportedNpmRegistry(let registry):
            return "不支持的 npm 源：\(registry)。仅支持淘宝加速与 npm 官方。"
        case .xcodeCommandLineToolsMissing:
            return "检测到缺少 Xcode Command Line Tools。请先在 ClawdHome 的「开发环境修复」中点击“安装开发工具”，完成后重试。若需终端方式，可执行 `xcode-select --install`。"
        case .xcodeLicenseNotAccepted:
            return "检测到 Xcode license 未接受。请先在 ClawdHome 的「开发环境修复」中点击“同意 Xcode 许可”，完成后重试。若需终端方式，可执行 `sudo xcodebuild -license accept`。"
        case .xcodeToolchainNotReady(let details):
            return "检测到 Xcode/CLT 工具链未就绪。请先在 ClawdHome 的「开发环境修复」中完成修复后重试。\n\(details)"
        }
    }
}
