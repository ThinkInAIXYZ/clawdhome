// ClawdHome/ContentView.swift

import AppKit
import SwiftUI

// MARK: - 顶层导航目的地
enum NavDestination: Hashable {
    case dashboard
    case clawPool
    case vaultFiles
    case prompts
    case network
    case aiLab
    case models
    case roleMarket
    case audit
    case backup
    case settings
}

struct ContentView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool
    @Environment(UpdateChecker.self) private var updater
    @Environment(AppLockStore.self) private var lockStore
    @State private var daemonInstaller = DaemonInstaller()
    @State private var navSelection: NavDestination? = .clawPool
    @State private var chromeInstallCheckCompleted = false
    @State private var isChromeInstalled = true
    @State private var browserSessionPromptUsername: String?
    @State private var browserSessionPromptSuppressed = false
    @State private var browserSessionPromptCheckInFlight = false
    // 0 = 跟随系统, 1 = 浅色, 2 = 深色
    @AppStorage("colorSchemePreference") private var colorSchemePreference: Int = 0

    private let chromeInstallCheckTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    private var shouldShowChromeInstallHint: Bool {
        chromeInstallCheckCompleted
        && !isChromeInstalled
        && !lockStore.isLocked
        && (navSelection == .dashboard || navSelection == .clawPool || navSelection == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = pool.loadError {
                Text(L10n.f("content_view.text_c851a279", fallback: "加载用户失败：%@", String(describing: err)))
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(8)
            }

            NavigationSplitView {
                List(selection: $navSelection) {
                    Section(L10n.k("auto.content_view.daily", fallback: "日常")) {
                        Label(L10n.k("auto.content_view.dashboard", fallback: "仪表盘"), systemImage: "gauge.with.dots.needle.33percent")
                            .tag(NavDestination.dashboard)
                        Label { Text(L10n.k("auto.content_view.claw_pool", fallback: "虾塘")) } icon: { OpenClawLogoMark().frame(width: 16, height: 16) }
                            .tag(NavDestination.clawPool)
                        Label(L10n.k("auto.content_view.vault_files", fallback: "文件共享"), systemImage: "folder.badge.person.crop")
                            .tag(NavDestination.vaultFiles)
                        Label(L10n.k("content_view.nav.prompts", fallback: "Prompt"), systemImage: "text.bubble")
                            .tag(NavDestination.prompts)
                    }
                    Section(L10n.k("auto.content_view.services", fallback: "服务")) {
                        Label { Text(L10n.k("auto.content_view.role_market", fallback: "角色中心")) } icon: { Text("🎭") }
                            .tag(NavDestination.roleMarket)
                        Label { Text(L10n.k("auto.content_view.models", fallback: "模型")) } icon: { Text("🧠") }
                            .tag(NavDestination.models)
                        Label(L10n.k("auto.content_view.network", fallback: "网络"), systemImage: "network")
                            .tag(NavDestination.network)
                        Label(L10n.k("auto.content_view.ai_lab", fallback: "AI 实验室"), systemImage: "flask.fill")
                            .tag(NavDestination.aiLab)
                    }
                    Section(L10n.k("auto.content_view.system", fallback: "系统")) {
                        Label(L10n.k("auto.content_view.security_audit", fallback: "安全审计"), systemImage: "shield.lefthalf.filled")
                            .tag(NavDestination.audit)
                        Label(L10n.k("auto.content_view.backups", fallback: "备份"), systemImage: "externaldrive.badge.timemachine")
                            .tag(NavDestination.backup)
                        Label(L10n.k("auto.content_view.settings", fallback: "设置"), systemImage: "gearshape")
                            .tag(NavDestination.settings)
                    }
                }
                .listStyle(.sidebar)
                // Keep sidebar scroll content below the title area on macOS.
                .contentMargins(.top, 12, for: .scrollContent)
                .navigationTitle("ClawdHome")
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        // App 自身更新提示横幅
                        AppUpdateBanner()
                            .environment(updater)
                        HStack(spacing: 6) {
                            Text(L10n.k("auto.content_view.beta", fallback: "内测版"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("BETA")
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, Color(red: 0.95, green: 0.2, blue: 0.35)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                            Spacer()
                            Button {
                                colorSchemePreference = (colorSchemePreference + 1) % 3
                            } label: {
                                Image(systemName: colorSchemePreference == 1 ? "sun.max.fill" : colorSchemePreference == 2 ? "moon.fill" : "circle.lefthalf.filled")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(
                                colorSchemePreference == 1
                                ? L10n.k("content_view.theme.light", fallback: "浅色模式")
                                : colorSchemePreference == 2
                                    ? L10n.k("content_view.theme.dark", fallback: "深色模式")
                                    : L10n.k("content_view.theme.system", fallback: "跟随系统")
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                }
                .toolbar {
                    if lockStore.isEnabled {
                        ToolbarItem(placement: .primaryAction) {
                            Button { lockStore.lock() } label: {
                                Image(systemName: lockStore.isLocked ? "lock.fill" : "lock.open.fill")
                                    .foregroundStyle(lockStore.isLocked ? .red : .secondary)
                            }
                            .help(lockStore.isLocked ? L10n.k("auto.content_view.locked", fallback: "已锁定") : L10n.k("auto.content_view.app", fallback: "点击锁定 App"))
                            .disabled(lockStore.isLocked)
                        }
                    }
                }
            } detail: {
                switch navSelection {
                case .dashboard, nil:
                    DashboardView()
                        .environment(helperClient)
                case .clawPool:
                    ClawPoolView(
                        onLoadUsers: { pool.loadUsers() },
                        onGoToRoleMarket: { navSelection = .roleMarket }
                    )
                    .environment(helperClient)
                case .vaultFiles:
                    VaultFilesView()
                        .environment(helperClient)
                        .environment(pool)
                case .prompts:
                    PromptLibraryView()
                case .network:
                    NetworkPolicyView()
                        .environment(helperClient)
                case .models:
                    ModelManagerView()
                case .aiLab:
                    AILabView()
                case .roleMarket:
                    RoleMarketView()
                case .audit:
                    SecurityAuditView()
                        .environment(helperClient)
                        .environment(pool)
                case .backup:
                    BackupView(users: pool.users)
                        .environment(helperClient)
                case .settings:
                    SettingsView()
                        .environment(helperClient)
                }
            }
            .frame(minWidth: 960, minHeight: 560)
        }
        // 系统屏幕锁定时自动锁定 App
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: NSNotification.Name("com.apple.screenIsLocked")
            )
        ) { _ in lockStore.lock() }
        .onReceive(NotificationCenter.default.publisher(for: .roleMarketAdoptionStarted)) { _ in
            navSelection = .clawPool
        }
        .overlay(alignment: .top) {
            // Helper 未连接时显示安装引导横幅（最顶层浮动）
            if !helperClient.isConnected {
                DaemonSetupBanner(installer: daemonInstaller)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShowChromeInstallHint {
                ChromeInstallHintCard()
                    .padding(20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: helperClient.isConnected)
        .animation(.easeInOut(duration: 0.18), value: shouldShowChromeInstallHint)
        .alert(
            L10n.k("content_view.browser.init_session_title", fallback: "初始化浏览器 Session？"),
            isPresented: Binding(
                get: { browserSessionPromptUsername != nil },
                set: { if !$0 { browserSessionPromptUsername = nil } }
            ),
            presenting: browserSessionPromptUsername
        ) { username in
            Button(L10n.k("content_view.browser.skip_init", fallback: "这次不初始化"), role: .cancel) {
                browserSessionPromptSuppressed = true
                browserSessionPromptUsername = nil
            }
            Button(L10n.k("content_view.browser.open_browser", fallback: "打开浏览器")) {
                browserSessionPromptSuppressed = true
                browserSessionPromptUsername = nil
                Task {
                    try? await helperClient.openBrowserAccount(username: username)
                }
            }
        } message: { username in
            Text(L10n.f("content_view.browser.init_session_message", fallback: "检测到 %@ 的浏览器工具已安装，但还没有初始化 session。是否现在打开 Chrome 完成初始化？", username))
        }
        .overlay {
            if lockStore.isLocked {
                AppLockScreen()
                    .environment(lockStore)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: lockStore.isLocked)
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            let visible = (navSelection == .dashboard || navSelection == nil)
            pool.setDashboardVisible(visible)
            refreshChromeInstallStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshChromeInstallStatus()
        }
        .onReceive(chromeInstallCheckTimer) { _ in
            if chromeInstallCheckCompleted && !isChromeInstalled {
                refreshChromeInstallStatus()
            }
        }
        .onChange(of: isChromeInstalled) { _, _ in
            checkForBrowserSessionInitializationPrompt()
        }
        .onChange(of: pool.didFinishInitialUserLoad) { _, _ in
            checkForBrowserSessionInitializationPrompt()
        }
        .onChange(of: navSelection) { _, newValue in
            let visible = (newValue == .dashboard || newValue == nil)
            pool.setDashboardVisible(visible)
        }
    }

    private func refreshChromeInstallStatus() {
        isChromeInstalled = ChromeInstallDetector.isGoogleChromeInstalled()
        chromeInstallCheckCompleted = true
        checkForBrowserSessionInitializationPrompt()
    }

    private func checkForBrowserSessionInitializationPrompt() {
        guard chromeInstallCheckCompleted,
              isChromeInstalled,
              !browserSessionPromptSuppressed,
              browserSessionPromptUsername == nil,
              !browserSessionPromptCheckInFlight,
              pool.didFinishInitialUserLoad,
              !pool.users.isEmpty else {
            return
        }

        browserSessionPromptCheckInFlight = true
        let usernames = pool.users.map(\.username)
        Task {
            var candidate: String?
            for username in usernames {
                guard !Task.isCancelled else { return }
                guard let status = await helperClient.getBrowserAccountStatus(username: username) else {
                    continue
                }
                if status.toolInstalled && !status.sessionExists {
                    candidate = username
                    break
                }
            }

            await MainActor.run {
                browserSessionPromptCheckInFlight = false
                guard let candidate,
                      isChromeInstalled,
                      !browserSessionPromptSuppressed,
                      browserSessionPromptUsername == nil else {
                    return
                }
                browserSessionPromptUsername = candidate
            }
        }
    }

}

private enum ChromeInstallDetector {
    static func isGoogleChromeInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil {
            return true
        }

        let fileManager = FileManager.default
        let candidatePaths = [
            "/Applications/Google Chrome.app",
            "\(NSHomeDirectory())/Applications/Google Chrome.app",
        ]
        return candidatePaths.contains { fileManager.fileExists(atPath: $0) }
    }
}

private struct ChromeInstallHintCard: View {
    private let chromeDownloadURL = URL(string: "https://www.google.com/chrome/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("content_view.chrome.not_found", fallback: "未检测到 Google Chrome"))
                        .font(.headline)
                    Text(L10n.k("content_view.chrome.required_message", fallback: "浏览器账号和网页登录能力需要 Chrome。安装完成后，这个提示会自动消失。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Link(destination: chromeDownloadURL) {
                Label(L10n.k("content_view.chrome.install_link", fallback: "前往 Chrome 官网安装"), systemImage: "arrow.up.forward.square")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.orange.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 敬请期待占位视图

struct ComingSoonView: View {
    let title: String
    var icon: String = "sparkles"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2).fontWeight(.medium)
            Text(L10n.k("auto.content_view.coming_soon", fallback: "敬请期待"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}
