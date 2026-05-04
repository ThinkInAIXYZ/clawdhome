// ClawdHome/ClawdHomeApp.swift

import AppKit
import Observation
import SwiftUI

final class ClawdHomeAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}

@main
struct ClawdHomeApp: App {
    @NSApplicationDelegateAdaptor(ClawdHomeAppDelegate.self) private var appDelegate
    @State private var helperClient: HelperClient
    @State private var shrimpPool: ShrimpPool
    @State private var updater = UpdateChecker()
    @State private var modelStore = GlobalModelStore()
    @State private var keychainStore = ProviderKeychainStore()
    @State private var gatewayHub = GatewayHub()
    @State private var lockStore = AppLockStore()
    @State private var maintenanceWindowRegistry = MaintenanceWindowRegistry()
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue

    init() {
        // 强制忽略上次会话窗口恢复，确保每次启动从全新窗口开始
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let client = HelperClient()
        _helperClient = State(initialValue: client)
        _shrimpPool   = State(initialValue: ShrimpPool(helperClient: client))
    }

    var body: some Scene {
        let appLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system
        WindowGroup {
            ContentView()
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
                .task { await maintainConnection() }
                .task { await updater.runOpenclawAutoCheckLoop() }
                .task { await updater.refreshAppUpdateState(helperClient: helperClient) }
                .task { await MainActor.run { shrimpPool.start() } }
                .onAppear { modelStore.load() }
                .task {
                    // 主界面稳定后延迟 2s 预热角色中心 WebView，用户无感知
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        RoleMarketWebViewCache.shared.preloadIfNeeded()
                    }
                }
        }
        .windowStyle(.titleBar)
        // .contentSize 会随 inspector 列宽变化不断触发窗口 resize，造成约束死循环崩溃
        // .automatic 让窗口可自由拖动，列宽只约束 minimum，不产生反馈
        .windowResizability(.automatic)
        .defaultSize(
            width: UserDetailWindowLayout.mainWindowDefaultWidth,
            height: UserDetailWindowLayout.detailWindowDefaultHeight
        )
        .commands {
            // 隐藏主窗口L10n.k("clawd_home_app.text_ededdc48", fallback: "新建窗口")菜单项（单主窗口）
            CommandGroup(replacing: .newItem) { }
        }

        // 龙虾详情独立窗口：每个 username 唯一，重复触发时置前
        WindowGroup(id: "claw-detail", for: String.self) { $username in
            if let name = username {
                ClawDetailWindow(username: name)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(updater)
                    .environment(modelStore)
                    .environment(keychainStore)
                    .environment(gatewayHub)
                    .environment(maintenanceWindowRegistry)
                    .environment(\.locale, appLanguage.locale)
                    .background(ClawDetailWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(
            width: UserDetailWindowLayout.mainWindowDefaultWidth,
            height: UserDetailWindowLayout.detailWindowDefaultHeight
        )

        WindowGroup(id: "user-init-wizard", for: String.self) { $username in
            if let name = username {
                UserInitWizardWindow(username: name)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(updater)
                    .environment(modelStore)
                    .environment(keychainStore)
                    .environment(gatewayHub)
                    .environment(maintenanceWindowRegistry)
                    .environment(\.locale, appLanguage.locale)
                    .background(UserInitWizardWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 720)

        WindowGroup(id: "channel-onboarding", for: String.self) { $payload in
            ChannelOnboardingWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 520)

        WindowGroup(id: "maintenance-terminal", for: String.self) { $payload in
            MaintenanceTerminalWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 860, height: 560)

        WindowGroup(id: "maintenance-files", for: String.self) { $payload in
            MaintenanceFilesWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 960, height: 640)

        WindowGroup(id: "maintenance-processes", for: String.self) { $payload in
            MaintenanceProcessesWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 920, height: 620)

        WindowGroup(id: "clone-claw", for: String.self) { $sourceUsername in
            if let username = sourceUsername {
                CloneClawSheet(sourceUsername: username)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 640, height: 560)
    }

    /// 首次连接，断开后每 5 秒自动重试
    private func maintainConnection() async {
        helperClient.connect()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !helperClient.isConnected {
                helperClient.connect()
            }
        }
    }
}

// MARK: - 通用维护终端窗口模型

@MainActor
@Observable
final class MaintenanceWindowRegistry {
    private var nextIndexByUser: [String: Int] = [:]

    func makePayload(
        username: String,
        title: String,
        command: [String],
        engine: MaintenanceTerminalEngine? = nil,
        completionToken: String? = nil,
        completionContext: String? = nil
    ) -> String {
        let next = (nextIndexByUser[username] ?? 0) + 1
        nextIndexByUser[username] = next
        let req = MaintenanceTerminalWindowRequest(
            token: UUID().uuidString,
            username: username,
            title: title,
            command: MaintenanceTerminalCommandPolicy.commandForRuntime(
                command: command,
                runtime: engine?.managedHomeRuntime
            ),
            index: next,
            engine: engine,
            completionToken: completionToken,
            completionContext: completionContext
        )
        return req.payload
    }

    func makeToolWindowPayload(
        username: String,
        title: String,
        kind: MaintenanceToolWindowKind,
        scope: UserFilesScope = .home,
        initialRelativePath: String? = nil
    ) -> String {
        let next = (nextIndexByUser[username] ?? 0) + 1
        nextIndexByUser[username] = next
        let req = MaintenanceToolWindowRequest(
            token: UUID().uuidString,
            username: username,
            title: title,
            kind: kind,
            scope: scope,
            initialRelativePath: initialRelativePath,
            index: next
        )
        return req.payload
    }
}

/// 终端所属的 Agent 引擎；未指定时不显示任何引擎相关的快捷指令菜单
enum MaintenanceTerminalEngine: String, Codable {
    case openclaw
    case hermes

    var managedHomeRuntime: ManagedHomeRuntime {
        switch self {
        case .openclaw:
            return .openclaw
        case .hermes:
            return .hermes
        }
    }
}

struct MaintenanceTerminalWindowRequest: Codable {
    let token: String
    let username: String
    let title: String
    let command: [String]
    let index: Int
    let engine: MaintenanceTerminalEngine?
    let completionToken: String?
    let completionContext: String?

    var payload: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    init(
        token: String,
        username: String,
        title: String,
        command: [String],
        index: Int,
        engine: MaintenanceTerminalEngine? = nil,
        completionToken: String? = nil,
        completionContext: String? = nil
    ) {
        self.token = token
        self.username = username
        self.title = title
        self.command = command
        self.index = index
        self.engine = engine
        self.completionToken = completionToken
        self.completionContext = completionContext
    }

    init?(payload: String?) {
        guard let payload,
              let data = Data(base64Encoded: payload),
              let req = try? JSONDecoder().decode(MaintenanceTerminalWindowRequest.self, from: data) else {
            return nil
        }
        self = req
    }
}

enum MaintenanceToolWindowKind: String, Codable {
    case files
    case processes
}

struct MaintenanceToolWindowRequest: Codable {
    let token: String
    let username: String
    let title: String
    let kind: MaintenanceToolWindowKind
    let scope: UserFilesScope
    let initialRelativePath: String?
    let index: Int

    var payload: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    init(
        token: String,
        username: String,
        title: String,
        kind: MaintenanceToolWindowKind,
        scope: UserFilesScope = .home,
        initialRelativePath: String? = nil,
        index: Int
    ) {
        self.token = token
        self.username = username
        self.title = title
        self.kind = kind
        self.scope = scope
        self.initialRelativePath = initialRelativePath
        self.index = index
    }

    init?(payload: String?) {
        guard let payload,
              let data = Data(base64Encoded: payload),
              let req = try? JSONDecoder().decode(MaintenanceToolWindowRequest.self, from: data) else {
            return nil
        }
        self = req
    }
}

extension Notification.Name {
    static let maintenanceTerminalWindowClosed = Notification.Name("MaintenanceTerminalWindowClosed")
    static let channelOnboardingAutoDetected = Notification.Name("ChannelOnboardingAutoDetected")
}

// MARK: - 通用维护终端窗口

private struct MaintenanceTerminalWindow: View {
    let payload: String?

    var body: some View {
        if let request = MaintenanceTerminalWindowRequest(payload: payload) {
            MaintenanceTerminalWindowContent(request: request)
        } else {
            ContentUnavailableView(
                L10n.k("app.maintenance.invalid_params", fallback: "维护终端参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.maintenance.invalid_params.desc", fallback: "请从虾详情页或初始化向导重新打开维护终端。"))
            )
        }
    }
}

private struct MaintenanceFilesWindow: View {
    let payload: String?
    @Environment(ShrimpPool.self) private var pool

    var body: some View {
        if let request = MaintenanceToolWindowRequest(payload: payload),
           request.kind == .files,
           let user = pool.users.first(where: { $0.username == request.username }) {
            NavigationStack {
                UserFilesView(
                    users: [user],
                    preselectedUser: user,
                    scope: request.scope,
                    initialRelativePath: request.initialRelativePath
                )
            }
            .navigationTitle(request.title)
        } else {
            ContentUnavailableView(
                L10n.k("app.maintenance.invalid_params", fallback: "维护终端参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.maintenance.invalid_params.desc", fallback: "请从虾详情页或初始化向导重新打开维护终端。"))
            )
        }
    }
}

private struct MaintenanceProcessesWindow: View {
    let payload: String?
    @Environment(ShrimpPool.self) private var pool

    var body: some View {
        if let request = MaintenanceToolWindowRequest(payload: payload),
           request.kind == .processes,
           pool.users.contains(where: { $0.username == request.username }) {
            NavigationStack {
                ProcessTabView(username: request.username)
            }
            .navigationTitle(request.title)
        } else {
            ContentUnavailableView(
                L10n.k("app.maintenance.invalid_params", fallback: "维护终端参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.maintenance.invalid_params.desc", fallback: "请从虾详情页或初始化向导重新打开维护终端。"))
            )
        }
    }
}

private struct MaintenanceTerminalWindowContent: View {
    private struct OutputSearchMatch: Identifiable {
        let id: Int
        let range: NSRange
        let preview: String
    }

    let request: MaintenanceTerminalWindowRequest

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(ShrimpPool.self) private var pool
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()
    @State private var outputBuffer = ""
    @State private var didStart = false
    @State private var didPostCloseNotification = false
    @State private var didAutoCloseOnConfigureComplete = false
    @State private var terminalTheme: MaintenanceTerminalTheme = .system
    @State private var searchText = ""
    @State private var searchMatches: [OutputSearchMatch] = []
    @State private var selectedSearchMatchIndex = 0
    @State private var outputRateWindowStartedAt = Date()
    @State private var outputBytesInRateWindow = 0
    @State private var droppedOutputBytes = 0
    @State private var didNotifyRateLimit = false
    @AppStorage("app.maintenance.outputRateLimitEnabled") private var outputRateLimitEnabled = true
    @AppStorage("app.maintenance.fontSize") private var terminalFontSize = 12.0

    private let waitingThreshold: TimeInterval = 8
    private let outputRateLimitBytesPerSecond = 80 * 1024
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var windowTitle: String {
        L10n.f(
            "app.maintenance.window.title",
            fallback: L10n.k("clawd_home_app.arg_num", fallback: "@%@ · 维护窗口 #%d"),
            request.username,
            request.index
        )
    }
    private var isRunning: Bool { didStart && exitCode == nil }
    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }
    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
    private var isModelConfigureCommand: Bool {
        request.command.count >= 4
            && request.command[0] == "openclaw"
            && request.command[1] == "configure"
            && (request.command[2] == "--section" || request.command[2] == "--selection")
            && request.command[3] == "model"
    }
    private var sanitizedOutput: String {
        stripANSIEscapeSequences(outputBuffer)
    }
    private var latestAuthorizeURL: URL? {
        extractURLs(from: sanitizedOutput).last(where: { url in
            let abs = url.absoluteString.lowercased()
            return abs.contains("github.com/login/device") || abs.contains("/oauth/authorize")
        })
    }
    private var latestDeviceCode: String? {
        let pattern = #"(?mi)^\s*Code:\s*([A-Z0-9-]{4,})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = sanitizedOutput as NSString
        let all = regex.matches(in: sanitizedOutput, range: NSRange(location: 0, length: ns.length))
        guard let last = all.last, last.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: last.range(at: 1))
    }
    private var selectedSearchMatch: OutputSearchMatch? {
        guard selectedSearchMatchIndex >= 0, selectedSearchMatchIndex < searchMatches.count else { return nil }
        return searchMatches[selectedSearchMatchIndex]
    }
    private var searchSummaryText: String {
        guard !searchMatches.isEmpty else {
            return L10n.k("app.maintenance.search.no_hits", fallback: "0 项")
        }
        return String(
            format: L10n.k("app.maintenance.search.hit_count", fallback: "%d/%d"),
            selectedSearchMatchIndex + 1,
            searchMatches.count
        )
    }
    private var droppedOutputText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        let dropped = formatter.string(fromByteCount: Int64(max(0, droppedOutputBytes)))
        return L10n.f("app.maintenance.output_limited", fallback: "已限流（丢弃 %@）", dropped)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 10) {
            if isRunning {
                Label(
                    isWaitingInput
                        ? L10n.k("app.maintenance.status.running_waiting", fallback: "运行中（等待输入）")
                        : L10n.k("app.maintenance.status.running", fallback: "运行中"),
                    systemImage: isWaitingInput ? "hourglass" : "play.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(L10n.k("app.maintenance.status.exited", fallback: "已退出"), systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.f("app.maintenance.elapsed", fallback: "耗时 %@", elapsedText))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.k("common.action.interrupt", fallback: "中断")) { terminalControl.sendInterrupt() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!isRunning)
            Button(L10n.k("common.action.rerun", fallback: "重跑")) { startRun() }
                .keyboardShortcut("r", modifiers: .command)

            Spacer(minLength: 0)

            actionsMenu
            settingsMenu
            quickCommandMenu
        }
    }

    @ViewBuilder
    private var actionsMenu: some View {
        Menu {
            Button(L10n.k("common.action.clone_terminal", fallback: "复制终端")) {
                cloneTerminalWindow()
            }
            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) {
                copyTerminalOutput()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.k("common.action.clear_screen", fallback: "清屏")) {
                clearTerminalOutput()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(outputBuffer.isEmpty)

            Divider()

            Button(L10n.k("common.action.export_output", fallback: "导出输出…")) {
                exportTerminalOutput()
            }
            Button {
                outputRateLimitEnabled.toggle()
            } label: {
                if outputRateLimitEnabled {
                    Label(L10n.k("app.maintenance.output_rate_limit_enabled", fallback: "限流输出：开"), systemImage: "checkmark")
                } else {
                    Text(L10n.k("app.maintenance.output_rate_limit_disabled", fallback: "限流输出：关"))
                }
            }

            Divider()

            Button {
                terminalControl.sendLine("cd ~/clawdhome_shared/private/")
                statusText = L10n.k("app.maintenance.shared.cd_done", fallback: "已切换到共享目录：~/clawdhome_shared/private/")
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.cd_private", fallback: "终端进入 private 目录"),
                    systemImage: "terminal"
                )
            }

            Button {
                let payload = maintenanceWindowRegistry.makeToolWindowPayload(
                    username: request.username,
                    title: L10n.k("app.maintenance.shared.files_title", fallback: "共享文件夹（private）"),
                    kind: .files,
                    scope: .home,
                    initialRelativePath: "clawdhome_shared/private"
                )
                openWindow(id: "maintenance-files", value: payload)
                statusText = L10n.k("app.maintenance.shared.files_opened", fallback: "已打开文件管理并定位到共享目录。")
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.open_files", fallback: "文件管理打开 private 目录"),
                    systemImage: "folder"
                )
            }

            Button {
                let fm = FileManager.default
                let primaryPath = "/Users/Shared/ClawdHome/vaults/\(request.username)"
                let legacyPath = "/Users/\(request.username)/clawdhome_shared/private"
                let candidates = [primaryPath, legacyPath, "/Users/Shared/ClawdHome/vaults", "/Users/Shared/ClawdHome"]

                var opened = false
                for path in candidates where fm.fileExists(atPath: path) {
                    if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                        opened = true
                        break
                    }
                }

                statusText = opened
                    ? L10n.k("app.maintenance.shared.finder_opened", fallback: "已在 Finder 打开共享目录。")
                    : L10n.k("app.maintenance.shared.finder_failed", fallback: "无法打开 Finder 目录。")
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.open_finder", fallback: "在 Finder 打开 private 目录"),
                    systemImage: "folder.badge.gearshape"
                )
            }
        } label: {
            Label(L10n.k("app.maintenance.actions_menu", fallback: "操作"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.k("app.maintenance.search.placeholder", fallback: "搜索输出"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 220)
                .onSubmit {
                    jumpToSearchMatch(direction: .forward)
                }
                .onChange(of: searchText) { _, _ in
                    rebuildSearchMatches()
                }
            Button {
                jumpToSearchMatch(direction: .backward)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(searchMatches.isEmpty)
            Button {
                jumpToSearchMatch(direction: .forward)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: .command)
            .disabled(searchMatches.isEmpty)
            Text(searchSummaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let selectedSearchMatch {
                Text(selectedSearchMatch.preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if outputRateLimitEnabled, droppedOutputBytes > 0 {
                Text(droppedOutputText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Section(L10n.k("app.maintenance.font.section", fallback: "字号")) {
                Button(L10n.k("app.maintenance.font.decrease", fallback: "减小字号")) {
                    terminalFontSize = max(10, terminalFontSize - 1)
                }
                .disabled(terminalFontSize <= 10)
                Button(L10n.k("app.maintenance.font.increase", fallback: "增大字号")) {
                    terminalFontSize = min(16, terminalFontSize + 1)
                }
                .disabled(terminalFontSize >= 16)
                Button(String(format: L10n.k("app.maintenance.font.reset_to", fallback: "恢复默认（%.0f）"), 12.0)) {
                    terminalFontSize = 12
                }
                .disabled(terminalFontSize == 12)
            }
            Section(L10n.k("app.maintenance.theme.section", fallback: "背景")) {
                ForEach(MaintenanceTerminalTheme.allCases) { theme in
                    Button {
                        terminalTheme = theme
                    } label: {
                        if theme == terminalTheme {
                            Label(theme.title, systemImage: "checkmark")
                        } else {
                            Text(theme.title)
                        }
                    }
                }
            }
        } label: {
            Label(L10n.k("app.maintenance.settings_menu", fallback: "设置"), systemImage: "gearshape")
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    @ViewBuilder
    private var quickCommandMenu: some View {
        // 仅当请求方明确指定了 engine 时才显示对应引擎的快捷指令；否则隐藏菜单。
        switch request.engine {
        case .openclaw:
            Menu {
                ForEach(TerminalEngine.openclaw.quickCommandSections) { group in
                    Section(group.title) {
                        ForEach(group.commands) { cmd in
                            Button {
                                terminalControl.sendLine(cmd.command)
                            } label: {
                                Text(cmd.label)
                            }
                        }
                    }
                }
            } label: {
                Text(L10n.k("app.maintenance.quick.menu_title", fallback: "🦞openclaw 指令"))
            }
            .menuIndicator(.visible)
            .fixedSize()
        case .hermes:
            Menu {
                ForEach(TerminalEngine.hermes.quickCommandSections) { group in
                    Section(group.title) {
                        ForEach(group.commands) { cmd in
                            Button {
                                terminalControl.sendLine(cmd.command)
                            } label: {
                                Text(cmd.label)
                            }
                        }
                    }
                }
            } label: {
                Text(L10n.k("app.maintenance.quick.hermes.menu_title", fallback: "🪽hermes 指令"))
            }
            .menuIndicator(.visible)
            .fixedSize()
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            searchBar
            authAssistBar
            terminalPanel
            statusBar
            resourceUsageBar
        }
        .padding(10)
        .background(WindowTitleBinder(title: windowTitle))
        .onAppear {
            if !didStart {
                didStart = true
                startRun()
            }
        }
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .onDisappear {
            postCloseNotificationIfNeeded()
            terminalControl.terminate()
            appLog("[maintenance-window] closed user=\(request.username) index=\(request.index) title=\(request.title)")
        }
        .frame(minWidth: isModelConfigureCommand ? 900 : 760, minHeight: isModelConfigureCommand ? 640 : 480)
    }

    @ViewBuilder
    private var authAssistBar: some View {
        if latestAuthorizeURL != nil || latestDeviceCode != nil {
            HStack(spacing: 10) {
                Label(L10n.k("clawd_home_app.auth_assist", fallback: "授权辅助"), systemImage: "key.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = latestAuthorizeURL {
                    Button(L10n.k("clawd_home_app.open_auth_page", fallback: "打开授权页")) { _ = NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Text(url.absoluteString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let code = latestDeviceCode {
                    Button(L10n.k("clawd_home_app.copy_device_code", fallback: "复制验证码")) {
                        copyText(code, success: L10n.k("clawd_home_app.device_code_copied", fallback: "验证码已复制。"))
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private var terminalPanel: some View {
        HelperMaintenanceTerminalPanel(
            username: request.username,
            command: request.command,
            minHeight: isModelConfigureCommand ? 420 : 280,
            theme: terminalTheme,
            fontSize: CGFloat(terminalFontSize),
            onOutput: { chunk in
                handleTerminalOutput(chunk)
            },
            control: terminalControl,
            onExit: { code in
                handleCommandExit(code)
            }
        )
        .id(terminalRunID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let st = statusText {
                Text(st)
                    .font(.caption)
                    .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
            }
            if outputRateLimitEnabled, droppedOutputBytes > 0 {
                Text(droppedOutputText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }


    private func startRun() {
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        searchMatches = []
        selectedSearchMatchIndex = 0
        droppedOutputBytes = 0
        didNotifyRateLimit = false
        outputRateWindowStartedAt = Date()
        outputBytesInRateWindow = 0
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        let accepted = applyOutputRateLimitIfNeeded(chunk)
        if !accepted.isEmpty {
            outputBuffer += accepted
        }
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rebuildSearchMatches()
        }
        autoCloseIfConfigureCompleted(chunk)
    }

    private func applyOutputRateLimitIfNeeded(_ chunk: String) -> String {
        guard outputRateLimitEnabled else { return chunk }
        let now = Date()
        if now.timeIntervalSince(outputRateWindowStartedAt) >= 1 {
            outputRateWindowStartedAt = now
            outputBytesInRateWindow = 0
        }
        let bytes = Array(chunk.utf8)
        guard !bytes.isEmpty else { return "" }
        let remaining = max(0, outputRateLimitBytesPerSecond - outputBytesInRateWindow)
        guard remaining > 0 else {
            registerDroppedOutput(bytes.count)
            return ""
        }
        let acceptedCount = min(remaining, bytes.count)
        outputBytesInRateWindow += acceptedCount
        if acceptedCount < bytes.count {
            registerDroppedOutput(bytes.count - acceptedCount)
        }
        if acceptedCount == bytes.count { return chunk }
        return String(decoding: bytes.prefix(acceptedCount), as: UTF8.self)
    }

    private func registerDroppedOutput(_ droppedBytes: Int) {
        guard droppedBytes > 0 else { return }
        droppedOutputBytes += droppedBytes
        guard !didNotifyRateLimit else { return }
        didNotifyRateLimit = true
        statusText = L10n.k("app.maintenance.output_rate_limit_notice", fallback: "输出过快，已启用限流。可在“输出”菜单关闭。")
    }

    private func autoCloseIfConfigureCompleted(_ chunk: String) {
        guard isModelConfigureCommand, !didAutoCloseOnConfigureComplete else { return }
        let normalized = stripANSIEscapeSequences(chunk).lowercased()
        guard normalized.contains("configure complete.") else { return }
        didAutoCloseOnConfigureComplete = true
        statusText = L10n.k("views.maintenance.configure_complete_closing", fallback: "检测到 Configure complete.，正在关闭窗口并刷新调用方…")
        postCloseNotificationIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dismiss()
        }
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        if normalized == 0 {
            statusText = L10n.k("app.clawd_home_app.done", fallback: "维护命令执行完成。")
            appLog("[maintenance-window] command success user=\(request.username) index=\(request.index)")
        } else {
            statusText = String(format: L10n.k("app.clawd_home_app.command_exit_code", fallback: "命令已退出（exit %d）。请查看终端输出。"), normalized)
            appLog(
                "[maintenance-window] command failed user=\(request.username) index=\(request.index) exit=\(normalized)",
                level: .error
            )
        }
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("app.clawd_home_app.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        copyText(text, success: L10n.k("app.clawd_home_app.output_copied", fallback: "命令输出已复制。"))
    }

    private func clearTerminalOutput() {
        outputBuffer = ""
        searchMatches = []
        selectedSearchMatchIndex = 0
        droppedOutputBytes = 0
        didNotifyRateLimit = false
        outputRateWindowStartedAt = Date()
        outputBytesInRateWindow = 0
        terminalControl.clearDisplay()
        statusText = L10n.k("app.maintenance.output_cleared", fallback: "终端输出已清空。")
    }

    private func exportTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("app.clawd_home_app.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "maintenance-\(request.username)-\(timestampString()).log"
        panel.allowedFileTypes = ["log", "txt"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            statusText = L10n.f("app.maintenance.output_exported", fallback: "输出已导出：%@", url.lastPathComponent)
        } catch {
            statusText = L10n.f(
                "app.maintenance.output_export_failed",
                fallback: "导出失败：%@",
                error.localizedDescription
            )
        }
    }

    private func cloneTerminalWindow() {
        // 克隆窗口时继承当前命令与 engine，避免跨运行时环境漂移。
        let payload = maintenanceWindowRegistry.makePayload(
            username: request.username,
            title: L10n.k("user.detail.auto.cli_maintenance_advanced", fallback: "命令行维护（高级）"),
            command: request.command,
            engine: request.engine
        )
        openWindow(id: "maintenance-terminal", value: payload)
        statusText = L10n.k("app.maintenance.terminal_cloned", fallback: "已打开新的维护终端窗口。")
    }

    private enum SearchJumpDirection {
        case forward
        case backward
    }

    private func rebuildSearchMatches() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchMatches = []
            selectedSearchMatchIndex = 0
            return
        }
        let nsText = sanitizedOutput as NSString
        let previousLocation = selectedSearchMatch?.range.location
        var ranges: [NSRange] = []
        var scanLocation = 0
        while scanLocation < nsText.length {
            let searchRange = NSRange(location: scanLocation, length: nsText.length - scanLocation)
            let found = nsText.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let step = max(found.length, 1)
            scanLocation = found.location + step
        }
        searchMatches = ranges.enumerated().map { idx, range in
            OutputSearchMatch(id: idx, range: range, preview: searchPreview(in: nsText, at: range))
        }
        guard !searchMatches.isEmpty else {
            selectedSearchMatchIndex = 0
            return
        }
        if let previousLocation,
           let nearest = searchMatches.lastIndex(where: { $0.range.location <= previousLocation })
        {
            selectedSearchMatchIndex = nearest
        } else {
            selectedSearchMatchIndex = min(selectedSearchMatchIndex, searchMatches.count - 1)
        }
    }

    private func jumpToSearchMatch(direction: SearchJumpDirection) {
        guard !searchMatches.isEmpty else {
            statusText = L10n.k("app.maintenance.search.not_found", fallback: "没有匹配项。")
            return
        }
        switch direction {
        case .forward:
            selectedSearchMatchIndex = (selectedSearchMatchIndex + 1) % searchMatches.count
        case .backward:
            selectedSearchMatchIndex = (selectedSearchMatchIndex - 1 + searchMatches.count) % searchMatches.count
        }
        statusText = String(
            format: L10n.k("app.maintenance.search.jumped", fallback: "已跳转到匹配 %d/%d。"),
            selectedSearchMatchIndex + 1,
            searchMatches.count
        )
    }

    private func searchPreview(in text: NSString, at range: NSRange) -> String {
        let context = 36
        let start = max(0, range.location - context)
        let end = min(text.length, NSMaxRange(range) + context)
        let previewRange = NSRange(location: start, length: max(0, end - start))
        let raw = text.substring(with: previewRange)
        return raw
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func copyText(_ text: String, success: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = success
    }

    private func stripANSIEscapeSequences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)]+"#) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let raw = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            return URL(string: raw)
        }
    }

    @ViewBuilder
    private var resourceUsageBar: some View {
        if let shrimp = pool.snapshot?.shrimps.first(where: { $0.username == request.username }) {
            HStack(spacing: 10) {
                resourceChip(icon: "cpu", title: "CPU", value: shrimp.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                resourceChip(icon: "memorychip", title: L10n.k("common.resource.memory", fallback: "内存"), value: shrimp.memRssMB.map { formatMem($0) } ?? "—")
                resourceChip(icon: "arrow.down.circle", title: L10n.k("common.resource.net_in", fallback: "入网"), value: FormatUtils.formatBps(shrimp.netRateInBps))
                resourceChip(icon: "arrow.up.circle", title: L10n.k("common.resource.net_out", fallback: "出网"), value: FormatUtils.formatBps(shrimp.netRateOutBps))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func postCloseNotificationIfNeeded() {
        guard !didPostCloseNotification, let completionToken = request.completionToken else { return }
        didPostCloseNotification = true
        NotificationCenter.default.post(
            name: .maintenanceTerminalWindowClosed,
            object: nil,
            userInfo: [
                "token": completionToken,
                "username": request.username,
                "title": request.title,
                "context": request.completionContext ?? "",
                "exitCode": (exitCode.map(NSNumber.init(value:)) ?? NSNull()) as Any
            ]
        )
    }

    @ViewBuilder
    private func resourceChip(icon: String, title: String, value: String) -> some View {
        Label("\(title) \(value)", systemImage: icon)
            .lineLimit(1)
    }

    private func formatMem(_ memMB: Double) -> String {
        if memMB < 1024 {
            return String(format: "%.0f MB", memMB)
        }
        return String(format: "%.2f GB", memMB / 1024)
    }

private struct WindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
}

// MARK: - 通道配置窗口

private struct ChannelOnboardingWindow: View {
    let payload: String?
    @Environment(ShrimpPool.self) private var pool

    var body: some View {
        if let payload, let req = ChannelOnboardingRequest(payload: payload) {
            let displayName = pool.users.first(where: { $0.username == req.username })?.fullName ?? ""
            switch req.flow {
            case .feishu:
                FeishuChannelOnboardingSheet(
                    flow: .feishu,
                    displayName: displayName,
                    username: req.username,
                    entryMode: req.entryMode
                )
            case .weixin:
                FeishuChannelOnboardingSheet(
                    flow: .weixin,
                    displayName: displayName,
                    username: req.username,
                    entryMode: req.entryMode
                )
            }
        } else {
            ContentUnavailableView(
                L10n.k("app.channel.invalid_params", fallback: "通道参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.channel.invalid_params.desc", fallback: "请从虾详情页重新打开通道配置窗口。"))
            )
        }
    }
}

private struct ChannelOnboardingRequest {
    let flow: ChannelOnboardingFlow
    let username: String
    let entryMode: ChannelOnboardingEntryMode

    init?(payload: String) {
        let parts = payload.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2,
              let flow = ChannelOnboardingFlow(rawValue: parts[0]),
              !parts[1].isEmpty else { return nil }
        self.flow = flow
        self.username = parts[1]
        self.entryMode = parts.count >= 3
            ? (ChannelOnboardingEntryMode(rawValue: parts[2]) ?? .configuration)
            : .configuration
    }
}

// MARK: - 龙虾详情窗口定位器

/// 首次出现时把 claw-detail 窗口定位到主窗口右侧区域（侧栏宽度 idealSidebar）
private struct ClawDetailWindowPositioner: NSViewRepresentable {
    private let idealSidebar: CGFloat = 200
    private let preferredSize = NSSize(
        width: UserDetailWindowLayout.mainWindowDefaultWidth,
        height: UserDetailWindowLayout.detailWindowDefaultHeight
    )
    private let minimumSize = NSSize(
        width: UserDetailWindowLayout.detailWindowMinimumWidth,
        height: UserDetailWindowLayout.detailWindowMinimumHeight
    )

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(
                view: view,
                sidebar: idealSidebar,
                preferredSize: preferredSize,
                minimumSize: minimumSize
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(
        view: NSView,
        sidebar: CGFloat,
        preferredSize: NSSize,
        minimumSize: NSSize
    ) {
        guard let detailWindow = view.window else { return }
        detailWindow.contentMinSize = minimumSize
        // 找到主窗口（同进程、可见、非 claw-detail 自身）
        let mainWindow = NSApp.windows.first {
            $0 !== detailWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }
        let visibleFrame = main.screen?.visibleFrame ?? detailWindow.screen?.visibleFrame ?? main.frame

        // 首开时继承主窗口当前宽度，只在屏幕可见范围内钳制，避免详情窗口首开偏窄。
        let originX = min(main.frame.minX + sidebar, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let visibleWidth = visibleFrame.maxX - originX
        let width = resolvedUserDetailWindowWidth(
            mainWindowWidth: main.frame.width,
            visibleWidth: visibleWidth
        )
        let height = min(preferredSize.height, visibleFrame.maxY - originY)
        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: width,
            height: max(minimumSize.height, height)
        )
        detailWindow.setFrame(frame, display: true)
    }
}

// MARK: - 初始化窗口定位器

/// 首次出现时将初始化窗口高度对齐主窗口高度，避免与主窗口尺寸不一致。
private struct UserInitWizardWindowPositioner: NSViewRepresentable {
    private let preferredWidth: CGFloat = 980
    private let minimumSize = NSSize(width: 860, height: 560)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(view: view, preferredWidth: preferredWidth, minimumSize: minimumSize)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(view: NSView, preferredWidth: CGFloat, minimumSize: NSSize) {
        guard let wizardWindow = view.window else { return }
        wizardWindow.contentMinSize = minimumSize

        let mainWindow = NSApp.windows.first {
            $0 !== wizardWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }

        let visibleFrame = main.screen?.visibleFrame ?? wizardWindow.screen?.visibleFrame ?? main.frame
        let originX = min(main.frame.minX, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let targetHeight = min(main.frame.height, visibleFrame.maxY - originY)
        let targetWidth = min(preferredWidth, visibleFrame.maxX - originX)

        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: max(minimumSize.width, targetWidth),
            height: max(minimumSize.height, targetHeight)
        )
        wizardWindow.setFrame(frame, display: true)
    }
}

// MARK: - 龙虾详情窗口容器

/// 通过 username 从 ShrimpPool 查找用户并展示 UserDetailView。
/// 同一 username 的窗口由 SwiftUI 去重：再次 openWindow 只会置前已有窗口。
private struct ClawDetailWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss)       private var dismiss

    private var user: ManagedUser? {
        pool.users.first { $0.username == username }
    }

    var body: some View {
        if let user {
            if user.prefersHermesRuntime {
                HermesDetailContainer(user: user, onDeleted: {
                    dismiss()
                    Task { @MainActor in
                        pool.removeUser(username: username)
                    }
                })
            } else {
                NavigationStack {
                    UserDetailView(user: user, onDeleted: {
                        dismiss()
                        Task { @MainActor in
                            pool.removeUser(username: username)
                        }
                    })
                }
            }
        } else {
            NavigationStack {
                ContentUnavailableView(
                    "@\(username)",
                    systemImage: "person.slash",
                    description: Text(L10n.k("app.claw_detail.user_missing", fallback: "该用户已被删除或尚未加载"))
                )
                .navigationTitle("@\(username)")
            }
        }
    }
}

// v2 入口：使用 ShrimpInitWizardV2 替换 UserInitWizardView
// 保留 UserInitWizardWindow 名称避免修改 WindowGroup 注册
private struct UserInitWizardWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss) private var dismiss
    // 先消费 pool.pendingInitTeams 再渲染 wizard，保证 wizard 首帧 onAppear 就能
    // 在 hydrateInitialRolesIfNeeded() 里看到 teamDNA，避免 agents 被预填成 solo
    // 之后再 onChange 回来就被 `agents.isEmpty` guard 挡掉（只剩主 Agent 的 bug）。
    @State private var resolvedInitialRoles: WizardV2InitialRoles? = nil

    private var user: ManagedUser? {
        pool.users.first { $0.username == username }
    }

    var body: some View {
        if let user {
            if let resolvedInitialRoles {
                ShrimpInitWizardV2(user: user, initialRoles: resolvedInitialRoles) {
                    dismiss()
                }
            } else {
                Color.clear
                    .task {
                        guard resolvedInitialRoles == nil else { return }
                        resolvedInitialRoles = WizardV2InitialRoles(
                            teamDNA: pool.consumeInitTeam(for: username),
                            agents: WizardV2InitialRoles.solo.agents
                        )
                    }
            }
        } else {
            ContentUnavailableView(
                "@\(username)",
                systemImage: "person.slash",
                description: Text(L10n.k("app.user_init_wizard.user_missing", fallback: "该用户已被删除或尚未加载"))
            )
        }
    }
}
