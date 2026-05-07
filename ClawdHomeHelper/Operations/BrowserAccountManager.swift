// ClawdHomeHelper/Operations/BrowserAccountManager.swift
// Manages per-user Chrome profiles and the local CDP bridge session.

import Foundation
import SystemConfiguration

enum BrowserAccountError: LocalizedError {
    case invalidUsername
    case chromeNotFound
    case noConsoleSession
    case devToolsPortUnavailable
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
        case .devToolsPortUnavailable:
            return "Chrome 已启动，但未能获取 DevTools 调试端口"
        case .sessionMissing:
            return "浏览器账号尚未打开，请先在 ClawdHome 中打开浏览器账号"
        case .commandFailed(let message):
            return message
        }
    }
}

enum BrowserAccountManager {
    private static let chromeAppPath = "/Applications/Google Chrome.app"
    private static let openCLIReleaseAPIURL = "https://api.github.com/repos/jackwener/opencli/releases/latest"

    static func prepareForRuntimeInstall(username: String, logURL: URL? = nil) throws {
        appendInstallLog("→ 安装 ClawdHome 用户级浏览器工具\n", logURL: logURL)
        _ = try installTool(username: username)
        appendInstallLog("✓ ClawdHome 用户级浏览器工具已安装\n", logURL: logURL)

        if installWarmupCompleted(username: username) {
            appendInstallLog("✓ 浏览器安装预热已完成，本次跳过重复打开\n", logURL: logURL)
            return
        }

        guard isChromeInstalled() else {
            appendInstallLog("⚠ 未检测到 Google Chrome，已跳过浏览器预热。浏览器工具已安装，安装 Chrome 后可直接使用。\n", logURL: logURL)
            return
        }

        appendInstallLog("→ 首次打开用户级 Chrome 浏览器账号并写入 session\n", logURL: logURL)
        let context = try resolveContext(username: username)
        let extensionPath = try ensureOpenCLIBrowserBridgeExtensionInstalled(context: context, logURL: logURL)
        appendInstallLog("✓ OpenCLI Browser Bridge 扩展已安装：\(extensionPath)\n", logURL: logURL)
        var openedProfilePath = context.paths.profileDirectory.path
        do {
            let session = try open(username: username)
            openedProfilePath = session.profilePath
            Thread.sleep(forTimeInterval: 0.8)
            try closeWarmupBrowser(profilePath: openedProfilePath, logURL: logURL)
        } catch {
            appendInstallLog("⚠ 浏览器预热失败，先关闭已打开的 Chrome profile\n", logURL: logURL)
            try? closeWarmupBrowser(profilePath: openedProfilePath, logURL: logURL)
            throw error
        }
        try writeInstallWarmupMarker(username: username)
        appendInstallLog("✓ 浏览器账号已预热并关闭\n", logURL: logURL)
    }

    static func open(username: String) throws -> BrowserAccountSession {
        let context = try resolveContext(username: username)
        guard isChromeInstalled() else {
            throw BrowserAccountError.chromeNotFound
        }

        try prepareProfileDirectory(context.paths.profileDirectory.path, consoleUsername: context.consoleUsername)
        let extensionPath = try ensureOpenCLIBrowserBridgeExtensionInstalled(context: context, logURL: nil)
        try ensurePrivilegedBrowserLauncherInstalled(username: username)
        try closeBrowserProcessesMissingExtension(
            profilePath: context.paths.profileDirectory.path,
            extensionPath: extensionPath,
            logURL: nil
        )
        if let existingSession = readSession(username: username),
           isReachable(httpEndpoint: existingSession.httpEndpoint) {
            return existingSession
        }
        try removeStaleActivePortIfNeeded(context.paths.devToolsActivePortFile.path)

        let port = try findAvailableLocalPort()
        try spawnPipeBrowserLauncher(context: context, port: port, target: "about:blank", hidden: false)

        guard let activePort = waitForReachableEndpoint(port: port, timeout: 8) else {
            throw BrowserAccountError.devToolsPortUnavailable
        }

        let session = BrowserAccountSession(
            username: username,
            profilePath: context.paths.profileDirectory.path,
            devToolsActivePortPath: context.paths.devToolsActivePortFile.path,
            httpEndpoint: activePort.httpEndpoint,
            webSocketDebuggerURL: activePort.webSocketDebuggerURL,
            cdpPort: activePort.port,
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
            _ = try open(username: username)
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
                message: "用户不存在或用户名无效"
            )
        }

        let sessionPath = sessionPath(username: username)
        let toolPath = "/Users/\(username)/\(BrowserAccountPaths.toolExecutableRelativePath)"
        let session = readSession(username: username)
        let reachable = session.flatMap { isReachable(httpEndpoint: $0.httpEndpoint) } ?? false
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
            message: message
        )
    }

    static func reachableCDPEndpoint(username: String) -> String? {
        guard let session = readSession(username: username),
              isReachable(httpEndpoint: session.httpEndpoint) else {
            return nil
        }
        return session.httpEndpoint
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
        HermesConfigWriter.syncBrowserCDPEndpoint(username: username, endpoint: nil)
        let marker = installWarmupMarkerPath(username: username)
        if fm.fileExists(atPath: marker) {
            try fm.removeItem(atPath: marker)
        }
        return status(username: username)
    }

    private static func backupAndRemoveProfileIfNeeded(_ profile: String, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: profile) {
            let stamp = timestamp()
            let backup = "\(profile).backup-\(stamp)"
            try fm.moveItem(atPath: profile, toPath: backup)
        }
    }

    static func installTool(username: String) throws -> BrowserAccountStatus {
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

        for binDir in binDirs {
            try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try FilePermissionHelper.chownRecursive((binDir as NSString).deletingLastPathComponent, owner: username)
            try installBrowserShim(username: username, binDir: binDir, toolPath: toolPath)
            try installBrowserCommandWrappers(username: username, binDir: binDir, toolPath: toolPath)
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

    private static func browserBinDirectories(username: String) -> [String] {
        [
            "/Users/\(username)/\(BrowserAccountPaths.userLocalBinRelativePath)",
            npmGlobalBinDirectory(username: username),
        ]
    }

    private static func npmGlobalBinDirectory(username: String) -> String {
        "/Users/\(username)/\(BrowserAccountPaths.npmGlobalBinRelativePath)"
    }

    private static func ensureBrowserShellEnvironment(username: String, toolPath: String) throws {
        let browserCommand = "\(toolPath) open %s"
        let block = """

        # ClawdHome browser account
        export PATH="$HOME/.local/bin:$PATH"
        export BROWSER="\(browserCommand)"
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

        CLAWDHOME_BROWSER_HIDE=1 /usr/bin/env python3 "\(toolPath)" open "https://clawdhome.ai" >/dev/null 2>&1 || {
          echo "opencli-prelaunch=failed" >> "$LOG" 2>&1 || true
          echo "ClawdHome: 已尝试自动打开该用户的 ClawdHome Chrome，但启动失败。请先在 ClawdHome 中打开浏览器账号。" >&2
        }
        echo "opencli-prelaunch=done" >> "$LOG" 2>&1 || true

        port="${OPENCLI_DAEMON_PORT:-\(daemonPort)}"
        export OPENCLI_DAEMON_PORT="$port"
        if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
          echo "opencli-daemon=start port=$port" >> "$LOG" 2>&1 || true
          mkdir -p "$HOME/.opencli"
          /usr/bin/nohup /usr/bin/env node "\(daemonPath)" >> "$HOME/.opencli/clawdhome-daemon.log" 2>&1 &
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
            sleep 0.2
          done
        fi

        for _ in {1..40}; do
          status_json="$(/usr/bin/curl -fsS -H 'X-OpenCLI: 1' "http://127.0.0.1:$port/status" 2>/dev/null || true)"
          echo "$status_json" | /usr/bin/grep -q '"extensionConnected":true' && break
          sleep 0.5
        done

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
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FilePermissionHelper.chownRecursive(path, owner: consoleUsername)
        try FilePermissionHelper.chmod(path, mode: "700")
    }

    private static func openCLIDaemonPort(username: String) -> Int {
        let hash = username.utf8.reduce(UInt32(2166136261)) { partial, byte in
            (partial ^ UInt32(byte)) &* 16777619
        }
        return 20000 + Int(hash % 20000)
    }

    private static func ensureOpenCLIBrowserBridgeExtensionInstalled(context: Context, logURL: URL?) throws -> String {
        let extensionPath = context.paths.openCLIBrowserBridgeExtensionDirectory.path
        let manifestPath = "\(extensionPath)/manifest.json"
        let backgroundPath = "\(extensionPath)/dist/background.js"
        let markerPath = "\(extensionPath)/.clawdhome-extension.json"
        let daemonPort = openCLIDaemonPort(username: context.username)
        let fm = FileManager.default
        if fm.fileExists(atPath: manifestPath),
           openCLIExtensionMarkerDaemonPort(markerPath) == daemonPort,
           let background = try? String(contentsOfFile: backgroundPath, encoding: .utf8),
           background.contains("const DAEMON_PORT = \(daemonPort);") {
            return extensionPath
        }

        appendInstallLog("→ 下载 OpenCLI Browser Bridge 扩展\n", logURL: logURL)
        try? closeWarmupBrowser(profilePath: context.paths.profileDirectory.path, logURL: logURL)
        let asset = try latestOpenCLIExtensionAsset()
        let tmpRoot = "/tmp/clawdhome-opencli-extension-\(UUID().uuidString)"
        let zipPath = "\(tmpRoot)/extension.zip"
        let stagingPath = "\(tmpRoot)/staging"
        defer { try? fm.removeItem(atPath: tmpRoot) }

        try fm.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)
        try run("/usr/bin/curl", args: ["-fL", "--retry", "2", "-o", zipPath, asset.downloadURL])
        try validateZipEntries(zipPath: zipPath)
        try run("/usr/bin/unzip", args: ["-q", "-o", zipPath, "-d", stagingPath])

        guard fm.fileExists(atPath: "\(stagingPath)/manifest.json") else {
            throw BrowserAccountError.commandFailed("OpenCLI Browser Bridge 扩展包无效：缺少 manifest.json")
        }
        try patchOpenCLIExtensionDaemonPort(extensionPath: stagingPath, daemonPort: daemonPort)

        let parent = (extensionPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: extensionPath) {
            try fm.removeItem(atPath: extensionPath)
        }
        try fm.moveItem(atPath: stagingPath, toPath: extensionPath)
        let marker: [String: Any] = [
            "source": asset.downloadURL,
            "assetName": asset.name,
            "daemonPort": daemonPort,
            "installedAt": Date().timeIntervalSince1970,
        ]
        let markerData = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try markerData.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        try FilePermissionHelper.chownRecursive(parent, owner: context.consoleUsername)
        try FilePermissionHelper.chmodRecursive(parent, mode: "755")
        return extensionPath
    }

    private static func openCLIExtensionMarkerDaemonPort(_ markerPath: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: markerPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["daemonPort"] as? Int
    }

    private static func patchOpenCLIExtensionDaemonPort(extensionPath: String, daemonPort: Int) throws {
        let backgroundPath = "\(extensionPath)/dist/background.js"
        guard var background = try? String(contentsOfFile: backgroundPath, encoding: .utf8) else {
            throw BrowserAccountError.commandFailed("OpenCLI Browser Bridge 扩展包无效：缺少 dist/background.js")
        }
        guard background.contains("const DAEMON_PORT = 19825;")
                || background.range(of: #"const DAEMON_PORT = \d+;"#, options: .regularExpression) != nil else {
            throw BrowserAccountError.commandFailed("OpenCLI Browser Bridge 扩展包端口常量未找到")
        }
        background = background.replacingOccurrences(
            of: #"const DAEMON_PORT = \d+;"#,
            with: "const DAEMON_PORT = \(daemonPort);",
            options: .regularExpression
        )
        try background.write(toFile: backgroundPath, atomically: true, encoding: .utf8)
    }

    private struct OpenCLIExtensionAsset {
        let name: String
        let downloadURL: String
    }

    private static func latestOpenCLIExtensionAsset() throws -> OpenCLIExtensionAsset {
        let raw = try run("/usr/bin/curl", args: ["-fsSL", openCLIReleaseAPIURL])
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw BrowserAccountError.commandFailed("无法读取 OpenCLI release 信息：\(openCLIReleaseAPIURL)")
        }

        let candidates = assets.compactMap { asset -> OpenCLIExtensionAsset? in
            guard let name = asset["name"] as? String,
                  let downloadURL = asset["browser_download_url"] as? String,
                  name.lowercased().contains("extension"),
                  name.lowercased().hasSuffix(".zip") else {
                return nil
            }
            return OpenCLIExtensionAsset(name: name, downloadURL: downloadURL)
        }
        guard let selected = candidates.sorted(by: { $0.name < $1.name }).last else {
            throw BrowserAccountError.commandFailed("OpenCLI release 中未找到 Browser Bridge 扩展 zip")
        }
        return selected
    }

    private static func validateZipEntries(zipPath: String) throws {
        let listing = try run("/usr/bin/unzip", args: ["-Z1", zipPath])
        for rawEntry in listing.split(whereSeparator: \.isNewline) {
            let entry = String(rawEntry)
            if entry.hasPrefix("/")
                || entry.contains("../")
                || entry == ".."
                || entry.hasPrefix("..") {
                throw BrowserAccountError.commandFailed("OpenCLI Browser Bridge 扩展包包含非法路径：\(entry)")
            }
        }
    }

    private static func removeStaleActivePortIfNeeded(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let activePort = BrowserAccountActivePort.parse(raw),
              !isReachable(httpEndpoint: activePort.httpEndpoint) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func waitForActivePort(filePath: String, timeout: TimeInterval) -> BrowserAccountActivePort? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = try? String(contentsOfFile: filePath, encoding: .utf8),
               let activePort = BrowserAccountActivePort.parse(raw),
               isReachable(httpEndpoint: activePort.httpEndpoint) {
                return activePort
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private static func waitForReachableEndpoint(port: Int, timeout: TimeInterval) -> BrowserAccountActivePort? {
        let endpoint = "http://127.0.0.1:\(port)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReachable(httpEndpoint: endpoint) {
                let webSocketPath = webSocketPathForEndpoint(endpoint) ?? "/devtools/browser"
                return BrowserAccountActivePort(
                    port: port,
                    webSocketPath: webSocketPath.hasPrefix("/") ? webSocketPath : "/\(webSocketPath)"
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private static func webSocketPathForEndpoint(_ endpoint: String) -> String? {
        guard let url = URL(string: "\(endpoint)/json/version"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["webSocketDebuggerUrl"] as? String,
              let parsed = URL(string: raw),
              !parsed.path.isEmpty else {
            return nil
        }
        return parsed.path
    }

    private static func writeSession(_ session: BrowserAccountSession, username: String) throws {
        let path = sessionPath(username: username)
        let dir = (path as NSString).deletingLastPathComponent
        try prepareUserWritableBrowserDirectory(dir, username: username)
        let data = try JSONEncoder().encode(session)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FilePermissionHelper.chown(path, owner: username)
        try FilePermissionHelper.chmod(path, mode: "600")
        HermesConfigWriter.syncBrowserCDPEndpoint(username: username, endpoint: session.httpEndpoint)
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

    private static func closeBrowserProcessesMissingExtension(profilePath: String, extensionPath: String, logURL: URL?) throws {
        var matchedPIDs = browserProcessIDs(profilePath: profilePath, missingRequiredExtensionPath: extensionPath)
        guard !matchedPIDs.isEmpty else { return }
        appendInstallLog("→ 发现未加载 Browser Bridge 插件的 Chrome profile，准备重启：\(matchedPIDs.joined(separator: ", "))\n", logURL: logURL)
        for pid in matchedPIDs {
            _ = try? run("/bin/kill", args: ["-TERM", pid])
        }
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            matchedPIDs = browserProcessIDs(profilePath: profilePath, missingRequiredExtensionPath: extensionPath)
            if matchedPIDs.isEmpty {
                return
            }
        }
        for pid in matchedPIDs {
            _ = try? run("/bin/kill", args: ["-KILL", pid])
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private static func browserProcessIDs(profilePath: String) -> [String] {
        browserProcessIDs(profilePath: profilePath, missingRequiredExtensionPath: nil)
    }

    private static func browserProcessIDs(profilePath: String, missingRequiredExtensionPath: String?) -> [String] {
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
                if let missingRequiredExtensionPath,
                   text.contains("--enable-unsafe-extension-debugging") {
                    return nil
                }
                return text.split(separator: " ", maxSplits: 1).first.map(String.init)
            }
    }

    private static func isMainChromeProcessCommand(_ text: String) -> Bool {
        text.contains("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome ")
            || text.hasSuffix("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    private static func isReachable(httpEndpoint: String) -> Bool {
        guard let url = URL(string: "\(httpEndpoint)/json/version") else { return false }
        return (try? Data(contentsOf: url)) != nil
    }

    private static func findAvailableLocalPort() throws -> Int {
        let script = "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
        let raw = try run("/usr/bin/python3", args: ["-c", script]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(raw), port > 0, port <= 65535 else {
            throw BrowserAccountError.commandFailed("无法分配 Chrome 调试端口")
        }
        return port
    }

    private static func spawnPipeBrowserLauncher(context: Context, port: Int, target: String, hidden: Bool) throws {
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
            "\(port)",
            target,
            hidden ? "1" : "0",
            "/Users/\(context.username)",
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
        - `clawdhome-browser launch [url]`：底层启动命令，通常无需直接使用。
        - `clawdhome-browser title`：读取当前页面标题。
        - `clawdhome-browser extract-text`：提取当前页面正文。
        - `clawdhome-browser screenshot`：保存当前页面截图。

        常见浏览器打开命令已被接管：`open <url>`、`google-chrome <url>`、`chrome <url>`、`chromium <url>`、`xdg-open <url>` 会自动跳到 `clawdhome-browser open <url>`；无 URL 时默认打开 `https://clawdhome.ai`。

        如果该用户已安装 `opencli`，ClawdHome 会把真实入口保存在 `opencli.clawdhome-real`，并用 wrapper 接管 `opencli`：每次运行 OpenCLI 前会先自动执行 `clawdhome-browser open https://clawdhome.ai`，确保 Browser Bridge 有机会连接到该用户的 ClawdHome Chrome。

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
import base64
import datetime
import getpass
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SESSION_PATH = os.path.expanduser("~/.clawdhome/browser/session.json")
LEGACY_SESSION_PATH = os.path.expanduser("~/.openclaw/clawdhome-browser-session.json")
PROFILE_PATH = os.path.expanduser("~/.clawdhome/browser/profile")
LEGACY_PROFILE_PATH = os.path.expanduser("~/.openclaw/browser-profile")
ACTIVE_PORT_PATH = os.path.join(PROFILE_PATH, "DevToolsActivePort")
PROFILE_EXTENSIONS_DIR_NAME = "ClawdHomeExtensions"
OPENCLI_EXTENSION_DIR_NAME = "opencli-browser-bridge"
LAUNCHER_PATH = os.path.expanduser("~/.clawdhome/tools/clawdhome-browser/clawdhome-browser-launcher")
LEGACY_LAUNCHER_PATH = os.path.expanduser("~/.openclaw/tools/clawdhome-browser/clawdhome-browser-launcher")
CHROME_APP = "/Applications/Google Chrome.app"
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

def request_json(url, method="GET"):
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode("utf-8"))

def endpoint_reachable(endpoint):
    try:
        request_json(endpoint.rstrip("/") + "/json/version")
        debug_log(f"endpoint_reachable ok endpoint={endpoint!r}")
        return True
    except Exception as exc:
        debug_log(f"endpoint_reachable fail endpoint={endpoint!r} error={exc!r}")
        return False

def should_hide_browser():
    return os.environ.get("CLAWDHOME_BROWSER_HIDE") == "1"

def opencli_extension_path(profile_path):
    return os.path.join(profile_path, PROFILE_EXTENSIONS_DIR_NAME, OPENCLI_EXTENSION_DIR_NAME)

def opencli_extension_args(profile_path):
    extension_path = opencli_extension_path(profile_path)
    # The CLI runs as the managed user, but the Chrome profile lives under the
    # console user's Library. The managed user often cannot stat that path.
    # Always pass the required extension arg; helper/launcher perform privileged
    # installation and manifest validation.
    return [f"--disable-extensions-except={extension_path}", f"--load-extension={extension_path}"]

def chrome_processes_missing_extension(profile_path):
    extension_arg = f"--load-extension={opencli_extension_path(profile_path)}"
    try:
        result = subprocess.run(
            ["/bin/ps", "-ax", "-o", "pid=,command="],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception as exc:
        debug_log(f"chrome_processes_missing_extension ps_fail error={exc!r}")
        return []
    pids = []
    for line in result.stdout.splitlines():
        text = line.strip()
        if "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome " not in text:
            continue
        if f"--user-data-dir={profile_path}" not in text and profile_path not in text:
            continue
        if "--enable-unsafe-extension-debugging" in text:
            continue
        pid = text.split(" ", 1)[0]
        if pid.isdigit():
            pids.append(pid)
    return pids

def close_chrome_processes_missing_extension(profile_path):
    pids = chrome_processes_missing_extension(profile_path)
    if not pids:
        return
    debug_log(f"close_chrome_processes_missing_extension term pids={pids!r} profile={profile_path!r}")
    for pid in pids:
        subprocess.run(["/bin/kill", "-TERM", pid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 4
    while time.time() < deadline:
        time.sleep(0.25)
        if not chrome_processes_missing_extension(profile_path):
            return
    remaining = chrome_processes_missing_extension(profile_path)
    debug_log(f"close_chrome_processes_missing_extension kill pids={remaining!r} profile={profile_path!r}")
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

def parse_active_port(active_port_path=ACTIVE_PORT_PATH):
    if not os.path.exists(active_port_path):
        return None
    with open(active_port_path, "r", encoding="utf-8") as f:
        lines = [line.strip() for line in f.readlines() if line.strip()]
    if len(lines) < 2:
        return None
    try:
        port = int(lines[0])
    except ValueError:
        return None
    if port <= 0 or not lines[1].startswith("/"):
        return None
    return {
        "port": port,
        "httpEndpoint": f"http://127.0.0.1:{port}",
        "webSocketDebuggerURL": f"ws://127.0.0.1:{port}{lines[1]}",
    }

def save_session(active_port, profile_path=PROFILE_PATH, active_port_path=ACTIVE_PORT_PATH, base_session=None):
    os.makedirs(os.path.dirname(SESSION_PATH), exist_ok=True)
    session = {
        "username": (base_session or {}).get("username", os.environ.get("USER", "")),
        "profilePath": profile_path,
        "devToolsActivePortPath": active_port_path,
        "httpEndpoint": active_port["httpEndpoint"],
        "webSocketDebuggerURL": active_port["webSocketDebuggerURL"],
        "cdpPort": active_port["port"],
        "launchedAt": time.time(),
        "consoleUsername": (base_session or {}).get("consoleUsername", os.environ.get("USER", "")),
    }
    with open(SESSION_PATH, "w", encoding="utf-8") as f:
        json.dump(session, f, ensure_ascii=False, indent=2)
    os.chmod(SESSION_PATH, 0o600)
    return session

def current_session_reachable():
    session = load_session_if_present()
    if not session:
        return None
    if endpoint_reachable(session.get("httpEndpoint", "")):
        return session
    return None

def http_endpoint():
    return load_session()["httpEndpoint"].rstrip("/")

def list_pages():
    return [p for p in request_json(http_endpoint() + "/json/list") if p.get("type") == "page"]

def normalize_url_for_match(url):
    parsed = urllib.parse.urlparse(url)
    scheme = parsed.scheme.lower()
    netloc = parsed.netloc.lower()
    if scheme == "https" and netloc.endswith(":443"):
        netloc = netloc[:-4]
    if scheme == "http" and netloc.endswith(":80"):
        netloc = netloc[:-3]
    if netloc == "clawdhome.ai":
        netloc = "clawdhome.app"
    path = parsed.path or "/"
    if path != "/" and path.endswith("/"):
        path = path.rstrip("/")
    return urllib.parse.urlunparse((scheme, netloc, path, "", parsed.query, ""))

def find_open_page(url):
    wanted = normalize_url_for_match(url)
    for page in list_pages():
        current = page.get("url", "")
        if current and normalize_url_for_match(current) == wanted:
            return page
    return None

def activate_page(page):
    target_id = page.get("id")
    if not target_id:
        return
    try:
        urllib.request.urlopen(http_endpoint() + "/json/activate/" + urllib.parse.quote(target_id, safe=""), timeout=2).read()
    except Exception:
        pass

def ensure_page():
    pages = list_pages()
    if pages:
        return pages[0]
    return request_json(http_endpoint() + "/json/new?about%3Ablank", method="PUT")

class CDP:
    def __init__(self, websocket_url):
        parsed = urllib.parse.urlparse(websocket_url)
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port
        self.path = parsed.path
        self.sock = socket.create_connection((self.host, self.port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode("ascii"))
        response = self.sock.recv(4096)
        if b" 101 " not in response:
            raise RuntimeError("CDP WebSocket handshake failed")
        self.next_id = 1

    def send(self, method, params=None):
        msg_id = self.next_id
        self.next_id += 1
        payload = json.dumps({"id": msg_id, "method": method, "params": params or {}}).encode("utf-8")
        self._send_frame(payload)
        while True:
            data = json.loads(self._recv_frame().decode("utf-8"))
            if data.get("id") == msg_id:
                if "error" in data:
                    raise RuntimeError(data["error"].get("message", str(data["error"])))
                return data.get("result", {})

    def _send_frame(self, payload):
        header = bytearray([0x81])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + masked)

    def _recv_exact(self, n):
        chunks = bytearray()
        while len(chunks) < n:
            chunk = self.sock.recv(n - len(chunks))
            if not chunk:
                raise RuntimeError("CDP WebSocket closed")
            chunks.extend(chunk)
        return bytes(chunks)

    def _recv_frame(self):
        first, second = self._recv_exact(2)
        opcode = first & 0x0F
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        masked = second & 0x80
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 8:
            raise RuntimeError("CDP WebSocket closed")
        return payload

def page_client():
    page = ensure_page()
    ws = page.get("webSocketDebuggerUrl")
    if not ws:
        fail("当前没有可控制的页面。")
    return CDP(ws)

def command_status():
    debug_log(f"command_status argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r}")
    session = load_session()
    try:
        version = request_json(session["httpEndpoint"].rstrip("/") + "/json/version")
    except Exception:
        print(json.dumps({
            "ok": False,
            "endpoint": session.get("httpEndpoint", ""),
            "profilePath": session.get("profilePath", ""),
            "message": "已记录浏览器账号，但当前 Chrome 不可连接"
        }, ensure_ascii=False, indent=2))
        return
    print(json.dumps({
        "ok": True,
        "endpoint": session["httpEndpoint"],
        "browser": version.get("Browser", ""),
        "profilePath": session.get("profilePath", "")
    }, ensure_ascii=False, indent=2))

def command_launch(url=None):
    debug_log(f"command_launch start url={url!r} argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r} hide={should_hide_browser()}")
    session = current_session_reachable()
    if session:
        try:
            opencli_extension_args(session.get("profilePath", PROFILE_PATH))
            close_chrome_processes_missing_extension(session.get("profilePath", PROFILE_PATH))
        except SystemExit:
            raise
        session = current_session_reachable()
        if not session:
            debug_log("command_launch existing_session_closed_for_missing_extension")
        else:
            debug_log(f"command_launch existing_session_still_reachable endpoint={session.get('httpEndpoint')!r}")
    if session:
        debug_log(f"command_launch existing_session_reachable endpoint={session.get('httpEndpoint')!r}")
        if url:
            command_open(url)
        else:
            print(json.dumps({
                "ok": True,
                "endpoint": session["httpEndpoint"],
                "profilePath": session.get("profilePath", PROFILE_PATH),
                "message": "浏览器账号已运行"
            }, ensure_ascii=False, indent=2))
        return

    existing_session = load_session_if_present()
    debug_log(f"command_launch existing_session={bool(existing_session)}")
    launch_profile_path = (existing_session or {}).get("profilePath", PROFILE_PATH)
    launch_active_port_path = (existing_session or {}).get(
        "devToolsActivePortPath",
        os.path.join(launch_profile_path, "DevToolsActivePort"),
    )
    launch_port = int((existing_session or {}).get("cdpPort", 0) or 0)

    if not existing_session and launch_profile_path == PROFILE_PATH:
        fail("浏览器账号尚未初始化。请先在 ClawdHome 中点击一次“打开浏览器账号”，之后该用户命令会自动复用并拉起它。")

    if not os.path.exists(CHROME_APP):
        fail("未找到 Google Chrome，请先安装 Chrome。")

    if launch_profile_path == PROFILE_PATH:
        os.makedirs(launch_profile_path, exist_ok=True)
    if os.path.exists(launch_active_port_path) and os.access(launch_active_port_path, os.W_OK):
        try:
            os.remove(launch_active_port_path)
        except OSError:
            pass

    target = url or "about:blank"
    port_arg = str(launch_port) if launch_port > 0 else "0"
    launcher_path = resolve_launcher_path() if existing_session else None
    if existing_session and launcher_path:
        args = [launcher_path, target]
        if should_hide_browser():
            args.append("--hidden")
        debug_log(f"command_launch route=privileged-launcher args={args!r} profile={launch_profile_path!r} port={launch_port}")
    else:
        args = [
        "/usr/bin/open", "-na", "Google Chrome",
        ]
        if should_hide_browser():
            args.append("-j")
        args += [
        "--args",
        f"--user-data-dir={launch_profile_path}",
        "--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={port_arg}",
        "--no-first-run",
        ] + opencli_extension_args(launch_profile_path) + [
            "--new-window",
            target,
        ]
        debug_log(f"command_launch route=direct-open-fallback args={args!r} profile={launch_profile_path!r} port={launch_port}")
    try:
        result = subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        debug_log(f"command_launch subprocess ok stdout={result.stdout.strip()!r} stderr={result.stderr.strip()!r}")
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        debug_log(f"command_launch subprocess fail returncode={exc.returncode} stdout={(exc.stdout or '').strip()!r} stderr={(exc.stderr or '').strip()!r}")
        fail("当前用户直接启动 GUI Chrome 失败。该用户可能没有 macOS 图形会话。" + (f"\n{detail}" if detail else ""))

    deadline = time.time() + 8
    while time.time() < deadline:
        active_port = None
        if launch_port > 0:
            endpoint = f"http://127.0.0.1:{launch_port}"
            if endpoint_reachable(endpoint):
                try:
                    version = request_json(endpoint + "/json/version")
                    ws = version.get("webSocketDebuggerUrl", "")
                    ws_path = urllib.parse.urlparse(ws).path if ws else "/devtools/browser"
                except Exception:
                    ws_path = "/devtools/browser"
                active_port = {
                    "port": launch_port,
                    "httpEndpoint": endpoint,
                    "webSocketDebuggerURL": f"ws://127.0.0.1:{launch_port}{ws_path}",
                }
        else:
            active_port = parse_active_port(launch_active_port_path)
        if active_port and endpoint_reachable(active_port["httpEndpoint"]):
            session = save_session(active_port, launch_profile_path, launch_active_port_path, existing_session)
            hide_browser_if_requested()
            debug_log(f"command_launch success endpoint={session['httpEndpoint']!r} profile={session['profilePath']!r}")
            print(json.dumps({
                "ok": True,
                "endpoint": session["httpEndpoint"],
                "profilePath": session["profilePath"],
                "message": "浏览器账号已启动"
            }, ensure_ascii=False, indent=2))
            return
        time.sleep(0.2)

    fail("Chrome 已尝试启动，但未能读取 DevToolsActivePort。该用户可能没有可用 GUI 会话，或 Chrome 启动被 macOS 拒绝。")

def command_open(url):
    debug_log(f"command_open start url={url!r} argv={sys.argv!r} user={os.environ.get('USER')!r} path={os.environ.get('PATH')!r}")
    if not url:
        fail("用法: clawdhome-browser open <url>")
    session = current_session_reachable()
    if session:
        opencli_extension_args(session.get("profilePath", PROFILE_PATH))
        close_chrome_processes_missing_extension(session.get("profilePath", PROFILE_PATH))
        session = current_session_reachable()
    if not session:
        debug_log("command_open route=launch because session missing/unreachable")
        command_launch(url)
        return
    existing_page = find_open_page(url)
    if existing_page:
        debug_log(f"command_open route=activate existing_page={existing_page.get('id')!r} url={existing_page.get('url')!r}")
        activate_page(existing_page)
        hide_browser_if_requested()
        print(url)
        return
    encoded = urllib.parse.quote(url, safe="")
    request_json(http_endpoint() + "/json/new?" + encoded, method="PUT")
    debug_log(f"command_open route=new_tab url={url!r}")
    hide_browser_if_requested()
    print(url)

def command_eval(expression):
    client = page_client()
    result = client.send("Runtime.evaluate", {
        "expression": expression,
        "returnByValue": True,
        "awaitPromise": True
    })
    value = result.get("result", {}).get("value", "")
    print(value if value is not None else "")

def command_screenshot():
    client = page_client()
    client.send("Page.enable")
    result = client.send("Page.captureScreenshot", {"format": "png", "fromSurface": True})
    raw = base64.b64decode(result["data"])
    name = "clawdhome-browser-screenshot-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".png"
    path = os.path.abspath(name)
    with open(path, "wb") as f:
        f.write(raw)
    print(path)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    debug_log(f"main cmd={cmd!r} argv={sys.argv!r} cwd={os.getcwd()!r} uid={os.getuid()} euid={os.geteuid()} user={os.environ.get('USER')!r}")
    if cmd == "status":
        command_status()
    elif cmd == "launch":
        command_launch(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "open":
        command_open(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "title":
        command_eval("document.title")
    elif cmd == "extract-text":
        command_eval("document.body ? document.body.innerText : ''")
    elif cmd == "screenshot":
        command_screenshot()
    else:
        fail("用法: clawdhome-browser status|launch [url]|open <url>|title|extract-text|screenshot")

if __name__ == "__main__":
    main()
"""#

private let browserPipeLauncherScript = #"""
#!/usr/bin/env python3
import json
import os
import select
import signal
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

def send(fd, msg_id, method, params=None):
    payload = json.dumps({"id": msg_id, "method": method, "params": params or {}}).encode("utf-8") + b"\0"
    os.write(fd, payload)

def recv(fd, target_id, timeout=30):
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if fd not in ready:
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            raise RuntimeError("Chrome debugging pipe closed")
        buf += chunk
        while b"\0" in buf:
            raw, buf = buf.split(b"\0", 1)
            if not raw:
                continue
            msg = json.loads(raw.decode("utf-8"))
            if msg.get("id") == target_id:
                if "error" in msg:
                    raise RuntimeError(msg["error"].get("message", str(msg["error"])))
                return msg.get("result", {})
    raise TimeoutError("Chrome debugging pipe timed out")

def main():
    if len(sys.argv) < 5:
        print("usage: clawdhome-browser-pipe-launcher <profile> <port> <target> <hidden> <log-home>", file=sys.stderr)
        return 64
    profile, port, target, hidden = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
    log_home = sys.argv[5] if len(sys.argv) > 5 else os.path.expanduser("~")
    extension = os.path.join(profile, "ClawdHomeExtensions", "opencli-browser-bridge")
    manifest = os.path.join(extension, "manifest.json")
    if not os.path.exists(manifest):
        log(log_home, f"extension manifest missing path={manifest!r}")
        return 77

    in_r, in_w = os.pipe()
    out_r, out_w = os.pipe()
    def setup_child():
        os.dup2(in_r, 3)
        os.dup2(out_w, 4)
        for fd in (in_r, in_w, out_r, out_w):
            try:
                if fd not in (3, 4):
                    os.close(fd)
            except OSError:
                pass

    args = [
        CHROME,
        f"--user-data-dir={profile}",
        "--remote-debugging-pipe",
        "--enable-unsafe-extension-debugging",
        "--remote-debugging-address=127.0.0.1",
        f"--remote-debugging-port={port}",
        "--no-first-run",
        "--new-window",
        target or "about:blank",
    ]
    log(log_home, f"exec chrome profile={profile!r} port={port!r} target={target!r}")
    proc = subprocess.Popen(
        args,
        pass_fds=(3, 4),
        preexec_fn=setup_child,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.close(in_r)
    os.close(out_w)
    try:
        send(in_w, 1, "Browser.getVersion")
        recv(out_r, 1)
        send(in_w, 2, "Extensions.loadUnpacked", {"path": extension})
        loaded = recv(out_r, 2)
        log(log_home, f"extension loaded id={loaded.get('id')!r}")
        if hidden:
            subprocess.run(
                ["/usr/bin/osascript", "-e", 'tell application "Google Chrome" to hide'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        return proc.wait()
    except Exception as exc:
        log(log_home, f"failed error={exc!r}")
        try:
            proc.terminate()
        except Exception:
            pass
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
    int hidden = argc > 2 && strcmp(argv[2], "--hidden") == 0;

    char uidbuf[32], portbuf[32], extensionmanifest[4096], pipe_launcher[4096], hiddenarg[8], stale[4096];
    snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)st.st_uid);
    snprintf(portbuf, sizeof(portbuf), "%d", port);
    snprintf(extensionmanifest, sizeof(extensionmanifest), "%s/ClawdHomeExtensions/opencli-browser-bridge/manifest.json", profile);
    snprintf(pipe_launcher, sizeof(pipe_launcher), "/Library/Application Support/ClawdHome/BrowserLaunchers/%s/clawdhome-browser-pipe-launcher", pw->pw_name);
    snprintf(hiddenarg, sizeof(hiddenarg), "%d", hidden ? 1 : 0);

    snprintf(stale, sizeof(stale), "%s/DevToolsActivePort", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonLock", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonCookie", profile);
    unlink(stale);
    snprintf(stale, sizeof(stale), "%s/SingletonSocket", profile);
    unlink(stale);

    if (access(extensionmanifest, R_OK) != 0) {
        append_log(pw->pw_dir, "opencli extension manifest missing, abort launch");
        fprintf(stderr, "OpenCLI Browser Bridge extension missing. Reinstall browser tool in ClawdHome first.\\n");
        return 77;
    }
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
    args[i] = NULL;
    char msg[4096];
    snprintf(msg, sizeof(msg), "spawn pipe launchctl console=%s target=%s profile=%s port=%d hidden=%d", console->pw_name, target, profile, port, hidden);
    append_log(pw->pw_dir, msg);
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
