// ClawdHome/Views/UserDetailView.swift

import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 详情窗口 Tab

private enum ClawTab: String, Hashable {
    case overview, files, logs, processes, cron, skills, characterDef, sessions, memory
}

private enum DetailXcodeHealthState {
    case checking
    case healthy
    case unhealthy
}

struct UserDetailView: View {
    let user: ManagedUser
    var onDeleted: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool
    @Environment(UpdateChecker.self) private var updater
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow
    @State private var isLoading = false
    @State private var actionError: String?
    @State private var showConfig = false
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteHomeOption: DeleteHomeOption = .deleteHome
    @State private var deleteAdminPassword = ""
    @State private var deleteError: String? = nil      // 删除专用错误，不显示在操作区
    @State private var showResetConfirm = false
    @State private var isResetting = false
    @State private var versionChecked = false
    @State private var hasPendingInitWizard = false
    @State private var isRefreshingStatus = false
    @State private var refreshStatusNeedsRerun = false
    @State private var refreshStatusGeneration: UInt64 = 0
    @State private var forceOnboardingAtEntry = false
    private var isSelf: Bool { user.username == NSUserName() }

    /// HTTP probe + launchctl 综合判断是否运行中（任一来源确认即为 true）
    private var isEffectivelyRunning: Bool {
        if user.isFrozen { return false }
        switch gatewayHub.readinessMap[user.username] {
        case .ready, .starting, .zombie: return true
        case .stopped: return false
        case .none: return user.isRunning
        }
    }

    /// 从 GatewayHub readiness 映射得到状态文字
    private var readinessLabel: String {
        if user.isFrozen { return user.freezeMode?.statusLabel ?? L10n.k("models.managed_user.freeze", fallback: "已冻结") }
        switch gatewayHub.readinessMap[user.username] {
        case .ready:    return L10n.k("models.managed_user.running", fallback: "运行中")
        case .starting:
            if user.isRunning,
               let startedAt = user.startedAt,
               Date().timeIntervalSince(startedAt) > 20 {
                return L10n.k("views.user_detail_view.statussync", fallback: "状态同步中…")
            }
            return L10n.k("views.user_detail_view.start", fallback: "启动中…")
        case .zombie:   return L10n.k("views.user_detail_view.abnormal_no_response", fallback: "异常（无响应）")
        case .stopped:  return L10n.k("models.managed_user.not_running", fallback: "未运行")
        case .none:     return user.isRunning ? L10n.k("models.managed_user.running", fallback: "运行中") : L10n.k("models.managed_user.not_running", fallback: "未运行")
        }
    }
    // 状态：Gateway 地址
    @State private var gatewayURL: String? = nil
    @State private var gatewayURLTokenPollTask: Task<Void, Never>? = nil
    // 模型配置
    @State private var defaultModel: String? = nil
    @State private var fallbackModels: [String] = []
    @State private var descriptionDraft: String = ""
    @State private var showModelConfig = false
    @State private var showModelPriority = false
    @State private var isAdvancedConfigExpanded = false
    @State private var npmRegistryOption: NpmRegistryOption = .defaultForInitialization
    @State private var npmRegistryCustomURL: String? = nil
    @State private var npmRegistryError: String? = nil
    @State private var isUpdatingNpmRegistry = false
    @State private var isNodeInstalledReady = false
    @State private var xcodeEnvStatus: XcodeEnvStatus? = nil
    @State private var isInstallingXcodeCLT = false
    @State private var isAcceptingXcodeLicense = false
    @State private var isRepairingHomebrewPermission = false
    @State private var xcodeFixMessage: String? = nil
    @State private var showGatewayNodeRepairSheet = false
    @State private var gatewayNodeRepairReason = ""
    @State private var isGatewayNodeRepairing = false
    @State private var gatewayNodeRepairCompletedSteps = 0
    @State private var gatewayNodeRepairCurrentStep = ""
    @State private var gatewayNodeRepairError: String?
    @State private var gatewayNodeRepairReadyToRetryStart = false
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue
    @State private var isReopeningInitWizard = false
    @State private var suppressNpmRegistryOnChange = false
    @State private var showHealthCheck = false
    @State private var lastHealthCheck: DiagnosticsResult? = nil
    @State private var showUpgradeConfirm = false
    @State private var pendingUpgradeVersion: String? = nil
    // 版本回退（记录升级前版本，支持降级）
    @State private var preUpgradeVersion: String? = nil
    @State private var showRollbackConfirm = false
    @State private var isRollingBack = false
    @State private var showInstallConsole = false
    @State private var versionSpinnerAnimating = false
    @State private var showLogoutConfirm = false
    @State private var isLoggingOut = false
    @State private var showFlashFreezeConfirm = false
    @State private var showPauseFreezeConfirm = false
    @State private var showNormalFreezeConfirm = false
    // Hermes
    @State private var showHermesSetup = false
    // 密码
    @State private var showPassword = false
    @State private var logSearchText = ""
    @State private var isQuickTransferDropTargeted = false
    @State private var quickTransferAlertMessage: String?
    @State private var quickTransferClipboardText = ""
    @State private var quickTransferLastPaths: [String] = []
    // Tab
    @State private var selectedTab: ClawTab = .overview
    // Agent
    @State private var agents: [AgentProfile] = []
    @State private var selectedAgentId: String? = nil
    @State private var showCreateAgent = false
    @State private var editingAgentModel: AgentProfile? = nil
    @State private var isDetailSidebarCollapsed = false
    @State private var isOverviewSidebarCollapsed = false
    @State private var hasOpenedStandaloneInitWindow = false
    @State private var detailAutoRefreshActive = false
    @StateObject private var embeddedOverviewConsoleStore = EmbeddedGatewayConsoleStore()
    private var shouldPinWindowTopmost: Bool {
        !user.isAdmin
        && user.clawType == .macosUser
        && (user.initStep != nil || hasPendingInitWizard)
    }

    private var initPresentationRoute: UserInitPresentationRoute {
        resolveUserInitPresentation(
            versionChecked: versionChecked,
            hasInitStep: user.initStep != nil,
            hasPendingInitWizard: hasPendingInitWizard,
            isAdmin: user.isAdmin,
            isMacOSUser: user.clawType == .macosUser
        )
    }
    private var detailWindowTitle: String {
        user.fullName.isEmpty ? user.username : user.fullName
    }
    private var detailWindowSubtitle: String {
        "@\(user.username)"
    }

    var body: some View {
        tabbedContent
        .navigationTitle(detailWindowTitle)
        .navigationSubtitle(detailWindowSubtitle)
        .background(UserDetailWindowTitleBinder(title: detailWindowTitle, subtitle: detailWindowSubtitle))
        .background(UserDetailWindowLevelBinder(elevated: shouldPinWindowTopmost))
        .onAppear {
            descriptionDraft = user.profileDescription
            pool.addLiveSnapshotConsumer()
            detailAutoRefreshActive = true
            if pool.consumeNeedsOnboarding(username: user.username) {
                forceOnboardingAtEntry = true
                versionChecked = false
            }
            // 虾塘点击 agent 卡片跳转：消费 pendingAgentSelection，自动选中对应 agent
            if let pendingAgent = pool.pendingAgentSelection.removeValue(forKey: user.username) {
                selectedAgentId = pendingAgent
            }
            maybeOpenStandaloneInitWindow()
        }
        .onChange(of: user.username) { _, _ in
            forceOnboardingAtEntry = false
            hasOpenedStandaloneInitWindow = false
            if pool.consumeNeedsOnboarding(username: user.username) {
                forceOnboardingAtEntry = true
            }
            versionChecked = false
            descriptionDraft = user.profileDescription
            logSearchText = ""
            gatewayURLTokenPollTask?.cancel()
            gatewayURLTokenPollTask = nil
            gatewayURL = nil
        }
        .onDisappear {
            detailAutoRefreshActive = false
            pool.removeLiveSnapshotConsumer()
            gatewayURLTokenPollTask?.cancel()
            gatewayURLTokenPollTask = nil
        }
        .onChange(of: user.initStep) { _, newValue in
            if newValue == nil && hasPendingInitWizard {
                Task { await refreshStatus() }
            }
        }
        .onChange(of: initPresentationRoute) { _, newRoute in
            if newRoute == .standaloneWizard {
                maybeOpenStandaloneInitWindow()
            } else {
                hasOpenedStandaloneInitWindow = false
            }
        }
    }

    // MARK: - Tab 容器

    private let allTabs: [ClawTab] = [.overview, .characterDef, .files, .processes, .logs, .cron, .skills, .sessions, .memory]
    private let agentTabs: [ClawTab] = [.overview, .characterDef, .cron, .skills, .sessions, .memory]
    private let gatewayTabs: [ClawTab] = [.files, .processes, .logs]

    private var shouldEmbedOverviewConsole: Bool {
        shouldEmbedOverviewGatewayConsole(
            selectedTabRawValue: selectedTab.rawValue,
            initPresentationRoute: initPresentationRoute,
            isAdmin: user.isAdmin,
            versionChecked: versionChecked,
            hasInstalledOpenClaw: user.openclawVersion != nil,
            isGatewayOperational: isEffectivelyRunning
        )
    }

    private var shouldShowOverviewSidebar: Bool {
        shouldShowOverviewNativeSidebar(
            selectedTabRawValue: selectedTab.rawValue,
            initPresentationRoute: initPresentationRoute
        )
    }

    private var detailSidebarShowsLabels: Bool {
        shouldShowDetailSidebarLabels(isCollapsed: isDetailSidebarCollapsed)
    }

    private var selectedAgent: AgentProfile? {
        agents.first(where: { $0.id == selectedAgentId })
    }

    private var selectedAgentLabel: String {
        selectedAgent?.name ?? "默认角色"
    }

    private var shouldRenderOverviewSidebar: Bool {
        shouldRenderOverviewSidebarPanel(
            selectedTabRawValue: selectedTab.rawValue,
            initPresentationRoute: initPresentationRoute,
            isCollapsed: isOverviewSidebarCollapsed
        )
    }

    private var currentShrimpStats: ShrimpNetStats? {
        pool.snapshot?.shrimps.first(where: { $0.username == user.username })
    }

    private var detailSidebarWidth: CGFloat {
        isDetailSidebarCollapsed ? 76 : UserDetailWindowLayout.expandedSidebarWidth
    }

    private var detailSidebarButtonSize: CGFloat {
        36
    }

    private func tabInfo(_ tab: ClawTab) -> (label: String, icon: String) {
        switch tab {
        case .overview:  return (L10n.k("user.detail.auto.overview", fallback: "概览"), "gauge.with.dots.needle.33percent")
        case .files:     return (L10n.k("user.detail.auto.files", fallback: "文件"), "folder")
        case .logs:      return (L10n.k("user.detail.auto.logs", fallback: "日志"), "doc.text.magnifyingglass")
        case .cron:      return (L10n.k("user.detail.auto.scheduled", fallback: "定时"), "clock")
        case .skills:    return ("Skills", "star.leadinghalf.filled")
        case .characterDef: return (L10n.k("user.detail.auto.character_def", fallback: "角色"), "theatermasks")
        case .sessions:  return (L10n.k("user.detail.auto.sessions", fallback: "会话"), "bubble.left.and.bubble.right")
        case .memory:    return (L10n.k("user.detail.auto.memory", fallback: "记忆"), "brain.head.profile")
        case .processes: return (L10n.k("user.detail.auto.processes", fallback: "进程"), "square.3.layers.3d")
        }
    }

    @ViewBuilder private func sidebarButton(_ tab: ClawTab) -> some View {
        let info = tabInfo(tab)
        let selected = selectedTab == tab
        Button { selectedTab = tab } label: {
            HStack(spacing: detailSidebarShowsLabels ? 8 : 0) {
                Image(systemName: info.icon)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: detailSidebarButtonSize, height: detailSidebarButtonSize)
                if detailSidebarShowsLabels {
                    Text(info.label)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 14, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, detailSidebarShowsLabels ? 10 : 0)
            .padding(.vertical, detailSidebarShowsLabels ? 4 : 0)
            .frame(maxWidth: .infinity, alignment: detailSidebarShowsLabels ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 折叠/展开按钮
            HStack {
                if detailSidebarShowsLabels {
                    Text(L10n.k("user.detail.auto.overview", fallback: "概览"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDetailSidebarCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isDetailSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                        .frame(width: detailSidebarButtonSize, height: detailSidebarButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, detailSidebarShowsLabels ? 2 : 4)
            .frame(maxWidth: .infinity)

            // OpenClaw logo
            OpenClawLogoMark()
                .frame(width: detailSidebarShowsLabels ? 48 : 32, height: detailSidebarShowsLabels ? 48 : 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)

            // Agent 选择器
            if detailSidebarShowsLabels {
                Menu {
                    ForEach(agents) { agent in
                        Button {
                            selectedAgentId = agent.id
                        } label: {
                            // 合并为单个 Text，macOS Menu 才能正确显示全部内容
                            let emoji = agent.emoji.isEmpty ? "🤖" : agent.emoji
                            Text("\(emoji) \(agent.name)")
                        }
                        .contextMenu {
                            Button {
                                editingAgentModel = agent
                            } label: {
                                Label(L10n.k("agent.menu.edit_model", fallback: "编辑模型配置"), systemImage: "cpu")
                            }
                        }
                    }
                    Divider()
                    Button {
                        showCreateAgent = true
                    } label: {
                        Label(L10n.k("agent.menu.create", fallback: "新建角色…"), systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: 4) {
                        let emoji = selectedAgent?.emoji.isEmpty == false ? selectedAgent!.emoji : "🤖"
                        Text("\(emoji) \(selectedAgentLabel)")
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.horizontal, 10)
            } else {
                EmptyView()
            }

            Divider()
                .padding(.horizontal, detailSidebarShowsLabels ? 10 : 4)
                .padding(.vertical, 2)

            // 分组：当前角色
            if detailSidebarShowsLabels {
                Text(L10n.k("user.detail.sidebar.agent_section", fallback: "当前角色"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
            ForEach(agentTabs, id: \.self) { sidebarButton($0) }

            Divider()
                .padding(.horizontal, detailSidebarShowsLabels ? 10 : 4)
                .padding(.vertical, 2)

            // 分组：实例
            if detailSidebarShowsLabels {
                Text(L10n.k("user.detail.sidebar.instance_section", fallback: "实例"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
            ForEach(gatewayTabs, id: \.self) { sidebarButton($0) }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(
            minWidth: detailSidebarWidth,
            idealWidth: detailSidebarWidth,
            maxWidth: detailSidebarWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(.bar)
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .overview:  overviewTabContent
        case .files:     UserFilesView(users: [user], preselectedUser: user)
        case .logs:
            GatewayLogViewer(username: user.username, externalSearchQuery: $logSearchText)
        case .cron:      CronTabView(username: user.username, agentId: selectedAgentId)
        case .skills:    SkillsTabView(username: user.username, gatewayURL: gatewayURL, agentId: selectedAgentId)
        case .characterDef: CharacterDefTabView(
                username: user.username,
                agentId: selectedAgentId,
                agentLabel: selectedAgent != nil && selectedAgent?.isDefault != true ? selectedAgentLabel : nil
            )
            .id(selectedAgentId)
        case .sessions:  SessionsTabView(username: user.username, agentId: selectedAgentId)
        case .memory:    MemoryTabView(username: user.username, agentId: selectedAgentId)
        case .processes:
            ProcessTabView(
                username: user.username
            )
        }
    }

    // 拆分：基础布局 + 事件响应，减轻编译器类型推断压力
    private var tabbedContentBase: some View {
        HStack(spacing: 0) {
            detailSidebar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refreshStatus() }
        .task {
            // 视图首次出现时，如果 gateway 已就绪，补消费 pending 团队 agent
            if isEffectivelyRunning && gatewayHub.readinessMap[user.username] == .ready {
                await consumePendingTeamAgents()
                await consumePendingV2Agents()
            }
        }
        .task(id: detailAutoRefreshActive) {
            guard detailAutoRefreshActive else { return }
            while detailAutoRefreshActive, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard detailAutoRefreshActive, !Task.isCancelled else { break }
                await refreshStatus()
            }
        }
        .onChange(of: helperClient.isConnected) { _, connected in
            if connected {
                Task { await refreshStatus() }
            } else {
                // 连接丢失时保持"待判定"状态，避免误落到概览页。
                versionChecked = false
                // XPC 连接断开时，若 withCheckedContinuation 正在等待 installOpenclaw/getOpenclawVersion
                // 的 reply，reply 会被丢弃导致 continuation 永远不 resume，isInstalling 永久卡 true。
                // 此处主动解锁，让用户可以关闭窗口并重试。
                if isInstalling {
                    installError = String(localized: "upgrade.error.connection_lost", defaultValue: "连接中断，请关闭后重试")
                    isInstalling = false
                }
                if isRollingBack {
                    installError = String(localized: "upgrade.error.connection_lost", defaultValue: "连接中断，请关闭后重试")
                    isRollingBack = false
                }
            }
        }
        .modifier(GatewayProbeModifier(
            username: user.username,
            uid: user.macUID ?? 0,
            gatewayURL: gatewayURL,
            hub: gatewayHub
        ))
        .onChange(of: user.isRunning) { _, running in
            if !running && !isEffectivelyRunning {
                Task { await gatewayHub.disconnect(username: user.username) }
            }
            if running {
                refreshGatewayURLUntilTokenReady()
            } else {
                gatewayURLTokenPollTask?.cancel()
                gatewayURLTokenPollTask = nil
                // Gateway 启动后立即崩溃：readinessMap 还停留在 .starting，但进程已死
                if gatewayHub.readinessMap[user.username] == .starting {
                    gatewayHub.markPendingStopped(username: user.username)
                    showHealthCheck = true
                }
            }
        }
        .onChange(of: selectedAgentId) { _, newId in
            guard let newId = newId else { return }
            // 通过 JS 通知 OpenClaw WebUI 切换到对应 agent 的会话
            // agentId 仅允许 [a-zA-Z0-9_-]，过滤非法字符防止 JS 注入
            let sanitized = newId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !sanitized.isEmpty else { return }
            // OpenClaw session key 格式: "agent:{agentId}:main"
            let sessionKey = "agent:\(sanitized):main"
            let js = """
            (function() {
                var sk = '\(sessionKey)';
                var sel = document.querySelector('.chat-controls__session select');
                if (sel) {
                    if (!sel.querySelector('option[value=\"' + sk + '\"]')) {
                        var opt = document.createElement('option');
                        opt.value = sk;
                        opt.textContent = sk;
                        sel.appendChild(opt);
                    }
                    sel.value = sk;
                    sel.dispatchEvent(new Event('change', { bubbles: true }));
                } else {
                    var url = new URL(window.location.href);
                    url.searchParams.set('session', sk);
                    window.location.href = url.toString();
                }
            })();
            """
            embeddedOverviewConsoleStore.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
        .onChange(of: gatewayHub.readinessMap[user.username]) { _, newReadiness in
            if newReadiness == .ready {
                Task { await refreshStatus() }
                Task { await consumePendingTeamAgents() }
                Task { await consumePendingV2Agents() }
                embeddedOverviewConsoleStore.reloadCurrent()
            } else if newReadiness == .stopped, !user.isRunning {
                Task { await gatewayHub.disconnect(username: user.username) }
                gatewayURLTokenPollTask?.cancel()
                gatewayURLTokenPollTask = nil
                // 探测状态从启动态回落后重判一次初始化路由，避免卡在概览。
                Task { await refreshStatus() }
            }
            if newReadiness == .ready || newReadiness == .starting {
                refreshGatewayURLUntilTokenReady()
            }
        }
    }

    private var tabbedContentSheets1: some View {
        tabbedContentBase
        .sheet(isPresented: $showPassword) {
            UserPasswordSheet(username: user.username)
        }
        .sheet(isPresented: $showCreateAgent) {
            CreateAgentSheet(username: user.username) { newAgent in
                Task {
                    // 重启 gateway 让新 agent 配置生效
                    if isEffectivelyRunning {
                        try? await helperClient.restartGateway(username: user.username)
                    }
                    await loadAgents()
                    // 自动选中新创建的 agent
                    selectedAgentId = newAgent.id
                }
            }
            .environment(helperClient)
        }
        .sheet(item: $editingAgentModel) { agent in
            AgentModelEditSheet(username: user.username, agent: agent) { updatedAgent in
                if let idx = agents.firstIndex(where: { $0.id == updatedAgent.id }) {
                    agents[idx] = updatedAgent
                }
            }
        }
        .sheet(isPresented: $showHermesSetup) {
            HermesSetupSheet(user: user)
        }
        .sheet(isPresented: $showConfig) {
            ConfigEditorSheet(user: user)
        }
        .sheet(isPresented: $showModelConfig) {
            modelConfigSheet
        }
        .sheet(isPresented: $showModelPriority) {
            ModelPrioritySheet(user: user) {
                Task {
                    beginGatewayRestartVisualTransition()
                    await refreshModelStatusSummary()
                }
            }
            .environment(helperClient)
            .environment(gatewayHub)
        }
        .sheet(isPresented: $showHealthCheck) {
            DiagnosticsSheet(user: user, engineHint: defaultModel) { diagResult in
                lastHealthCheck = diagResult
            }
        }
    }

    private var tabbedContent: some View {
        tabbedContentSheets1
        .onReceive(NotificationCenter.default.publisher(for: .openUpgradeSheet)) { notification in
            guard let username = notification.userInfo?["username"] as? String,
                  username == user.username,
                  !isInstalling, !isRollingBack,
                  updater.needsUpdate(user.openclawVersion),
                  let latest = updater.latestVersion else { return }
            pendingUpgradeVersion = latest
            showUpgradeConfirm = true
        }
        .sheet(isPresented: $showUpgradeConfirm) {
            UpgradeConfirmSheet(
                username: user.username,
                currentVersion: user.openclawVersion,
                targetVersion: pendingUpgradeVersion ?? "",
                releaseURL: updater.latestReleaseURL,
                isInstalling: isInstalling,
                installError: installError
            ) { version, _ in
                Task { await installOpenclaw(version: version) }
            }
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteUserSheet(
                username: user.username,
                adminUser: NSUserName(),
                option: $deleteHomeOption,
                adminPassword: $deleteAdminPassword,
                isDeleting: isDeleting,
                error: deleteError,
                onConfirm: { Task { await performDelete() } },
                onCancel: {
                    showDeleteConfirm = false
                    deleteError = nil
                    deleteAdminPassword = ""
                }
            )
            .interactiveDismissDisabled(isDeleting)
        }
        .confirmationDialog(
            L10n.k("user.detail.auto.confirm_pause_freeze", fallback: "确认暂停冻结"),
            isPresented: $showPauseFreezeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.k("user.detail.auto.pause_freeze", fallback: "暂停冻结")) {
                showPauseFreezeConfirm = false
                performAction { try await freezeUser(mode: .pause) }
            }
            Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) {
                showPauseFreezeConfirm = false
            }
        } message: {
            Text(L10n.k("user.detail.auto.pause_freeze_suspend_openclaw_processes_and_resume_later", fallback: "暂停冻结：挂起 openclaw 进程，可恢复继续执行（内存不释放）"))
        }
        .confirmationDialog(
            L10n.k("user.detail.auto.confirm_normal_freeze", fallback: "确认普通冻结"),
            isPresented: $showNormalFreezeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.k("user.detail.auto.normal_freeze", fallback: "普通冻结")) {
                showNormalFreezeConfirm = false
                performAction { try await freezeUser(mode: .normal) }
            }
            Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) {
                showNormalFreezeConfirm = false
            }
        } message: {
            Text(L10n.k("user.detail.auto.freeze_stop_gateway", fallback: "普通冻结：停止 Gateway，最稳妥"))
        }
        .confirmationDialog(
            L10n.k("user.detail.auto.confirm_flash_freeze", fallback: "确认速冻"),
            isPresented: $showFlashFreezeConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.k("user.detail.auto.flash_freeze", fallback: "速冻"), role: .destructive) {
                showFlashFreezeConfirm = false
                performAction { try await freezeUser(mode: .flash) }
            }
            Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) {
                showFlashFreezeConfirm = false
            }
        } message: {
            Text(L10n.k("user.detail.auto.userprocess_openclaw_process_start", fallback: "将紧急终止该虾的用户空间进程（优先 openclaw 相关），已终止进程不可恢复，只能重新启动。"))
        }
        .alert(
            L10n.k("user.detail.auto.file", fallback: "文件快传结果"),
            isPresented: Binding(
                get: { quickTransferAlertMessage != nil },
                set: { show in if !show { quickTransferAlertMessage = nil } }
            )
        ) {
            Button(L10n.k("user.detail.auto.copy_path", fallback: "复制路径")) {
                QuickFileTransferService.copyToPasteboard(quickTransferClipboardText)
            }
            Button(L10n.k("user.detail.auto.got_it", fallback: "知道了"), role: .cancel) {
                quickTransferAlertMessage = nil
            }
        } message: {
            Text(quickTransferAlertMessage ?? "")
        }
        .sheet(isPresented: $showGatewayNodeRepairSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.k("user.detail.gateway.node_missing.title", fallback: "检测到 Node.js 环境缺失"))
                    .font(.headline)
                Text(
                    L10n.f(
                        "user.detail.gateway.node_missing.message",
                        fallback: "启动 Gateway 依赖该用户私有目录中的 node/npm/npx。\n\n将执行基础环境修复，完成后你可以手动再次启动。",
                        user.username
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                ProgressView(
                    value: Double(gatewayNodeRepairCompletedSteps),
                    total: 4
                ) {
                    Text(L10n.f("user.detail.gateway.repair.progress", fallback: "修复进度：%d/4", gatewayNodeRepairCompletedSteps))
                        .font(.subheadline.weight(.medium))
                } currentValueLabel: {
                    Text("\(Int((Double(gatewayNodeRepairCompletedSteps) / 4) * 100))%")
                }

                if !gatewayNodeRepairCurrentStep.isEmpty {
                    Text(L10n.f("user.detail.gateway.repair.current_step", fallback: "当前步骤：%@", gatewayNodeRepairCurrentStep))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !gatewayNodeRepairReason.isEmpty {
                    Text(L10n.f("user.detail.gateway.repair.reason", fallback: "触发原因：%@", gatewayNodeRepairReason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let gatewayNodeRepairError, !gatewayNodeRepairError.isEmpty {
                    Text(gatewayNodeRepairError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    if gatewayNodeRepairReadyToRetryStart {
                        Button(L10n.k("user.detail.gateway.repair.retry_start", fallback: "再次启动 Gateway")) {
                            Task { await retryGatewayStartAfterRepairFromSheet() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGatewayNodeRepairing)
                    } else {
                        Button(isGatewayNodeRepairing
                               ? L10n.k("user.detail.gateway.repair.in_progress", fallback: "修复中…")
                               : L10n.k("user.detail.gateway.repair.start", fallback: "开始修复")) {
                            Task { await runGatewayNodeRepairFlow() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGatewayNodeRepairing)
                    }
                    Spacer()
                    Button(L10n.k("user.detail.gateway.repair.close", fallback: "关闭")) {
                        showGatewayNodeRepairSheet = false
                    }
                    .disabled(isGatewayNodeRepairing)
                }
            }
            .padding(18)
            .frame(minWidth: 520)
        }
        .modifier(MainContentAlertsModifier(user: user,
            showRollbackConfirm: $showRollbackConfirm,
            showLogoutConfirm: $showLogoutConfirm,
            showResetConfirm: $showResetConfirm,
            preUpgradeVersion: preUpgradeVersion,
            performRollback: performRollback,
            performLogout: performLogout,
            performReset: performReset
        ))
    }

    // MARK: - 概览 Tab（原 mainContent）

    @ViewBuilder
    private var overviewTabContent: some View {
        switch initPresentationRoute {
        case .loading:
            ProgressView(L10n.k("user.detail.auto.text_f522c76d24", fallback: "检查环境…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await refreshStatus() }
        case .standaloneWizard:
            standaloneInitWizardNotice
        case .detailTabs:
            if user.isAdmin && versionChecked && user.openclawVersion == nil && !isEffectivelyRunning {
                ContentUnavailableView(
                    L10n.k("user.detail.auto.adminnot_installed_openclaw", fallback: "管理员账号未安装 openclaw"),
                    systemImage: "shield.lefthalf.filled",
                    description: Text(L10n.k("user.detail.auto.admin_accounts_only_support_basic_management_installation_and", fallback: "管理员账号仅支持基础管理，不支持在该账号执行安装或初始化。"))
                )
            } else {
                embeddedOverviewConsoleContent
            }
        }
    }

    @ViewBuilder
    private var embeddedOverviewConsoleContent: some View {
        if shouldShowOverviewSidebar {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    overviewConsolePane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if shouldRenderOverviewSidebar {
                        Divider()
                        overviewSidebar
                    }
                }

                if !shouldRenderOverviewSidebar {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isOverviewSidebarCollapsed = false
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                    )
                    .padding(16)
                }
            }
        } else {
            overviewContent
        }
    }

    @ViewBuilder
    private var overviewConsolePane: some View {
        if shouldEmbedOverviewConsole,
           let url = embeddedOverviewConsoleURL {
            EmbeddedGatewayConsoleView(url: url, store: embeddedOverviewConsoleStore)
        } else if shouldEmbedOverviewConsole, isEffectivelyRunning {
            ContentUnavailableView {
                Label(L10n.k("user.detail.auto.waiting_token", fallback: "等待 Token…"), systemImage: "network")
            } description: {
                Text(L10n.k("user.detail.auto.statussync", fallback: "状态同步中…"))
            }
        } else if shouldEmbedOverviewConsole {
            ContentUnavailableView {
                Label(L10n.k("models.managed_user.not_running", fallback: "未运行"), systemImage: "power")
            } description: {
                Text(L10n.k("user.detail.auto.openclaw_needs_start_before_console", fallback: "启动该虾的 Gateway 后，这里会直接显示 Web 控制台。"))
            }
        } else {
            overviewContent
        }
    }

    private var embeddedOverviewConsoleURL: URL? {
        guard shouldEmbedOverviewConsole,
              isEffectivelyRunning,
              let urlStr = gatewayURL,
              !urlStr.isEmpty,
              gatewayToken(from: urlStr) != nil else { return nil }
        return URL(string: urlStr)
    }

    private var shouldShowOverviewSupplementaryCards: Bool {
        shouldShowOverviewSupplementaryEntries(
            selectedTabRawValue: selectedTab.rawValue,
            initPresentationRoute: initPresentationRoute
        )
    }

    private var overviewSidebar: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: UserDetailWindowLayout.overviewSidebarSectionSpacing) {
                    overviewStatusCard
                    overviewQuickActionSection

                    // ─── Agent 联动区 ───
                    if shouldShowOverviewSupplementaryCards {
                        Divider().padding(.vertical, 4)
                        overviewAgentIdentifier
                        overviewSupplementaryEntriesSection
                    }

                    overviewResourceCard
                    overviewOpenConsoleButton
                }
                .padding(.horizontal, UserDetailWindowLayout.overviewSidebarPadding)
                .padding(.top, UserDetailWindowLayout.overviewFloatingHeaderTopPadding)
                .padding(.bottom, UserDetailWindowLayout.overviewSidebarPadding)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOverviewSidebarCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(
                        width: UserDetailWindowLayout.overviewFloatingToolbarButtonSize,
                        height: UserDetailWindowLayout.overviewFloatingToolbarButtonSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, UserDetailWindowLayout.overviewSidebarPadding)
            .padding(.top, UserDetailWindowLayout.overviewFloatingHeaderTopPadding)
        }
        .frame(
            minWidth: UserDetailWindowLayout.overviewSidebarWidth,
            idealWidth: UserDetailWindowLayout.overviewSidebarWidth,
            maxWidth: UserDetailWindowLayout.overviewSidebarWidth,
            maxHeight: .infinity,
            alignment: .top
        )
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), ignoresSafeAreaEdges: [.bottom, .trailing])
    }

    private var overviewStatusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.08))
                Image(systemName: "globe")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(
                width: UserDetailWindowLayout.overviewStatusCardIconSize,
                height: UserDetailWindowLayout.overviewStatusCardIconSize
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(overviewStatusColor)
                        .frame(width: 10, height: 10)
                    Text(readinessLabel)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(overviewVersionAndPortLabel)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if updater.needsUpdate(user.openclawVersion),
                       let latest = updater.latestVersion {
                        Button(L10n.k("user.detail.version.update_badge", fallback: "有新版本")) {
                            pendingUpgradeVersion = latest
                            showUpgradeConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(!helperClient.isConnected || isInstalling || isRollingBack)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(UserDetailWindowLayout.overviewStatusCardPadding)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var overviewQuickActionSection: some View {
        VStack(alignment: .leading, spacing: UserDetailWindowLayout.overviewCompactActionSpacing) {
            // 第一行：启动/重启 | 终端
            HStack(spacing: UserDetailWindowLayout.overviewCompactActionSpacing) {
                overviewCompactActionButton(
                    title: user.isRunning
                        ? L10n.k("user.detail.auto.restart", fallback: "重启")
                        : ((gatewayHub.readinessMap[user.username] == .starting)
                            ? L10n.k("views.user_detail_view.start", fallback: "启动中…")
                            : L10n.k("user.detail.auto.start_action", fallback: "启动")),
                    systemImage: "arrow.clockwise",
                    tint: user.isRunning ? Color.accentColor : Color.cyan.opacity(0.16),
                    foreground: user.isRunning ? .white : .cyan,
                    disabled: isLoading
                        || !helperClient.isConnected
                        || (!user.isRunning && gatewayHub.readinessMap[user.username] == .starting)
                ) {
                    if user.isRunning {
                        gatewayHub.markPendingStart(username: user.username)
                        beginGatewayRestartVisualTransition()
                        performAction { try await helperClient.restartGateway(username: user.username) }
                    } else {
                        performAction {
                            if user.isFrozen {
                                try await unfreezeUser()
                            }
                            gatewayHub.markPendingStart(username: user.username)
                            beginGatewayRestartVisualTransition()
                            try await startGatewayWithNodeRepairPrompt()
                        }
                    }
                }

                overviewCompactActionButton(
                    title: L10n.k("user.detail.auto.health_check", fallback: "体检"),
                    systemImage: "stethoscope",
                    tint: Color.secondary.opacity(0.08),
                    foreground: .primary,
                    disabled: !helperClient.isConnected
                ) {
                    showHealthCheck = true
                }

                overviewCompactActionButton(
                    title: L10n.k("user.detail.auto.terminal", fallback: "终端"),
                    systemImage: "terminal",
                    tint: Color.secondary.opacity(0.08),
                    foreground: .primary,
                    disabled: !helperClient.isConnected
                ) {
                    openTerminal()
                }
            }

            // 第二行：冻结 | 更多操作
            HStack(spacing: UserDetailWindowLayout.overviewCompactActionSpacing) {
                Menu {
                    if user.isFrozen {
                        Button {
                            performAction { try await unfreezeUser() }
                        } label: {
                            Label(L10n.k("user.detail.auto.unfreeze", fallback: "解除冻结"), systemImage: "play.circle")
                        }
                    }
                    Button {
                        showPauseFreezeConfirm = true
                    } label: {
                        Label(L10n.k("user.detail.auto.pause_freeze_recoverable", fallback: "暂停冻结"), systemImage: "pause.circle")
                    }
                    Button {
                        showNormalFreezeConfirm = true
                    } label: {
                        Label(L10n.k("user.detail.auto.freeze_stop_gateway", fallback: "普通冻结"), systemImage: "snowflake")
                    }
                    Button(role: .destructive) {
                        showFlashFreezeConfirm = true
                    } label: {
                        Label(L10n.k("user.detail.auto.flash_freeze_emergency_kill", fallback: "速冻"), systemImage: "bolt.fill")
                    }
                } label: {
                    overviewCompactActionLabel(
                        title: freezeToolbarLabel,
                        systemImage: user.isFrozen ? "snowflake.circle" : "snowflake",
                        tint: Color.orange.opacity(0.16),
                        foreground: .orange
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(isLoading || !helperClient.isConnected)
                .opacity((isLoading || !helperClient.isConnected) ? 0.55 : 1)

                Menu {
                    Button {
                        showPassword = true
                    } label: {
                        Label(L10n.k("views.user_detail_view.os_user_password", fallback: "获取 OS 用户密码"), systemImage: "key")
                    }

                    if updater.needsUpdate(user.openclawVersion),
                       let latest = updater.latestVersion {
                        Divider()
                        Button {
                            pendingUpgradeVersion = latest
                            showUpgradeConfirm = true
                        } label: {
                            Label(
                                L10n.f("user.detail.openclaw.upgrade_to", fallback: "Upgrade openclaw (v%@)", latest),
                                systemImage: "arrow.up.circle"
                            )
                        }
                        .disabled(isInstalling || isRollingBack || !helperClient.isConnected)
                    }

                    if !user.isAdmin {
                        Divider()

                        Button {
                            showLogoutConfirm = true
                        } label: {
                            Label(L10n.k("user.detail.auto.log_out", fallback: "注销"), systemImage: "rectangle.portrait.and.arrow.right")
                        }

                        Divider()

                        Button {
                            showResetConfirm = true
                        } label: {
                            Label(L10n.k("user.detail.auto.reset", fallback: "重置生存空间"), systemImage: "arrow.counterclockwise")
                        }
                        .disabled(isResetting || !helperClient.isConnected)

                        Button(role: .destructive) {
                            deleteError = nil
                            deleteAdminPassword = ""
                            showDeleteConfirm = true
                        } label: {
                            Label(L10n.k("user.detail.auto.deleteuser", fallback: "删除用户"), systemImage: "trash")
                        }
                        .disabled(isDeleting || !helperClient.isConnected || isSelf)
                    }
                } label: {
                    overviewCompactActionLabel(
                        title: L10n.k("user.detail.auto.more_actions", fallback: "更多操作"),
                        systemImage: "ellipsis.circle",
                        tint: Color.secondary.opacity(0.06),
                        foreground: .secondary
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(isLoading)
                .opacity(isLoading ? 0.55 : 1)
            }
        }
    }

    /// 当前 Agent 标识（多 agent 时显示）
    @ViewBuilder
    private var overviewAgentIdentifier: some View {
        if agents.count > 1, let agent = selectedAgent {
            HStack(spacing: 6) {
                if !agent.emoji.isEmpty {
                    Text(agent.emoji)
                }
                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    private var overviewSupplementaryEntriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            overviewSupplementaryCard(
                title: L10n.k("user.detail.auto.model_configuration", fallback: "模型配置"),
                subtitle: (selectedAgent?.modelPrimary ?? defaultModel).map { L10n.f("views.user_detail_view.current_model", fallback: "当前：%@", String(describing: $0)) }
                    ?? L10n.k("user.detail.auto.configuration", fallback: "未配置")
            ) {
                HStack(spacing: 8) {
                    overviewCompactActionButton(
                        title: L10n.k("user.detail.auto.manage", fallback: "管理"),
                        systemImage: "slider.horizontal.3",
                        tint: Color.secondary.opacity(0.08),
                        foreground: .primary,
                        disabled: !helperClient.isConnected
                    ) {
                        showModelConfig = true
                    }
                    overviewCompactActionButton(
                        title: L10n.k("model_priority.button", fallback: "优先级"),
                        systemImage: "list.number",
                        tint: Color.secondary.opacity(0.08),
                        foreground: .primary,
                        disabled: !helperClient.isConnected
                    ) {
                        showModelPriority = true
                    }
                }
            }

            overviewChannelCard
        }
    }

    private var overviewResourceCard: some View {
        VStack(spacing: 0) {
            overviewMetricRow(
                color: overviewStatusColor,
                value: overviewCpuMemoryLabel,
                title: L10n.k("user.detail.auto.resource_usage", fallback: "内存与算力资源")
            )
            Divider().opacity(0.55)
            overviewMetricRow(
                color: .orange,
                value: overviewOpenClawStorageLabel,
                title: L10n.k("user.detail.auto.core_environment_openclaw", fallback: "核心环境 (.openclaw)")
            )
            Divider().opacity(0.55)
            overviewMetricRow(
                color: .blue,
                value: overviewHomeStorageLabel,
                title: L10n.k("user.detail.auto.user_data_partition", fallback: "用户数据区容量")
            )
            Divider().opacity(0.55)
            overviewMetricRow(
                color: .secondary.opacity(0.25),
                value: overviewUptimeLabel,
                title: L10n.k("user.detail.auto.stable_running", fallback: "持续稳定运行")
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func overviewMetricRow(color: Color, value: String, title: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, UserDetailWindowLayout.overviewMetricRowVerticalPadding)
    }

    private var overviewOpenConsoleButton: some View {
        Button {
            guard let url = embeddedOverviewConsoleURL ?? (gatewayURL.flatMap(URL.init(string:))) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(L10n.k("user.detail.auto.open_openclaw_web_console", fallback: "打开 Web 控制台"))
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .frame(height: UserDetailWindowLayout.overviewPrimaryButtonHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: UserDetailWindowLayout.overviewPrimaryButtonCornerRadius, style: .continuous)
                .fill(Color.green)
                .shadow(color: Color.green.opacity(0.14), radius: 12, y: 6)
        )
        .disabled(gatewayURL == nil)
        .opacity(gatewayURL == nil ? 0.6 : 1)
    }

    private var freezeToolbarLabel: String {
        if user.isFrozen {
            return user.freezeMode?.statusLabel ?? L10n.k("user.detail.auto.freeze", fallback: "冻结")
        }
        return L10n.k("user.detail.auto.freeze", fallback: "冻结")
    }

    private func overviewCompactActionButton(
        title: String,
        systemImage: String,
        tint: Color,
        foreground: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            overviewCompactActionLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                foreground: foreground
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func overviewCompactActionLabel(
        title: String,
        systemImage: String,
        tint: Color,
        foreground: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: UserDetailWindowLayout.overviewActionButtonHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: UserDetailWindowLayout.overviewActionButtonCornerRadius, style: .continuous)
                .fill(tint)
        )
    }

    private func overviewSupplementaryCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                content()
            }
            .padding(UserDetailWindowLayout.overviewSupplementaryCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UserDetailWindowLayout.overviewSupplementaryCardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var overviewStatusColor: Color {
        if user.isFrozen {
            switch user.freezeMode {
            case .pause: return .blue
            case .flash: return .orange
            case .normal, .none: return .cyan
            }
        }

        switch gatewayHub.readinessMap[user.username] {
        case .ready: return .green
        case .starting: return .orange
        case .zombie: return .red
        case .stopped, .none: return user.isRunning ? .orange : .secondary
        }
    }

    private var overviewVersionAndPortLabel: String {
        user.openclawVersionLabel ?? "—"
    }

    private var overviewCpuMemoryLabel: String {
        let cpu = user.cpuPercent ?? currentShrimpStats?.cpuPercent
        let mem = user.memRssMB ?? currentShrimpStats?.memRssMB
        switch (cpu, mem) {
        case let (.some(cpu), .some(mem)):
            return String(format: "%.1f%% / %.0f MB", cpu, mem)
        case let (.some(cpu), .none):
            return String(format: "%.1f%% / —", cpu)
        case let (.none, .some(mem)):
            return String(format: "— / %.0f MB", mem)
        default:
            return "— / —"
        }
    }

    private var overviewOpenClawStorageLabel: String {
        guard let bytes = currentShrimpStats?.openclawDirBytes, bytes > 0 else { return "—" }
        return FormatUtils.formatBytes(bytes)
    }

    private var overviewHomeStorageLabel: String {
        guard let bytes = currentShrimpStats?.homeDirBytes, bytes > 0 else { return "—" }
        return FormatUtils.formatBytes(bytes)
    }

    private var overviewUptimeLabel: String {
        guard let startedAt = user.startedAt else { return "—" }
        return relativeUptimeString(since: startedAt)
    }

    private func relativeUptimeString(since date: Date) -> String {
        let interval = max(0, Int(Date().timeIntervalSince(date)))
        let day = interval / 86_400
        let hour = (interval % 86_400) / 3_600
        let minute = (interval % 3_600) / 60

        if day > 0 {
            return "\(day)天 \(max(hour, 1))小时"
        }
        if hour > 0 {
            return "\(hour)小时 \(max(minute, 1))分钟"
        }
        return "\(max(minute, 1))分钟"
    }

    @ViewBuilder
    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                quickTransferSection
                sharedFoldersSection
                configSection
                actionsSection
                dangerZoneSection
            }
            .padding(20)
        }
    }

    private var standaloneInitWizardNotice: some View {
        ContentUnavailableView {
            Label(L10n.k("user.detail.auto.setup_wizard", fallback: "初始化向导"), systemImage: "wand.and.stars")
        } description: {
            Text(L10n.k("user.detail.auto.init_wizard_opened_in_separate_window", fallback: "该虾的初始化流程已在独立窗口中打开，不再与概览等管理标签共用。"))
        } actions: {
            Button(L10n.k("user.detail.auto.reopen", fallback: "重新打开")) {
                openStandaloneInitWindow(force: true)
            }
            .buttonStyle(.borderedProminent)

            Button(L10n.k("user.detail.auto.refresh", fallback: "刷新状态")) {
                Task { await refreshStatus() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            maybeOpenStandaloneInitWindow()
        }
    }

    // MARK: - 状态卡片

    @ViewBuilder
    private var statusSection: some View {
        let readiness = gatewayHub.readinessMap[user.username] ?? (user.isRunning ? .starting : .stopped)
        let freezeSymbol: String = {
            switch user.freezeMode {
            case .pause: return "pause.circle"
            case .flash: return "bolt.fill"
            case .normal, .none: return "snowflake"
            }
        }()
        let freezeTint: Color = {
            switch user.freezeMode {
            case .pause: return .blue
            case .flash: return .orange
            case .normal, .none: return .cyan
            }
        }()

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.k("user.detail.auto.status", fallback: "运行状态"))
                    .font(.headline)
                Spacer()
                Button {
                    performAction { }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isLoading || !helperClient.isConnected)
            }

            Divider().opacity(0.55)

            if let warning = user.freezeWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.bottom, 2)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {

                // Gateway 状态
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.gateway_status", fallback: "网关状态"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if isLoading && !versionChecked {
                            ProgressView().scaleEffect(0.7)
                        } else if user.isFrozen {
                            Image(systemName: freezeSymbol)
                                .foregroundStyle(freezeTint)
                                .font(.system(size: 10, weight: .semibold))
                        } else {
                            GatewayStatusDot(readiness: readiness)
                        }
                        Text(readinessLabel)
                    }
                    if readiness == .starting, user.isRunning {
                        Text(L10n.k("user.detail.auto.statussync", fallback: "状态同步中…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 版本
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.version", fallback: "版本")).font(.caption).foregroundStyle(.secondary)
                    versionRowContent
                }

                // PID
                VStack(alignment: .leading, spacing: 4) {
                    Text("PID").font(.caption).foregroundStyle(.secondary)
                    if let pid = user.pid {
                        Text("\(pid)").monospacedDigit()
                    } else if isEffectivelyRunning {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                // 启动时间
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.start", fallback: "启动时间")).font(.caption).foregroundStyle(.secondary)
                    if let started = user.startedAt {
                        Text(started, style: .relative).foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                // CPU / 内存
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.resource_usage", fallback: "资源占用")).font(.caption).foregroundStyle(.secondary)
                    if let cpu = user.cpuPercent, let mem = user.memRssMB {
                        Text(String(format: "%.1f%%  /  %.0f MB", cpu, mem))
                            .monospacedDigit()
                    } else if isEffectivelyRunning, pool.snapshot == nil {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                // 网络
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.network", fallback: "网络流量")).font(.caption).foregroundStyle(.secondary)
                    networkRowContent
                }

                // 存储
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.storage", fallback: "存储")).font(.caption).foregroundStyle(.secondary)
                    StorageRowContent(snapshot: pool.snapshot, username: user.username)
                }

                // 地址
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.address", fallback: "地址")).font(.caption).foregroundStyle(.secondary)
                    addressRowContent
                }
            }
            .padding(.vertical, 4)

            Divider().opacity(0.55)

            // 体检
            healthCheckRowContent
        }
        .modifier(OverviewCardModifier())
    }

    @ViewBuilder
    private var versionRowContent: some View {
        HStack(spacing: 8) {
            if let v = user.openclawVersionLabel {
                Text(v)
                    .foregroundStyle(updater.needsUpdate(user.openclawVersion) ? .orange : .primary)
                if isInstalling || isRollingBack {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(versionSpinnerAnimating ? 360 : 0))
                            .animation(
                                .linear(duration: 0.9).repeatForever(autoreverses: false),
                                value: versionSpinnerAnimating
                            )
                            .onAppear { versionSpinnerAnimating = true }
                            .onDisappear { versionSpinnerAnimating = false }
                        Text(isRollingBack ? L10n.k("user.detail.auto.rollback", fallback: "回退中…") : L10n.k("user.detail.auto.upgrade", fallback: "升级中…"))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    if updater.needsUpdate(user.openclawVersion),
                       let latest = updater.latestVersion {
                        Button("↑v\(latest)") {
                            pendingUpgradeVersion = latest
                            showUpgradeConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(!helperClient.isConnected)
                    }
                    if preUpgradeVersion != nil {
                        Button(L10n.k("user.detail.auto.rollback", fallback: "↩回退")) { showRollbackConfirm = true }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(!helperClient.isConnected)
                    }
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var networkRowContent: some View {
        if let shrimp = pool.snapshot?.shrimps.first(where: { $0.username == user.username }) {
            let rateIn = FormatUtils.formatBps(shrimp.netRateInBps)
            let rateOut = FormatUtils.formatBps(shrimp.netRateOutBps)
            let totalIn = FormatUtils.formatTotalBytes(shrimp.netBytesIn)
            let totalOut = FormatUtils.formatTotalBytes(shrimp.netBytesOut)
            VStack(alignment: .leading, spacing: 2) {
                Text("↓ \(rateIn)  ↑ \(rateOut)")
                    .monospacedDigit()
                Text(L10n.f("views.user_detail_view.text_8559f26d", fallback: "累计 ↓ %@  ↑ %@", String(describing: totalIn), String(describing: totalOut)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if isEffectivelyRunning, pool.snapshot == nil {
            ProgressView().scaleEffect(0.6)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var addressRowContent: some View {
        if isEffectivelyRunning, let urlStr = gatewayURL, !urlStr.isEmpty,
           gatewayToken(from: urlStr) != nil,
           let nsURL = URL(string: urlStr) {
            Button(L10n.k("user.detail.auto.open_openclaw_web_console", fallback: "打开 OpenClaw Web 控制台")) {
                NSWorkspace.shared.open(nsURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(L10n.k("user.detail.auto.open", fallback: "点击在浏览器中打开"))
        } else if isEffectivelyRunning {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text(L10n.k("user.detail.auto.waiting_token", fallback: "等待 Token…")).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var healthCheckRowContent: some View {
        HStack(spacing: 12) {
            Text(L10n.k("user.detail.auto.health_check", fallback: "健康体检")).font(.subheadline)
            Spacer()
            Button(L10n.k("views.user_detail_view.text_258fc51d", fallback: "体检")) {
                showHealthCheck = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(!helperClient.isConnected)
        }
    }

    // MARK: - 文件快传

    @ViewBuilder
    private var quickTransferSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("user.detail.auto.file", fallback: "文件快传")).font(.headline)
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                    Text(L10n.k("user.detail.auto.file_folder_select", fallback: "支持拖入文件/文件夹，或点击下方区域选择后上传"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text(QuickFileTransferService.destinationAbsolutePath(username: user.username))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        let path = QuickFileTransferService.destinationAbsolutePath(username: user.username)
                        QuickFileTransferService.copyToPasteboard(path)
                    } label: {
                        Label(L10n.k("user.detail.auto.copy_path", fallback: "复制路径"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                Button {
                    Task { await quickTransferPickAndUpload() }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text(L10n.k("user.detail.auto.file_selectfile", fallback: "拖入文件到这里，或点击选择文件"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.secondary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.3, dash: [9, 7])
                            )
                    )
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { droppedURLs, _ in
                    let fileURLs = droppedURLs.filter(\.isFileURL)
                    guard !fileURLs.isEmpty else { return false }
                    Task { await quickTransferUpload(fileURLs) }
                    return true
                } isTargeted: { targeted in
                    isQuickTransferDropTargeted = targeted
                }
                .overlay {
                    if isQuickTransferDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        Color.accentColor.opacity(0.45),
                                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                    )
                            )
                            .allowsHitTesting(false)
                    }
                }

                if let last = quickTransferLastPaths.first {
                    HStack(spacing: 8) {
                        Text(L10n.k("user.detail.auto.recent_uploads", fallback: "最近上传："))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(last)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
            }
        }
        .modifier(OverviewCardModifier())
    }

    // MARK: - 共享文件夹

    @ViewBuilder
    private var sharedFoldersSection: some View {
        let vaultPath = "/Users/Shared/ClawdHome/vaults/\(user.username)"
        let publicPath = "/Users/Shared/ClawdHome/public"
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("user.detail.shared_folders.title", fallback: "共享文件夹")).font(.headline)
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                sharedFolderRow(
                    title: L10n.k("user.detail.shared_folders.vault", fallback: "安全文件夹"),
                    description: L10n.k("user.detail.shared_folders.vault_desc", fallback: "仅你和这只虾可访问"),
                    icon: "folder.badge.person.crop",
                    path: vaultPath
                )
                Divider().opacity(0.3)
                sharedFolderRow(
                    title: L10n.k("user.detail.shared_folders.public", fallback: "公共文件夹"),
                    description: L10n.k("user.detail.shared_folders.public_desc", fallback: "所有虾和你共享"),
                    icon: "folder",
                    path: publicPath
                )
            }
        }
        .modifier(OverviewCardModifier())
    }

    private func sharedFolderRow(title: String, description: String, icon: String, path: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await openSharedFolder(path: path) }
            } label: {
                Label(L10n.k("user.detail.shared_folders.reveal", fallback: "在 Finder 中显示"), systemImage: "arrow.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openSharedFolder(path: String) async {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? await helperClient.setupVault(username: user.username)
        }
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            // fallback 到父目录
            let parent = url.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    // MARK: - 配置区

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("user.detail.auto.configuration", fallback: "配置")).font(.headline)
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(L10n.k("user.detail.auto.model_configuration", fallback: "模型配置"))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        if let def = defaultModel {
                            Text(L10n.f("views.user_detail_view.current_model", fallback: "当前：%@", String(describing: def)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(L10n.k("user.detail.auto.configuration", fallback: "未配置"))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button(L10n.k("user.detail.auto.manage", fallback: "管理")) { showModelConfig = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!helperClient.isConnected)
                }
                Divider()
                channelDetailRow

                if let status = xcodeEnvStatus, !status.isHealthy {
                    Divider().padding(.top, 2)
                    xcodeEnvironmentCard
                }

                Divider().padding(.top, 2)
                DisclosureGroup(L10n.k("user.detail.auto.configuration", fallback: "高级配置"), isExpanded: $isAdvancedConfigExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.k("user.detail.auto.description", fallback: "描述")).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            TextField(L10n.k("user.detail.auto.example_imac", fallback: "例如：客厅 iMac / 儿童账号"), text: $descriptionDraft)
                                .textFieldStyle(.roundedBorder)
                            Button(L10n.k("user.detail.auto.save", fallback: "保存")) { saveDescription() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) == user.profileDescription)
                        }
                        if !user.isAdmin && user.clawType == .macosUser {
                            HStack {
                                Text(L10n.k("user.detail.auto.setup_wizard", fallback: "初始化向导")).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text(L10n.k("user.detail.auto.models_channelconfiguration", fallback: "可回到模型/频道步骤重新配置"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                if isReopeningInitWizard {
                                    ProgressView().scaleEffect(0.6)
                                }
                                Button(L10n.k("user.detail.auto.re_enter", fallback: "重新进入")) {
                                    Task { await reopenInitWizardAtModelStep() }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(!helperClient.isConnected || isReopeningInitWizard)
                            }
                        }
                        HStack {
                            Text(L10n.k("user.detail.auto.npm", fallback: "npm 源")).foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Picker(L10n.k("user.detail.auto.npm", fallback: "npm 源"), selection: $npmRegistryOption) {
                                ForEach(NpmRegistryOption.allCases, id: \.self) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .disabled(!helperClient.isConnected || isUpdatingNpmRegistry || !isNodeInstalledReady)
                            if isUpdatingNpmRegistry {
                                ProgressView().scaleEffect(0.6)
                            }
                        }
                        .onChange(of: npmRegistryOption) { oldValue, newValue in
                            guard oldValue != newValue, !suppressNpmRegistryOnChange else { return }
                            guard isNodeInstalledReady else {
                                npmRegistryError = L10n.k("user.detail.auto.node_js_not_installed_npm", fallback: "Node.js 未安装就绪，暂不允许切换 npm 源")
                                setDisplayedNpmRegistry(oldValue)
                                return
                            }
                            Task { await updateNpmRegistry(to: newValue) }
                        }
                        if !isNodeInstalledReady {
                            Text(L10n.k("user.detail.auto.node_js_is_not_ready_npm_source_switching", fallback: "Node.js 未安装就绪，暂不允许切换 npm 源。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let customURL = npmRegistryCustomURL, !customURL.isEmpty {
                            Text(L10n.f("views.user_detail_view.text_948c087f", fallback: "检测到自定义源：%@。切换后将覆盖为上方选项。", String(describing: customURL)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let err = npmRegistryError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Divider()
                        if let err = installError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(OverviewCardModifier())
    }

    // MARK: - 操作区

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("user.detail.auto.actions", fallback: "操作")).font(.headline)
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if user.isFrozen {
                        Button(L10n.k("user.detail.auto.unfreeze", fallback: "解冻")) {
                            performAction {
                                try await unfreezeUser()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if user.isRunning {
                        Button(L10n.k("user.detail.auto.restart", fallback: "重启")) {
                            gatewayHub.markPendingStart(username: user.username)
                            beginGatewayRestartVisualTransition()
                            performAction {
                                try await helperClient.restartGateway(username: user.username)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(
                            (gatewayHub.readinessMap[user.username] == .starting)
                                ? L10n.k("views.user_detail_view.start", fallback: "启动中…")
                                : L10n.k("user.detail.auto.start_action", fallback: "启动")
                        ) {
                            performAction {
                                if user.isFrozen {
                                    try await unfreezeUser()
                                }
                                gatewayHub.markPendingStart(username: user.username)
                                beginGatewayRestartVisualTransition()
                                try await startGatewayWithNodeRepairPrompt()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(gatewayHub.readinessMap[user.username] == .starting)
                    }

                    Button { openTerminal() } label: {
                        Label(L10n.k("user.detail.auto.terminal", fallback: "终端"), systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button {
                            showPauseFreezeConfirm = true
                        } label: { Label(L10n.k("user.detail.auto.pause_freeze_recoverable", fallback: "暂停冻结（可恢复）"), systemImage: "pause.circle") }
                        Button {
                            showNormalFreezeConfirm = true
                        } label: { Label(L10n.k("user.detail.auto.freeze_stop_gateway", fallback: "普通冻结（停止 Gateway）"), systemImage: "snowflake") }
                        Button(role: .destructive) {
                            showFlashFreezeConfirm = true
                        } label: { Label(L10n.k("user.detail.auto.flash_freeze_emergency_kill", fallback: "速冻（紧急终止进程）"), systemImage: "bolt.fill") }
                    } label: {
                        Label(L10n.k("user.detail.auto.freeze", fallback: "冻结…"), systemImage: "snowflake")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Menu {
                        Button {
                            showHealthCheck = true
                        } label: {
                            Label(L10n.k("user.detail.auto.health_check", fallback: "体检"), systemImage: "checkmark.shield")
                        }

                        Button {
                            showPassword = true
                        } label: {
                            Label(L10n.k("views.user_detail_view.os_user_password", fallback: "获取 OS 用户密码"), systemImage: "key")
                        }

                        Button {
                            showHermesSetup = true
                        } label: {
                            Label("Hermes Agent", systemImage: "brain.head.profile")
                        }

                        Divider()

                        if updater.needsUpdate(user.openclawVersion),
                           let latest = updater.latestVersion {
                            Button {
                                pendingUpgradeVersion = latest
                                showUpgradeConfirm = true
                            } label: {
                                Label(
                                    L10n.f("user.detail.openclaw.upgrade_to", fallback: "Upgrade openclaw (v%@)", latest),
                                    systemImage: "arrow.up.circle"
                                )
                            }
                            .disabled(isInstalling || isRollingBack || !helperClient.isConnected)

                            Divider()
                        }

                        if !user.isAdmin {
                            Button {
                                showLogoutConfirm = true
                            } label: {
                                Label(L10n.k("user.detail.auto.log_out", fallback: "注销"), systemImage: "rectangle.portrait.and.arrow.right")
                            }

                            Divider()

                            Button {
                                showResetConfirm = true
                            } label: {
                                Label(L10n.k("user.detail.auto.reset", fallback: "重置生存空间"), systemImage: "arrow.counterclockwise")
                            }
                            .disabled(isResetting || !helperClient.isConnected)

                            Button(role: .destructive) {
                                deleteError = nil
                                deleteAdminPassword = ""
                                showDeleteConfirm = true
                            } label: {
                                Label(L10n.k("user.detail.auto.deleteuser", fallback: "删除用户"), systemImage: "trash")
                            }
                            .disabled(isDeleting || !helperClient.isConnected || isSelf)
                        }
                    } label: {
                        Label(L10n.k("user.detail.auto.more_actions", fallback: "更多操作"), systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    Spacer()
                }
                .disabled(isLoading || !helperClient.isConnected)

                if !helperClient.isConnected {
                    Text(L10n.k("user.detail.auto.helper_clawdhome", fallback: "Helper 未连接，请先安装 ClawdHome 系统服务"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if user.isFrozen {
                    Text(frozenHintText)
                        .font(.caption)
                        .foregroundStyle(frozenHintColor)
                    if let warning = user.freezeWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let err = actionError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                if isInstalling || isRollingBack || showInstallConsole {
                    Divider().padding(.top, 4)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showInstallConsole.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showInstallConsole ? "chevron.down" : "chevron.right")
                                .imageScale(.small)
                            Text(L10n.k("user.detail.auto.command_output", fallback: "命令输出"))
                                .font(.caption).fontWeight(.medium)
                            Spacer()
                            if (isInstalling || isRollingBack) && !showInstallConsole {
                                Circle().fill(.blue).frame(width: 6, height: 6)
                                    .symbolEffect(.pulse, options: .repeating)
                            }
                            if isInstalling || isRollingBack {
                                Text(isRollingBack ? L10n.k("user.detail.auto.rollback", fallback: "回退中…") : L10n.k("user.detail.auto.upgrade", fallback: "升级中…"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)

                    if showInstallConsole {
                        TerminalLogPanel(username: user.username)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.top, 4)
        }
        .modifier(OverviewCardModifier())
    }

    @ViewBuilder
    private var modelConfigSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.k("user.detail.auto.model_configuration", fallback: "模型配置")).font(.headline)
                Spacer()
                Button(L10n.k("user.detail.auto.close", fallback: "关闭")) { showModelConfig = false }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()

            ScrollView {
                ProviderModelConfigPanel(
                    user: user,
                    onApplied: {
                        Task {
                            beginGatewayRestartVisualTransition()
                            await refreshModelStatusSummary()
                        }
                        showModelConfig = false
                    }
                )
                .environment(helperClient)
                .padding(16)
            }
        }
        .frame(width: 520)
    }

    private func refreshModelStatusSummary() async {
        if let status = await helperClient.getModelsStatus(username: user.username) {
            defaultModel = status.resolvedDefault ?? status.defaultModel
            fallbackModels = status.fallbacks
        }
    }

    /// 在重启/启动 Gateway 时，先让概览 Web 控制台回到等待态，再轮询新的 token。
    private func beginGatewayRestartVisualTransition() {
        gatewayURLTokenPollTask?.cancel()
        gatewayURLTokenPollTask = nil
        gatewayURL = nil
        embeddedOverviewConsoleStore.invalidateLoadedURL()
        refreshGatewayURLUntilTokenReady()
    }

    // MARK: - 操作封装

    private func performAction(_ action: @escaping () async throws -> Void) {
        Task {
            isLoading = true
            actionError = nil
            do {
                try await action()
            } catch {
                if error is GatewayStartNodeRepairPromptError {
                    // 已切换到"修复并继续启动"弹窗，不显示通用错误。
                } else if error is GatewayStartDiagnosticsPromptError {
                    // 已自动弹出诊断中心，不显示通用错误。
                } else {
                    actionError = error.localizedDescription
                }
            }
            await refreshStatus()
            isLoading = false
        }
    }

    private struct GatewayStartNodeRepairPromptError: Error {}
    private struct GatewayStartDiagnosticsPromptError: Error {}

    private func startGatewayWithNodeRepairPrompt() async throws {
        do {
            let result = try await helperClient.startGatewayDiagnoseNodeToolchain(username: user.username)
            switch result {
            case .started:
                return
            case .needsNodeRepair(let reason):
                appLog("[gateway-repair] detected missing base env user=\(user.username) reason=\(reason)", level: .warn)
                gatewayNodeRepairReason = reason
                gatewayNodeRepairCompletedSteps = 0
                gatewayNodeRepairCurrentStep = ""
                gatewayNodeRepairError = nil
                gatewayNodeRepairReadyToRetryStart = false
                showGatewayNodeRepairSheet = true
                throw GatewayStartNodeRepairPromptError()
            }
        } catch let error where !(error is GatewayStartNodeRepairPromptError) {
            appLog("[gateway-diag] start failed, opening diagnostics user=\(user.username) error=\(error.localizedDescription)", level: .warn)
            showHealthCheck = true
            throw GatewayStartDiagnosticsPromptError()
        }
    }

    private func runGatewayNodeRepairFlow() async {
        guard !isGatewayNodeRepairing else { return }
        isGatewayNodeRepairing = true
        gatewayNodeRepairError = nil
        gatewayNodeRepairReadyToRetryStart = false
        gatewayNodeRepairCompletedSteps = 0
        gatewayNodeRepairCurrentStep = "修复 Homebrew 权限"
        appLog("[gateway-repair] start user=\(user.username)")
        defer {
            isGatewayNodeRepairing = false
        }
        do {
            appLog("[gateway-repair] step 1/4 homebrew-permission user=\(user.username)")
            try? await helperClient.repairHomebrewPermission(username: user.username)
            gatewayNodeRepairCompletedSteps = 1

            gatewayNodeRepairCurrentStep = "安装/修复 Node.js"
            appLog("[gateway-repair] step 2/4 install-node user=\(user.username)")
            try await helperClient.installNode(username: user.username, nodeDistURL: nodeDistURL)
            gatewayNodeRepairCompletedSteps = 2

            gatewayNodeRepairCurrentStep = "配置 npm 目录"
            appLog("[gateway-repair] step 3/4 setup-npm-env user=\(user.username)")
            try await helperClient.setupNpmEnv(username: user.username)
            gatewayNodeRepairCompletedSteps = 3

            gatewayNodeRepairCurrentStep = "执行体检修复"
            appLog("[gateway-repair] step 4/4 health-check-fix user=\(user.username)")
            _ = await helperClient.runHealthCheck(username: user.username, fix: true)
            gatewayNodeRepairCompletedSteps = 4

            gatewayNodeRepairCurrentStep = "修复完成，等待再次启动"
            gatewayNodeRepairReadyToRetryStart = true
            appLog("[gateway-repair] completed user=\(user.username)")
        } catch {
            appLog("[gateway-repair] failed user=\(user.username) error=\(error.localizedDescription)", level: .error)
            gatewayNodeRepairError = error.localizedDescription
        }
    }

    private func retryGatewayStartAfterRepairFromSheet() async {
        guard !isGatewayNodeRepairing else { return }
        isGatewayNodeRepairing = true
        gatewayNodeRepairError = nil
        gatewayNodeRepairCurrentStep = "正在启动 Gateway"
        appLog("[gateway-repair] retry-start user=\(user.username)")
        defer { isGatewayNodeRepairing = false }
        do {
            gatewayHub.markPendingStart(username: user.username)
            beginGatewayRestartVisualTransition()
            try await helperClient.startGateway(username: user.username)
            showGatewayNodeRepairSheet = false
            appLog("[gateway-repair] retry-start success user=\(user.username)")
        } catch {
            appLog("[gateway-repair] retry-start failed user=\(user.username) error=\(error.localizedDescription)", level: .error)
            gatewayNodeRepairError = error.localizedDescription
        }
        await refreshStatus()
    }

    private func quickTransferPickAndUpload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard await panel.begin() == .OK else { return }
        await quickTransferUpload(panel.urls)
    }

    private func quickTransferUpload(_ droppedURLs: [URL]) async {
        let result = await QuickFileTransferService.uploadDroppedItems(
            droppedURLs,
            username: user.username,
            helperClient: helperClient
        )
        quickTransferLastPaths = result.uploadedTopLevelPaths
        quickTransferClipboardText = result.clipboardText
        QuickFileTransferService.copyToPasteboard(result.clipboardText)
        quickTransferAlertMessage = result.summaryMessage
    }

    private func saveDescription() {
        let normalized = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        pool.setDescription(normalized, for: user.username)
        descriptionDraft = normalized
    }

    private func freezeUser(mode: FreezeMode) async throws {
        appLog("freeze start user=\(user.username) mode=\(mode.statusLabel)")
        do {
            let previousAutostart = await helperClient.getUserAutostart(username: user.username)
            try? await helperClient.setUserAutostart(username: user.username, enabled: false)
            if mode != .pause {
                gatewayHub.markPendingStopped(username: user.username)
                do {
                    try await helperClient.stopGateway(username: user.username)
                } catch {
                    // 速冻为兜底路径：即使 stopGateway 失败也继续强制终止进程。
                    if mode != .flash { throw error }
                }
            }

            if mode == .pause {
                let processes = await helperClient.getProcessList(username: user.username)
                let targets = ProcessEmergencyFreezeResolver.resolvePauseTargets(processes: processes)
                var pausedPIDs: [Int32] = []
                var failedPIDs: [Int32] = []
                for proc in targets {
                    do {
                        try await helperClient.killProcess(pid: proc.pid, signal: Int32(SIGSTOP))
                        pausedPIDs.append(proc.pid)
                    } catch {
                        failedPIDs.append(proc.pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.pid", fallback: "@%@ 暂停冻结部分失败，未挂起 PID: %@", String(describing: user.username), String(describing: pidList)))
                }
                pool.setFrozen(
                    true,
                    mode: mode,
                    pausedPIDs: pausedPIDs,
                    previousAutostartEnabled: previousAutostart,
                    for: user.username
                )
                appLog("freeze success user=\(user.username) mode=\(mode.statusLabel) paused=\(pausedPIDs.count)")
                return
            }

            if mode == .flash {
                let processes = await helperClient.getProcessList(username: user.username)
                let targets = ProcessEmergencyFreezeResolver.resolveTargets(processes: processes)
                var failedPIDs: [Int32] = []
                for proc in targets {
                    do {
                        try await helperClient.killProcess(pid: proc.pid, signal: 9)
                    } catch {
                        failedPIDs.append(proc.pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.pid_0cbf36", fallback: "@%@ 速冻部分失败，未终止 PID: %@", String(describing: user.username), String(describing: pidList)))
                }
                // 二次 stop，防止状态滞后导致 launchd/job 被重新拉起。
                try? await helperClient.stopGateway(username: user.username)
                // 速冻后立即复核：若关键进程被外部拉起，给出明确提示。
                try? await Task.sleep(for: .milliseconds(250))
                let remaining = await helperClient.getProcessList(username: user.username)
                    .filter(ProcessEmergencyFreezeResolver.isOpenclawRelated)
                if !remaining.isEmpty {
                    let pidList = remaining.prefix(8).map { String($0.pid) }.joined(separator: ",")
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.pid_414c18", fallback: "@%@ 速冻后检测到进程仍在运行（可能被自动拉起），PID: %@", String(describing: user.username), String(describing: pidList)))
                }
            }

            pool.setFrozen(
                true,
                mode: mode,
                pausedPIDs: [],
                previousAutostartEnabled: previousAutostart,
                for: user.username
            )
            appLog("freeze success user=\(user.username) mode=\(mode.statusLabel)")
        } catch {
            appLog("freeze failed user=\(user.username) mode=\(mode.statusLabel) error=\(error.localizedDescription)", level: .error)
            throw error
        }
    }

    private func unfreezeUser() async throws {
        let mode = user.freezeMode
        appLog("unfreeze start user=\(user.username) mode=\(mode?.statusLabel ?? L10n.k("views.user_detail_view.text_1622dc9b", fallback: "未知"))")
        do {
            let pausedPIDs = user.pausedProcessPIDs
            if mode == .pause, !pausedPIDs.isEmpty {
                var failedPIDs: [Int32] = []
                for pid in pausedPIDs {
                    do {
                        try await helperClient.killProcess(pid: pid, signal: Int32(SIGCONT))
                    } catch {
                        failedPIDs.append(pid)
                    }
                }
                if !failedPIDs.isEmpty {
                    let pidList = failedPIDs.prefix(8).map(String.init).joined(separator: ",")
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.pid_e5e7a7", fallback: "@%@ 解除暂停部分失败，未恢复 PID: %@", String(describing: user.username), String(describing: pidList)))
                }
            }
            if let restoreAutostart = user.freezePreviousAutostartEnabled {
                try? await helperClient.setUserAutostart(username: user.username, enabled: restoreAutostart)
            }
            pool.setFrozen(false, for: user.username)
            appLog("unfreeze success user=\(user.username)")
        } catch {
            appLog("unfreeze failed user=\(user.username) error=\(error.localizedDescription)", level: .error)
            throw error
        }
    }

    private var frozenHintText: String {
        switch user.freezeMode {
        case .pause:
            return L10n.k("views.user_detail_view.shrimp_paused_freeze_mode_openclaw_processes_suspended_resume", fallback: "该虾已暂停冻结：openclaw 进程被挂起，解除冻结后会继续执行（内存不会释放）。")
        case .flash:
            return L10n.k("views.user_detail_view.userprocess_freezestart", fallback: "该虾已速冻：已紧急终止用户空间进程，解除冻结后需手动重新启动服务。")
        case .normal:
            return L10n.k("views.user_detail_view.freeze_gateway_stop_freezestart", fallback: "该虾已冻结：Gateway 已停止，解除冻结后可再次启动。")
        case .none:
            return L10n.k("views.user_detail_view.freeze", fallback: "该虾已冻结。")
        }
    }

    private var frozenHintColor: Color {
        switch user.freezeMode {
        case .pause: .blue
        case .flash: .orange
        case .normal, .none: .cyan
        }
    }

    @MainActor
    private func refreshStatus() async {
        if !forceOnboardingAtEntry, pool.consumeNeedsOnboarding(username: user.username) {
            forceOnboardingAtEntry = true
        }
        if isRefreshingStatus {
            refreshStatusNeedsRerun = true
            return
        }
        isRefreshingStatus = true
        refreshStatusGeneration &+= 1
        let requestID = refreshStatusGeneration
        defer {
            isRefreshingStatus = false
            if refreshStatusNeedsRerun {
                refreshStatusNeedsRerun = false
                Task { await refreshStatus() }
            }
        }

        guard helperClient.isConnected else {
            // Helper 未连接时不要把状态标记为"已判定"，避免误落到概览。
            versionChecked = false
            isNodeInstalledReady = false
            xcodeEnvStatus = nil
            return
        }

        // 所有 XPC 调用一次性并行发出，避免分批串行等待
        async let statusResult = helperClient.getGatewayStatus(username: user.username)
        async let wizardStateResult = loadWizardState()
        async let nodeInstalledResult = helperClient.isNodeInstalled(username: user.username)
        async let xcodeStatusResult = helperClient.getXcodeEnvStatus()
        async let urlResult = helperClient.getGatewayURL(username: user.username)
        async let modelsStatusResult = helperClient.getModelsStatus(username: user.username)
        async let installedVersionResult = helperClient.getOpenclawVersion(username: user.username)
        async let npmRegistryResult = helperClient.getNpmRegistry(username: user.username)

        // --- 处理结果 ---

        if let (running, pid) = try? await statusResult {
            if user.isFrozen {
                user.isRunning = false
                user.pid = nil
                user.startedAt = nil
            } else {
                user.isRunning = running
                user.pid = pid > 0 ? pid : nil
                if running, pid > 0 {
                    // 使用 sysctl 获取进程真实启动时间
                    user.startedAt = GatewayHub.processStartTime(pid: pid)
                } else {
                    user.startedAt = nil
                }
            }
        }
        guard requestID == refreshStatusGeneration else { return }

        let installedVersion = await installedVersionResult
        user.openclawVersion = installedVersion
        versionChecked = true

        let wizardState = await wizardStateResult
        let ensuredPending = await ensureOnboardingWizardSessionIfNeeded(
            existingState: wizardState,
            forceOnboarding: forceOnboardingAtEntry,
            hasInstalledOpenClaw: installedVersion != nil
        )
        hasPendingInitWizard = ensuredPending
        isNodeInstalledReady = await nodeInstalledResult
        xcodeEnvStatus = await xcodeStatusResult

        let (url, modelsStatus, registryURL) = await (
            urlResult,
            modelsStatusResult,
            npmRegistryResult
        )
        guard requestID == refreshStatusGeneration else { return }

        gatewayURL = url.isEmpty ? nil : url
        if user.isRunning, gatewayToken(from: url) == nil {
            refreshGatewayURLUntilTokenReady()
        } else if gatewayToken(from: url) != nil {
            gatewayURLTokenPollTask?.cancel()
            gatewayURLTokenPollTask = nil
        }
        defaultModel = modelsStatus?.resolvedDefault ?? modelsStatus?.defaultModel
        fallbackModels = modelsStatus?.fallbacks ?? []
        applyLoadedNpmRegistry(registryURL)
        loadPreUpgradeInfo()
        // Gateway 运行且有地址时，建立 WebSocket 连接（幂等）
        if user.isRunning, let gatewayURLValue = gatewayURL {
            await gatewayHub.connect(username: user.username, gatewayURL: gatewayURLValue)
        }
        await loadAgents()

    }

    /// 加载当前 Shrimp 的 Agent 列表
    private func loadAgents() async {
        // 优先用 GatewayHub RPC（gateway 运行时）
        if isEffectivelyRunning, let rpcAgents = await gatewayHub.agentsList(username: user.username) {
            agents = rpcAgents
        } else {
            // fallback: 通过 HelperClient 读文件
            agents = (try? await helperClient.listAgents(username: user.username)) ?? []
        }
        // 确保主角色（main）始终存在且排在首位
        if !agents.contains(where: { $0.id == "main" }) {
            let mainAgent = AgentProfile(id: "main", name: L10n.k("agent.main.name", fallback: "默认角色"), emoji: "🎭", modelPrimary: nil, modelFallbacks: [], workspacePath: nil, isDefault: true)
            agents.insert(mainAgent, at: 0)
        } else if let idx = agents.firstIndex(where: { $0.id == "main" }), idx != 0 {
            // main 存在但不在首位，移到首位
            let main = agents.remove(at: idx)
            agents.insert(main, at: 0)
        }
        // 给 main 加友好名称和 emoji（服务端可能返回原始 "main"）
        if let idx = agents.firstIndex(where: { $0.id == "main" }) {
            if agents[idx].name == "main" || agents[idx].name.isEmpty {
                agents[idx].name = L10n.k("agent.main.name", fallback: "默认角色")
            }
            if agents[idx].emoji.isEmpty {
                agents[idx].emoji = "🎭"
            }
        }
        if selectedAgentId == nil || !agents.contains(where: { $0.id == selectedAgentId }) {
            selectedAgentId = agents.first(where: { $0.isDefault })?.id ?? agents.first?.id
        }
    }

    /// 消费 pending_team_agents.json：gateway 首次 ready 后批量创建团队 agent
    private func consumePendingTeamAgents() async {
        let pendingPath = ".openclaw/workspace/pending_team_agents.json"
        guard let data = try? await helperClient.readFile(username: user.username, relativePath: pendingPath),
              let members = try? JSONDecoder().decode([AgentDNA].self, from: data),
              !members.isEmpty
        else { return }

        // 先写入空数组标记"已消费"，防止重复导入
        try? await helperClient.writeFile(username: user.username, relativePath: pendingPath, data: Data("[]".utf8))

        appLog("[Team] 开始批量导入 \(members.count) 个 agent @\(user.username)")

        for dna in members {
            let id = dna.suggestedAgentID ?? dna.id
            let workspace = "~/.openclaw/workspace-\(id)"
            do {
                var profile = try await gatewayHub.agentsCreate(
                    username: user.username,
                    name: id,
                    workspace: workspace,
                    emoji: dna.emoji.isEmpty ? nil : dna.emoji
                )
                if !dna.name.isEmpty && dna.name != id {
                    try? await gatewayHub.agentsUpdate(username: user.username, agentId: profile.id, name: dna.name)
                    profile.name = dna.name
                }
                if let soul = dna.fileSoul, !soul.isEmpty {
                    try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "SOUL.md", content: soul)
                }
                if let identity = dna.fileIdentity, !identity.isEmpty {
                    try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "IDENTITY.md", content: identity)
                }
                if let userFile = dna.fileUser, !userFile.isEmpty {
                    try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "USER.md", content: userFile)
                }
                appLog("[Team] 导入成功: \(dna.name) (\(profile.id))")
            } catch {
                appLog("[Team] 导入失败: \(dna.name) — \(error.localizedDescription)", level: .warn)
            }
        }

        // 重载 agent 列表 + 重启 gateway 让配置生效
        if isEffectivelyRunning {
            try? await helperClient.restartGateway(username: user.username)
        }
        await loadAgents()
        appLog("[Team] 批量导入完成 @\(user.username)")
    }

    /// 消费 pending_v2_agents.json：v2 向导完成后，gateway ready 时为各 agent 写入 persona 文件
    /// v2 中 agent 已通过 applyV2Config 写入 openclaw.json，gateway 启动时自动初始化；
    /// 此处仅补写 SOUL/IDENTITY/USER.md（角色定义文件）
    private func consumePendingV2Agents() async {
        let pendingPath = ".openclaw/workspace/pending_v2_agents.json"
        guard let data = try? await helperClient.readFile(username: user.username, relativePath: pendingPath),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !entries.isEmpty
        else { return }

        // 先清空，防止重复消费
        try? await helperClient.writeFile(username: user.username, relativePath: pendingPath, data: Data("[]".utf8))

        // 拿到当前 gateway 里的 agent 列表（agentId → profile），用于匹配
        guard let profiles = await gatewayHub.agentsList(username: user.username) else { return }
        let profileByDefId = Dictionary(uniqueKeysWithValues: profiles.compactMap { p -> (String, AgentProfile)? in
            // OpenClaw normalize 后 agentId 等于 AgentDef.id（lowercase 英数 + _-）
            (p.id, p)
        })

        appLog("[V2] 开始写入 persona 文件，共 \(entries.count) 个 agent @\(user.username)")

        for entry in entries {
            guard let agentDefId = entry["agentDefId"] as? String,
                  let dnaDict = entry["dna"] as? [String: Any],
                  let dnaData = try? JSONSerialization.data(withJSONObject: dnaDict),
                  let dna = try? JSONDecoder().decode(AgentDNA.self, from: dnaData)
            else { continue }

            // agentId 在 gateway 里可能与 agentDefId 相同（OpenClaw normalize）
            guard let profile = profileByDefId[agentDefId] else {
                appLog("[V2] 找不到 agent profile: \(agentDefId)，跳过 persona 写入", level: .warn)
                continue
            }

            if let soul = dna.fileSoul, !soul.isEmpty {
                try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "SOUL.md", content: soul)
            }
            if let identity = dna.fileIdentity, !identity.isEmpty {
                try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "IDENTITY.md", content: identity)
            }
            if let userFile = dna.fileUser, !userFile.isEmpty {
                try? await gatewayHub.agentsFileSet(username: user.username, agentId: profile.id, fileName: "USER.md", content: userFile)
            }
            appLog("[V2] persona 写入完成: \(dna.name) (\(profile.id))")
        }

        await loadAgents()
        appLog("[V2] persona 写入全部完成 @\(user.username)")
    }

    private func refreshGatewayURLUntilTokenReady(
        maxAttempts: Int = 20,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) {
        let current = gatewayURL
        if gatewayToken(from: current) != nil { return }
        let readiness = gatewayHub.readinessMap[user.username]
        guard user.isRunning || readiness == .starting || readiness == .ready else { return }

        gatewayURLTokenPollTask?.cancel()
        gatewayURLTokenPollTask = Task { @MainActor in
            for attempt in 1...maxAttempts {
                guard !Task.isCancelled else { return }
                let url = await helperClient.getGatewayURL(username: user.username)
                guard !Task.isCancelled else { return }
                if !url.isEmpty {
                    gatewayURL = url
                    if gatewayToken(from: url) != nil {
                        gatewayURLTokenPollTask = nil
                        return
                    }
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
            gatewayURLTokenPollTask = nil
        }
    }

    private func gatewayToken(from gatewayURL: String?) -> String? {
        guard let gatewayURL,
              let components = URLComponents(string: gatewayURL),
              let fragment = components.fragment,
              fragment.hasPrefix("token=") else { return nil }
        let token = String(fragment.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func loadWizardState() async -> InitWizardState? {
        let json = await helperClient.loadInitState(username: user.username)
        return InitWizardState.from(json: json)
    }

    /// 会话路由优先使用 active；若历史状态存在可恢复进度（failed/running），也保持进入向导。
    /// 当首次安装且没有可恢复会话时，自动创建 onboarding 会话。
    private func ensureOnboardingWizardSessionIfNeeded(
        existingState: InitWizardState?,
        forceOnboarding: Bool,
        hasInstalledOpenClaw: Bool
    ) async -> Bool {
        let shouldForceOnboarding = forceOnboarding
            && !user.isAdmin
            && user.clawType == .macosUser

        if let state = existingState {
            let inferredStep: InitStep? = {
                if let step = InitStep.from(key: state.currentStep) {
                    return step
                }
                for step in InitStep.allCases {
                    let raw = state.steps[step.key] ?? state.steps[step.title] ?? "pending"
                    if raw == "failed" || raw == "running" {
                        return step
                    }
                }
                return InitStep.allCases.first { step in
                    let raw = state.steps[step.key] ?? state.steps[step.title] ?? "pending"
                    return raw != "done"
                }
            }()

            let hasRecoverableProgress: Bool = {
                if state.isCompleted { return false }
                return InitStep.allCases.contains { step in
                    let raw = state.steps[step.key] ?? state.steps[step.title] ?? "pending"
                    return raw != "pending"
                }
            }()

            // 迁移旧脏状态：active=true 但全 pending，会导致 UI 误判为"正在初始化"。
            if state.active && !state.isCompleted && !hasRecoverableProgress {
                var repaired = state
                repaired.active = false
                repaired.currentStep = nil
                repaired.updatedAt = Date()
                do {
                    try await helperClient.saveInitState(username: user.username, json: repaired.toJSON())
                } catch {
                    actionError = L10n.f("views.user_detail_view.text_5cce2fbd", fallback: "初始化向导状态修复失败：%@", String(describing: error.localizedDescription))
                }
                user.initStep = nil
                let readiness = gatewayHub.readinessMap[user.username]
                return !user.isAdmin
                    && user.clawType == .macosUser
                    && !hasInstalledOpenClaw
                    && !(user.isRunning || readiness == .starting || readiness == .ready)
            }

            if state.active || hasRecoverableProgress {
                if let step = inferredStep {
                    user.initStep = step.title
                }
                if !state.active {
                    var repaired = state
                    repaired.active = true
                    if repaired.currentStep == nil {
                        repaired.currentStep = inferredStep?.key
                    }
                    repaired.updatedAt = Date()
                    do {
                        try await helperClient.saveInitState(username: user.username, json: repaired.toJSON())
                    } catch {
                        actionError = L10n.f("views.user_detail_view.text_5cce2fbd", fallback: "初始化向导状态修复失败：%@", String(describing: error.localizedDescription))
                    }
                }
                return true
            }

            // 已有未完成会话，但尚未开始（全部 pending）：
            // 仅在"仍符合 onboarding 条件"时保持在初始化向导 pre-start。
            if !state.isCompleted {
                let shouldKeepOnboarding = shouldForceOnboarding || (!user.isAdmin
                    && user.clawType == .macosUser
                    && !hasInstalledOpenClaw)
                if shouldKeepOnboarding {
                    user.initStep = nil
                    return true
                }
            }
        }

        // 已经完成过初始化，不自动重启向导。
        if let state = existingState, state.isCompleted {
            user.initStep = nil
            return false
        }

        guard !user.isAdmin, user.clawType == .macosUser else {
            user.initStep = nil
            return false
        }
        guard shouldForceOnboarding || !hasInstalledOpenClaw else {
            user.initStep = nil
            return false
        }
        let readiness = gatewayHub.readinessMap[user.username]
        if !shouldForceOnboarding && (user.isRunning || readiness == .starting || readiness == .ready) {
            // Gateway 已运行/启动中时，说明该用户不是"未初始化"状态，不应自动回流到初始化向导。
            user.initStep = nil
            return false
        }

        var state = InitWizardState()
        state.schemaVersion = 2
        state.mode = .onboarding
        // 仅创建会话壳，不预置为 running，避免"未实际开始却显示正在初始化"。
        state.active = false
        state.currentStep = nil
        state.steps = [
            InitStep.basicEnvironment.key: "pending",
            InitStep.injectRole.key: "pending",
            InitStep.configureModel.key: "pending",
            InitStep.configureChannel.key: "pending",
            InitStep.finish.key: "pending",
        ]
        state.npmRegistry = npmRegistryOption.rawValue
        state.updatedAt = Date()

        do {
            try await helperClient.saveInitState(username: user.username, json: state.toJSON())
            user.initStep = nil
            return true
        } catch {
            actionError = L10n.f("views.user_detail_view.text_020b8a41", fallback: "初始化向导状态写入失败：%@", String(describing: error.localizedDescription))
            user.initStep = nil
            return shouldForceOnboarding
        }
    }

    /// 在已初始化状态下重新进入初始化向导，从"模型配置"步骤继续。
    /// 该入口会持久化状态，App 重启后仍停留在该步骤。
    private func reopenInitWizardAtModelStep() async {
        guard helperClient.isConnected else { return }
        isReopeningInitWizard = true
        defer { isReopeningInitWizard = false }

        var state = InitWizardState()
        state.schemaVersion = 2
        state.mode = .reconfigure
        state.active = true
        state.currentStep = InitStep.configureModel.key
        state.steps = [
            InitStep.basicEnvironment.key: "done",
            InitStep.injectRole.key: "done",
            InitStep.configureModel.key: "running",
            InitStep.configureChannel.key: "pending",
            InitStep.finish.key: "pending",
        ]
        state.npmRegistry = npmRegistryOption.rawValue
        state.modelName = defaultModel ?? ""
        state.channelType = "telegram"
        state.updatedAt = Date()

        do {
            try await helperClient.saveInitState(username: user.username, json: state.toJSON())
            user.initStep = InitStep.configureModel.title
            hasPendingInitWizard = true
            versionChecked = true
            actionError = nil
            openStandaloneInitWindow(force: true)
        } catch {
            actionError = L10n.f("views.user_detail_view.text_ceb875b6", fallback: "重新进入初始化向导失败：%@", String(describing: error.localizedDescription))
        }
    }

    private func maybeOpenStandaloneInitWindow() {
        guard initPresentationRoute == .standaloneWizard else { return }
        openStandaloneInitWindow(force: false)
    }

    private func openStandaloneInitWindow(force: Bool) {
        if !force && hasOpenedStandaloneInitWindow {
            return
        }
        hasOpenedStandaloneInitWindow = true
        openWindow(id: "user-init-wizard", value: user.username)
    }

    private func applyLoadedNpmRegistry(_ registryURL: String) {
        let normalized = NpmRegistryOption.normalize(registryURL)
        if normalized.isEmpty {
            npmRegistryCustomURL = nil
            setDisplayedNpmRegistry(.npmOfficial)
            return
        }
        if let option = NpmRegistryOption.fromRegistryURL(normalized) {
            npmRegistryCustomURL = nil
            setDisplayedNpmRegistry(option)
        } else {
            npmRegistryCustomURL = normalized
            setDisplayedNpmRegistry(.npmOfficial)
        }
    }

    private func setDisplayedNpmRegistry(_ option: NpmRegistryOption) {
        suppressNpmRegistryOnChange = true
        npmRegistryOption = option
        suppressNpmRegistryOnChange = false
    }

    private func updateNpmRegistry(to option: NpmRegistryOption) async {
        guard helperClient.isConnected else {
            npmRegistryError = L10n.k("user.detail.auto.helper_npm", fallback: "Helper 未连接，无法切换 npm 源")
            return
        }
        guard isNodeInstalledReady else {
            npmRegistryError = L10n.k("user.detail.auto.node_js_not_installed_npm", fallback: "Node.js 未安装就绪，暂不允许切换 npm 源")
            return
        }
        isUpdatingNpmRegistry = true
        npmRegistryError = nil
        do {
            try await helperClient.setNpmRegistry(username: user.username, registry: option.rawValue)
        } catch {
            npmRegistryError = error.localizedDescription
        }
        let effective = await helperClient.getNpmRegistry(username: user.username)
        applyLoadedNpmRegistry(effective)
        isUpdatingNpmRegistry = false
    }

    @ViewBuilder
    private var xcodeEnvironmentCard: some View {
        let status = xcodeEnvStatus
        let healthState: DetailXcodeHealthState = {
            guard let status else { return .checking }
            return status.isHealthy ? .healthy : .unhealthy
        }()
        let healthy = healthState == .healthy
        let iconName: String = {
            switch healthState {
            case .checking: return "clock"
            case .healthy: return "checkmark.circle.fill"
            case .unhealthy: return "exclamationmark.triangle.fill"
            }
        }()
        let iconColor: Color = {
            switch healthState {
            case .checking: return .secondary
            case .healthy: return .green
            case .unhealthy: return .orange
            }
        }()
        let backgroundColor: Color = {
            switch healthState {
            case .checking: return Color.secondary.opacity(0.07)
            case .healthy: return Color.green.opacity(0.07)
            case .unhealthy: return Color.orange.opacity(0.07)
            }
        }()
        let statusColor: Color = {
            if status == nil { return .secondary }
            return healthy ? .secondary : .orange
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 12))
                Text(L10n.k("user.detail.auto.development_environment", fallback: "开发环境"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission {
                    ProgressView().scaleEffect(0.6)
                }
                Text(status == nil ? L10n.k("views.user_detail_view.text_d6a22312", fallback: "检查中…") : (healthy ? L10n.k("views.user_detail_view.text_298ac017", fallback: "环境正常") : L10n.k("views.user_detail_view.text_cba971a5", fallback: "需要修复")))
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            if let status, !status.isHealthy {
                VStack(alignment: .leading, spacing: 4) {
                    Label(status.commandLineToolsInstalled ? L10n.k("user.detail.auto.clt", fallback: "CLT 已安装") : L10n.k("user.detail.auto.clt_not_installed", fallback: "CLT 未安装"), systemImage: status.commandLineToolsInstalled ? "checkmark" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(status.commandLineToolsInstalled ? Color.secondary : Color.orange)
                    Label(status.licenseAccepted ? L10n.k("user.detail.auto.xcode_license", fallback: "Xcode license 已接受") : L10n.k("user.detail.auto.xcode_license", fallback: "Xcode license 未接受"), systemImage: status.licenseAccepted ? "checkmark" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(status.licenseAccepted ? Color.secondary : Color.orange)
                    HStack(spacing: 8) {
                        Button(isInstallingXcodeCLT ? L10n.k("user.detail.auto.text_b2c6913616", fallback: "安装中…") : L10n.k("user.detail.auto.install_developer_tools", fallback: "安装开发工具")) {
                            Task { await installXcodeCommandLineTools() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                        Button(isAcceptingXcodeLicense ? L10n.k("user.detail.auto.processing", fallback: "处理中…") : L10n.k("user.detail.auto.xcode", fallback: "同意 Xcode 许可")) {
                            Task { await acceptXcodeLicense() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                        Button(isRepairingHomebrewPermission ? L10n.k("user.detail.auto.processing", fallback: "处理中…") : L10n.k("user.detail.auto.repair_homebrew_permission", fallback: "修复 Homebrew 权限")) {
                            Task { await repairHomebrewPermission() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                        Button(L10n.k("user.detail.auto.open", fallback: "打开软件更新")) {
                            openSoftwareUpdate()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)
                    }
                    if let message = xcodeFixMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !status.detail.isEmpty {
                        Text(status.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
    }

    private func installXcodeCommandLineTools() async {
        isInstallingXcodeCLT = true
        xcodeFixMessage = nil
        do {
            try await helperClient.installXcodeCommandLineTools()
            xcodeFixMessage = L10n.k("user.detail.auto.hintdone", fallback: "已触发系统安装窗口，请按提示完成安装。")
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
        isInstallingXcodeCLT = false
    }

    private func acceptXcodeLicense() async {
        isAcceptingXcodeLicense = true
        xcodeFixMessage = nil
        do {
            try await helperClient.acceptXcodeLicense()
            xcodeFixMessage = L10n.k("user.detail.auto.license_refreshstatus", fallback: "已执行 license 接受，正在刷新状态。")
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
        isAcceptingXcodeLicense = false
    }

    private func repairHomebrewPermission() async {
        isRepairingHomebrewPermission = true
        xcodeFixMessage = nil
        do {
            try await helperClient.repairHomebrewPermission(username: user.username)
            xcodeFixMessage = L10n.k("user.detail.auto.repair_homebrew_permission_done", fallback: "Homebrew 权限修复完成：已安装/更新 ~/.brew，并写入 ~/.zprofile 环境变量。")
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
        isRepairingHomebrewPermission = false
    }

    private func openSoftwareUpdate() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") else {
            return
        }
        NSWorkspace.shared.open(url)
        xcodeFixMessage = L10n.k("user.detail.auto.open_settings_command_line_tools", fallback: "已打开“软件更新”。若未看到安装弹窗，可在系统设置中手动安装 Command Line Tools。")
    }

    // MARK: - 版本回退持久化

    private func loadPreUpgradeInfo() {
        let dict = UserDefaults.standard.dictionary(forKey: "preUpgrade.\(user.username)")
        preUpgradeVersion = dict?["version"] as? String
    }

    private func savePreUpgradeInfo() {
        let key = "preUpgrade.\(user.username)"
        if let v = preUpgradeVersion {
            UserDefaults.standard.set(["version": v], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func performLogout() async {
        isLoggingOut = true
        actionError = nil
        do {
            try await helperClient.logoutUser(username: user.username)
            await refreshStatus()
        } catch {
            actionError = error.localizedDescription
        }
        isLoggingOut = false
    }

    private func performReset() async {
        isResetting = true
        do {
            try await helperClient.resetUserEnv(username: user.username)
            // 重置后 openclawVersion 变为 nil，触发初始化向导
            user.openclawVersion = nil
            versionChecked = false
        } catch {
            actionError = error.localizedDescription
        }
        isResetting = false
    }

    private func performDelete() async {
        isDeleting = true
        deleteError = nil

        let keepHome = deleteHomeOption == .keepHome
        let adminPassword = deleteAdminPassword
        deleteAdminPassword = ""   // 立即清除内存中的密码

        let targetUsername = user.username   // 在 main actor 上捕获，避免跨 actor 访问 warning
        do {
            // 删除前预清理：停止/卸载 gateway、移除群组、归档 vault
            try? await helperClient.prepareDeleteUser(username: targetUsername)
            // 执行 sysadminctl 删除（使用管理员凭据）
            try await UserDeleteService.deleteUserViaSysadminctl(username: targetUsername, keepHome: keepHome, adminPassword: adminPassword)
            // 删除后清理：移除状态文件
            try? await helperClient.cleanupDeletedUser(username: targetUsername)

            isDeleting = false
            showDeleteConfirm = false
            deleteError = nil
            deleteAdminPassword = ""
            onDeleted?()
        } catch {
            deleteError = error.localizedDescription
            isDeleting = false
            showDeleteConfirm = true   // 重新打开 sheet 显示错误
        }
    }


    private func openTerminal() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("user.detail.auto.cli_maintenance_advanced", fallback: "命令行维护（高级）"),
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func openChannelOnboarding(_ flow: ChannelOnboardingFlow) {
        openWindow(
            id: "channel-onboarding",
            value: "\(flow.rawValue):\(user.username):\(ChannelOnboardingEntryMode.configuration.rawValue)"
        )
    }

    /// 按频道 ID 打开配对窗口（支持所有已知频道）
    private func openChannelOnboarding(_ channelId: String) {
        let canonical = canonicalChannelId(channelId)
        if let flow = ChannelOnboardingFlow(rawValue: canonical) {
            openChannelOnboarding(flow)
        } else {
            // 对于尚无专用 onboarding 流程的频道，使用通用 channel-onboarding
            openWindow(
                id: "channel-onboarding",
                value: "\(channelId):\(user.username)"
            )
        }
    }

    // MARK: - 频道状态 UI

    /// 默认展示的频道（即使未绑定也显示）
    private static let defaultChannelIds = ["feishu", "weixin"]

    /// 频道别名归一化（例如 openclaw-weixin → weixin）
    private static let channelAliasToCanonical: [String: String] = [
        "openclaw-weixin": "weixin"
    ]

    /// 频道对应的 SF Symbol
    private static let channelSystemImages: [String: String] = [
        "feishu": "message",
        "weixin": "message.badge",
        "slack": "number",
        "discord": "bubble.left.and.bubble.right",
        "telegram": "paperplane",
        "whatsapp": "message",
        "signal": "antenna.radiowaves.left.and.right",
        "imessage": "message.fill",
        "googlechat": "message.badge",
    ]

    /// compact 概览卡片：显示已绑定频道 + 默认频道
    private var overviewChannelCard: some View {
        let cStore = gatewayHub.channelStore(for: user.username)
        let visibleChannels = channelVisibleIds(store: cStore)
        return overviewSupplementaryCard(
            title: L10n.k("user.detail.auto.channel", fallback: "IM 绑定"),
            subtitle: channelSubtitle(store: cStore)
        ) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(visibleChannels.count, 3))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(visibleChannels, id: \.self) { chId in
                    let bound = isChannelBound(store: cStore, canonicalId: chId)
                    let label = channelDisplayLabel(store: cStore, canonicalId: chId)
                    let icon = Self.channelSystemImages[chId] ?? "bubble.left"
                    overviewCompactActionButton(
                        title: label,
                        systemImage: icon,
                        tint: bound ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08),
                        foreground: bound ? .accentColor : .primary,
                        disabled: !helperClient.isConnected
                    ) {
                        openChannelOnboarding(chId)
                    }
                    .overlay(alignment: .topTrailing) {
                        if bound {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: -2, y: 2)
                        }
                    }
                }
            }
        }
    }

    /// detail 列表中的频道行：已绑定频道徽章 + 配对按钮
    private var channelDetailRow: some View {
        let cStore = gatewayHub.channelStore(for: user.username)
        let boundChannels = canonicalBoundChannelIds(store: cStore)
        return HStack {
            Text(L10n.k("user.detail.auto.channel", fallback: "频道")).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            ForEach(boundChannels, id: \.self) { chId in
                channelDetailBadge(label: channelDisplayLabel(store: cStore, canonicalId: chId))
            }
            if boundChannels.isEmpty {
                Text(L10n.k("user.detail.channel.none", fallback: "未配置"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(L10n.k("user.detail.channel.pair", fallback: "配对")) {
                openChannelOnboarding("feishu")
            }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(!helperClient.isConnected)
        }
    }

    /// 频道已绑定徽章（纯事实：已配置）
    @ViewBuilder
    private func channelDetailBadge(label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
    }

    /// 决定 compact 卡片中显示哪些频道：已绑定的 + 默认的，去重保序
    private func channelVisibleIds(store: GatewayChannelStore) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for chId in store.channelOrder where store.isBound(chId) {
            let canonical = canonicalChannelId(chId)
            if seen.insert(canonical).inserted { result.append(canonical) }
        }
        for chId in Self.defaultChannelIds {
            if seen.insert(chId).inserted { result.append(chId) }
        }
        return result
    }

    /// 频道卡片副标题
    private func channelSubtitle(store: GatewayChannelStore) -> String {
        let boundCount = canonicalBoundChannelIds(store: store).count
        if boundCount == 0 {
            return L10n.k("user.detail.auto.feishu_wechat_configuration", fallback: "飞书/微信均通过独立流程扫码绑定，支持首次配置和重新绑定。")
        }
        return "已配置 \(boundCount) 个频道"
    }

    private static func channelAliases(for canonicalId: String) -> [String] {
        switch canonicalId {
        case "weixin": return ["weixin", "openclaw-weixin"]
        default: return [canonicalId]
        }
    }

    private func canonicalChannelId(_ channelId: String) -> String {
        Self.channelAliasToCanonical[channelId] ?? channelId
    }

    private func isChannelBound(store: GatewayChannelStore, canonicalId: String) -> Bool {
        Self.channelAliases(for: canonicalId).contains(where: { store.isBound($0) })
    }

    private func canonicalBoundChannelIds(store: GatewayChannelStore) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for channelId in store.channelOrder where store.isBound(channelId) {
            let canonical = canonicalChannelId(channelId)
            if seen.insert(canonical).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    private func channelDisplayLabel(store: GatewayChannelStore, canonicalId: String) -> String {
        if canonicalId == "weixin" {
            return L10n.k("channel.flow.weixin.title", fallback: "微信")
        }
        for alias in Self.channelAliases(for: canonicalId) {
            let label = store.label(for: alias)
            if label != alias {
                return label
            }
        }
        return store.label(for: canonicalId)
    }

    private func installOpenclaw(version: String? = nil) async {
        isInstalling = true
        showInstallConsole = true
        installError = nil
        let currentVersion = user.openclawVersion

        // 记录升级前版本，供降级使用
        if version != nil, let currentVersion {
            preUpgradeVersion = currentVersion
            savePreUpgradeInfo()
        }

        do {
            try await helperClient.installOpenclaw(username: user.username, version: version)
            user.openclawVersion = await helperClient.getOpenclawVersion(username: user.username)
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }

    // MARK: - 版本回退

    private func performRollback() async {
        guard let prevVersion = preUpgradeVersion else { return }
        isRollingBack = true
        showInstallConsole = true
        installError = nil

        // 停止 Gateway
        let wasRunning = user.isRunning
        if wasRunning {
            gatewayHub.markPendingStopped(username: user.username)
            try? await helperClient.stopGateway(username: user.username)
        }

        // 降级二进制
        do {
            try await helperClient.installOpenclaw(username: user.username, version: prevVersion)
            user.openclawVersion = await helperClient.getOpenclawVersion(username: user.username)
        } catch {
            installError = error.localizedDescription
            if wasRunning {
                gatewayHub.markPendingStart(username: user.username)
                try? await helperClient.startGateway(username: user.username)
            }
            isRollingBack = false
            return
        }

        // 重启 Gateway
        if wasRunning {
            gatewayHub.markPendingStart(username: user.username)
            try? await helperClient.startGateway(username: user.username)
        }

        // 清除回退记录
        preUpgradeVersion = nil
        savePreUpgradeInfo()
        isRollingBack = false
    }

    // MARK: - 删除进度视图

    @ViewBuilder
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("user.detail.auto.danger_zone", fallback: "危险操作")).font(.headline).foregroundStyle(.red)
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 8) {
                if user.isAdmin {
                    Text(L10n.k("user.detail.auto.admin_resetdelete", fallback: "管理员账号仅支持基础管理，已禁用重置与删除。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(isResetting ? L10n.k("user.detail.auto.reset", fallback: "重置中…") : L10n.k("user.detail.auto.reset", fallback: "重置生存空间"), role: .destructive) {
                            showResetConfirm = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .disabled(isResetting || !helperClient.isConnected)
                    }
                    Divider()
                    HStack {
                        Button(L10n.k("user.detail.auto.deleteuser", fallback: "删除用户"), role: .destructive) {
                            deleteError = nil
                            deleteAdminPassword = ""
                            showDeleteConfirm = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelf ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.red))
                        .disabled(isDeleting || !helperClient.isConnected || isSelf)
                        .help(isSelf ? L10n.k("user.detail.auto.deleteadmin", fallback: "无法删除当前登录的管理员账号") : "")
                    }
                    if isDeleting { deleteProgressView }
                }
            }
            .padding(.top, 4)
        }
        .modifier(OverviewCardModifier())
    }

    @ViewBuilder
    private var deleteProgressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.65)
                Text(L10n.k("user.detail.auto.deleteaccount", fallback: "删除账户中…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
