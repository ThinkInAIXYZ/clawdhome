// ClawdHome/ContentView.swift

import SwiftUI

// MARK: - 顶层导航目的地
enum NavDestination: Hashable {
    case dashboard
    case clawPool
    case vaultFiles
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
                        Label { Text(L10n.k("auto.content_view.claw_pool", fallback: "虾塘")) } icon: { Text("🦞") }
                            .tag(NavDestination.clawPool)
                        Label(L10n.k("auto.content_view.vault_files", fallback: "文件共享"), systemImage: "folder.badge.person.crop")
                            .tag(NavDestination.vaultFiles)
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
                case .network:
                    NetworkPolicyView()
                        .environment(helperClient)
                case .models:
                    #if DEBUG
                    ModelManagerView()
                    #else
                    ComingSoonView(title: L10n.k("auto.content_view.models", fallback: "模型"), icon: "cpu.fill")
                    #endif
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
        .animation(.easeInOut(duration: 0.25), value: helperClient.isConnected)
        .overlay {
            if lockStore.isLocked {
                AppLockScreen()
                    .environment(lockStore)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: lockStore.isLocked)
        .onAppear {
            let visible = (navSelection == .dashboard || navSelection == nil)
            pool.setDashboardVisible(visible)
        }
        .onChange(of: navSelection) { _, newValue in
            let visible = (newValue == .dashboard || newValue == nil)
            pool.setDashboardVisible(visible)
        }
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
