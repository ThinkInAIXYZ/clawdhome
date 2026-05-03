// ClawdHome/ContentView.swift

import AppKit
import SwiftUI

// MARK: - 顶层导航目的地
enum NavDestination: Hashable {
    case dashboard
    case clawPool
    case vaultFiles
    case notes
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
                        Label(L10n.k("content_view.notes_center", fallback: "笔记"), systemImage: "book.closed")
                            .tag(NavDestination.notes)
                        Label("Prompt", systemImage: "text.bubble")
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
                            .help(colorSchemePreference == 1 ? "浅色模式" : colorSchemePreference == 2 ? "深色模式" : "跟随系统")
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
                case .notes:
                    NotesWorkspaceView()
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
        .onChange(of: navSelection) { _, newValue in
            let visible = (newValue == .dashboard || newValue == nil)
            pool.setDashboardVisible(visible)
        }
    }

    private func refreshChromeInstallStatus() {
        isChromeInstalled = ChromeInstallDetector.isGoogleChromeInstalled()
        chromeInstallCheckCompleted = true
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
                    Text("未检测到 Google Chrome")
                        .font(.headline)
                    Text("浏览器账号和网页登录能力需要 Chrome。安装完成后，这个提示会自动消失。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Link(destination: chromeDownloadURL) {
                Label("前往 Chrome 官网安装", systemImage: "arrow.up.forward.square")
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

private enum NotesWorkspaceTab: String, CaseIterable, Identifiable {
    case editor
    case status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: return "笔记"
        case .status: return "笔记状态"
        }
    }

    var icon: String {
        switch self {
        case .editor: return "book.closed"
        case .status: return "checklist.checked"
        }
    }
}

private struct NotesWorkspaceView: View {
    @State private var selectedTab: NotesWorkspaceTab = .editor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(NotesWorkspaceTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selectedTab == tab ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ZStack {
                WikiHostView {
                    selectedTab = .status
                }
                .opacity(selectedTab == .editor ? 1 : 0)
                .allowsHitTesting(selectedTab == .editor)

                NotesCenterView()
                    .opacity(selectedTab == .status ? 1 : 0)
                    .allowsHitTesting(selectedTab == .status)
            }
        }
        .navigationTitle(selectedTab.title)
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
