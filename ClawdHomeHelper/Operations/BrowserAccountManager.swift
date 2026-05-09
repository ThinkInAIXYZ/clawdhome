// ClawdHomeHelper/Operations/BrowserAccountManager.swift
// Manages per-user Chrome profiles and browser tool integration.

import Foundation
import SystemConfiguration

enum BrowserAccountError: LocalizedError {
    case invalidUsername
    case chromeNotFound
    case noConsoleSession
    case sessionMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return "无效的用户名"
        case .chromeNotFound:
            return "未找到 Google Chrome，请先安装 Chrome"
        case .noConsoleSession:
            return "未检测到可交互的 macOS 桌面登录会话"
        case .sessionMissing:
            return "浏览器账号尚未打开，请先在 ClawdHome 中打开浏览器账号"
        case .commandFailed(let message):
            return message
        }
    }
}

enum BrowserAccountManager {
    private static let chromeAppPath = "/Applications/Google Chrome.app"
    private static let openCLIBrowserBridgeExtensionID = "ildkmabpimmkaediidaifkhjpohdnifk"
    private static let openCLIBrowserBridgeUpdateURL = "https://clients2.google.com/service/update2/crx"
    private static let chromeManagedPolicyPath = "/Library/Managed Preferences/com.google.Chrome.plist"
    // 主动防御：默认不触碰宿主机全局 Chrome 策略，只有显式创建该开关文件才允许写入 force-install。
    // 这样可以避免误把宿主机默认浏览器也强制安装 OpenCLI 扩展。
    private static let allowGlobalChromePolicyFlagPath = "/var/lib/clawdhome/browser/allow-global-chrome-policy"
    private static let openCLIDefaultDaemonPort = 19825
    private static let openCLIDefaultCDPCapturePort = 9222

    static func prepareForRuntimeInstall(username: String, logURL: URL? = nil) throws {
        appendInstallLog("→ 安装 ClawdHome 用户级浏览器工具\n", logURL: logURL)
        _ = try installTool(username: username, logURL: logURL)
        appendInstallLog("✓ ClawdHome 用户级浏览器工具已安装\n", logURL: logURL)

        if installWarmupCompleted(username: username),
           readOpenCLIProfile(username: username) != nil {
            appendInstallLog("✓ 浏览器安装预热与 OpenCLI profile 初始化已完成，本次跳过重复打开\n", logURL: logURL)
            return
        }

        guard isChromeInstalled() else {
            appendInstallLog("⚠ 未检测到 Google Chrome，已跳过浏览器预热。浏览器工具已安装，安装 Chrome 后可直接使用。\n", logURL: logURL)
            return
        }

        appendInstallLog("→ 首次打开用户级 Chrome 浏览器账号并写入 session\n", logURL: logURL)
        let context = try resolveContext(username: username)
        let bridgePolicyAction = try ensureOpenCLIBrowserBridgeExtensionInstalled(context: context, logURL: logURL)
        switch bridgePolicyAction {
        case .configured(let policyPath):
            appendInstallLog("✓ OpenCLI Browser Bridge 安装策略已写入：\(policyPath)\n", logURL: logURL)
        case .guardedPolicyRemoved(let policyPath):
            appendInstallLog(
                "⚠ 已触发主动防御：检测到宿主机全局 force-install 条目，已移除：\(policyPath)\n",
                logURL: logURL
            )
        case .guardedNoPolicyChange:
            appendInstallLog(
                "✓ 已启用主动防御：默认不写入宿主机 Chrome 全局策略（仅维护实例专属 profile）\n",
                logURL: logURL
            )
        }
        var openedProfilePath = context.paths.profileDirectory.path
        do {
            let session = try open(username: username, requireBridge: true, enableCDPCapture: true)
            openedProfilePath = session.profilePath
            Thread.sleep(forTimeInterval: 0.8)
            do {
                let profile = try captureAndPersistOpenCLIProfile(
                    username: username,
                    profilePath: openedProfilePath,
                    logURL: logURL
                )
                appendInstallLog("✓ OpenCLI profile 已记录：\(profile)\n", logURL: logURL)
            } catch {
                appendInstallLog("⚠ OpenCLI profile 初始化失败（稍后可由 wrapper 自动补全）：\(error.localizedDescription)\n", logURL: logURL)
            }
            try closeWarmupBrowser(profilePath: openedProfilePath, logURL: logURL)
        } catch {
            appendInstallLog("⚠ 浏览器预热失败，先关闭已打开的 Chrome profile\n", logURL: logURL)
            try? closeWarmupBrowser(profilePath: openedProfilePath, logURL: logURL)
            throw error
        }
        try writeInstallWarmupMarker(username: username)
        appendInstallLog("✓ 浏览器账号已预热并关闭\n", logURL: logURL)
    }

    static func open(
        username: String,
        requireBridge: Bool = false,
        enableCDPCapture: Bool = false
    ) throws -> BrowserAccountSession {
        // 每次 open 前先做一次脚本自愈，防止历史用户继续执行旧 wrapper 逻辑。
        try ensureBrowserToolCurrent(username: username)
        let context = try resolveContext(username: username)
        guard isChromeInstalled() else {
            throw BrowserAccountError.chromeNotFound
        }

        try prepareProfileDirectory(context.paths.profileDirectory.path, consoleUsername: context.consoleUsername)
        _ = try ensureOpenCLIBrowserBridgeExtensionInstalled(context: context, logURL: nil)
        try ensurePrivilegedBrowserLauncherInstalled(username: username)
        if let existingSession = readSession(username: username),
           !browserProcessIDs(profilePath: existingSession.profilePath).isEmpty {
            if !requireBridge {
                return existingSession
            }
            try closeWarmupBrowser(profilePath: existingSession.profilePath, logURL: nil)
        }
        let launchMode: String
        // 仅安装预热阶段允许带 CDP 参数启动；日常 runtime/bridge 都保持无 CDP 参数，避免登录风控问题。
        if enableCDPCapture {
            launchMode = "install-cdp"
        } else if requireBridge {
            launchMode = "bridge"
        } else {
            launchMode = "runtime"
        }
        try spawnPipeBrowserLauncher(
            context: context,
            target: "about:blank",
            hidden: false,
            mode: launchMode
        )
        let startupDeadline = Date().addingTimeInterval(5)
        while Date() < startupDeadline {
            if !browserProcessIDs(profilePath: context.paths.profileDirectory.path).isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !browserProcessIDs(profilePath: context.paths.profileDirectory.path).isEmpty else {
            throw BrowserAccountError.commandFailed("Chrome 已尝试启动，但进程未就绪。请确认当前 macOS 图形会话可用。")
        }

        let session = BrowserAccountSession(
            username: username,
            profilePath: context.paths.profileDirectory.path,
            devToolsActivePortPath: context.paths.devToolsActivePortFile.path,
            httpEndpoint: "",
            webSocketDebuggerURL: "",
            cdpPort: openCLIDefaultCDPCapturePort,
            launchedAt: Date().timeIntervalSince1970,
            consoleUsername: context.consoleUsername
        )
        try writeSession(session, username: username)
        return session
    }

    private static func isChromeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: chromeAppPath)
    }

    static func openURL(username: String, url: String) throws {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw BrowserAccountError.commandFailed("只支持 http(s) 授权链接")
        }

        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        if !FileManager.default.isExecutableFile(atPath: toolPath) {
            _ = try installTool(username: username)
        }

        let currentStatus = status(username: username)
        if !currentStatus.browserReachable {
            _ = try open(username: username, requireBridge: false)
        }

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { "\($0.0)=\($0.1)" }
        try run(
            "/usr/bin/sudo",
            args: ["-n", "-u", username, "-H", "/usr/bin/env"] + envArgs + [toolPath, "open", url]
        )
    }

    static func status(username: String) -> BrowserAccountStatus {
        guard let context = try? resolveContext(username: username) else {
            return BrowserAccountStatus(
                username: username,
                profilePath: "",
                sessionPath: "/Users/\(username)/\(BrowserAccountPaths.sessionRelativePath)",
                toolPath: "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)",
                toolInstalled: false,
                sessionExists: false,
                browserReachable: false,
                httpEndpoint: nil,
                openCLIBrowserBridgeInstalled: nil,
                openCLIBrowserBridgeInstalledVersion: nil,
                openCLIBrowserBridgeLatestVersion: nil,
                openCLIBrowserBridgeUpdateAvailable: nil,
                openCLIProfile: readOpenCLIProfile(username: username),
                message: "用户不存在或用户名无效"
            )
        }

        let sessionPath = sessionPath(username: username)
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        let session = readSession(username: username)
        let reachable = session.map { !browserProcessIDs(profilePath: $0.profilePath).isEmpty } ?? false
        let bridgeMeta = openCLIBrowserBridgeMeta(context: context)
        let message: String
        if reachable {
            message = "浏览器账号运行中"
        } else if session != nil {
            message = "已记录浏览器账号，但当前 Chrome 不可连接"
        } else {
            message = "尚未打开浏览器账号"
        }
        return BrowserAccountStatus(
            username: username,
            profilePath: session?.profilePath ?? context.paths.profileDirectory.path,
            sessionPath: sessionPath,
            toolPath: toolPath,
            toolInstalled: FileManager.default.isExecutableFile(atPath: toolPath),
            sessionExists: sessionFileExists(username: username),
            browserReachable: reachable,
            httpEndpoint: session?.httpEndpoint,
            openCLIBrowserBridgeInstalled: bridgeMeta.installed,
            openCLIBrowserBridgeInstalledVersion: bridgeMeta.installedVersion,
            openCLIBrowserBridgeLatestVersion: bridgeMeta.latestVersion,
            openCLIBrowserBridgeUpdateAvailable: bridgeMeta.updateAvailable,
            openCLIProfile: readOpenCLIProfile(username: username),
            message: message
        )
    }

    static func reachableCDPEndpoint(username: String) -> String? {
        nil
    }

    static func reset(username: String) throws -> BrowserAccountStatus {
        let context = try resolveContext(username: username)
        let fm = FileManager.default
        try backupAndRemoveProfileIfNeeded(context.paths.profileDirectory.path, fileManager: fm)
        try backupAndRemoveProfileIfNeeded("/Users/\(username)/\(BrowserAccountPaths.toolBrowserProfileRelativePath)", fileManager: fm)
        try backupAndRemoveProfileIfNeeded("/Users/\(username)/\(BrowserAccountPaths.legacyToolBrowserProfileRelativePath)", fileManager: fm)
        for session in sessionPaths(username: username) where fm.fileExists(atPath: session) {
            try fm.removeItem(atPath: session)
        }
        let openCLIProfile = openCLIProfilePath(username: username)
        if fm.fileExists(atPath: openCLIProfile) {
            try fm.removeItem(atPath: openCLIProfile)
        }
        HermesConfigWriter.syncBrowserCDPEndpoint(username: username, endpoint: nil)
        let marker = installWarmupMarkerPath(username: username)
        if fm.fileExists(atPath: marker) {
            try fm.removeItem(atPath: marker)
        }
        try ensureBrowserShellEnvironment(
            username: username,
            toolPath: "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        )
        return status(username: username)
    }

    private static func backupAndRemoveProfileIfNeeded(_ profile: String, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: profile) {
            let stamp = timestamp()
            let backup = "\(profile).backup-\(stamp)"
            try fm.moveItem(atPath: profile, toPath: backup)
        }
    }

    static func installTool(username: String, logURL: URL? = nil) throws -> BrowserAccountStatus {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        let toolDir = "/Users/\(username)/\(BrowserAccountPaths.toolDirectoryRelativePath)"
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        let binDirs = browserBinDirectories(username: username)

        try FileManager.default.createDirectory(atPath: toolDir, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive("/Users/\(username)/.clawdhome", owner: username)
        try browserToolScript.write(toFile: toolPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chownRecursive(toolDir, owner: username)
        try FilePermissionHelper.chmod(toolPath, mode: "755")
        try installPrivilegedBrowserLauncher(username: username, toolDir: toolDir)
        if isChromeInstalled() {
            let context = try resolveContext(username: username)
            _ = try ensureOpenCLIBrowserBridgeExtensionInstalled(context: context, logURL: nil)
        }
        try ensureDefaultOpenCLIInstalled(username: username, logURL: logURL)

        for binDir in binDirs {
            try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try FilePermissionHelper.chownRecursive((binDir as NSString).deletingLastPathComponent, owner: username)
            try installBrowserShim(username: username, binDir: binDir, toolPath: toolPath)
            try installBrowserCommandWrappers(username: username, binDir: binDir, toolPath: toolPath)
            try installNPMWrapperIfPossible(username: username, binDir: binDir, toolPath: toolPath)
            try installOpenCLIWrapperIfPresent(
                username: username,
                binDir: binDir,
                executableName: "opencli",
                realExecutableName: BrowserAccountPaths.openCLIRealExecutableName,
                toolPath: toolPath
            )
            try installOpenURLCLIWrapper(
                username: username,
                binDir: binDir,
                executableName: BrowserAccountPaths.openCLINPMExecutableName,
                toolPath: toolPath
            )
        }
        try installOpenCLIPathShadowWrapperIfPresent(username: username, binDirs: binDirs, toolPath: toolPath)
        try ensureBrowserShellEnvironment(username: username, toolPath: toolPath)

        try appendToolsGuidanceIfNeeded(username: username)
        return status(username: username)
    }

    static func installOpenCLI(username: String, logURL: URL? = nil) throws {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        let npmPath = try InstallManager.findNpmBinary(for: username)
        let prefix = InstallManager.npmGlobalDir(for: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { "\($0.0)=\($0.1)" }
        let args = ["-n", "-u", username, "-H", "/usr/bin/env"]
            + envArgs
            + [npmPath, "install", "-g", "--prefix", prefix, "@jackwener/opencli@latest"]
        if let logURL {
            _ = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
        } else {
            _ = try run("/usr/bin/sudo", args: args)
        }
        _ = try installTool(username: username)
    }

    static func openCLIVersion(username: String) -> String? {
        guard BrowserAccountPaths.isValidUsername(username) else { return nil }
        guard let target = resolveOpenCLIExecutable(username: username) else { return nil }
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { "\($0.0)=\($0.1)" }
        let args = ["-n", "-u", username, "-H", "/usr/bin/env"] + envArgs + [target, "--version"]
        let out = try? run("/usr/bin/sudo", args: args)
        let version = out?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init)
        return version?.isEmpty == false ? version : nil
    }

    static func runOpenCLIDoctor(username: String) throws -> String {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        guard let target = resolveOpenCLIExecutable(username: username) else {
            throw BrowserAccountError.commandFailed("OpenCLI 未安装")
        }
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { "\($0.0)=\($0.1)" }
        let args = ["-n", "-u", username, "-H", "/usr/bin/env"] + envArgs + [target, "doctor"]
        return try run("/usr/bin/sudo", args: args)
    }

    private static func resolveOpenCLIExecutable(username: String) -> String? {
        let npmGlobalBin = InstallManager.npmGlobalBin(for: username)
        let candidates = [
            "\(npmGlobalBin)/\(BrowserAccountPaths.openCLIRealExecutableName)",
            "\(npmGlobalBin)/opencli",
            "/Users/\(username)/\(BrowserAccountPaths.userLocalBinRelativePath)/opencli",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract.orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .map { "\($0.0)=\($0.1)" }
        let lookupArgs = ["-n", "-u", username, "-H", "/usr/bin/env"] + envArgs + ["/bin/zsh", "-lc", "command -v opencli"]
        guard let output = try? run("/usr/bin/sudo", args: lookupArgs) else { return nil }
        let resolved = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .first
            .map(String.init)
        guard let resolved, !resolved.isEmpty, FileManager.default.isExecutableFile(atPath: resolved) else {
            return nil
        }
        return resolved
    }

    private static func browserBinDirectories(username: String) -> [String] {
        [
            "/Users/\(username)/\(BrowserAccountPaths.userLocalBinRelativePath)",
            npmGlobalBinDirectory(username: username),
        ]
    }

    private static func npmGlobalBinDirectory(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.npmGlobalBinRelativePath)"
    }

    private static func npmGlobalDirectory(username: String) -> String {
        "/Users/\(username)/.npm-global"
    }

    private static func openCLIProfilePath(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.openCLIProfileRelativePath)"
    }

    private static func ensureBrowserToolCurrent(username: String) throws {
        // 旧版本 wrapper 会导致 profile 选择错误；检测到旧标记时立即重装工具并覆盖脚本。
        guard needsBrowserToolRefresh(username: username) else { return }
        _ = try installTool(username: username)
    }

    private static func needsBrowserToolRefresh(username: String) -> Bool {
        let fm = FileManager.default
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        if !fm.isExecutableFile(atPath: toolPath) { return true }
        // 用功能标记判断脚本代际，避免依赖版本号管理历史遗留用户。
        if !fileContainsMarker(path: toolPath, marker: "opencli-profile-known-sync")
            || !fileContainsMarker(path: toolPath, marker: "profile_runtime_active")
            || !fileContainsMarker(path: toolPath, marker: "profile-strict-open-v4") {
            return true
        }

        for wrapper in openCLIWrapperCandidates(username: username) where fm.fileExists(atPath: wrapper) {
            if !fileContainsMarker(path: wrapper, marker: "opencli-profile-known-sync") {
                return true
            }
        }
        // wrapper 不存在通常代表用户尚未安装 opencli，此时不需要因 wrapper 缺失触发刷新。
        return false
    }

    private static func openCLIWrapperCandidates(username: String) -> [String] {
        [
            "/Users/\(username)/.local/bin/opencli",
            "\(npmGlobalBinDirectory(username: username))/opencli",
        ]
    }

    private static func fileContainsMarker(path: String, marker: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return text.contains(marker)
    }

    static func readOpenCLIProfile(username: String) -> String? {
        let path = openCLIProfilePath(username: username)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? String else {
            return nil
        }
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidOpenCLIProfile(trimmed) ? trimmed : nil
    }

    private static func writeOpenCLIProfile(
        _ profile: String,
        username: String,
        source: String = "opencli profile list"
    ) throws {
        guard isValidOpenCLIProfile(profile) else {
            throw BrowserAccountError.commandFailed("OpenCLI profile id 无效：\(profile)")
        }
        let path = openCLIProfilePath(username: username)
        let payload: [String: Any] = [
            "profile": profile,
            "capturedAt": Date().timeIntervalSince1970,
            "source": source,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "600")
        try ensureBrowserShellEnvironment(
            username: username,
            toolPath: "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        )
    }

    @discardableResult
    private static func captureAndPersistOpenCLIProfile(
        username: String,
        profilePath: String,
        logURL: URL?
    ) throws -> String {
        let preferredOpenCLI = "/Users/\(username)/\(BrowserAccountPaths.userLocalBinRelativePath)/opencli"
        let fallbackOpenCLI = "\(npmGlobalBinDirectory(username: username))/opencli"
        let openCLIPath = FileManager.default.isExecutableFile(atPath: preferredOpenCLI)
            ? preferredOpenCLI
            : fallbackOpenCLI
        guard FileManager.default.isExecutableFile(atPath: openCLIPath) else {
            throw BrowserAccountError.commandFailed("OpenCLI 未安装，无法获取 Browser Bridge profile")
        }

        appendInstallLog("→ 获取 OpenCLI Browser Bridge profile\n", logURL: logURL)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract
            .orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .filter { $0.0 != "OPENCLI_PROFILE" }
            .map { "\($0.0)=\($0.1)" }
        let args = ["-n", "-u", username, "-H", "/usr/bin/env"]
            + envArgs
            + [openCLIPath, "profile", "list"]
        do {
            let output: String
            if let logURL {
                output = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
            } else {
                output = try run("/usr/bin/sudo", args: args)
            }
            if let profile = parseOpenCLIProfileList(output) {
                try writeOpenCLIProfile(profile, username: username)
                return profile
            }
            appendInstallLog("⚠ opencli profile list 未解析到 connected profile，尝试读取 OpenCLI daemon 状态与插件本地存储\n", logURL: logURL)
        } catch {
            appendInstallLog("⚠ opencli profile list 执行失败，尝试读取 OpenCLI daemon 状态与插件本地存储：\(error.localizedDescription)\n", logURL: logURL)
        }

        // 顺序设计：
        // 1) 先用 daemon status（成本最低、兼容最好）；
        // 2) 再尝试 CDP 直读扩展 storage（仅安装阶段临时开启）；
        // 3) 最后回退到本地 extension 存储文件扫描。
        if let profile = readOpenCLIProfileFromDaemonStatus(username: username) {
            appendInstallLog("✓ 已从 OpenCLI daemon status 捕获 profile：\(profile)\n", logURL: logURL)
            try writeOpenCLIProfile(profile, username: username, source: "opencli daemon status")
            return profile
        }

        if let profile = readOpenCLIProfileFromCDP(port: openCLIDefaultCDPCapturePort) {
            appendInstallLog("✓ 已通过 CDP 读取 OpenCLI 扩展 profile：\(profile)\n", logURL: logURL)
            try writeOpenCLIProfile(profile, username: username, source: "chrome extension cdp")
            return profile
        }

        guard let profile = readOpenCLIProfileFromExtensionStorage(profilePath: profilePath) else {
            throw BrowserAccountError.commandFailed("未能获取 OpenCLI Browser Bridge profile")
        }
        try writeOpenCLIProfile(profile, username: username, source: "chrome extension storage")
        return profile
    }

    private static func readOpenCLIProfileFromDaemonStatus(username: String) -> String? {
        let daemonPort = openCLIDaemonPort(username: username)
        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract
            .orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .filter { $0.0 != "OPENCLI_PROFILE" }
            .map { "\($0.0)=\($0.1)" }
        let args = ["-n", "-u", username, "-H", "/usr/bin/env"]
            + envArgs
            + ["/usr/bin/curl", "-fsS", "-H", "X-OpenCLI: 1", "http://127.0.0.1:\(daemonPort)/status"]
        guard let output = try? run("/usr/bin/sudo", args: args),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]] else {
            return nil
        }
        let connectedProfiles = profiles.compactMap { item -> String? in
            guard (item["extensionConnected"] as? Bool) == true else { return nil }
            guard let contextId = (item["contextId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  isValidOpenCLIProfile(contextId) else {
                return nil
            }
            return contextId
        }
        if connectedProfiles.count == 1 {
            return connectedProfiles[0]
        }
        return nil
    }

    private static func readOpenCLIProfileFromCDP(port: Int) -> String? {
        // MV3 service worker 可能尚未激活，短轮询一段时间等待 target 出现。
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let targets = openCLIBridgeCDPTargetWebSocketURLs(port: port)
            for target in targets {
                if let profile = evaluateOpenCLIProfileOnCDPTarget(webSocketDebuggerURL: target) {
                    return profile
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    private static func openCLIBridgeCDPTargetWebSocketURLs(port: Int) -> [String] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list"),
              let payload = readJSONObject(url: url, timeout: 1.2) as? [[String: Any]] else {
            return []
        }
        let prefix = "chrome-extension://\(openCLIBrowserBridgeExtensionID)/"
        return payload
            .compactMap { item -> (Int, String)? in
                guard let targetURL = item["url"] as? String,
                      targetURL.hasPrefix(prefix),
                      let ws = item["webSocketDebuggerUrl"] as? String,
                      !ws.isEmpty else {
                    return nil
                }
                let type = (item["type"] as? String ?? "").lowercased()
                // service worker 通常最接近扩展后台状态，优先尝试。
                let score = type == "service_worker" ? 0 : 1
                return (score, ws)
            }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1 < rhs.1
                }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    private static func evaluateOpenCLIProfileOnCDPTarget(webSocketDebuggerURL: String) -> String? {
        guard let url = URL(string: webSocketDebuggerURL) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        guard sendCDPCommand(task: task, id: 1, method: "Runtime.enable", params: [:]) else {
            return nil
        }
        // 必须在扩展上下文读取 chrome.storage.local；普通网页 target 无权限访问。
        let expression = """
        (async () => {
          const key = "opencli_context_id_v1";
          if (!globalThis.chrome || !chrome.storage || !chrome.storage.local) return null;
          const raw = await chrome.storage.local.get(key);
          const value = raw && typeof raw[key] === "string" ? raw[key].trim() : "";
          return value || null;
        })()
        """
        guard sendCDPCommand(
            task: task,
            id: 2,
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "awaitPromise": true,
                "returnByValue": true,
            ]
        ) else {
            return nil
        }

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            guard let message = receiveCDPMessage(task: task, timeout: 0.6) else {
                continue
            }
            let raw: String
            switch message {
            case .string(let text):
                raw = text
            case .data(let data):
                raw = String(decoding: data, as: UTF8.self)
            @unknown default:
                continue
            }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseID = object["id"] as? Int,
                  responseID == 2,
                  let result = object["result"] as? [String: Any],
                  let runtimeResult = result["result"] as? [String: Any],
                  let value = runtimeResult["value"] as? String else {
                continue
            }
            let profile = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidOpenCLIProfile(profile) {
                return profile
            }
            return nil
        }
        return nil
    }

    private static func sendCDPCommand(
        task: URLSessionWebSocketTask,
        id: Int,
        method: String,
        params: [String: Any]
    ) -> Bool {
        let payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        task.send(.string(text)) { error in
            succeeded = (error == nil)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return succeeded
    }

    private static func receiveCDPMessage(
        task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) -> URLSessionWebSocketTask.Message? {
        let semaphore = DispatchSemaphore(value: 0)
        var message: URLSessionWebSocketTask.Message?
        task.receive { result in
            if case .success(let value) = result {
                message = value
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return message
    }

    private static func readJSONObject(url: URL, timeout: TimeInterval) -> Any? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        let task = session.dataTask(with: url) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        guard responseError == nil, let responseData else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: responseData)
    }

    private static func readOpenCLIProfileFromExtensionStorage(profilePath: String) -> String? {
        let storageRoot = URL(fileURLWithPath: profilePath)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Local Extension Settings", isDirectory: true)
        let fm = FileManager.default
        guard let extensionDirs = try? fm.contentsOfDirectory(
            at: storageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for dir in extensionDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for file in files {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let data = try? Data(contentsOf: file),
                      let profile = parseOpenCLIProfileFromStorageData(data) else {
                    continue
                }
                return profile
            }
        }
        return nil
    }

    private static func parseOpenCLIProfileFromStorageData(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = [
            #""contextId"\s*:\s*"([A-Za-z0-9_-]{4,64})""#,
            #"opencli_context_id_v1[\s\S]{0,128}"([A-Za-z0-9_-]{4,64})""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = String(text[valueRange])
            if isValidOpenCLIProfile(value) {
                return value
            }
        }
        return nil
    }

    private static func parseOpenCLIProfileList(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().contains("connected") else { continue }
            guard !line.lowercased().hasPrefix("connected browser bridge profiles") else { continue }
            let firstToken = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if isValidOpenCLIProfile(firstToken) {
                return firstToken
            }
        }
        return nil
    }

    private static func isValidOpenCLIProfile(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.lowercased() != "connected" else { return false }
        return value.count >= 4
            && value.count <= 64
            && value.rangeOfCharacter(from: allowed.inverted) == nil
    }

    private static func ensureDefaultOpenCLIInstalled(username: String, logURL: URL?) throws {
        let prefix = npmGlobalDirectory(username: username)
        let binDir = npmGlobalBinDirectory(username: username)
        let daemonPath = "\(prefix)/lib/node_modules/@jackwener/opencli/dist/src/daemon.js"
        let realPath = "\(binDir)/\(BrowserAccountPaths.openCLIRealExecutableName)"
        let wrappedPath = "\(binDir)/opencli"
        let fm = FileManager.default

        if fm.fileExists(atPath: daemonPath),
           fm.fileExists(atPath: realPath) || fm.fileExists(atPath: wrappedPath) {
            appendInstallLog("✓ OpenCLI 已安装，跳过 npm 安装\n", logURL: logURL)
            return
        }

        let npmPath: String
        do {
            npmPath = try InstallManager.findNpmBinary(for: username)
        } catch {
            appendInstallLog("⚠ 未找到 npm，已跳过 OpenCLI 默认安装；Node 初始化后会再次修复\n", logURL: logURL)
            return
        }

        appendInstallLog("→ 默认安装 OpenCLI：@jackwener/opencli\n", logURL: logURL)
        try InstallManager.ensureNpmBuildToolchainReady()
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: UserEnvContract.npmSharedCacheDir(), withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive(prefix, owner: username)
        try? FilePermissionHelper.chmod("/var/lib/clawdhome/cache", mode: "1777")
        try? FilePermissionHelper.chmod(UserEnvContract.npmSharedCacheDir(), mode: "1777")

        let nodePath = ConfigWriter.buildNodePath(username: username)
        let envArgs = UserEnvContract
            .orderedRuntimeEnvironment(username: username, nodePath: nodePath)
            .filter { $0.0 != "OPENCLI_PROFILE" }
            .map { "\($0.0)=\($0.1)" }
        let args = ["-u", username, "-H", "env"]
            + envArgs
            + [
                npmPath, "install", "-g", "--prefix", prefix,
                "--cache", UserEnvContract.npmSharedCacheDir(),
                "--loglevel", "warn",
                "@jackwener/opencli",
            ]
        if let logURL {
            _ = try runLogging("/usr/bin/sudo", args: args, logURL: logURL)
        } else {
            _ = try run("/usr/bin/sudo", args: args)
        }
        try FilePermissionHelper.chownRecursive(prefix, owner: username)
        appendInstallLog("✓ OpenCLI 默认安装完成\n", logURL: logURL)
    }

    private static func ensureBrowserShellEnvironment(username: String, toolPath: String) throws {
        let browserCommand = "\(toolPath) open %s"
        let profileExport: String
        if let profile = readOpenCLIProfile(username: username) {
            profileExport = "\nexport OPENCLI_PROFILE=\"\(profile)\""
        } else {
            profileExport = ""
        }
        let block = """

        # ClawdHome browser account
        export PATH="$HOME/.local/bin:$PATH"
        export BROWSER="\(browserCommand)"\(profileExport)
        # End ClawdHome browser account
        """
        for path in ["/Users/\(username)/.zprofile", "/Users/\(username)/.zshrc"] {
            var existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if let start = existing.range(of: "# ClawdHome browser account"),
               let end = existing.range(of: "# End ClawdHome browser account", range: start.lowerBound..<existing.endIndex) {
                existing.replaceSubrange(start.lowerBound..<end.upperBound, with: block.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing += "\n"
                }
                existing += block + "\n"
            }
            try Data(existing.utf8).write(to: URL(fileURLWithPath: path))
            try FilePermissionHelper.chown(path, owner: username)
            try FilePermissionHelper.chmod(path, mode: "644")
        }
    }

    private static func installBrowserShim(username: String, binDir: String, toolPath: String) throws {
        let binPath = "\(binDir)/clawdhome-browser"
        let wrapper = """
        #!/bin/zsh
        LOG="$HOME/\(BrowserAccountPaths.debugLogRelativePath)"
        mkdir -p "$HOME/\(BrowserAccountPaths.browserDirectoryRelativePath)"
        {
          echo "--- $(/bin/date '+%Y-%m-%d %H:%M:%S') clawdhome-browser shim"
          echo "argv=$*"
          echo "pwd=$PWD"
          echo "PATH=$PATH"
          echo "which-open=$(command -v open 2>/dev/null || true)"
          echo "which-clawdhome-browser=$(command -v clawdhome-browser 2>/dev/null || true)"
        } >> "$LOG" 2>&1 || true
        exec /usr/bin/env python3 "\(toolPath)" "$@"
        """
        try wrapper.write(toFile: binPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(binPath, owner: username)
        try FilePermissionHelper.chmod(binPath, mode: "755")
    }

    private static func installPrivilegedBrowserLauncher(username: String, toolDir: String) throws {
        let sourcePath = "\(toolDir)/clawdhome-browser-launcher.c"
        let launcherDirectory = "/Library/Application Support/ClawdHome/BrowserLaunchers/\(username)"
        let launcherPath = "\(launcherDirectory)/clawdhome-browser-launcher"
        let pipeLauncherPath = "\(launcherDirectory)/clawdhome-browser-pipe-launcher"
        try browserLauncherSource.write(toFile: sourcePath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(sourcePath, owner: username)
        try FilePermissionHelper.chmod(sourcePath, mode: "600")
        try FileManager.default.createDirectory(
            atPath: launcherDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FilePermissionHelper.chown(launcherDirectory, owner: "root", group: "wheel")
        try FilePermissionHelper.chmod(launcherDirectory, mode: "755")
        try browserPipeLauncherScript.write(toFile: pipeLauncherPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(pipeLauncherPath, owner: "root", group: "wheel")
        try? FilePermissionHelper.clearACL(pipeLauncherPath)
        try FilePermissionHelper.chmod(pipeLauncherPath, mode: "755")
        try run("/usr/bin/clang", args: [sourcePath, "-o", launcherPath])
        try FilePermissionHelper.chown(launcherPath, owner: "root", group: "wheel")
        try? FilePermissionHelper.clearACL(launcherPath)
        try FilePermissionHelper.chmod(launcherPath, mode: "4755")
        try verifyPrivilegedBrowserLauncher(launcherPath)
    }

    private static func ensurePrivilegedBrowserLauncherInstalled(username: String) throws {
        let toolDir = "/Users/\(username)/\(BrowserAccountPaths.toolDirectoryRelativePath)"
        let launcherPath = "/Library/Application Support/ClawdHome/BrowserLaunchers/\(username)/clawdhome-browser-launcher"
        let pipeLauncherPath = "/Library/Application Support/ClawdHome/BrowserLaunchers/\(username)/clawdhome-browser-pipe-launcher"
        if FileManager.default.isExecutableFile(atPath: launcherPath),
           FileManager.default.isExecutableFile(atPath: pipeLauncherPath) {
            return
        }
        try FileManager.default.createDirectory(atPath: toolDir, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive("/Users/\(username)/.clawdhome", owner: username)
        try installPrivilegedBrowserLauncher(username: username, toolDir: toolDir)
    }

    private static func verifyPrivilegedBrowserLauncher(_ launcherPath: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: launcherPath)
        let owner = attrs[.ownerAccountName] as? String
        let group = attrs[.groupOwnerAccountName] as? String
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        guard owner == "root", group == "wheel", (mode & 0o4000) != 0, (mode & 0o755) == 0o755 else {
            throw BrowserAccountError.commandFailed(
                "clawdhome-browser-launcher 权限异常：\(launcherPath) owner=\(owner ?? "?") group=\(group ?? "?") mode=\(String(mode, radix: 8))"
            )
        }
    }

    private static func installBrowserCommandWrappers(username: String, binDir: String, toolPath: String) throws {
        for name in BrowserAccountPaths.browserCommandWrapperNames {
            let path = "\(binDir)/\(name)"
            let wrapper = browserCommandWrapperScript(commandName: name, toolPath: toolPath)
            try wrapper.write(toFile: path, atomically: true, encoding: .utf8)
            try FilePermissionHelper.chown(path, owner: username)
            try FilePermissionHelper.chmod(path, mode: "755")
        }
    }

    private static func browserCommandWrapperScript(commandName: String, toolPath: String) -> String {
        let systemOpenFallback = commandName == "open" ? """
        exec /usr/bin/open "$@"
        """ : """
        echo "\(commandName): ClawdHome 已接管浏览器打开操作；请传入 http(s) URL。" >&2
        exit 1
        """
        return """
        #!/bin/zsh
        set -e
        LOG="$HOME/\(BrowserAccountPaths.debugLogRelativePath)"
        mkdir -p "$HOME/\(BrowserAccountPaths.browserDirectoryRelativePath)"
        {
          echo "--- $(/bin/date '+%Y-%m-%d %H:%M:%S') browser-command \(commandName)"
          echo "argv=$*"
          echo "pwd=$PWD"
          echo "PATH=$PATH"
          echo "which-open=$(command -v open 2>/dev/null || true)"
          echo "which-clawdhome-browser=$(command -v clawdhome-browser 2>/dev/null || true)"
        } >> "$LOG" 2>&1 || true

        for arg in "$@"; do
          case "$arg" in
            http://*|https://*)
              echo "route=clawdhome-browser-open url=$arg" >> "$LOG" 2>&1 || true
              exec /usr/bin/env python3 "\(toolPath)" open "$arg"
              ;;
          esac
        done

        if [ "$#" -eq 0 ]; then
          echo "route=clawdhome-browser-open-default url=https://clawdhome.ai" >> "$LOG" 2>&1 || true
          exec /usr/bin/env python3 "\(toolPath)" open "https://clawdhome.ai"
        fi

        echo "route=system-fallback command=\(commandName) argv=$*" >> "$LOG" 2>&1 || true
        \(systemOpenFallback)
        """
    }

    private static func installNPMWrapperIfPossible(username: String, binDir: String, toolPath: String) throws {
        guard binDir == "/Users/\(username)/\(BrowserAccountPaths.userLocalBinRelativePath)" else {
            return
        }
        let wrapperPath = "\(binDir)/npm"
        let fm = FileManager.default
        let realCandidates = [
            "/Users/\(username)/.brew/bin/npm",
            "/Users/\(username)/.brew/lib/nodejs/node-v24.9.0-darwin-arm64/bin/npm",
            "/Users/\(username)/.brew/lib/nodejs/node-v22.18.0-darwin-arm64/bin/npm",
            "/Users/\(username)/.brew/lib/nodejs/node-v20.19.0-darwin-arm64/bin/npm",
            "/Users/\(username)/.brew/lib/nodejs/node-v18.20.8-darwin-arm64/bin/npm",
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
        ]
        guard let realNPM = realCandidates.first(where: { candidate in
            candidate != wrapperPath && fm.isExecutableFile(atPath: candidate)
        }) else {
            return
        }

        let wrapper = npmWrapperScript(toolPath: toolPath, realNPM: realNPM)
        try wrapper.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(wrapperPath, owner: username)
        try FilePermissionHelper.chmod(wrapperPath, mode: "755")
    }

    private static func npmWrapperScript(toolPath: String, realNPM: String) -> String {
        """
        #!/bin/zsh
        # CLAWDHOME_NPM_WRAPPER
        LOG="$HOME/\(BrowserAccountPaths.debugLogRelativePath)"
        mkdir -p "$HOME/\(BrowserAccountPaths.browserDirectoryRelativePath)"

        saw_install=0
        saw_global=0
        saw_opencli=0
        for arg in "$@"; do
          case "$arg" in
            install|i|add)
              saw_install=1
              ;;
            -g|--global)
              saw_global=1
              ;;
            @jackwener/opencli|@jackwener/opencli@*|opencli|opencli@*)
              saw_opencli=1
              ;;
          esac
        done

        "\(realNPM)" "$@"
        npm_status=$?

        if [ "$npm_status" -eq 0 ] && [ "$saw_install" -eq 1 ] && [ "$saw_global" -eq 1 ] && [ "$saw_opencli" -eq 1 ]; then
          {
            echo "--- $(/bin/date '+%Y-%m-%d %H:%M:%S') npm-wrapper repair-opencli"
            echo "argv=$*"
            echo "real-npm=\(realNPM)"
          } >> "$LOG" 2>&1 || true
          /usr/bin/env python3 "\(toolPath)" repair-opencli >> "$LOG" 2>&1 || true
          hash -r 2>/dev/null || true
        fi

        exit "$npm_status"
        """
    }

    private static func installOpenCLIWrapperIfPresent(
        username: String,
        binDir: String,
        executableName: String,
        realExecutableName: String,
        toolPath: String
    ) throws {
        let opencliPath = "\(binDir)/\(executableName)"
        let realPath = "\(binDir)/\(realExecutableName)"
        let fm = FileManager.default
        guard fm.fileExists(atPath: opencliPath) || fm.fileExists(atPath: realPath) else {
            return
        }

        let existing = (try? String(contentsOfFile: opencliPath, encoding: .utf8)) ?? ""
        if !existing.contains("CLAWDHOME_OPENCLI_WRAPPER"), fm.fileExists(atPath: opencliPath) {
            if fm.fileExists(atPath: realPath) {
                let backupPath = "\(opencliPath).backup-\(timestamp())"
                try fm.moveItem(atPath: opencliPath, toPath: backupPath)
                try FilePermissionHelper.chown(backupPath, owner: username)
            } else {
                try fm.moveItem(atPath: opencliPath, toPath: realPath)
                try FilePermissionHelper.chown(realPath, owner: username)
                try FilePermissionHelper.chmod(realPath, mode: "755")
            }
        }

        let daemonPath = "\(binDir)/../lib/node_modules/@jackwener/opencli/dist/src/daemon.js"
        let wrapper = openCLIWrapperScript(
            username: username,
            toolPath: toolPath,
            realPath: realPath,
            daemonPath: daemonPath
        )
        try wrapper.write(toFile: opencliPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(opencliPath, owner: username)
        try FilePermissionHelper.chmod(opencliPath, mode: "755")
    }

    private static func installOpenCLIPathShadowWrapperIfPresent(
        username: String,
        binDirs: [String],
        toolPath: String
    ) throws {
        guard let preferredBinDir = binDirs.first else { return }
        let wrapperPath = "\(preferredBinDir)/opencli"
        let realExecutableName = BrowserAccountPaths.openCLIRealExecutableName
        let fm = FileManager.default

        let realCandidates = binDirs.flatMap { binDir -> [String] in
            [
                "\(binDir)/\(realExecutableName)",
                "\(binDir)/opencli",
            ]
        }
        guard let realPath = realCandidates.first(where: { path in
            guard path != wrapperPath, fm.fileExists(atPath: path) else { return false }
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return !existing.contains("CLAWDHOME_OPENCLI_WRAPPER")
        }) else {
            return
        }

        try fm.createDirectory(atPath: preferredBinDir, withIntermediateDirectories: true)
        let existingWrapper = (try? String(contentsOfFile: wrapperPath, encoding: .utf8)) ?? ""
        if fm.fileExists(atPath: wrapperPath), !existingWrapper.contains("CLAWDHOME_OPENCLI_WRAPPER") {
            let backupPath = "\(wrapperPath).backup-\(timestamp())"
            try fm.moveItem(atPath: wrapperPath, toPath: backupPath)
            try FilePermissionHelper.chown(backupPath, owner: username)
        }

        let realBinDir = (realPath as NSString).deletingLastPathComponent
        let daemonPath = "\(realBinDir)/../lib/node_modules/@jackwener/opencli/dist/src/daemon.js"
        let wrapper = openCLIWrapperScript(
            username: username,
            toolPath: toolPath,
            realPath: realPath,
            daemonPath: daemonPath
        )
        try wrapper.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(wrapperPath, owner: username)
        try FilePermissionHelper.chmod(wrapperPath, mode: "755")
    }

    private static func installOpenURLCLIWrapper(
        username: String,
        binDir: String,
        executableName: String,
        toolPath: String
    ) throws {
        let wrapperPath = "\(binDir)/\(executableName)"
        let wrapper = openURLCLIWrapperScript(commandName: executableName, toolPath: toolPath)
        try wrapper.write(toFile: wrapperPath, atomically: true, encoding: .utf8)
        try FilePermissionHelper.chown(wrapperPath, owner: username)
        try FilePermissionHelper.chmod(wrapperPath, mode: "755")
    }

    private static func openCLIWrapperScript(username: String, toolPath: String, realPath: String, daemonPath: String) -> String {
        let daemonPort = openCLIDaemonPort(username: username)
        return """
        #!/bin/zsh
        # CLAWDHOME_OPENCLI_WRAPPER
        set -e
        LOG="$HOME/\(BrowserAccountPaths.debugLogRelativePath)"
        mkdir -p "$HOME/\(BrowserAccountPaths.browserDirectoryRelativePath)"
        {
          echo "--- $(/bin/date '+%Y-%m-%d %H:%M:%S') opencli-wrapper"
          echo "argv=$*"
          echo "pwd=$PWD"
          echo "PATH=$PATH"
          echo "which-open=$(command -v open 2>/dev/null || true)"
          echo "which-opencli-real=\(realPath)"
        } >> "$LOG" 2>&1 || true

        port="${OPENCLI_DAEMON_PORT:-\(daemonPort)}"
        export OPENCLI_DAEMON_PORT="$port"
        profile_file="$HOME/\(BrowserAccountPaths.openCLIProfileRelativePath)"
        # 优先读取本地缓存 profile，减少每次启动都依赖 daemon 返回。
        if [ -z "${OPENCLI_PROFILE:-}" ] && [ -f "$profile_file" ]; then
          profile_from_file="$(/usr/bin/python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("profile") or "").strip())' "$profile_file" 2>/dev/null || true)"
          if [ -n "$profile_from_file" ]; then
            export OPENCLI_PROFILE="$profile_from_file"
          fi
        fi
        if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
          echo "opencli-daemon=start port=$port" >> "$LOG" 2>&1 || true
          mkdir -p "$HOME/.opencli"
          /usr/bin/nohup /usr/bin/env node "\(daemonPath)" >> "$HOME/.opencli/clawdhome-daemon.log" 2>&1 &
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
            sleep 0.2
          done
        fi

        bridge_connected=0
        status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
        # known_* 用于“纠正陈旧 profile”，connected_* 用于“判断是否已连上桥接”。
        known_profiles="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; print(" ".join(profiles))' 2>/dev/null || true)"
        known_primary="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; print(next((c for c in preferred if c in profiles), (profiles[-1] if profiles else "")))' 2>/dev/null || true)"
        connected_profiles="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; print(" ".join([x for x in profiles if x]))' 2>/dev/null || true)"
        connected_primary="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; [preferred.append((p.get("contextId") or "").strip()) for p in data.get("profiles", []) if (p.get("contextId") or "").strip() and any(p.get(flag) is True for flag in ("current","active","isCurrent","isActive","selected","default"))]; print(next((c for c in preferred if c in profiles), (profiles[0] if profiles else "")))' 2>/dev/null || true)"
        known_count="$(printf '%s\n' "$known_profiles" | /usr/bin/awk '{print NF}')"
        [ -n "$known_count" ] || known_count=0
        profile_known=0
        if [ -n "${OPENCLI_PROFILE:-}" ]; then
          case " $known_profiles " in
            *" $OPENCLI_PROFILE "*) profile_known=1 ;;
          esac
        fi
        if [ "$profile_known" -ne 1 ] && [ -n "${known_primary:-}" ]; then
          export OPENCLI_PROFILE="$known_primary"
          echo "opencli-profile-known-sync=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
        fi
        connected_count="$(printf '%s\n' "$connected_profiles" | /usr/bin/awk '{print NF}')"
        [ -n "$connected_count" ] || connected_count=0
        profile_connected=0
        if [ -n "${OPENCLI_PROFILE:-}" ]; then
          case " $connected_profiles " in
            *" $OPENCLI_PROFILE "*) profile_connected=1 ;;
          esac
        fi
        if [ "$profile_connected" -eq 1 ]; then
          bridge_connected=1
          echo "opencli-prelaunch=skip-profile-connected profile=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
        elif [ -n "${connected_primary:-}" ]; then
          # 当前 profile 未连通时，优先切到 daemon 认为已连通的主 profile。
          profile_from_status="$connected_primary"
          mkdir -p "$(dirname "$profile_file")"
          /usr/bin/python3 -c 'import json,sys,time; json.dump({"profile": sys.argv[1], "capturedAt": time.time(), "source": "opencli daemon status"}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)' "$profile_from_status" "$profile_file" 2>/dev/null || true
          chmod 600 "$profile_file" 2>/dev/null || true
          export OPENCLI_PROFILE="$profile_from_status"
          bridge_connected=1
          echo "opencli-prelaunch=adopt-connected profile=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
        fi

        if [ "$bridge_connected" -ne 1 ]; then
          # 仅在确实未连通时触发 bridge-open，避免重复拉起同 profile 浏览器。
          /usr/bin/env python3 "\(toolPath)" bridge-open "https://clawdhome.ai" >/dev/null 2>&1 || {
            echo "opencli-prelaunch=failed" >> "$LOG" 2>&1 || true
            echo "ClawdHome: 已尝试自动打开该用户的 ClawdHome Chrome，但启动失败。请先在 ClawdHome 中打开浏览器账号。" >&2
          }
          echo "opencli-prelaunch=done" >> "$LOG" 2>&1 || true
        fi

        for _ in {1..40}; do
          status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
          echo "$status_json" | /usr/bin/grep -q '"extensionConnected":true' && break
          sleep 0.5
        done

        known_profiles="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; print(" ".join(profiles))' 2>/dev/null || true)"
        known_primary="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; print(next((c for c in preferred if c in profiles), (profiles[-1] if profiles else "")))' 2>/dev/null || true)"
        connected_profiles="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; print(" ".join([x for x in profiles if x]))' 2>/dev/null || true)"
        connected_primary="$(printf '%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; [preferred.append((p.get("contextId") or "").strip()) for p in data.get("profiles", []) if (p.get("contextId") or "").strip() and any(p.get(flag) is True for flag in ("current","active","isCurrent","isActive","selected","default"))]; print(next((c for c in preferred if c in profiles), (profiles[0] if profiles else "")))' 2>/dev/null || true)"
        known_count="$(printf '%s\n' "$known_profiles" | /usr/bin/awk '{print NF}')"
        [ -n "$known_count" ] || known_count=0
        profile_known=0
        if [ -n "${OPENCLI_PROFILE:-}" ]; then
          case " $known_profiles " in
            *" $OPENCLI_PROFILE "*) profile_known=1 ;;
          esac
        fi
        if [ "$profile_known" -ne 1 ] && [ -n "${known_primary:-}" ]; then
          export OPENCLI_PROFILE="$known_primary"
          echo "opencli-profile-known-sync=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
        fi
        connected_count="$(printf '%s\n' "$connected_profiles" | /usr/bin/awk '{print NF}')"
        [ -n "$connected_count" ] || connected_count=0
        profile_connected=0
        if [ -n "${OPENCLI_PROFILE:-}" ]; then
          case " $connected_profiles " in
            *" $OPENCLI_PROFILE "*) profile_connected=1 ;;
          esac
        fi
        if [ "$profile_connected" -ne 1 ] && [ -n "${connected_primary:-}" ]; then
          profile_from_status="$connected_primary"
          mkdir -p "$(dirname "$profile_file")"
          /usr/bin/python3 -c 'import json,sys,time; json.dump({"profile": sys.argv[1], "capturedAt": time.time(), "source": "opencli daemon status"}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)' "$profile_from_status" "$profile_file" 2>/dev/null || true
          chmod 600 "$profile_file" 2>/dev/null || true
          export OPENCLI_PROFILE="$profile_from_status"
          echo "opencli-profile-sync=$profile_from_status" >> "$LOG" 2>&1 || true
        elif [ "$profile_connected" -ne 1 ] && [ "$connected_count" -eq 0 ] && [ "$known_count" -eq 0 ] && [ -n "${OPENCLI_PROFILE:-}" ]; then
          echo "opencli-profile-stale-clear=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
          unset OPENCLI_PROFILE
        fi

        if [ "${1:-}" = "profile" ] && [ "${2:-}" = "list" ] && [ -n "${OPENCLI_PROFILE:-}" ]; then
          # profile list 直接复用 daemon 状态，避免 real opencli 在未连通时输出误导信息。
          extension_version="$(printf '%s' "${status_json:-}" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("extensionVersion") or "")' 2>/dev/null || true)"
          [ -n "$extension_version" ] || extension_version="unknown"
          printf 'Connected Browser Bridge profiles\\n\\n  %s — connected v%s\\n' "$OPENCLI_PROFILE" "$extension_version"
          exit 0
        fi

        if [ -n "${OPENCLI_PROFILE:-}" ]; then
          # 在真正执行命令前强制 real opencli 切到同一 profile，避免读取到旧默认 profile。
          "\(realPath)" profile use "$OPENCLI_PROFILE" >/dev/null 2>&1 || true
        fi

        echo "opencli-wrapper=exec-real" >> "$LOG" 2>&1 || true
        exec "\(realPath)" "$@"
        """
    }

    private static func openURLCLIWrapperScript(commandName: String, toolPath: String) -> String {
        """
        #!/bin/zsh
        # CLAWDHOME_OPEN_URL_CLI_WRAPPER
        set -e
        LOG="$HOME/\(BrowserAccountPaths.debugLogRelativePath)"
        mkdir -p "$HOME/\(BrowserAccountPaths.browserDirectoryRelativePath)"
        {
          echo "--- $(/bin/date '+%Y-%m-%d %H:%M:%S') \(commandName)-wrapper"
          echo "argv=$*"
          echo "pwd=$PWD"
          echo "PATH=$PATH"
          echo "which-clawdhome-browser=$(command -v clawdhome-browser 2>/dev/null || true)"
        } >> "$LOG" 2>&1 || true

        for arg in "$@"; do
          case "$arg" in
            http://*|https://*)
              echo "\(commandName)-route=clawdhome-browser-open url=$arg" >> "$LOG" 2>&1 || true
              exec /usr/bin/env python3 "\(toolPath)" open "$arg"
              ;;
          esac
        done

        echo "\(commandName): ClawdHome 已接管 URL 打开操作；请传入 http(s) URL。" >&2
        exit 1
        """
    }

    private struct Context {
        let username: String
        let consoleUsername: String
        let consoleUID: uid_t
        let paths: BrowserAccountPaths
    }

    private static func resolveContext(username: String) throws -> Context {
        guard BrowserAccountPaths.isValidUsername(username) else {
            throw BrowserAccountError.invalidUsername
        }
        let (consoleUsername, consoleUID) = try resolveConsoleSession()
        let appSupport = URL(fileURLWithPath: "/Users/\(consoleUsername)/Library/Application Support/ClawdHome")
        return Context(
            username: username,
            consoleUsername: consoleUsername,
            consoleUID: consoleUID,
            paths: BrowserAccountPaths(username: username, appSupportDirectory: appSupport)
        )
    }

    private static func resolveConsoleSession() throws -> (username: String, uid: uid_t) {
        var uid: uid_t = 0
        guard let cfUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil), uid != 0 else {
            throw BrowserAccountError.noConsoleSession
        }
        let username = (cfUser as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username != "loginwindow" else {
            throw BrowserAccountError.noConsoleSession
        }
        return (username, uid)
    }

    private static func prepareProfileDirectory(_ path: String, consoleUsername: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FilePermissionHelper.chown(parent, owner: consoleUsername)
        try FilePermissionHelper.chmod(parent, mode: "755")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive(path, owner: consoleUsername)
        try FilePermissionHelper.chmod(path, mode: "700")
    }

    private static func openCLIDaemonPort(username: String) -> Int {
        _ = username
        return openCLIDefaultDaemonPort
    }

    private enum BridgePolicyAction {
        case configured(path: String)
        case guardedPolicyRemoved(path: String)
        case guardedNoPolicyChange
    }

    private static func ensureOpenCLIBrowserBridgeExtensionInstalled(
        context: Context,
        logURL: URL?
    ) throws -> BridgePolicyAction {
        // 默认防御：不允许写入宿主机全局 Chrome 策略，除非管理员显式创建 allow flag。
        // 这样可避免把 OpenCLI 扩展误安装到默认/非实例浏览器环境。
        if !isGlobalChromePolicyInstallAllowed() {
            do {
                if try removeOpenCLIBrowserBridgePolicyIfPresent() {
                    cleanupLegacyUnpackedBridgeExtensionIfNeeded(context: context, logURL: logURL)
                    return .guardedPolicyRemoved(path: chromeManagedPolicyPath)
                }
            } catch {
                // 防御分支不应阻断实例浏览器启动；清理失败仅记录安装日志（有 logURL 时）。
                appendInstallLog(
                    "⚠ 主动防御清理宿主机策略失败（可忽略，不影响实例浏览器）：\(error.localizedDescription)\n",
                    logURL: logURL
                )
            }
            cleanupLegacyUnpackedBridgeExtensionIfNeeded(context: context, logURL: logURL)
            return .guardedNoPolicyChange
        }

        let alreadyConfigured = isOpenCLIBrowserBridgePolicyConfigured()
        if !alreadyConfigured {
            appendInstallLog("→ 写入 Chrome 托管策略，强制安装 OpenCLI Browser Bridge（无需开发者模式）\n", logURL: logURL)
        }
        try ensureOpenCLIBrowserBridgePolicyConfigured()
        if !alreadyConfigured {
            appendInstallLog("✓ Chrome 托管策略写入完成，首次生效需重启 Chrome profile\n", logURL: logURL)
        }
        cleanupLegacyUnpackedBridgeExtensionIfNeeded(context: context, logURL: logURL)
        return .configured(path: chromeManagedPolicyPath)
    }

    private static func isGlobalChromePolicyInstallAllowed() -> Bool {
        FileManager.default.fileExists(atPath: allowGlobalChromePolicyFlagPath)
    }

    private static func ensureOpenCLIBrowserBridgePolicyConfigured() throws {
        let fm = FileManager.default
        let policyURL = URL(fileURLWithPath: chromeManagedPolicyPath)
        let policyDir = policyURL.deletingLastPathComponent().path

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: chromeManagedPolicyPath) {
            let data = try Data(contentsOf: policyURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = plist as? [String: Any] else {
                throw BrowserAccountError.commandFailed("Chrome 托管策略文件格式无效：\(chromeManagedPolicyPath)")
            }
            root = dict
        }

        var extensionSettings = root["ExtensionSettings"] as? [String: Any] ?? [:]
        var bridgeEntry = extensionSettings[openCLIBrowserBridgeExtensionID] as? [String: Any] ?? [:]
        bridgeEntry["installation_mode"] = "force_installed"
        bridgeEntry["update_url"] = openCLIBrowserBridgeUpdateURL
        extensionSettings[openCLIBrowserBridgeExtensionID] = bridgeEntry
        root["ExtensionSettings"] = extensionSettings

        let output = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try fm.createDirectory(atPath: policyDir, withIntermediateDirectories: true)
        try output.write(to: policyURL, options: .atomic)
        try FilePermissionHelper.chown(chromeManagedPolicyPath, owner: "root", group: "wheel")
        try FilePermissionHelper.chmod(chromeManagedPolicyPath, mode: "644")
    }

    private static func removeOpenCLIBrowserBridgePolicyIfPresent() throws -> Bool {
        let fm = FileManager.default
        let policyURL = URL(fileURLWithPath: chromeManagedPolicyPath)
        guard fm.fileExists(atPath: chromeManagedPolicyPath) else {
            return false
        }
        let data = try Data(contentsOf: policyURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard var root = plist as? [String: Any] else {
            throw BrowserAccountError.commandFailed("Chrome 托管策略文件格式无效：\(chromeManagedPolicyPath)")
        }
        guard var extensionSettings = root["ExtensionSettings"] as? [String: Any] else {
            return false
        }
        guard let bridgeEntry = extensionSettings[openCLIBrowserBridgeExtensionID] as? [String: Any],
              let mode = bridgeEntry["installation_mode"] as? String,
              let updateURL = bridgeEntry["update_url"] as? String,
              mode == "force_installed",
              updateURL == openCLIBrowserBridgeUpdateURL else {
            return false
        }

        extensionSettings.removeValue(forKey: openCLIBrowserBridgeExtensionID)
        if extensionSettings.isEmpty {
            root.removeValue(forKey: "ExtensionSettings")
        } else {
            root["ExtensionSettings"] = extensionSettings
        }
        let output = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try output.write(to: policyURL, options: .atomic)
        try FilePermissionHelper.chown(chromeManagedPolicyPath, owner: "root", group: "wheel")
        try FilePermissionHelper.chmod(chromeManagedPolicyPath, mode: "644")
        return true
    }

    private static func isOpenCLIBrowserBridgePolicyConfigured() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: chromeManagedPolicyPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let extensionSettings = plist["ExtensionSettings"] as? [String: Any],
              let bridgeEntry = extensionSettings[openCLIBrowserBridgeExtensionID] as? [String: Any],
              let mode = bridgeEntry["installation_mode"] as? String,
              let updateURL = bridgeEntry["update_url"] as? String else {
            return false
        }
        return mode == "force_installed" && updateURL == openCLIBrowserBridgeUpdateURL
    }

    private static func cleanupLegacyUnpackedBridgeExtensionIfNeeded(context: Context, logURL: URL?) {
        let legacyDir = context.paths.openCLIBrowserBridgeExtensionDirectory.path
        guard FileManager.default.fileExists(atPath: legacyDir) else { return }
        let backupPath = "\(legacyDir).legacy-unpacked-\(timestamp())"
        do {
            try FileManager.default.moveItem(atPath: legacyDir, toPath: backupPath)
            try FilePermissionHelper.chownRecursive(backupPath, owner: context.consoleUsername)
            try FilePermissionHelper.chmodRecursive(backupPath, mode: "755")
            appendInstallLog("✓ 已归档旧版 unpacked 扩展目录：\(backupPath)\n", logURL: logURL)
        } catch {
            appendInstallLog("⚠ 旧版 unpacked 扩展目录归档失败（可忽略）：\(error.localizedDescription)\n", logURL: logURL)
        }
    }

    private struct OpenCLIBrowserBridgeMeta {
        let installed: Bool
        let installedVersion: String?
        let latestVersion: String?
        let updateAvailable: Bool?
    }

    private static func openCLIBrowserBridgeMeta(context: Context) -> OpenCLIBrowserBridgeMeta {
        let policyConfigured = isOpenCLIBrowserBridgePolicyConfigured()
        let installedVersion = installedOpenCLIBrowserBridgeVersion(profilePath: context.paths.profileDirectory.path)
        // 状态优先看实例 profile 中是否实际安装了扩展；policy 仅作为辅助信号。
        let installed = installedVersion != nil || policyConfigured
        return OpenCLIBrowserBridgeMeta(
            installed: installed,
            installedVersion: installedVersion,
            latestVersion: nil,
            updateAvailable: nil
        )
    }

    private static func installedOpenCLIBrowserBridgeVersion(profilePath: String) -> String? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: profilePath)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(openCLIBrowserBridgeExtensionID, isDirectory: true)
        guard fm.fileExists(atPath: root.path),
              let candidates = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }
        let versions = candidates.compactMap { item -> String? in
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let manifestPath = item.appendingPathComponent("manifest.json").path
            guard let data = fm.contents(atPath: manifestPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let version = json["version"] as? String,
               !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return version
            }
            return nil
        }
        return versions.sorted { lhs, rhs in
            lhs.compare(rhs, options: .numeric) == .orderedAscending
        }.last
    }

    private static func writeSession(_ session: BrowserAccountSession, username: String) throws {
        let path = sessionPath(username: username)
        let dir = (path as NSString).deletingLastPathComponent
        try prepareUserWritableBrowserDirectory(dir, username: username)
        let data = try JSONEncoder().encode(session)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "600")
        HermesConfigWriter.syncBrowserCDPEndpoint(username: username, endpoint: nil)
    }

    private static func readSession(username: String) -> BrowserAccountSession? {
        for path in sessionPaths(username: username) {
            guard let data = FileManager.default.contents(atPath: path),
                  let session = try? JSONDecoder().decode(BrowserAccountSession.self, from: data) else {
                continue
            }
            if path == legacySessionPath(username: username) {
                try? writeSession(session, username: username)
            }
            return session
        }
        return nil
    }

    private static func sessionPath(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.sessionRelativePath)"
    }

    private static func legacySessionPath(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.legacySessionRelativePath)"
    }

    private static func sessionPaths(username: String) -> [String] {
        [sessionPath(username: username), legacySessionPath(username: username)]
    }

    private static func sessionFileExists(username: String) -> Bool {
        sessionPaths(username: username).contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func installWarmupMarkerPath(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.installWarmupMarkerRelativePath)"
    }

    private static func installWarmupCompleted(username: String) -> Bool {
        FileManager.default.fileExists(atPath: installWarmupMarkerPath(username: username))
    }

    private static func writeInstallWarmupMarker(username: String) throws {
        let path = installWarmupMarkerPath(username: username)
        let dir = (path as NSString).deletingLastPathComponent
        try prepareUserWritableBrowserDirectory(dir, username: username)
        let payload: [String: Any] = [
            "username": username,
            "completedAt": Date().timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "600")
    }

    private static func prepareUserWritableBrowserDirectory(_ path: String, username: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "755")
    }

    private static func closeWarmupBrowser(profilePath: String, logURL: URL?) throws {
        var matchedPIDs = browserProcessIDs(profilePath: profilePath)
        guard !matchedPIDs.isEmpty else {
            appendInstallLog("ℹ 未找到需要关闭的 Chrome profile 进程，视为已关闭\n", logURL: logURL)
            return
        }

        appendInstallLog("→ 关闭 Chrome profile 进程：\(matchedPIDs.joined(separator: ", "))\n", logURL: logURL)
        for pid in matchedPIDs {
            _ = try? run("/bin/kill", args: ["-TERM", pid])
        }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            matchedPIDs = browserProcessIDs(profilePath: profilePath)
            if matchedPIDs.isEmpty {
                appendInstallLog("✓ Chrome profile 进程已正常退出\n", logURL: logURL)
                return
            }
        }

        appendInstallLog("⚠ Chrome profile 未及时退出，强制关闭：\(matchedPIDs.joined(separator: ", "))\n", logURL: logURL)
        for pid in matchedPIDs {
            _ = try? run("/bin/kill", args: ["-KILL", pid])
        }

        Thread.sleep(forTimeInterval: 0.5)
        let remaining = browserProcessIDs(profilePath: profilePath)
        guard remaining.isEmpty else {
            throw BrowserAccountError.commandFailed("初始化浏览器已打开，但未能关闭 Chrome profile 进程：\(remaining.joined(separator: ", "))")
        }
        appendInstallLog("✓ Chrome profile 进程已强制关闭\n", logURL: logURL)
    }

    private static func browserProcessIDs(profilePath: String) -> [String] {
        guard let raw = try? run("/bin/ps", args: ["-ax", "-o", "pid=,command="]) else {
            return []
        }
        return raw
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = String(line)
                guard isMainChromeProcessCommand(text),
                      text.contains("--user-data-dir=\(profilePath)") || text.contains(profilePath) else {
                    return nil
                }
                return text.split(separator: " ", maxSplits: 1).first.map(String.init)
            }
    }

    private static func isMainChromeProcessCommand(_ text: String) -> Bool {
        text.contains("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome ")
            || text.hasSuffix("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    private static func spawnPipeBrowserLauncher(
        context: Context,
        target: String,
        hidden: Bool,
        mode: String
    ) throws {
        let pipeLauncherPath = "/Library/Application Support/ClawdHome/BrowserLaunchers/\(context.username)/clawdhome-browser-pipe-launcher"
        guard FileManager.default.isExecutableFile(atPath: pipeLauncherPath) else {
            throw BrowserAccountError.commandFailed("ClawdHome pipe launcher missing. Reinstall browser tool in ClawdHome first.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "asuser", "\(context.consoleUID)",
            "/usr/bin/sudo", "-u", context.consoleUsername, "-H",
            pipeLauncherPath,
            context.paths.profileDirectory.path,
            "\(openCLIDefaultCDPCapturePort)",
            target,
            hidden ? "1" : "0",
            "/Users/\(context.username)",
            mode,
        ]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        try process.run()
    }

    private static func appendToolsGuidanceIfNeeded(username: String) throws {
        let relativePath = BrowserAccountPaths.toolsGuideRelativePath
        try UserFileManager.createDirectory(username: username, relativePath: ".clawdhome")

        let marker = "clawdhome_browser_account"
        let guidance = """

        ## ClawdHome 浏览器账号

        <!-- clawdhome_browser_account -->

        你可以使用 `clawdhome-browser` 操作该 macOS 用户级的已登录 Chrome 浏览器账号。

        - `clawdhome-browser status`：检查浏览器账号是否已打开。
        - `clawdhome-browser open <url>`：启动/复用该用户的 ClawdHome Chrome，并打开网页。
        - `clawdhome-browser bridge-open <url>`：以 Browser Bridge 优先模式启动并打开网页（用于 OpenCLI 连接）。
        - `clawdhome-browser launch [url]`：底层启动命令，通常无需直接使用。
        常见浏览器打开命令已被接管：`open <url>`、`google-chrome <url>`、`chrome <url>`、`chromium <url>`、`xdg-open <url>` 会自动跳到 `clawdhome-browser open <url>`；无 URL 时默认打开 `https://clawdhome.ai`。

        如果该用户已安装 `opencli`，ClawdHome 会把真实入口保存在 `opencli.clawdhome-real`，并用 wrapper 接管 `opencli`：运行 OpenCLI 时会先检查 Browser Bridge 连接状态，仅在未连接时才自动执行 `clawdhome-browser bridge-open https://clawdhome.ai`。

        如果当前命令行用户没有 macOS 图形会话，`launch` 可能会被系统拒绝；此时请让用户在 ClawdHome 中点击“打开浏览器账号”完成初始化。
        """
        let existing = (try? UserFileManager.readFile(username: username, relativePath: relativePath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard !existing.contains(marker) else { return }
        let next = existing.isEmpty ? guidance.trimmingCharacters(in: .whitespacesAndNewlines) : existing + guidance
        try UserFileManager.writeFile(username: username, relativePath: relativePath, data: Data(next.utf8))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func appendInstallLog(_ message: String, logURL: URL?) {
        guard let logURL,
              let handle = FileHandle(forWritingAtPath: logURL.path) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(message.utf8))
        handle.closeFile()
    }
}

private let browserToolScript = #"""
#!/usr/bin/env python3
import datetime
import getpass
import hashlib
import json
import os
import subprocess
import sys
import time

SESSION_PATH = os.path.expanduser("~/.clawdhome/browser/session.json")
LEGACY_SESSION_PATH = os.path.expanduser("~/.openclaw/clawdhome-browser-session.json")
PROFILE_PATH = os.path.expanduser("~/.clawdhome/browser/profile")
LEGACY_PROFILE_PATH = os.path.expanduser("~/.openclaw/browser-profile")
ACTIVE_PORT_PATH = os.path.join(PROFILE_PATH, "DevToolsActivePort")
LAUNCHER_PATH = os.path.expanduser("~/.clawdhome/tools/clawdhome-browser/clawdhome-browser-launcher")
LEGACY_LAUNCHER_PATH = os.path.expanduser("~/.openclaw/tools/clawdhome-browser/clawdhome-browser-launcher")
CHROME_APP = "/Applications/Google Chrome.app"
CHROME_BINARY = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DEBUG_LOG_PATH = os.path.expanduser("~/.clawdhome/browser/debug.log")

def debug_log(message):
    try:
        os.makedirs(os.path.dirname(DEBUG_LOG_PATH), exist_ok=True)
        with open(DEBUG_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now().isoformat(timespec='seconds')} pid={os.getpid()} {message}\n")
    except Exception:
        pass

def fail(message, code=1):
    debug_log(f"fail code={code} message={message!r} argv={sys.argv!r}")
    print(message, file=sys.stderr)
    sys.exit(code)

def load_session():
    session = load_session_if_present()
    if not session:
        fail("浏览器账号尚未打开。请先运行 clawdhome-browser launch，或在 ClawdHome 中点击“打开浏览器账号”。")
    return session

def session_paths():
    return [SESSION_PATH, LEGACY_SESSION_PATH]

def write_session_dict(session):
    os.makedirs(os.path.dirname(SESSION_PATH), exist_ok=True)
    with open(SESSION_PATH, "w", encoding="utf-8") as f:
        json.dump(session, f, ensure_ascii=False, indent=2)
    os.chmod(SESSION_PATH, 0o600)

def load_session_if_present():
    for path in session_paths():
        if not os.path.exists(path):
            debug_log(f"load_session missing path={path!r}")
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                session = json.load(f)
                debug_log(f"load_session ok path={path!r} endpoint={session.get('httpEndpoint')!r} profile={session.get('profilePath')!r} port={session.get('cdpPort')!r}")
                if path == LEGACY_SESSION_PATH and not os.path.exists(SESSION_PATH):
                    write_session_dict(session)
                return session
        except Exception as exc:
            debug_log(f"load_session fail path={path!r} error={exc!r}")
    return None

def should_hide_browser():
    return os.environ.get("CLAWDHOME_BROWSER_HIDE") == "1"

def profile_path_markers(profile_path):
    markers = [f"--user-data-dir={profile_path}", profile_path]
    escaped = profile_path.replace(" ", "\\ ")
    if escaped != profile_path:
        markers.extend([f"--user-data-dir={escaped}", escaped])
    return markers

def command_mentions_profile(command, profile_path):
    for marker in profile_path_markers(profile_path):
        if marker and marker in command:
            return True
    return False

def browser_process_running(profile_path):
    try:
        result = subprocess.run(
            ["/bin/ps", "-ax", "-o", "command="],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception as exc:
        debug_log(f"browser_process_running ps_fail error={exc!r}")
        return False
    for text in result.stdout.splitlines():
        if CHROME_BINARY not in text:
            continue
        if command_mentions_profile(text, profile_path):
            return True
    return False

def lock_file_in_use(profile_path):
    lock_path = os.path.join(profile_path, "SingletonLock")
    if not os.path.exists(lock_path):
        return False
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-t", lock_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception as exc:
        debug_log(f"lock_file_in_use lsof_fail path={lock_path!r} error={exc!r}")
        return False
    pids = [line.strip() for line in result.stdout.splitlines() if line.strip().isdigit()]
    if not pids:
        debug_log(f"lock_file_in_use no_holder path={lock_path!r}")
        return False
    for pid in pids:
        try:
            cmd = subprocess.run(
                ["/bin/ps", "-p", pid, "-o", "command="],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            ).stdout.strip()
        except Exception:
            continue
        if CHROME_BINARY in cmd:
            debug_log(f"lock_file_in_use holder pid={pid} path={lock_path!r}")
            return True
    debug_log(f"lock_file_in_use holder_not_chrome pids={pids!r} path={lock_path!r}")
    return False

def profile_runtime_active(profile_path):
    running = browser_process_running(profile_path)
    lock_held = lock_file_in_use(profile_path)
    active = running or lock_held
    debug_log(f"profile_runtime_active profile={profile_path!r} process_running={running} lock_held={lock_held} active={active}")
    return active

def chrome_profile_processes(profile_path):
    try:
        result = subprocess.run(
            ["/bin/ps", "-ax", "-o", "pid=,command="],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception as exc:
        debug_log(f"chrome_profile_processes ps_fail error={exc!r}")
        return []
    pids = []
    for line in result.stdout.splitlines():
        raw = line.strip()
        if not raw:
            continue
        parts = raw.split(None, 1)
        if not parts:
            continue
        pid = parts[0]
        command = parts[1] if len(parts) > 1 else ""
        if CHROME_BINARY not in command:
            continue
        if not command_mentions_profile(command, profile_path):
            continue
        if pid.isdigit():
            pids.append(pid)
    return pids

def close_profile_chrome_processes(profile_path):
    pids = chrome_profile_processes(profile_path)
    if not pids:
        return
    debug_log(f"close_profile_chrome_processes term pids={pids!r} profile={profile_path!r}")
    for pid in pids:
        subprocess.run(["/bin/kill", "-TERM", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 4
    while time.time() < deadline:
        time.sleep(0.25)
        if not chrome_profile_processes(profile_path):
            return
    remaining = chrome_profile_processes(profile_path)
    debug_log(f"close_profile_chrome_processes kill pids={remaining!r} profile={profile_path!r}")
    for pid in remaining:
        subprocess.run(["/bin/kill", "-KILL", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)

def launcher_candidates():
    username = os.environ.get("USER") or getpass.getuser()
    candidates = []
    if username:
        candidates.append(f"/Library/Application Support/ClawdHome/BrowserLaunchers/{username}/clawdhome-browser-launcher")
    candidates.append(LAUNCHER_PATH)
    candidates.append(LEGACY_LAUNCHER_PATH)
    return candidates

def resolve_launcher_path():
    debug_log(f"resolve_launcher_path candidates={launcher_candidates()!r}")
    for path in launcher_candidates():
        if os.path.exists(path) and os.access(path, os.X_OK):
            debug_log(f"resolve_launcher_path selected={path!r}")
            return path
        debug_log(f"resolve_launcher_path skip path={path!r} exists={os.path.exists(path)} executable={os.access(path, os.X_OK)}")
    return None

def hide_browser_if_requested():
    if not should_hide_browser():
        return
    debug_log("hide_browser_if_requested")
    subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to hide'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

def open_url_via_launcher_reuse(launcher_path, target):
    # profile-strict-open-v4
    # 严格模式：只允许通过 launcher 在实例专属 profile 打开 URL；不回退到 open -a/AppleScript。
    args = [launcher_path, target, "--reuse-open-url"]
    try:
        result = subprocess.run(
            args,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        debug_log(f"open_url_via_launcher_reuse ok url={target!r} launcher={launcher_path!r} stdout={result.stdout.strip()!r} stderr={result.stderr.strip()!r}")
        return True
    except subprocess.CalledProcessError as exc:
        debug_log(f"open_url_via_launcher_reuse fail url={target!r} launcher={launcher_path!r} rc={exc.returncode} stdout={(exc.stdout or '').strip()!r} stderr={(exc.stderr or '').strip()!r}")
        return False

def command_status():
    debug_log(f"command_status argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r}")
    session = load_session_if_present()
    if not session:
        print(json.dumps({
            "ok": False,
            "profilePath": "",
            "message": "浏览器账号尚未初始化，请先在 ClawdHome 中点击“打开浏览器账号”。"
        }, ensure_ascii=False, indent=2))
        return
    profile_path = session.get("profilePath", PROFILE_PATH)
    running = profile_runtime_active(profile_path)
    print(json.dumps({
        "ok": running,
        "profilePath": profile_path,
        "message": "浏览器账号正在运行" if running else "浏览器账号已初始化，但当前未运行"
    }, ensure_ascii=False, indent=2))

def command_launch(url=None, emit_json=True, require_bridge=False):
    debug_log(f"command_launch start url={url!r} argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r} hide={should_hide_browser()} require_bridge={require_bridge}")
    existing_session = load_session_if_present()
    debug_log(f"command_launch existing_session={bool(existing_session)}")
    launch_profile_path = (existing_session or {}).get("profilePath", PROFILE_PATH)

    if not existing_session and launch_profile_path == PROFILE_PATH:
        fail("浏览器账号尚未初始化。请先在 ClawdHome 中点击一次“打开浏览器账号”，之后该用户命令会自动复用并拉起它。")

    if not os.path.exists(CHROME_APP):
        fail("未找到 Google Chrome，请先安装 Chrome。")

    if launch_profile_path == PROFILE_PATH:
        os.makedirs(launch_profile_path, exist_ok=True)

    target = url or "about:blank"
    if existing_session and profile_runtime_active(launch_profile_path):
        debug_log(f"command_launch reuse-running profile={launch_profile_path!r} target={target!r} require_bridge={require_bridge}")
        launcher_path = resolve_launcher_path()
        opened = False
        # bridge 场景下避免对已运行窗口再发一次 URL 打开请求，防止 Chrome 生成额外窗口或误路由。
        if require_bridge and target != "about:blank":
            debug_log("command_launch reuse-running skip-open-url require_bridge=1")
            opened = True
        elif target != "about:blank":
            if not launcher_path:
                fail("无法定位实例专属浏览器 launcher，已拒绝回退到系统默认浏览器。请先在 ClawdHome 重新安装浏览器工具。")
            opened = open_url_via_launcher_reuse(launcher_path, target)
            if not opened:
                fail("实例专属 profile 打开 URL 失败，已拒绝回退到其他浏览器 profile。请检查该实例浏览器会话是否正常。")
        if target == "about:blank" or opened:
            hide_browser_if_requested()
            if emit_json:
                print(json.dumps({
                    "ok": True,
                    "profilePath": launch_profile_path,
                    "message": "浏览器账号已在运行并复用"
                }, ensure_ascii=False, indent=2))
            return

    launcher_path = resolve_launcher_path() if existing_session else None
    if existing_session and launcher_path:
        # bridge 模式先回收旧进程，确保扩展连接与 opencli 观察到的是同一个新进程。
        if require_bridge:
            close_profile_chrome_processes(launch_profile_path)
        args = [launcher_path, target]
        if should_hide_browser():
            args.append("--hidden")
        if require_bridge:
            args.append("--bridge")
        debug_log(f"command_launch route=privileged-launcher args={args!r} profile={launch_profile_path!r}")
    else:
        args = [
        "/usr/bin/open", "-na", "Google Chrome",
        ]
        if should_hide_browser():
            args.append("-j")
        args += [
        "--args",
        f"--user-data-dir={launch_profile_path}",
        "--no-first-run",
        "--new-window",
        target,
        ]
        debug_log(f"command_launch route=direct-open-fallback args={args!r} profile={launch_profile_path!r}")
    try:
        result = subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        debug_log(f"command_launch subprocess ok stdout={result.stdout.strip()!r} stderr={result.stderr.strip()!r}")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        debug_log(f"command_launch subprocess fail returncode={exc.returncode} stdout={(exc.stdout or '').strip()!r} stderr={(exc.stderr or '').strip()!r}")
        fail("当前用户直接启动 GUI Chrome 失败。该用户可能没有 macOS 图形会话。" + (f"\n{detail}" if detail else ""))

    hide_browser_if_requested()
    debug_log(f"command_launch success profile={launch_profile_path!r} target={target!r}")
    if emit_json:
        print(json.dumps({
            "ok": True,
            "profilePath": launch_profile_path,
            "message": "浏览器账号已启动"
        }, ensure_ascii=False, indent=2))

def command_open(url):
    debug_log(f"command_open start url={url!r} argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r}")
    if not url:
        fail("用法: clawdhome-browser open <url>")
    command_launch(url, emit_json=False)
    debug_log(f"command_open route=launch url={url!r}")
    print(url)

def command_bridge_open(url):
    debug_log(f"command_bridge_open start url={url!r} argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r}")
    if not url:
        fail("用法: clawdhome-browser bridge-open <url>")
    command_launch(url, emit_json=False, require_bridge=True)
    debug_log(f"command_bridge_open route=launch+bridge url={url!r}")
    print(url)

def opencli_daemon_port(username):
    _ = username
    return 19825

def contains_marker(path, marker):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return marker in f.read(4096)
    except Exception:
        return False

def sh_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

def atomic_write_executable(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = path + ".tmp-" + str(os.getpid())
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(tmp_path, 0o755)
    os.replace(tmp_path, path)

def opencli_wrapper_content(real_path, daemon_path):
    username = os.environ.get("USER") or getpass.getuser()
    daemon_port = opencli_daemon_port(username)
    return '''#!/bin/zsh
# CLAWDHOME_OPENCLI_WRAPPER
set -e
LOG="$HOME/.clawdhome/browser/debug.log"
mkdir -p "$HOME/.clawdhome/browser"
{
  echo "--- $(/bin/date '+%%Y-%%m-%%d %%H:%%M:%%S') opencli-wrapper"
  echo "argv=$*"
  echo "pwd=$PWD"
  echo "PATH=$PATH"
  echo "which-open=$(command -v open 2>/dev/null || true)"
  echo "which-opencli-real=%s"
} >> "$LOG" 2>&1 || true

port="${OPENCLI_DAEMON_PORT:-%d}"
export OPENCLI_DAEMON_PORT="$port"
profile_file="$HOME/.clawdhome/browser/opencli-profile.json"
# 优先读取本地缓存 profile，减少每次启动都依赖 daemon 返回。
if [ -z "${OPENCLI_PROFILE:-}" ] && [ -f "$profile_file" ]; then
  profile_from_file="$(/usr/bin/python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("profile") or "").strip())' "$profile_file" 2>/dev/null || true)"
  if [ -n "$profile_from_file" ]; then
    export OPENCLI_PROFILE="$profile_from_file"
  fi
fi
if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
  echo "opencli-daemon=start port=$port" >> "$LOG" 2>&1 || true
  mkdir -p "$HOME/.opencli"
  /usr/bin/nohup /usr/bin/env node %s >> "$HOME/.opencli/clawdhome-daemon.log" 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
    sleep 0.2
  done
fi

bridge_connected=0
status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
# known_* 用于“纠正陈旧 profile”，connected_* 用于“判断是否已连上桥接”。
known_profiles="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; print(" ".join(profiles))' 2>/dev/null || true)"
known_primary="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; print(next((c for c in preferred if c in profiles), (profiles[-1] if profiles else "")))' 2>/dev/null || true)"
connected_profiles="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; print(" ".join([x for x in profiles if x]))' 2>/dev/null || true)"
connected_primary="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; [preferred.append((p.get("contextId") or "").strip()) for p in data.get("profiles", []) if (p.get("contextId") or "").strip() and any(p.get(flag) is True for flag in ("current","active","isCurrent","isActive","selected","default"))]; print(next((c for c in preferred if c in profiles), (profiles[0] if profiles else "")))' 2>/dev/null || true)"
known_count="$(printf '%%s\n' "$known_profiles" | /usr/bin/awk '{print NF}')"
[ -n "$known_count" ] || known_count=0
profile_known=0
if [ -n "${OPENCLI_PROFILE:-}" ]; then
  case " $known_profiles " in
    *" $OPENCLI_PROFILE "*) profile_known=1 ;;
  esac
fi
if [ "$profile_known" -ne 1 ] && [ -n "${known_primary:-}" ]; then
  export OPENCLI_PROFILE="$known_primary"
  echo "opencli-profile-known-sync=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
fi
connected_count="$(printf '%%s\n' "$connected_profiles" | /usr/bin/awk '{print NF}')"
[ -n "$connected_count" ] || connected_count=0
profile_connected=0
if [ -n "${OPENCLI_PROFILE:-}" ]; then
  case " $connected_profiles " in
    *" $OPENCLI_PROFILE "*) profile_connected=1 ;;
  esac
fi
if [ "$profile_connected" -eq 1 ]; then
  bridge_connected=1
  echo "opencli-prelaunch=skip-profile-connected profile=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
elif [ -n "${connected_primary:-}" ]; then
  # 当前 profile 未连通时，优先切到 daemon 认为已连通的主 profile。
  profile_from_status="$connected_primary"
  mkdir -p "$(dirname "$profile_file")"
  /usr/bin/python3 -c 'import json,sys,time; json.dump({"profile": sys.argv[1], "capturedAt": time.time(), "source": "opencli daemon status"}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)' "$profile_from_status" "$profile_file" 2>/dev/null || true
  chmod 600 "$profile_file" 2>/dev/null || true
  export OPENCLI_PROFILE="$profile_from_status"
  bridge_connected=1
  echo "opencli-prelaunch=adopt-connected profile=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
fi

if [ "$bridge_connected" -ne 1 ]; then
  # 仅在确实未连通时触发 bridge-open，避免重复拉起同 profile 浏览器。
  /usr/bin/env python3 "$HOME/.clawdhome/tools/clawdhome-browser/clawdhome-browser" bridge-open "https://clawdhome.ai" >/dev/null 2>&1 || {
    echo "opencli-prelaunch=failed" >> "$LOG" 2>&1 || true
    echo "ClawdHome: 已尝试自动打开该用户的 ClawdHome Chrome，但启动失败。请先在 ClawdHome 中打开浏览器账号。" >&2
  }
  echo "opencli-prelaunch=done" >> "$LOG" 2>&1 || true
fi

for _ in {1..40}; do
  status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
  echo "$status_json" | /usr/bin/grep -q '"extensionConnected":true' && break
  sleep 0.5
done

connected_profiles="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; print(" ".join([x for x in profiles if x]))' 2>/dev/null || true)"
known_profiles="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; print(" ".join(profiles))' 2>/dev/null || true)"
known_primary="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[]; [profiles.append(v) for p in data.get("profiles", []) for v in [((p.get("contextId") or p.get("id") or p.get("profile") or p.get("name") or "").strip() if isinstance(p, dict) else "")] if v]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; print(next((c for c in preferred if c in profiles), (profiles[-1] if profiles else "")))' 2>/dev/null || true)"
connected_primary="$(printf '%%s' "$status_json" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); profiles=[(p.get("contextId") or "").strip() for p in data.get("profiles", []) if p.get("extensionConnected") and p.get("contextId")]; profiles=[x for x in profiles if x]; preferred=[]; [preferred.append((data.get(k) or "").strip()) for k in ("currentContextId","activeContextId","contextId","currentProfile","activeProfile","profile") if isinstance(data.get(k), str) and (data.get(k) or "").strip()]; [preferred.append((p.get("contextId") or "").strip()) for p in data.get("profiles", []) if (p.get("contextId") or "").strip() and any(p.get(flag) is True for flag in ("current","active","isCurrent","isActive","selected","default"))]; print(next((c for c in preferred if c in profiles), (profiles[0] if profiles else "")))' 2>/dev/null || true)"
known_count="$(printf '%%s\n' "$known_profiles" | /usr/bin/awk '{print NF}')"
[ -n "$known_count" ] || known_count=0
profile_known=0
if [ -n "${OPENCLI_PROFILE:-}" ]; then
  case " $known_profiles " in
    *" $OPENCLI_PROFILE "*) profile_known=1 ;;
  esac
fi
if [ "$profile_known" -ne 1 ] && [ -n "${known_primary:-}" ]; then
  export OPENCLI_PROFILE="$known_primary"
  echo "opencli-profile-known-sync=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
fi
connected_count="$(printf '%%s\n' "$connected_profiles" | /usr/bin/awk '{print NF}')"
[ -n "$connected_count" ] || connected_count=0
profile_connected=0
if [ -n "${OPENCLI_PROFILE:-}" ]; then
  case " $connected_profiles " in
    *" $OPENCLI_PROFILE "*) profile_connected=1 ;;
  esac
fi
if [ "$profile_connected" -ne 1 ] && [ -n "${connected_primary:-}" ]; then
  profile_from_status="$connected_primary"
  mkdir -p "$(dirname "$profile_file")"
  /usr/bin/python3 -c 'import json,sys,time; json.dump({"profile": sys.argv[1], "capturedAt": time.time(), "source": "opencli daemon status"}, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)' "$profile_from_status" "$profile_file" 2>/dev/null || true
  chmod 600 "$profile_file" 2>/dev/null || true
  export OPENCLI_PROFILE="$profile_from_status"
  echo "opencli-profile-sync=$profile_from_status" >> "$LOG" 2>&1 || true
elif [ "$profile_connected" -ne 1 ] && [ "$connected_count" -eq 0 ] && [ "$known_count" -eq 0 ] && [ -n "${OPENCLI_PROFILE:-}" ]; then
  echo "opencli-profile-stale-clear=$OPENCLI_PROFILE" >> "$LOG" 2>&1 || true
  unset OPENCLI_PROFILE
fi

if [ "${1:-}" = "profile" ] && [ "${2:-}" = "list" ] && [ -n "${OPENCLI_PROFILE:-}" ]; then
  # profile list 直接复用 daemon 状态，避免 real opencli 在未连通时输出误导信息。
  extension_version="$(printf '%%s' "${status_json:-}" | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("extensionVersion") or "")' 2>/dev/null || true)"
  [ -n "$extension_version" ] || extension_version="unknown"
  printf 'Connected Browser Bridge profiles\\n\\n  %%s — connected v%%s\\n' "$OPENCLI_PROFILE" "$extension_version"
  exit 0
fi

if [ -n "${OPENCLI_PROFILE:-}" ]; then
  # 在真正执行命令前强制 real opencli 切到同一 profile，避免读取到旧默认 profile。
  %s profile use "$OPENCLI_PROFILE" >/dev/null 2>&1 || true
fi

echo "opencli-wrapper=exec-real" >> "$LOG" 2>&1 || true
exec %s "$@"
''' % (real_path, daemon_port, sh_quote(daemon_path), sh_quote(real_path), sh_quote(real_path))

def command_repair_opencli():
    home = os.path.expanduser("~")
    local_bin = os.path.join(home, ".local", "bin")
    npm_bin = os.path.join(home, ".npm-global", "bin")
    npm_opencli = os.path.join(npm_bin, "opencli")
    local_opencli = os.path.join(local_bin, "opencli")
    real_opencli = os.path.join(npm_bin, "opencli.clawdhome-real")
    daemon_path = os.path.join(npm_bin, "..", "lib", "node_modules", "@jackwener", "opencli", "dist", "src", "daemon.js")
    marker = "CLAWDHOME_OPENCLI_WRAPPER"

    debug_log(f"command_repair_opencli start npm_opencli={npm_opencli!r} real_opencli={real_opencli!r}")
    if os.path.lexists(npm_opencli) and not contains_marker(npm_opencli, marker):
        if os.path.lexists(real_opencli):
            backup_path = real_opencli + ".backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            os.replace(real_opencli, backup_path)
            debug_log(f"command_repair_opencli backup_real path={backup_path!r}")
        os.replace(npm_opencli, real_opencli)
        os.chmod(real_opencli, 0o755)
        debug_log("command_repair_opencli moved raw npm opencli to real")

    if not os.path.exists(real_opencli):
        print("opencli executable not found; nothing to repair")
        debug_log("command_repair_opencli no real opencli")
        return
    if not os.path.exists(daemon_path):
        print("opencli daemon not found; wrapper not changed")
        debug_log(f"command_repair_opencli missing daemon path={daemon_path!r}")
        return

    wrapper = opencli_wrapper_content(real_opencli, daemon_path)
    atomic_write_executable(npm_opencli, wrapper)
    atomic_write_executable(local_opencli, wrapper)
    print("opencli wrapper repaired")
    debug_log("command_repair_opencli repaired")

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    debug_log(f"main cmd={cmd!r} argv={sys.argv!r} cwd={os.getcwd()!r} uid={os.getuid()} euid={os.geteuid()} user={os.environ.get('USER')!r}")
    if cmd == "status":
        command_status()
    elif cmd == "launch":
        command_launch(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "open":
        command_open(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "bridge-open":
        command_bridge_open(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "repair-opencli":
        command_repair_opencli()
    else:
        fail("用法: clawdhome-browser status|launch [url]|open <url>|bridge-open <url>|repair-opencli")

if __name__ == "__main__":
    main()
"""#

private let browserPipeLauncherScript = #"""
#!/usr/bin/env python3
import os
import subprocess
import sys
import time

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

def log(home, message):
    try:
        path = os.path.join(home, ".clawdhome", "browser", "debug.log")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} pipe-launcher pid={os.getpid()} {message}\n")
    except Exception:
        pass

def main():
    if len(sys.argv) < 5:
        print("usage: clawdhome-browser-pipe-launcher <profile> <port> <target> <hidden> <log-home> [runtime|bridge]", file=sys.stderr)
        return 64
    profile, port, target, hidden = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
    log_home = sys.argv[5] if len(sys.argv) > 5 else os.path.expanduser("~")
    mode = sys.argv[6] if len(sys.argv) > 6 else "runtime"
    for stale_name in ("DevToolsActivePort", "SingletonLock", "SingletonCookie", "SingletonSocket"):
        stale_path = os.path.join(profile, stale_name)
        try:
            os.unlink(stale_path)
        except FileNotFoundError:
            pass
        except Exception:
            pass

    args = [
        CHROME,
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--new-window",
        target or "about:blank",
    ]
    # 只在安装预热时短暂开启 CDP 端口读取扩展 context id；日常模式不携带 CDP 参数。
    if mode == "install-cdp":
        args.append(f"--remote-debugging-port={port}")
    log(log_home, f"exec chrome mode={mode} profile={profile!r} target={target!r} port={port!r}")
    try:
        proc = subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log(log_home, f"chrome started pid={proc.pid}")
        if hidden:
            time.sleep(1)
            subprocess.run(
                ["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to hide'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        return 0
    except Exception as exc:
        log(log_home, f"failed runtime error={exc!r}")
        return 78

if __name__ == "__main__":
    raise SystemExit(main())
"""#

private let browserLauncherSource = #"""
#include <ctype.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int read_file(const char *path, char *buf, size_t cap) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, cap - 1, f);
    buf[n] = '\0';
    fclose(f);
    return 0;
}

static int json_string(const char *json, const char *key, char *out, size_t cap) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    char *p = strstr(json, pat);
    if (!p) return -1;
    p = strchr(p + strlen(pat), ':');
    if (!p) return -1;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return -1;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < cap) {
        if (*p == '\\' && p[1]) p++;
        out[i++] = *p++;
    }
    out[i] = '\0';
    return i > 0 ? 0 : -1;
}

static int json_int(const char *json, const char *key) {
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    char *p = strstr(json, pat);
    if (!p) return 0;
    p = strchr(p + strlen(pat), ':');
    if (!p) return 0;
    p++;
    while (*p && !isdigit((unsigned char)*p)) p++;
    return atoi(p);
}

static void append_log(const char *home, const char *message) {
    if (!home || !message) return;
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s/.clawdhome", home);
    mkdir(dir, 0700);
    snprintf(dir, sizeof(dir), "%s/.clawdhome/browser", home);
    mkdir(dir, 0700);
    char path[4096];
    snprintf(path, sizeof(path), "%s/.clawdhome/browser/debug.log", home);
    FILE *f = fopen(path, "a");
    if (!f) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char stamp[64];
    strftime(stamp, sizeof(stamp), "%Y-%m-%dT%H:%M:%S", &tmv);
    fprintf(f, "%s launcher pid=%d uid=%d euid=%d %s\n", stamp, getpid(), getuid(), geteuid(), message);
    fclose(f);
}

int main(int argc, char **argv) {
    uid_t original_uid = getuid();
    struct passwd *pw = getpwuid(original_uid);
    const char *caller_home = (pw && pw->pw_dir) ? pw->pw_dir : NULL;
    append_log(caller_home, "start");
    if (setreuid(0, 0) != 0) {
        append_log(caller_home, "setreuid failed");
        perror("setreuid");
        return 69;
    }
    append_log(caller_home, "setreuid ok");

    if (!pw || !pw->pw_dir) {
        fprintf(stderr, "cannot resolve caller home\n");
        return 70;
    }

    char session_path[4096];
    snprintf(session_path, sizeof(session_path), "%s/.clawdhome/browser/session.json", pw->pw_dir);
    char json[65536];
    if (read_file(session_path, json, sizeof(json)) != 0) {
        snprintf(session_path, sizeof(session_path), "%s/.openclaw/clawdhome-browser-session.json", pw->pw_dir);
        if (read_file(session_path, json, sizeof(json)) != 0) {
            append_log(pw->pw_dir, "session missing");
            fprintf(stderr, "browser session missing: %s\n", session_path);
            return 71;
        }
    }

    char profile[4096];
    if (json_string(json, "profilePath", profile, sizeof(profile)) != 0) {
        append_log(pw->pw_dir, "profilePath missing");
        fprintf(stderr, "profilePath missing in session\n");
        return 72;
    }
    int port = json_int(json, "cdpPort");
    if (port <= 0 || port > 65535) {
        append_log(pw->pw_dir, "invalid cdpPort");
        fprintf(stderr, "invalid cdpPort in session\n");
        return 73;
    }

    struct stat st;
    if (stat("/dev/console", &st) != 0) {
        append_log(pw->pw_dir, "stat console failed");
        perror("stat /dev/console");
        return 74;
    }
    struct passwd *console = getpwuid(st.st_uid);
    if (!console || !console->pw_name) {
        append_log(pw->pw_dir, "resolve console user failed");
        fprintf(stderr, "cannot resolve console user\n");
        return 75;
    }

    const char *target = (argc > 1 && argv[1] && argv[1][0]) ? argv[1] : "about:blank";
    int hidden = 0;
    int bridge = 0;
    int reuse_open_url = 0;
    for (int a = 2; a < argc; a++) {
        if (strcmp(argv[a], "--hidden") == 0) hidden = 1;
        if (strcmp(argv[a], "--bridge") == 0) bridge = 1;
        if (strcmp(argv[a], "--reuse-open-url") == 0) reuse_open_url = 1;
    }

    char uidbuf[32], portbuf[32], pipe_launcher[4096], hiddenarg[8], stale[4096];
    const char *modearg = bridge ? "bridge" : "runtime";
    snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)st.st_uid);
    snprintf(portbuf, sizeof(portbuf), "%d", port);
    snprintf(pipe_launcher, sizeof(pipe_launcher), "/Library/Application Support/ClawdHome/BrowserLaunchers/%s/clawdhome-browser-pipe-launcher", pw->pw_name);
    snprintf(hiddenarg, sizeof(hiddenarg), "%d", hidden ? 1 : 0);

    if (reuse_open_url) {
        char profile_arg[4096];
        snprintf(profile_arg, sizeof(profile_arg), "--user-data-dir=%s", profile);

        char *open_args[20];
        int i = 0;
        open_args[i++] = "/bin/launchctl";
        open_args[i++] = "asuser";
        open_args[i++] = uidbuf;
        open_args[i++] = "/usr/bin/sudo";
        open_args[i++] = "-u";
        open_args[i++] = console->pw_name;
        open_args[i++] = "-H";
        open_args[i++] = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
        open_args[i++] = profile_arg;
        open_args[i++] = "--no-first-run";
        open_args[i++] = "--new-tab";
        open_args[i++] = (char *)target;
        open_args[i] = NULL;

        char msg[4096];
        snprintf(msg, sizeof(msg), "reuse-open-url strict-profile launchctl console=%s target=%s profile=%s", console->pw_name, target, profile);
        append_log(pw->pw_dir, msg);

        pid_t child = fork();
        if (child < 0) {
            append_log(pw->pw_dir, "fork launchctl reuse-open-url failed");
            perror("fork");
            return 76;
        }
        if (child == 0) {
            FILE *devnull = fopen("/dev/null", "r+");
            if (devnull) {
                int fd = fileno(devnull);
                dup2(fd, STDIN_FILENO);
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
            }
            execv(open_args[0], open_args);
            _exit(127);
        }
        return 0;
    }

    snprintf(stale, sizeof(stale), "%s/DevToolsActivePort", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonLock", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonCookie", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonSocket", profile);
    unlink(stale);

    if (access(pipe_launcher, X_OK) != 0) {
        append_log(pw->pw_dir, "pipe launcher missing, abort launch");
        fprintf(stderr, "ClawdHome pipe launcher missing. Reinstall browser tool in ClawdHome first.\\n");
        return 78;
    }

    char *args[24];
    int i = 0;
    args[i++] = "/bin/launchctl";
    args[i++] = "asuser";
    args[i++] = uidbuf;
    args[i++] = "/usr/bin/sudo";
    args[i++] = "-u";
    args[i++] = console->pw_name;
    args[i++] = "-H";
    args[i++] = pipe_launcher;
    args[i++] = profile;
    args[i++] = portbuf;
    args[i++] = (char *)target;
    args[i++] = hiddenarg;
    args[i++] = pw->pw_dir;
    args[i++] = (char *)modearg;
    args[i] = NULL;
    char pipe_msg[4096];
    snprintf(pipe_msg, sizeof(pipe_msg), "spawn pipe launchctl console=%s target=%s profile=%s port=%d hidden=%d mode=%s", console->pw_name, target, profile, port, hidden, modearg);
    append_log(pw->pw_dir, pipe_msg);
    pid_t child = fork();
    if (child < 0) {
        append_log(pw->pw_dir, "fork launchctl failed");
        perror("fork");
        return 76;
    }
    if (child == 0) {
        FILE *devnull = fopen("/dev/null", "r+");
        if (devnull) {
            int fd = fileno(devnull);
            dup2(fd, STDIN_FILENO);
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
        }
        execv(args[0], args);
        _exit(127);
    }
    return 0;
}
"""#
