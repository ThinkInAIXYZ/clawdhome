// ClawdHome/Views/UserDetailView.swift

import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct QuickFileTransferOutcome {
    let destinationRootPath: String
    let uploadedTopLevelPaths: [String]
    let failures: [String]

    var clipboardText: String {
        if uploadedTopLevelPaths.isEmpty { return destinationRootPath }
        return uploadedTopLevelPaths.joined(separator: "\n")
    }

    var summaryMessage: String {
        var blocks: [String] = []
        if uploadedTopLevelPaths.isEmpty {
            blocks.append(L10n.k("user.detail.auto.text_accbdb5ed1", fallback: "未检测到可上传项目。"))
        } else {
            let shownPaths = uploadedTopLevelPaths.prefix(2).map(Self.displayPath)
            var uploadedBlock = L10n.f("views.user_detail_view.text_7b6b4044", fallback: "已上传 %@ 项。", String(describing: uploadedTopLevelPaths.count))
            if let first = shownPaths.first {
                uploadedBlock += L10n.f("views.user_detail_view.n_n_n", fallback: "\n\n路径：\n%@", String(describing: first))
                if shownPaths.count > 1 {
                    uploadedBlock += "\n\(shownPaths[1])"
                }
            }
            if uploadedTopLevelPaths.count > 2 {
                uploadedBlock += L10n.f("views.user_detail_view.n", fallback: "\n…以及另外 %@ 项", String(describing: uploadedTopLevelPaths.count - 2))
            }
            blocks.append(uploadedBlock)
        }
        if !failures.isEmpty {
            let shownFailures = failures.prefix(2).joined(separator: "\n")
            var failedBlock = L10n.f("views.user_detail_view.n_8d3d10", fallback: "失败 %@ 项：\n%@", String(describing: failures.count), String(describing: shownFailures))
            if failures.count > 2 {
                failedBlock += L10n.f("views.user_detail_view.n", fallback: "\n…以及另外 %@ 项", String(describing: failures.count - 2))
            }
            blocks.append(failedBlock)
        }
        blocks.append(L10n.k("user.detail.auto.tips_file", fallback: "Tips：已复制到剪贴板，可以贴给你的虾，来处理文件。"))
        return blocks.joined(separator: "\n\n")
    }

    private static func displayPath(_ absolutePath: String) -> String {
        let tail = absolutePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropFirst(2)
            .joined(separator: "/")
        if absolutePath.hasPrefix("/Users/"), !tail.isEmpty {
            return "~/" + tail
        }
        return absolutePath
    }
}

enum QuickFileTransferService {
    static let destinationRelativePath = ".openclaw/clawdhome_upload"

    static func destinationAbsolutePath(username: String) -> String {
        "/Users/\(username)/\(destinationRelativePath)"
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.setString(text, forType: .string)
    }

    static func uploadDroppedItems(
        _ droppedURLs: [URL],
        username: String,
        helperClient: HelperClient
    ) async -> QuickFileTransferOutcome {
        let destinationRoot = destinationAbsolutePath(username: username)
        let fileURLs = uniqueFileURLs(from: droppedURLs)
        guard !fileURLs.isEmpty else {
            return QuickFileTransferOutcome(
                destinationRootPath: destinationRoot,
                uploadedTopLevelPaths: [],
                failures: []
            )
        }

        var uploaded: [String] = []
        var failures: [String] = []

        do {
            try await helperClient.createDirectory(username: username, relativePath: destinationRelativePath)
        } catch {
            return QuickFileTransferOutcome(
                destinationRootPath: destinationRoot,
                uploadedTopLevelPaths: [],
                failures: [L10n.f("views.user_detail_view.text_e9b3435d", fallback: "创建目录失败：%@", String(describing: error.localizedDescription))]
            )
        }

        for srcURL in fileURLs {
            let scoped = srcURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { srcURL.stopAccessingSecurityScopedResource() }
            }

            let topName = srcURL.lastPathComponent
            let destTopRel = "\(destinationRelativePath)/\(topName)"
            let destTopAbs = "\(destinationRoot)/\(topName)"
            let isDir = (try? srcURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            do {
                if isDir {
                    try await uploadDirectory(srcURL, username: username, baseRelativePath: destTopRel, helperClient: helperClient)
                } else {
                    let data = try Data(contentsOf: srcURL)
                    try await helperClient.writeFile(username: username, relativePath: destTopRel, data: data)
                }
                uploaded.append(destTopAbs)
            } catch {
                failures.append("\(topName)：\(error.localizedDescription)")
            }
        }

        return QuickFileTransferOutcome(
            destinationRootPath: destinationRoot,
            uploadedTopLevelPaths: uploaded,
            failures: failures
        )
    }

    private static func uniqueFileURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .filter(\.isFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    private static func uploadDirectory(
        _ srcURL: URL,
        username: String,
        baseRelativePath: String,
        helperClient: HelperClient
    ) async throws {
        try await helperClient.createDirectory(username: username, relativePath: baseRelativePath)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: srcURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw NSError(
                domain: "QuickFileTransferService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.k("user.detail.auto.folder", fallback: "无法读取文件夹内容")]
            )
        }

        let items = enumerator.allObjects.compactMap { $0 as? URL }
        for itemURL in items {
            let relativeSuffix = String(itemURL.path.dropFirst(srcURL.path.count + 1))
            guard !relativeSuffix.isEmpty else { continue }
            let destRel = "\(baseRelativePath)/\(relativeSuffix)"
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                try await helperClient.createDirectory(username: username, relativePath: destRel)
            } else {
                let data = try Data(contentsOf: itemURL)
                try await helperClient.writeFile(username: username, relativePath: destRel, data: data)
            }
        }
    }
}

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
    @State private var deleteStep: DeleteStep? = nil   // 当前删除进度阶段
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
    // 密码
    @State private var showPassword = false
    @State private var logSearchText = ""
    @State private var isQuickTransferDropTargeted = false
    @State private var quickTransferAlertMessage: String?
    @State private var quickTransferClipboardText = ""
    @State private var quickTransferLastPaths: [String] = []
    // Tab
    @State private var selectedTab: ClawTab = .overview
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

            ForEach(allTabs, id: \.self) { sidebarButton($0) }
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
        case .cron:      CronTabView(username: user.username)
        case .skills:    SkillsTabView(username: user.username, gatewayURL: gatewayURL)
        case .characterDef: CharacterDefTabView(username: user.username)
        case .sessions:  SessionsTabView(username: user.username)
        case .memory:    MemoryTabView(username: user.username)
        case .processes:
            ProcessTabView(
                username: user.username
            )
        }
    }

    private var tabbedContent: some View {
        HStack(spacing: 0) {
            detailSidebar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refreshStatus() }
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
        .onChange(of: gatewayHub.readinessMap[user.username]) { _, newReadiness in
            if newReadiness == .ready {
                Task { await refreshStatus() }
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
        .sheet(isPresented: $showPassword) {
            UserPasswordSheet(username: user.username)
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
            DiagnosticsSheet(user: user) { diagResult in
                lastHealthCheck = diagResult
            }
        }
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
                success: deleteStep == .done,
                isDeleting: isDeleting,
                error: deleteError,
                onConfirm: { Task { await performDelete() } },
                onCloseSuccess: {
                    showDeleteConfirm = false
                    deleteStep = nil
                    deleteError = nil
                    deleteAdminPassword = ""
                    onDeleted?()
                },
                onCancel: {
                    showDeleteConfirm = false
                    deleteError = nil
                    deleteAdminPassword = ""
                    deleteStep = nil
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
                    if shouldShowOverviewSupplementaryCards {
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
                            deleteStep = nil
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

    private var overviewSupplementaryEntriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            overviewSupplementaryCard(
                title: L10n.k("user.detail.auto.model_configuration", fallback: "模型配置"),
                subtitle: defaultModel.map { L10n.f("views.user_detail_view.current_model", fallback: "当前：%@", String(describing: $0)) }
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
                                deleteStep = nil
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
                KimiMinimaxModelConfigPanel(user: user) {
                    Task {
                        beginGatewayRestartVisualTransition()
                        await refreshModelStatusSummary()
                    }
                }
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

        deleteStep = .deleting
        let keepHome = deleteHomeOption == .keepHome
        let adminPassword = deleteAdminPassword
        deleteAdminPassword = ""   // 立即清除内存中的密码

        let targetUsername = user.username   // 在 main actor 上捕获，避免跨 actor 访问 warning
        do {
            // 直接执行 sysadminctl 删除（使用管理员凭据）
            try await deleteUserViaSysadminctl(username: targetUsername, keepHome: keepHome, adminPassword: adminPassword)

            deleteStep = .done
            isDeleting = false
        } catch {
            deleteError = error.localizedDescription
            deleteStep = nil
            isDeleting = false
            showDeleteConfirm = true   // 重新打开 sheet 显示错误
        }
    }

    private func deleteUserViaSysadminctl(username: String, keepHome: Bool, adminPassword: String) async throws {
        let trimmed = adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"))
        }
        let timeoutSeconds: TimeInterval = 30

        try await Task.detached(priority: .userInitiated) {
            appLog("[user-delete] start @\(username) keepHome=\(keepHome)")

            let verifyArgs = ["-S", "-k", "-p", "", "-v"]
            let verify: (status: Int32, output: String)
            do {
                verify = try runProcessWithTimeout(
                    executable: "/usr/bin/sudo",
                    arguments: verifyArgs,
                    timeoutSeconds: timeoutSeconds,
                    stdin: "\(trimmed)\n"
                )
            } catch UserDeleteCommandError.timeout {
                appLog("[user-delete] command timeout @\(username)", level: .error)
                throw HelperError.operationFailed(L10n.k("user.detail.auto.admin", fallback: "管理员权限校验超时，请重试"))
            }

            if verify.status != 0 {
                let verifyOutput = verify.output
                let normalized = verifyOutput.lowercased()
                if normalized.contains("incorrect password") || normalized.contains("sorry, try again") {
                    throw HelperError.operationFailed(L10n.k("user.detail.auto.adminpassword", fallback: "管理员密码错误，请重试"))
                }
                if !verifyOutput.isEmpty {
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_0a32bf3a", fallback: "管理员权限校验失败：%@", String(describing: verifyOutput)))
                }
                throw HelperError.operationFailed(L10n.k("user.detail.auto.admin", fallback: "管理员权限校验失败"))
            }

            var sudoArgs = ["-S", "-p", "", "/usr/sbin/sysadminctl", "-deleteUser", username]
            if keepHome { sudoArgs.append("-keepHome") }

            let result = try runProcessWithTimeout(
                executable: "/usr/bin/sudo",
                arguments: sudoArgs,
                timeoutSeconds: timeoutSeconds,
                stdin: "\(trimmed)\n"
            )

            appLog("[user-delete] sysadminctl exit=\(result.status) outputBytes=\(result.output.utf8.count) @\(username)")
            if result.status != 0 {
                let output = result.output
                if output.lowercased().contains("unknown user") { return }
                if output.isEmpty {
                    throw HelperError.operationFailed(L10n.f("views.user_detail_view.sysa_minctl_exit", fallback: "删除用户失败：sysadminctl exit %@", String(describing: result.status)))
                }
                throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_9d82e8aa", fallback: "删除用户失败：%@", String(describing: output)))
            }

            if !waitForUserRecordRemoval(username: username, retries: 40, sleepMs: 250) {
                appLog("[user-delete] record still exists after command @\(username)", level: .warn)
                throw HelperError.operationFailed(L10n.f("views.user_detail_view.text_a1027837", fallback: "删除用户 %@ 后校验失败：系统记录仍存在", String(describing: username)))
            }
            appLog("[user-delete] success @\(username)")
        }.value
    }

    private nonisolated func waitForUserRecordRemoval(username: String, retries: Int, sleepMs: UInt32) -> Bool {
        for _ in 0..<retries {
            if !userRecordExists(username: username) { return true }
            flushDirectoryCache()
            usleep(sleepMs * 1_000)
        }
        return !userRecordExists(username: username)
    }

    private nonisolated func userRecordExists(username: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        proc.arguments = ["/Local/Default", "-read", "/Users/\(username)", "UniqueID"]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated func flushDirectoryCache() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        proc.arguments = ["-flushcache"]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // best-effort
        }
    }

    private enum UserDeleteCommandError: LocalizedError {
        case timeout
        var errorDescription: String? {
            switch self {
            case .timeout: return "command timeout"
            }
        }
    }

    private final class ThreadSafeDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) {
            lock.lock()
            storage.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let data = storage
            lock.unlock()
            return data
        }
    }

    private nonisolated func runProcessWithTimeout(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        stdin: String? = nil
    ) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inputPipe = Pipe()
        proc.standardInput = inputPipe

        let buffer = ThreadSafeDataBuffer()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
        }

        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        try proc.run()
        if let stdin {
            if let data = stdin.data(using: .utf8) {
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
        }
        inputPipe.fileHandleForWriting.closeFile()

        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if proc.isRunning { proc.terminate() }
            reader.readabilityHandler = nil
            throw UserDeleteCommandError.timeout
        }

        reader.readabilityHandler = nil
        let tail = reader.readDataToEndOfFile()
        buffer.append(tail)
        let data = buffer.snapshot()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
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
                            deleteStep = nil
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
            switch deleteStep {
            case .deleting:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.65)
                    Text(L10n.k("user.detail.auto.deleteaccount", fallback: "删除账户中…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(L10n.k("user.detail.auto.done", fallback: "已完成"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case nil:
                EmptyView()
            }
        }
    }

}

private struct UserDetailWindowLevelBinder: NSViewRepresentable {
    let elevated: Bool

    final class Coordinator {
        var lastElevated: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window, context: context)
        }
    }

    private func apply(window: NSWindow?, context: Context) {
        guard let window else { return }
        let targetLevel: NSWindow.Level = elevated ? .floating : .normal
        if window.level != targetLevel {
            window.level = targetLevel
        }
        let changed = context.coordinator.lastElevated != elevated
        context.coordinator.lastElevated = elevated
        guard elevated, changed else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

// MARK: - Alerts Modifier（拆分减轻类型检查压力）

private struct MainContentAlertsModifier: ViewModifier {
    let user: ManagedUser
    @Binding var showRollbackConfirm: Bool
    @Binding var showLogoutConfirm: Bool
    @Binding var showResetConfirm: Bool
    let preUpgradeVersion: String?
    let performRollback: () async -> Void
    let performLogout: () async -> Void
    let performReset: () async -> Void

    func body(content: Content) -> some View {
        content
            .alert(L10n.f("user.detail.alert.rollback.title", fallback: "回退到 v%@?", preUpgradeVersion ?? ""), isPresented: $showRollbackConfirm) {
                Button(L10n.k("user.detail.auto.rollback", fallback: "回退"), role: .destructive) {
                    Task { await performRollback() }
                }
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
            } message: {
                Text(L10n.f("user.detail.alert.rollback.message", fallback: "将把 @%@ 的 openclaw 降级到 v%@\n\n此操作会短暂停止并重启 Gateway。", user.username, preUpgradeVersion ?? ""))
            }
            .alert(L10n.f("user.detail.alert.logout.title", fallback: "注销 @%@ 的登录会话？", user.username), isPresented: $showLogoutConfirm) {
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
                Button(L10n.k("user.detail.auto.log_out", fallback: "注销"), role: .destructive) {
                    Task { await performLogout() }
                }
            } message: {
                Text(L10n.k("user.detail.alert.logout.message", fallback: "将停止 Gateway 并退出该用户的登录会话（launchctl bootout）。\n\n用户数据不会被删除，可随时重新启动 Gateway。"))
            }
            .alert(L10n.f("user.detail.alert.reset.title", fallback: "重置 @%@ 的生存空间？", user.username), isPresented: $showResetConfirm) {
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
                Button(L10n.k("user.detail.auto.reset", fallback: "重置"), role: .destructive) {
                    Task { await performReset() }
                }
            } message: {
                Text(L10n.f("user.detail.alert.reset.message", fallback: "这将删除：\n• ~/.npm-global（openclaw 及所有 npm 全局包）\n• ~/.openclaw（配置、API Key、会话历史）\n\n建议先备份 /Users/%@/.openclaw/，其中包含 API Key 和历史记录。\n\n重置后需要重新初始化生存空间。", user.username))
            }
    }
}

struct OverviewCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.07), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}

// MARK: - 存储空间行

private struct StorageRowContent: View {
    let snapshot: DashboardSnapshot?
    let username: String

    var body: some View {
        if let shrimp = snapshot?.shrimps.first(where: { $0.username == username }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(FormatUtils.formatBytes(shrimp.openclawDirBytes))
                        .monospacedDigit()
                    Text(".openclaw/").font(.caption2).foregroundStyle(.secondary)
                }
                if shrimp.homeDirBytes > 0 {
                    HStack(spacing: 4) {
                        Text(FormatUtils.formatBytes(shrimp.homeDirBytes))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        Text(L10n.k("user.detail.auto.directory", fallback: "家目录")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 删除进度阶段

enum DeleteStep {
    case deleting
    case done
}

// MARK: - 删除家目录选项

enum DeleteHomeOption: Hashable {
    case deleteHome   // 删除个人文件夹（彻底清除）
    case keepHome     // 保留个人文件夹（仅删账户记录）
}

// MARK: - 删除用户确认 Sheet

struct DeleteUserSheet: View {
    let username: String
    let adminUser: String
    @Binding var option: DeleteHomeOption
    @Binding var adminPassword: String
    let success: Bool
    @State private var showAdminPassword = false
    @FocusState private var isAdminPasswordFocused: Bool
    let isDeleting: Bool
    let error: String?
    let onConfirm: () -> Void
    let onCloseSuccess: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题（避免转义符视觉噪音）
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.f("views.user_detail_view.delete_user_title", fallback: "删除用户 @%@", String(describing: username)))
                    .font(.headline)
                Text(L10n.k("views.user_detail_view.delete_user_subtitle", fallback: "此操作不可恢复，请选择个人文件夹处理方式。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 错误提示
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.caption)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if success {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.k("views.user_detail_view.delete_success_closing", fallback: "删除成功，即将关闭…"))
                        .font(.subheadline)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            if isDeleting {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.k("user.detail.auto.deleting_please_wait", fallback: "删除中，请稍候…"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(L10n.k("views.user_detail_view.delete_authorization_hint", fallback: "如果系统弹出授权窗口，请点击“允许”。如果你拒绝了，或者没有出现，请退出程序后重新操作。你也可以前往“系统设置 → 用户与群组”删除该用户。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if !success {
                // 选项
                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        value: .keepHome,
                        title: L10n.k("user.detail.auto.folder", fallback: "保留个人文件夹"),
                        desc: L10n.f("views.user_detail_view.users", fallback: "/Users/%@/ 保持不变", String(describing: username))
                    )
                    Divider().padding(.leading, 28)
                    optionRow(
                        value: .deleteHome,
                        title: L10n.k("user.detail.auto.deletefolder", fallback: "删除个人文件夹"),
                        desc: L10n.f("views.user_detail_view.users_4c31c5", fallback: "/Users/%@/ 及全部内容将被永久删除", String(describing: username))
                    )
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .disabled(isDeleting)

                // 管理员密码
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("user.detail.auto.adminpassword", fallback: "管理员密码")).font(.subheadline)
                    Text(L10n.f("views.user_detail_view.text_626047b9", fallback: "账号：%@", String(describing: adminUser)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        if showAdminPassword {
                            TextField(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"), text: $adminPassword)
                                .textFieldStyle(.roundedBorder)
                                .id("delete-admin-password-plain")
                                .focused($isAdminPasswordFocused)
                                .onChange(of: isAdminPasswordFocused) { _, focused in
                                    if focused {
                                        KeyboardInputSourceSwitcher.switchToEnglishASCII()
                                    }
                                }
                                .onChange(of: adminPassword) { _, newValue in
                                    let asciiOnly = newValue.filter(\.isASCII)
                                    if asciiOnly != newValue {
                                        adminPassword = asciiOnly
                                    }
                                }
                        } else {
                            SecureField(L10n.k("user.detail.auto.inputadminpassword", fallback: "请输入管理员登录密码"), text: $adminPassword)
                                .textFieldStyle(.roundedBorder)
                                .id("delete-admin-password-secure")
                                .focused($isAdminPasswordFocused)
                                .onChange(of: isAdminPasswordFocused) { _, focused in
                                    if focused {
                                        KeyboardInputSourceSwitcher.switchToEnglishASCII()
                                    }
                                }
                                .onChange(of: adminPassword) { _, newValue in
                                    let asciiOnly = newValue.filter(\.isASCII)
                                    if asciiOnly != newValue {
                                        adminPassword = asciiOnly
                                    }
                                }
                        }
                        Button {
                            showAdminPassword.toggle()
                            isAdminPasswordFocused = true
                        } label: {
                            Image(systemName: showAdminPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showAdminPassword ? L10n.k("user.detail.auto.password", fallback: "隐藏密码") : L10n.k("user.detail.auto.password", fallback: "显示密码"))
                    }
                }
                .disabled(isDeleting)

                // 按钮
                HStack {
                    Spacer()
                    Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isDeleting)
                    Button(L10n.k("user.detail.auto.deleteuser", fallback: "删除用户"), role: .destructive, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .disabled(adminPassword.isEmpty || isDeleting)
                }
            } else {
                HStack {
                    Spacer()
                    Button(L10n.k("user.detail.auto.close", fallback: "关闭"), action: onCloseSuccess)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: isDeleting) { _, deleting in
            if deleting { isAdminPasswordFocused = false }
        }
        .onChange(of: success) { _, didSucceed in
            if didSucceed { isAdminPasswordFocused = false }
        }
    }

    @ViewBuilder
    private func optionRow(value: DeleteHomeOption, title: String, desc: String) -> some View {
        Button {
            option = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: option == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(option == value ? .blue : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum KeyboardInputSourceSwitcher {
    static func switchToEnglishASCII() {
        guard let source = preferredEnglishSource() ?? fallbackASCIISource() else { return }
        TISSelectInputSource(source)
    }

    private static func preferredEnglishSource() -> TISInputSource? {
        allKeyboardInputSources().first {
            guard tisProperty($0, kTISPropertyInputSourceIsASCIICapable, as: Bool.self) == true else {
                return false
            }
            let languages = tisProperty($0, kTISPropertyInputSourceLanguages, as: [String].self) ?? []
            return languages.contains { $0.hasPrefix("en") }
        }
    }

    private static func fallbackASCIISource() -> TISInputSource? {
        allKeyboardInputSources().first {
            tisProperty($0, kTISPropertyInputSourceIsASCIICapable, as: Bool.self) == true
        }
    }

    private static func allKeyboardInputSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        return TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    }

    private static func tisProperty<T>(_ source: TISInputSource, _ key: CFString, as type: T.Type) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        return value as? T
    }
}

// MARK: - 查看用户密码 Sheet

struct UserPasswordSheet: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @State private var isRevealed = false
    @State private var storedPassword: String? = nil
    @State private var isResetting = false
    @State private var resetError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.f("views.user_detail_view.text_82ba9ab1", fallback: "@%@ 的登录密码", String(describing: username)))
                .font(.title3)
                .fontWeight(.semibold)

            if let pw = storedPassword {
                GroupBox {
                    HStack {
                        if isRevealed {
                            Text(pw)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: pw.count))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pw, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.k("user.detail.auto.password", fallback: "复制密码"))

                        Button { isRevealed.toggle() } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(isRevealed ? L10n.k("user.detail.auto.password", fallback: "隐藏密码") : L10n.k("user.detail.auto.password", fallback: "显示密码"))
                    }
                    .padding(4)
                }
            } else {
                GroupBox {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.k("user.detail.auto.password", fallback: "未找到已存储的密码"))
                                .fontWeight(.medium)
                            Text(L10n.k("user.detail.auto.userpassword_resetpassword", fallback: "该用户可能在密码管理功能上线前创建，点击下方按钮重置密码"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
                Button(isResetting ? L10n.k("user.detail.auto.reset", fallback: "重置中…") : L10n.k("user.detail.auto.passwordreset", fallback: "生成新密码并重置")) {
                    Task { await resetPassword() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResetting || !helperClient.isConnected)
                if let err = resetError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Text(L10n.k("user.detail.auto.passworduser", fallback: "此密码用于该用户登录图形界面"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if storedPassword != nil {
                    Button(isResetting ? L10n.k("user.detail.auto.reset", fallback: "重置中…") : L10n.k("user.detail.auto.resetpassword", fallback: "重置密码")) {
                        Task { await resetPassword() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isResetting || !helperClient.isConnected)
                }
                Spacer()
                Button(L10n.k("user.detail.auto.close", fallback: "关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            do {
                storedPassword = try UserPasswordStore.load(for: username)
            } catch {
                storedPassword = nil
                resetError = error.localizedDescription
            }
        }
    }

    private func resetPassword() async {
        isResetting = true
        resetError = nil
        do {
            let newPw = try UserPasswordStore.generateAndSave(for: username)
            do {
                try await helperClient.changeUserPassword(username: username, newPassword: newPw)
                storedPassword = newPw
                isRevealed = true  // 重置后自动显示，方便用户确认
            } catch {
                // 回滚 Keychain（避免存入的密码与实际账户密码不一致）
                UserPasswordStore.delete(for: username)
                storedPassword = nil
                resetError = error.localizedDescription
            }
        } catch {
            resetError = error.localizedDescription
        }
        isResetting = false
    }
}

// MARK: - 独立探活（不依赖 DashboardView）

/// 让 UserDetailView 自行对 gateway 发 HTTP 探活，
/// 确保独立窗口或非 Dashboard 页面也能刷新 readiness 状态
private struct UserDetailWindowTitleBinder: NSViewRepresentable {
    let title: String
    let subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window)
        }
    }

    private func apply(window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        if #available(macOS 11.0, *), window.subtitle != subtitle {
            window.subtitle = subtitle
        }
    }
}

private struct GatewayProbeModifier: ViewModifier {
    let username: String
    let uid: Int
    let gatewayURL: String?
    let hub: GatewayHub
    @Environment(ShrimpPool.self) private var pool

    func body(content: Content) -> some View {
        content.task(id: "\(username)#\(gatewayURL ?? "")") {
            while !Task.isCancelled {
                // 优先使用 getGatewayURL() 的真实端口，避免快照端口滞后导致误判"启动中"
                let portFromURL = gatewayURL
                    .flatMap { GatewayHub.parse(gatewayURL: $0)?.port } ?? 0
                // 回退：快照端口 -> 18000+uid 公式端口
                let portFromSnapshot = pool.snapshot?.shrimps.first(where: { $0.username == username })
                    .map { $0.gatewayPort > 0 ? $0.gatewayPort : (GatewayHub.gatewayPort(for: uid) ?? 0) } ?? 0
                let port = portFromURL > 0
                    ? portFromURL
                    : (portFromSnapshot > 0 ? portFromSnapshot : (GatewayHub.gatewayPort(for: uid) ?? 0))
                guard port > 0 else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                await hub.probeSingle(username: username, port: port)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Cron Tab

private struct CronTabView: View {
    let username: String
    @Environment(GatewayHub.self) private var hub

    private var isConnected: Bool {
        hub.connectedUsernames.contains(username)
    }

    var body: some View {
        CronTabContent(store: hub.cronStore(for: username))
            .task(id: isConnected) {
                guard isConnected else { return }
                await hub.ensureCronStarted(for: username)
            }
    }
}

private struct CronTabContent: View {
    let store: GatewayCronStore

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Text(L10n.k("user.detail.auto.scheduled_tasks", fallback: "定时任务"))
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            Divider()

            if let err = store.error {
                ContentUnavailableView(err, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.jobs.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    L10n.k("user.detail.cron.no_jobs", fallback: "暂无定时任务"),
                    systemImage: "clock",
                    description: Text(L10n.k("user.detail.cron.no_jobs_hint", fallback: "等待 Gateway 连接后自动加载"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // 左栏：任务列表
                    List(store.jobs, selection: Binding(
                        get: { store.selectedJobId },
                        set: { store.selectedJobId = $0 }
                    )) { job in
                        CronJobListRow(job: job)
                            .tag(job.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)

                    // 右栏：详情
                    if let jobId = store.selectedJobId,
                       let job = store.jobs.first(where: { $0.id == jobId }) {
                        CronJobDetailPane(job: job, store: store)
                    } else {
                        ContentUnavailableView(
                            L10n.k("user.detail.cron.select_job", fallback: "选择一个任务"),
                            systemImage: "clock"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { await store.refresh() }
    }
}

private struct CronJobListRow: View {
    let job: GatewayCronJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(job.enabled ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(job.name)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if let next = job.state.nextRunAtMs {
                    Text(relativeTime(ms: next))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                CronTagBadge(job.sessionTarget)
                CronTagBadge(job.wakeMode)
            }
        }
        .padding(.vertical, 2)
    }

    private func relativeTime(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let diff = date.timeIntervalSinceNow
        if diff < 0 { return L10n.k("user.detail.cron.expired", fallback: "已过期") }
        if diff < 60 { return "< 1m" }
        let mins = Int(diff / 60)
        if mins < 60 { return "in \(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "in \(hrs)h" }
        return "in \(hrs / 24)d"
    }
}

private struct CronTagBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}

private struct CronJobDetailPane: View {
    let job: GatewayCronJob
    let store: GatewayCronStore
    @State private var isRunning = false
    @State private var showRemoveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 头部
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.name).font(.title3).fontWeight(.semibold)
                        Text(job.id).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { job.enabled },
                        set: { _ in Task { try? await store.toggleEnabled(job: job) } }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                    Button(L10n.k("user.detail.cron.run", fallback: "Run")) {
                        isRunning = true
                        Task {
                            defer { isRunning = false }
                            try? await store.run(jobId: job.id)
                        }
                    }
                    .disabled(isRunning)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(16)

                Divider()

                // 详情字段
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    CronDetailGridRow(label: "Schedule", value: scheduleText)
                    CronDetailGridRow(label: "Auto-delete", value: job.deleteAfterRun == true ? "after success" : "—")
                    CronDetailGridRow(label: "Session", value: job.sessionTarget)
                    CronDetailGridRow(label: "Wake", value: job.wakeMode)
                    CronDetailGridRow(label: "Next run", value: timeText(ms: job.state.nextRunAtMs))
                    CronDetailGridRow(label: "Last run", value: timeText(ms: job.state.lastRunAtMs))
                    if let status = job.state.lastStatus {
                        CronDetailGridRow(label: "Last status", value: status)
                    }
                }
                .padding(16)

                Divider()

                // Payload
                VStack(alignment: .leading, spacing: 8) {
                    Text("Payload")
                        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.horizontal, 16).padding(.top, 16)
                    Text(payloadText)
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }

                Divider()

                // Run history
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Run history")
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        Button {
                            Task { await store.refreshRuns(jobId: job.id) }
                        } label: {
                            Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    }

                    if store.runEntries.isEmpty {
                        Text("No run log entries yet.")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(store.runEntries) { entry in
                                CronRunEntryRow(entry: entry)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .task(id: job.id) {
            await store.refreshRuns(jobId: job.id)
        }
    }

    private var scheduleText: String {
        switch job.schedule {
        case let .at(at): return "at \(at)"
        case let .every(ms, _):
            let secs = ms / 1000
            if secs < 60 { return "every \(secs)s" }
            if secs < 3600 { return "every \(secs / 60)m" }
            return "every \(secs / 3600)h"
        case let .cron(expr, tz):
            return tz.map { "cron: \(expr) (\($0))" } ?? "cron: \(expr)"
        }
    }

    private var payloadText: String {
        switch job.payload {
        case let .systemEvent(text): return text
        case let .agentTurn(message, _, _, _, _, _, _): return message
        }
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private func timeText(ms: Int?) -> String {
        guard let ms else { return "—" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

private struct CronDetailGridRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

private struct CronRunEntryRow: View {
    let entry: GatewayCronRunLogEntry
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.status == "ok" ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(entry.action).font(.caption)
            if let dur = entry.durationMs {
                Text("\(dur)ms").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Date(timeIntervalSince1970: TimeInterval(entry.ts) / 1000), style: .time)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Skills Tab
// 参考 openclaw/apps/macos/Sources/OpenClaw/SkillsSettings.swift
// 参考 openclaw commit 505b980f63 (2026-04-07)

private struct SkillsTabView: View {
    let username: String
    let gatewayURL: String?
    @Environment(GatewayHub.self) private var hub

    private var isConnected: Bool {
        hub.connectedUsernames.contains(username)
    }

    var body: some View {
        SkillsTabContent(store: hub.skillsStore(for: username), username: username, gatewayURL: gatewayURL)
            .task(id: isConnected) {
                guard isConnected else { return }
                await hub.ensureSkillsStarted(for: username)
            }
    }
}

// MARK: 筛选枚举

private enum SkillsFilter: String, CaseIterable, Identifiable {
    case all, ready, needsSetup, disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .ready: return "就绪"
        case .needsSetup: return "需配置"
        case .disabled: return "已禁用"
        }
    }
}

// MARK: 环境变量编辑状态

private struct SkillEnvEditorState: Identifiable {
    let skillKey: String
    let skillName: String
    let envKey: String
    let isPrimary: Bool
    let homepage: String?

    var id: String { "\(skillKey)::\(envKey)" }
}

// MARK: SkillsTabContent

private struct SkillsTabContent: View {
    let store: GatewaySkillsStore
    let username: String
    let gatewayURL: String?
    @Environment(HelperClient.self) private var helperClient
    @State private var filter: SkillsFilter = .all
    @State private var envEditor: SkillEnvEditorState?
    @State private var showSkillsMarket = false
    @State private var skillsMarketURL: URL?
    @State private var isPreparingSkillsMarket = false

    private var filteredSkills: [GatewaySkillStatus] {
        let base = store.skills.filter { skill in
            switch filter {
            case .all: return true
            case .ready: return !skill.disabled && skill.eligible
            case .needsSetup: return !skill.disabled && !skill.eligible
            case .disabled: return skill.disabled
            }
        }
        if store.searchText.isEmpty { return base }
        let q = store.searchText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills").font(.headline)
                    Text("满足依赖条件（二进制、环境变量、配置）后自动启用")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isPreparingSkillsMarket {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("准备中…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await openSkillsMarket() }
                    } label: {
                        Label("获取更多 Skills", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if store.isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
                } else {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Picker("筛选", selection: $filter) {
                    ForEach(SkillsFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 Skills…", text: Bindable(store).searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.bar)

            Divider()

            // 状态消息
            if let msg = store.statusMessage {
                HStack {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.statusMessage = nil } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.06))
            }

            // 内容
            if let err = store.error {
                ContentUnavailableView(err, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.skills.isEmpty && !store.isLoading {
                ContentUnavailableView("暂无 Skills", systemImage: "star.leadinghalf.filled")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSkills.isEmpty {
                ContentUnavailableView("没有匹配的 Skills", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSkills) { skill in
                    SkillItemRow(skill: skill, store: store, onSetEnv: { envKey, isPrimary in
                        envEditor = SkillEnvEditorState(
                            skillKey: skill.skillKey,
                            skillName: skill.name,
                            envKey: envKey,
                            isPrimary: isPrimary,
                            homepage: skill.homepage
                        )
                    })
                }
                .listStyle(.plain)
            }
        }
        .task { await store.refresh() }
        .sheet(item: $envEditor) { editor in
            SkillEnvEditorSheet(editor: editor) { value in
                Task {
                    if editor.isPrimary {
                        await store.setApiKey(skillKey: editor.skillKey, value: value)
                    } else {
                        await store.setEnvVar(skillKey: editor.skillKey, envKey: editor.envKey, value: value)
                    }
                }
            }
        }
        .sheet(isPresented: $showSkillsMarket) {
            if let url = skillsMarketURL {
                SkillsMarketSheetView(url: url)
            } else {
                ContentUnavailableView("无法打开 Skills 商店", systemImage: "network")
                    .frame(minWidth: 800, minHeight: 520)
            }
        }
    }

    private func openSkillsMarket() async {
        isPreparingSkillsMarket = true
        defer { isPreparingSkillsMarket = false }

        let freshGatewayURL = await helperClient.getGatewayURL(username: username)
        let candidates = [freshGatewayURL, gatewayURL ?? ""].filter { !$0.isEmpty }
        for raw in candidates {
            if let target = makeSkillsMarketURL(from: raw) {
                skillsMarketURL = target
                showSkillsMarket = true
                return
            }
        }
        store.statusMessage = "未获取到可用 Token，请先确认 Gateway 已启动并就绪。"
    }

    private func makeSkillsMarketURL(from rawURL: String) -> URL? {
        guard var components = URLComponents(string: rawURL) else { return nil }
        guard let fragment = components.fragment, fragment.hasPrefix("token=") else { return nil }
        let token = String(fragment.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        components.scheme = components.scheme ?? "http"
        components.host = components.host ?? "127.0.0.1"
        components.port = components.port ?? 18525
        components.path = "/skills"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        components.fragment = "token=\(token)"
        return components.url
    }
}

private struct SkillsMarketSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var store = EmbeddedGatewayConsoleStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Skills 商店")
                    .font(.headline)
                Spacer()
                Button("重载") {
                    store.reloadCurrent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("浏览器打开") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            EmbeddedGatewayConsoleView(url: url, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 720)
        .onDisappear {
            store.invalidateLoadedURL()
        }
    }
}

// MARK: SkillItemRow

private struct SkillItemRow: View {
    let skill: GatewaySkillStatus
    let store: GatewaySkillsStore
    let onSetEnv: (_ envKey: String, _ isPrimary: Bool) -> Void
    @State private var showRemoveConfirm = false

    private var isBusy: Bool { store.isBusy(skill: skill) }
    private var pendingLabel: String { store.pendingOps[skill.skillKey] ?? "" }
    private var requirementsMet: Bool { skill.missing.isEmpty }

    /// 有 missing bins 且存在 install option 时可安装
    private var installOptions: [GatewaySkillInstallOption] {
        guard !skill.missing.bins.isEmpty else { return [] }
        let missingSet = Set(skill.missing.bins)
        return skill.install.filter { opt in
            opt.bins.isEmpty || !missingSet.isDisjoint(with: opt.bins)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Emoji
            Text(skill.emoji ?? "✨").font(.title2)

            // 信息区
            VStack(alignment: .leading, spacing: 4) {
                // 名称
                Text(skill.name).font(.headline)

                // 描述
                Text(skill.description)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)

                // 标签行：来源 + 主页链接
                HStack(spacing: 8) {
                    CronTagBadge(skill.sourceLabel)
                    if let urlStr = skill.homepage,
                       let url = URL(string: urlStr),
                       url.scheme == "http" || url.scheme == "https" {
                        Link(destination: url) {
                            Label("网站", systemImage: "link")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.link)
                    }
                }

                // 禁用状态提示
                if skill.disabled {
                    Text("已在配置中禁用")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 缺失依赖提示（仅当没有安装选项或有非 bin 缺失时）
                if !skill.disabled, !requirementsMet, shouldShowMissingSummary {
                    missingSummary
                }

                // 配置检查
                if !skill.configChecks.isEmpty {
                    configChecksView
                }

                // 环境变量设置按钮
                if !skill.missing.env.isEmpty {
                    envActionRow
                }
            }

            Spacer(minLength: 0)

            // 右侧操作区
            trailingActions
        }
        .padding(.vertical, 6)
    }

    // MARK: 缺失摘要

    private var shouldShowMissingBins: Bool {
        !skill.missing.bins.isEmpty && installOptions.isEmpty
    }

    private var shouldShowMissingSummary: Bool {
        shouldShowMissingBins || !skill.missing.env.isEmpty || !skill.missing.config.isEmpty
    }

    private var missingSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if shouldShowMissingBins {
                Text("缺少二进制: \(skill.missing.bins.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !skill.missing.env.isEmpty {
                Text("缺少环境变量: \(skill.missing.env.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !skill.missing.config.isEmpty {
                Text("需要配置: \(skill.missing.config.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 配置检查

    private var configChecksView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(skill.configChecks) { check in
                HStack(spacing: 4) {
                    Image(systemName: check.satisfied ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(check.satisfied ? .green : .secondary)
                        .font(.caption)
                    Text(check.path).font(.caption)
                }
            }
        }
    }

    // MARK: 环境变量按钮

    private var envActionRow: some View {
        HStack(spacing: 6) {
            ForEach(skill.missing.env, id: \.self) { envKey in
                let isPrimary = envKey == skill.primaryEnv
                Button(isPrimary ? "设置 API Key" : "设置 \(envKey)") {
                    onSetEnv(envKey, isPrimary)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isBusy)
            }
        }
    }

    // MARK: 右侧操作

    @ViewBuilder
    private var trailingActions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isBusy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(pendingLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else if !installOptions.isEmpty {
                // 有可安装选项 → 显示安装按钮
                ForEach(installOptions) { option in
                    Button("安装") {
                        Task { await store.install(skill: skill, option: option) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help(option.label)
                }
            } else {
                // 已安装 → 启用/禁用 Toggle
                Toggle("", isOn: Binding(
                    get: { !skill.disabled },
                    set: { enabled in
                        Task { await store.toggleEnabled(skillKey: skill.skillKey, enabled: enabled) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isBusy || !requirementsMet)

                // 卸载按钮（仅非内置 skill）
                if !skill.isBundled {
                    Button("卸载") {
                        showRemoveConfirm = true
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .confirmationDialog(
                        "卸载 \(skill.name)？",
                        isPresented: $showRemoveConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("卸载", role: .destructive) {
                            Task { await store.remove(skillKey: skill.skillKey) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: 环境变量编辑 Sheet

private struct SkillEnvEditorSheet: View {
    let editor: SkillEnvEditorState
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.isPrimary ? "设置 API Key" : "设置环境变量")
                .font(.headline)
            Text("Skill: \(editor.skillName)")
                .font(.subheadline).foregroundStyle(.secondary)

            if let url = homepageUrl {
                Link("获取密钥 →", destination: url).font(.caption)
            }

            SecureField(editor.envKey, text: $value)
                .textFieldStyle(.roundedBorder)

            Text("保存至 openclaw.json 中 skills.entries.\(editor.skillKey)")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    onSave(value)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var homepageUrl: URL? {
        guard let raw = editor.homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

// MARK: - 配置 Tab (openclaw.json)

private struct ConfigTabView: View {
    let username: String
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isRestartingGateway = false
    @State private var errorMessage: String?
    @State private var jsonError: String?

    private let relPath = ".openclaw/openclaw.json"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("openclaw.json")
                    .font(.headline)
                Spacer()
                if isSaving || isRestartingGateway {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await load() } } label: {
                    Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isLoading || isSaving || isRestartingGateway)
                Button(
                    isRestartingGateway
                        ? L10n.k("views.user_detail_view.restarting_gateway", fallback: "重启中…")
                        : (isSaving
                            ? L10n.k("views.config_tab_view.saving", fallback: "保存中…")
                            : L10n.k("views.config_tab_view.save_and_restart", fallback: "保存并重启 Gateway"))
                ) { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLoading || isSaving || isRestartingGateway || jsonError != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let jsonError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(jsonError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }

            if isLoading {
                ProgressView(L10n.k("user.detail.auto.loading", fallback: "加载中…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .onChange(of: content) { _, newVal in validateJSON(newVal) }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text(L10n.k("views.config_tab_view.footer_hint", fallback: "编辑 .openclaw/openclaw.json 主配置。保存后将自动重启 Gateway 使配置生效。JSON 校验错误时保存按钮将禁用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await helperClient.readFile(username: username, relativePath: relPath)
            let raw = String(data: data, encoding: .utf8) ?? ""
            // 格式化 JSON 便于阅读
            if let jsonData = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let formatted = String(data: pretty, encoding: .utf8) {
                content = formatted
            } else {
                content = raw
            }
            validateJSON(content)
        } catch {
            errorMessage = L10n.f("views.user_detail_view.text_bc49b91a", fallback: "读取失败：%@", String(describing: error.localizedDescription))
        }
    }

    private func save() async {
        guard jsonError == nil else { return }
        isSaving = true
        isRestartingGateway = false
        errorMessage = nil
        defer {
            isSaving = false
            isRestartingGateway = false
        }
        guard let data = content.data(using: .utf8) else { return }
        do {
            try await helperClient.writeFile(username: username, relativePath: relPath, data: data)
            isSaving = false
            isRestartingGateway = true
            gatewayHub.markPendingStart(username: username)
            try await helperClient.restartGateway(username: username)
        } catch {
            errorMessage = L10n.f("views.user_detail_view.text_1eacd4c6", fallback: "保存失败：%@", String(describing: error.localizedDescription))
        }
    }

    private func validateJSON(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            jsonError = nil; return
        }
        guard let data = text.data(using: .utf8) else { jsonError = L10n.k("user.detail.auto.encoding_error", fallback: "编码错误"); return }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            jsonError = nil
        } catch {
            let desc = error.localizedDescription
            if let r = desc.range(of: "line ") {
                jsonError = L10n.f("views.user_detail_view.json", fallback: "JSON 语法错误：%@", String(describing: desc[r.lowerBound...]))
            } else {
                jsonError = L10n.k("user.detail.auto.json", fallback: "JSON 语法错误")
            }
        }
    }
}

// MARK: - 进程管理 Tab

private struct ProcessTabView: View {
    let username: String

    @Environment(HelperClient.self) private var helperClient
    @State private var processes: [ProcessEntry] = []
    @State private var isActive = false
    @State private var viewMode: ViewMode = .tree
    @State private var sortField: SortField = .pid
    @State private var sortAsc: Bool = true
    @State private var collapsedPIDs: Set<Int32> = []
    @State private var selectedPIDs: Set<Int32> = []
    @State private var killTargets: [ProcessEntry] = []
    @State private var killError: String? = nil
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var portsLoading = false
    @State private var lastUpdatedAt: Date? = nil
    @State private var detailTarget: ProcessEntry? = nil
    @State private var columnWidths = ProcessColumnWidths()

    enum ViewMode: String, CaseIterable, Identifiable {
        case flat = "flat"
        case tree = "tree"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat:
                return L10n.k("user.detail.process.view_mode.flat", fallback: "列表")
            case .tree:
                return L10n.k("user.detail.process.view_mode.tree", fallback: "树状")
            }
        }
    }
    enum SortField { case pid, name, cpu, mem, uptime }

    private static let statusTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 搜索过滤

    private var filtered: [ProcessEntry] {
        guard !searchText.isEmpty else { return processes }
        let q = searchText.lowercased()
        return processes.filter {
            $0.name.lowercased().contains(q) || $0.cmdline.lowercased().contains(q)
        }
    }

    // MARK: - 平铺排序

    private var sorted: [ProcessEntry] {
        let s: (ProcessEntry, ProcessEntry) -> Bool
        switch sortField {
        case .pid:    s = { sortAsc ? $0.pid < $1.pid : $0.pid > $1.pid }
        case .name:   s = { sortAsc ? $0.name < $1.name : $0.name > $1.name }
        case .cpu:    s = { sortAsc ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .mem:    s = { sortAsc ? $0.memRssMB < $1.memRssMB : $0.memRssMB > $1.memRssMB }
        case .uptime: s = { sortAsc ? $0.elapsedSeconds < $1.elapsedSeconds : $0.elapsedSeconds > $1.elapsedSeconds }
        }
        return filtered.sorted(by: s)
    }

    private var selectedTargets: [ProcessEntry] {
        ProcessBulkActionResolver.resolveTargets(
            selectedPIDs: selectedPIDs,
            processes: processes
        )
    }

    // MARK: - 进程树

    struct TreeNode: Identifiable {
        var id: Int32 { entry.pid }
        let entry: ProcessEntry
        let depth: Int
        let hasChildren: Bool
    }

    private var treeRows: [TreeNode] {
        let source = filtered
        let pidSet = Set(source.map(\.pid))
        let byParent = Dictionary(grouping: source) { $0.ppid }
        func build(_ p: ProcessEntry, depth: Int) -> [TreeNode] {
            let kids = (byParent[p.pid] ?? []).filter { $0.pid != p.pid }.sorted { $0.pid < $1.pid }
            var result = [TreeNode(entry: p, depth: depth, hasChildren: !kids.isEmpty)]
            if !collapsedPIDs.contains(p.pid) {
                for k in kids { result += build(k, depth: depth + 1) }
            }
            return result
        }
        let roots = source
            .filter { !pidSet.contains($0.ppid) || $0.ppid == $0.pid }
            .sorted { $0.pid < $1.pid }
        return roots.flatMap { build($0, depth: 0) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.k("user.detail.auto.process", fallback: "进程管理")).font(.headline)
                if searchText.isEmpty {
                    Text(L10n.f("views.user_detail_view.text_f40c2690", fallback: "%@ 个进程", String(describing: processes.count))).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(filtered.count) / \(processes.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                if !selectedTargets.isEmpty {
                    Text(L10n.f("views.user_detail_view.text_6ffeae31", fallback: "已选 %@", String(describing: selectedTargets.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Text(L10n.k("user.detail.auto.ctrl", fallback: "⌘/Ctrl 多选"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if isActive {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                    }
                    Text(isActive ? L10n.k("user.detail.auto.live", fallback: "实时") : L10n.k("user.detail.auto.paused", fallback: "已暂停")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            if !selectedTargets.isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.f("views.user_detail_view.text_5a560471", fallback: "已选 %@ 个进程", String(describing: selectedTargets.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.f("views.user_detail_view.text_e80c7665", fallback: "终止已选 (%@)", String(describing: selectedTargets.count))) {
                        killTargets = selectedTargets
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        Task { await doKill(selectedTargets, signal: 9) }
                    } label: {
                        Text(L10n.f("views.user_detail_view.text_6151cab2", fallback: "强制结束已选 (%@)", String(describing: selectedTargets.count)))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()
            }

            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.k("user.detail.auto.searchprocess", fallback: "搜索进程名或命令行…"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 列头
            ProcessColumnHeader(
                viewMode: viewMode,
                sortField: sortField,
                sortAsc: sortAsc,
                widths: $columnWidths
            ) { field in
                if sortField == field { sortAsc.toggle() } else { sortField = field; sortAsc = true }
            }

            Divider()

            // 列表内容
            if isLoading {
                ProgressView(L10n.k("user.detail.auto.loading", fallback: "加载中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty && isActive {
                Text(searchText.isEmpty ? L10n.k("user.detail.auto.process", fallback: "暂无进程") : L10n.k("user.detail.auto.process", fallback: "无匹配进程")).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .flat {
                List(sorted, selection: $selectedPIDs) { proc in
                    ProcessRow(
                        proc: proc,
                        depth: 0,
                        hasChildren: false,
                        isCollapsed: false,
                        widths: columnWidths,
                        onToggle: nil
                    )
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .onTapGesture(count: 2) { detailTarget = proc }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                handleControlToggleSelection(pid: proc.pid)
                            }
                        )
                        .contextMenu { killMenu(proc) }
                }
                .listStyle(.plain)
            } else {
                List(treeRows, selection: $selectedPIDs) { node in
                    ProcessRow(
                        proc: node.entry,
                        depth: node.depth,
                        hasChildren: node.hasChildren,
                        isCollapsed: collapsedPIDs.contains(node.entry.pid),
                        widths: columnWidths,
                        onToggle: {
                            if collapsedPIDs.contains(node.entry.pid) {
                                collapsedPIDs.remove(node.entry.pid)
                            } else {
                                collapsedPIDs.insert(node.entry.pid)
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .onTapGesture(count: 2) { detailTarget = node.entry }
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            handleControlToggleSelection(pid: node.entry.pid)
                        }
                    )
                    .contextMenu { killMenu(node.entry) }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack(spacing: 8) {
                if isLoading || portsLoading {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let t = lastUpdatedAt {
                    Text(L10n.f("views.user_detail_view.text_08170b91", fallback: "更新于 %@", String(describing: Self.statusTimeFormatter.string(from: t))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .onAppear  { isActive = true }
        .onDisappear { isActive = false }
        .task(id: isActive) {
            guard isActive else { return }
            isLoading = true
            while !Task.isCancelled && isActive {
                let snapshot = await helperClient.getProcessListSnapshot(username: username)
                processes = snapshot.entries
                portsLoading = snapshot.portsLoading
                lastUpdatedAt = Date(timeIntervalSince1970: snapshot.updatedAt)
                let livePIDs = Set(snapshot.entries.map(\.pid))
                selectedPIDs.formIntersection(livePIDs)
                isLoading = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .confirmationDialog(
            killDialogTitle,
            isPresented: Binding(get: { !killTargets.isEmpty }, set: { if !$0 { killTargets = [] } }),
            titleVisibility: .visible
        ) {
            if !killTargets.isEmpty {
                Button(L10n.k("user.detail.auto.sigterm", fallback: "发送 SIGTERM"), role: .destructive) { Task { await doKill(killTargets, signal: 15) } }
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { killTargets = [] }
            }
        }
        .alert(L10n.k("user.detail.auto.operation_failed", fallback: "操作失败"), isPresented: Binding(
            get: { killError != nil }, set: { if !$0 { killError = nil } }
        )) {
            Button(L10n.k("user.detail.auto.ok", fallback: "确定"), role: .cancel) { killError = nil }
        } message: { Text(killError ?? "") }
        .sheet(item: $detailTarget) { proc in
            ProcessDetailSheet(base: proc)
        }
    }

    @ViewBuilder
    private func killMenu(_ proc: ProcessEntry) -> some View {
        let targets = contextualKillTargets(for: proc)
        let count = targets.count
        Button { detailTarget = proc } label: {
            Label(L10n.k("views.user_detail_view.view_details", fallback: "查看详情"), systemImage: "info.circle")
        }
        Divider()
        Button { killTargets = targets } label: {
            Label(count > 1
                  ? String(format: L10n.k("views.user_detail_view.kill_selected_sigterm", fallback: "终止选中进程 (%d, SIGTERM)"), count)
                  : L10n.k("views.user_detail_view.process_sigterm", fallback: "终止进程 (SIGTERM)"),
                  systemImage: "stop.circle")
        }
        .disabled(targets.isEmpty)
        Button(role: .destructive) { Task { await doKill(targets, signal: 9) } } label: {
            Label(count > 1
                  ? String(format: L10n.k("views.user_detail_view.force_kill_selected_sigkill", fallback: "强制结束选中进程 (%d, SIGKILL)"), count)
                  : L10n.k("views.user_detail_view.sigkill", fallback: "强制结束 (SIGKILL)"),
                  systemImage: "xmark.circle.fill")
        }
        .disabled(targets.isEmpty)
    }

    private var killDialogTitle: String {
        if killTargets.count == 1, let first = killTargets.first {
            return String(format: L10n.k("views.user_detail_view.kill_process_confirmation", fallback: "终止进程 %@（PID %d）？"), first.name, first.pid)
        }
        return String(format: L10n.k("views.user_detail_view.kill_selected_process_count", fallback: "终止已选中的 %d 个进程？"), killTargets.count)
    }

    private func contextualKillTargets(for proc: ProcessEntry) -> [ProcessEntry] {
        let visiblePIDs: Set<Int32> = {
            if viewMode == .flat { return Set(sorted.map(\.pid)) }
            return Set(treeRows.map(\.id))
        }()
        let effectiveSelected = selectedPIDs.intersection(visiblePIDs)
        return ProcessKillSelectionResolver.resolveTargets(
            clickedPID: proc.pid,
            selectedPIDs: effectiveSelected,
            processes: processes
        )
    }

    private func handleControlToggleSelection(pid: Int32) {
        guard NSApp.currentEvent?.modifierFlags.contains(.control) == true else { return }
        if selectedPIDs.contains(pid) {
            selectedPIDs.remove(pid)
        } else {
            selectedPIDs.insert(pid)
        }
    }

    private func doKill(_ targets: [ProcessEntry], signal: Int32) async {
        killTargets = []
        guard !targets.isEmpty else { return }

        var failures: [String] = []
        for proc in targets {
            do {
                try await helperClient.killProcess(pid: proc.pid, signal: signal)
            } catch {
                failures.append("PID \(proc.pid): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            selectedPIDs.subtract(targets.map(\.pid))
            return
        }
        killError = failures.count == 1
            ? failures[0]
            : L10n.k("views.user_detail_view.process", fallback: "以下进程操作失败：\n") + failures.joined(separator: "\n")
    }

    private var statusText: String {
        if isLoading { return L10n.k("views.user_detail_view.loading_process_base_info", fallback: "正在加载进程基础信息…") }
        if portsLoading { return L10n.k("views.user_detail_view.port", fallback: "基础信息已就绪，正在补充端口信息…") }
        if processes.isEmpty { return L10n.k("views.user_detail_view.no_process_data", fallback: "暂无进程数据") }
        return String(format: L10n.k("views.user_detail_view.process_port_ready_count", fallback: "进程与端口数据已就绪（%d）"), processes.count)
    }
}

private struct ProcessDetailSheet: View {
    let base: ProcessEntry
    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var detail: ProcessDetail? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.f("views.user_detail_view.pid_fabd0d", fallback: "进程详情 · PID %@", String(describing: base.pid))).font(.headline)
                Spacer()
                Button(L10n.k("user.detail.auto.close", fallback: "关闭")) { dismiss() }
            }

            if isLoading {
                ProgressView(L10n.k("user.detail.auto.text_1087df4607", fallback: "正在读取详情…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow(L10n.k("user.detail.auto.process", fallback: "进程名"), value: resolved.name)
                        detailRow(L10n.k("user.detail.auto.command_line", fallback: "命令行"), value: resolved.cmdline)
                        detailRow(L10n.k("user.detail.auto.process_pid", fallback: "父进程 PID"), value: "\(resolved.ppid)")
                        detailRow(L10n.k("user.detail.auto.status", fallback: "状态"), value: resolved.stateLabel)
                        detailRow("CPU", value: String(format: "%.1f%%", resolved.cpuPercent))
                        detailRow(L10n.k("user.detail.process.mem", fallback: "内存"), value: resolved.memLabel)
                        detailRow(L10n.k("user.detail.auto.runtime", fallback: "运行时长"), value: resolved.uptimeLabel)
                        detailRow(L10n.k("user.detail.auto.start", fallback: "启动时间"), value: formatTime(resolved.startTime))
                        detailRow(L10n.k("user.detail.auto.port", fallback: "监听端口"), value: resolved.listeningPorts.isEmpty ? "—" : resolved.listeningPorts.joined(separator: ", "))
                        Divider().padding(.vertical, 2)
                        detailRow(L10n.k("user.detail.auto.executable_file", fallback: "可执行文件"), value: resolved.executablePath ?? "—")
                        detailRow(L10n.k("user.detail.auto.file_exists", fallback: "文件存在"), value: resolved.executableExists ? L10n.k("user.detail.auto.yes", fallback: "是") : L10n.k("user.detail.auto.no", fallback: "否"))
                        detailRow(L10n.k("user.detail.auto.file_size", fallback: "文件大小"), value: resolved.executableFileSizeBytes.map(FormatUtils.formatBytes) ?? "—")
                        detailRow(L10n.k("user.detail.auto.created_at", fallback: "创建时间"), value: formatTime(resolved.executableCreatedAt))
                        detailRow(L10n.k("user.detail.auto.modified_at", fallback: "修改时间"), value: formatTime(resolved.executableModifiedAt))
                        detailRow(L10n.k("user.detail.auto.accessed_at", fallback: "访问时间"), value: formatTime(resolved.executableAccessedAt))
                        detailRow(L10n.k("user.detail.auto.metadata_changed", fallback: "元数据变更"), value: formatTime(resolved.executableMetadataChangedAt))
                        detailRow("inode", value: resolved.executableInode.map(String.init) ?? "—")
                        detailRow(L10n.k("user.detail.auto.hard_link_count", fallback: "硬链接数"), value: resolved.executableLinkCount.map(String.init) ?? "—")
                        detailRow(L10n.k("user.detail.auto.owner", fallback: "属主"), value: resolved.executableOwner ?? "—")
                        detailRow(L10n.k("user.detail.auto.permissions", fallback: "权限"), value: resolved.executablePermissions ?? "—")
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 460)
        .task {
            let fetched = await helperClient.getProcessDetail(pid: base.pid)
            detail = fetched
            isLoading = false
            if fetched == nil {
                loadError = L10n.k("user.detail.auto.the_process_may_have_exited_details_are_unavailable", fallback: "进程可能已退出，无法读取详情。")
            }
        }
    }

    private var resolved: ProcessDetail {
        detail ?? ProcessDetail(
            pid: base.pid,
            ppid: base.ppid,
            name: base.name,
            cmdline: base.cmdline,
            cpuPercent: base.cpuPercent,
            memRssMB: base.memRssMB,
            state: base.state,
            elapsedSeconds: base.elapsedSeconds,
            startTime: nil,
            executablePath: nil,
            executableExists: false,
            executableFileSizeBytes: nil,
            executableCreatedAt: nil,
            executableModifiedAt: nil,
            executableAccessedAt: nil,
            executableMetadataChangedAt: nil,
            executableInode: nil,
            executableLinkCount: nil,
            executableOwner: nil,
            executablePermissions: nil,
            listeningPorts: base.listeningPorts
        )
    }

    private func detailRow(_ key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTime(_ ts: TimeInterval?) -> String {
        guard let ts else { return "—" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 列头（独立抽出减轻类型检查压力）

private struct ProcessColumnWidths {
    var pid: CGFloat = UserDetailWindowLayout.defaultProcessColumns.pid
    var name: CGFloat = UserDetailWindowLayout.defaultProcessColumns.name
    var command: CGFloat = UserDetailWindowLayout.defaultProcessColumns.command
    var cpu: CGFloat = UserDetailWindowLayout.defaultProcessColumns.cpu
    var mem: CGFloat = UserDetailWindowLayout.defaultProcessColumns.mem
    var uptime: CGFloat = UserDetailWindowLayout.defaultProcessColumns.uptime
    var ports: CGFloat = UserDetailWindowLayout.defaultProcessColumns.ports
    var purpose: CGFloat = UserDetailWindowLayout.defaultProcessColumns.purpose
}

private struct ProcessColumnHeader: View {
    let viewMode: ProcessTabView.ViewMode
    let sortField: ProcessTabView.SortField
    let sortAsc: Bool
    @Binding var widths: ProcessColumnWidths
    let onSort: (ProcessTabView.SortField) -> Void

    var body: some View {
        HStack(spacing: 0) {
            pidCol(right: $widths.name) { onSort(.pid) }
            nameCol { onSort(.name) }
            commandCol(right: $widths.cpu)
            cpuCol(right: $widths.mem) { onSort(.cpu) }
            memCol(right: $widths.uptime) { onSort(.mem) }
            uptimeCol(right: $widths.ports) { onSort(.uptime) }
            resizableText(L10n.k("user.detail.auto.port", fallback: "端口"), width: $widths.ports, min: 84, max: 360)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 30, alignment: .center)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder private func pidCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("PID", field: .pid, width: $widths.pid, min: 50, max: 120, align: .trailing,
                rightWidth: right, rightMin: 96, rightMax: 320, action: action)
    }
    @ViewBuilder private func nameCol(action: @escaping () -> Void) -> some View {
        if viewMode == .flat {
            sortBtn(L10n.k("user.detail.auto.process", fallback: "进程名"), field: .name, width: $widths.name, min: 96, max: 320, align: .leading,
                    action: action)
        } else {
            resizableText(L10n.k("user.detail.auto.process", fallback: "进程名"), width: $widths.name, min: 96, max: 320)
        }
    }
    @ViewBuilder private func commandCol(right: Binding<CGFloat>) -> some View {
        // Command 列为弹性列，自动填充剩余空间
        Text("Command")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .overlay(alignment: .trailing) {
                resizeHandle(width: right, min: 48, max: 120)
            }
    }
    @ViewBuilder private func cpuCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("CPU%", field: .cpu, width: $widths.cpu, min: 48, max: 120, align: .trailing,
                rightWidth: right, rightMin: 54, rightMax: 160, action: action)
    }
    @ViewBuilder private func memCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn(L10n.k("user.detail.process.mem", fallback: "内存"), field: .mem, width: $widths.mem, min: 54, max: 160, align: .trailing,
                rightWidth: right, rightMin: 48, rightMax: 160, action: action)
    }
    @ViewBuilder private func uptimeCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn(L10n.k("user.detail.auto.duration", fallback: "时长"), field: .uptime, width: $widths.uptime, min: 48, max: 160, align: .trailing,
                rightWidth: right, rightMin: 84, rightMax: 360, action: action)
    }

    @ViewBuilder
    private func sortBtn(_ label: String, field: ProcessTabView.SortField,
                         width: Binding<CGFloat>, min: CGFloat, max: CGFloat, align: Alignment,
                         rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                         defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if align == .trailing { Spacer() }
                Text(label).lineLimit(1)
                if sortField == field {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down").font(.system(size: 8))
                }
                if align == .leading { Spacer() }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width.wrappedValue, alignment: align)
        .padding(.horizontal, 4)
        .overlay(alignment: .trailing) {
            resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax,
                         defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
        }
    }

    private func resizableText(_ label: String, width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                               rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                               defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0) -> some View {
        Text(label)
            .lineLimit(1)
            .frame(width: width.wrappedValue, alignment: .leading)
            .padding(.horizontal, 4)
            .overlay(alignment: .trailing) {
                resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax,
                             defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
            }
    }

    private func resizeHandle(width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                              rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
                              defaultWidth: CGFloat = 0, defaultRightWidth: CGFloat = 0) -> some View {
        ResizeGrip(width: width, minWidth: min, maxWidth: max,
                   rightWidth: rightWidth, rightMinWidth: rightMin, rightMaxWidth: rightMax,
                   defaultWidth: defaultWidth, defaultRightWidth: defaultRightWidth)
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let proc: ProcessEntry
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    let widths: ProcessColumnWidths
    let onToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // PID
            Text(verbatim: "\(proc.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.pid, alignment: .trailing)
                .padding(.horizontal, 4)

            // 进程名（树状模式下含缩进 + 折叠按钮）
            HStack(spacing: 0) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 12)
                    Text("╰ ").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if hasChildren {
                    Button { onToggle?() } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else if depth > 0 {
                    Spacer().frame(width: 14)
                }
                Text(proc.name.isEmpty ? "?" : proc.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: widths.name, alignment: .leading)
            .padding(.horizontal, 4)
            .help(proc.purposeDescription.isEmpty ? proc.cmdline : proc.purposeDescription)

            // Command — 弹性列，可选中，居中截断
            Text(proc.cmdline.isEmpty ? "—" : proc.cmdline)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            // CPU%
            Text(String(format: "%.1f", proc.cpuPercent))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(proc.cpuPercent > 50 ? .orange : .primary)
                .frame(width: widths.cpu, alignment: .trailing)
                .padding(.horizontal, 4)

            // 内存
            Text(proc.memLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(width: widths.mem, alignment: .trailing)
                .padding(.horizontal, 4)

            // 时长
            Text(proc.uptimeLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.uptime, alignment: .trailing)
                .padding(.horizontal, 4)

            // 监听端口
            Text(proc.portsLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: widths.ports, alignment: .leading)
                .padding(.horizontal, 4)
        }
        .padding(.vertical, 2)
    }
}

private struct ResizeGrip: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let rightWidth: Binding<CGFloat>?
    let rightMinWidth: CGFloat
    let rightMaxWidth: CGFloat
    var defaultWidth: CGFloat = 0
    var defaultRightWidth: CGFloat = 0
    @State private var baseWidth: CGFloat = 0
    @State private var baseRightWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8, height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if baseWidth == 0 {
                            baseWidth = width
                            baseRightWidth = rightWidth?.wrappedValue ?? 0
                        }

                        // 边界拖拽：向右 => 左列变宽、右列变窄；向左反之。
                        var newLeft = Swift.min(Swift.max(baseWidth + value.translation.width, minWidth), maxWidth)
                        guard let rightWidth else {
                            width = newLeft
                            return
                        }

                        var delta = newLeft - baseWidth
                        var newRight = baseRightWidth - delta
                        if newRight < rightMinWidth {
                            newRight = rightMinWidth
                            delta = baseRightWidth - newRight
                            newLeft = Swift.min(Swift.max(baseWidth + delta, minWidth), maxWidth)
                        } else if newRight > rightMaxWidth {
                            newRight = rightMaxWidth
                            delta = baseRightWidth - newRight
                            newLeft = Swift.min(Swift.max(baseWidth + delta, minWidth), maxWidth)
                        }

                        width = newLeft
                        rightWidth.wrappedValue = newRight
                    }
                    .onEnded { _ in
                        baseWidth = 0
                        baseRightWidth = 0
                    }
            )
            .onTapGesture(count: 2) {
                // 双击重置为默认宽度
                if defaultWidth > 0 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        width = defaultWidth
                        if let rightWidth, defaultRightWidth > 0 {
                            rightWidth.wrappedValue = defaultRightWidth
                        }
                    }
                }
            }
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1)
            }
    }
}

private enum DirectProviderChoice: String, CaseIterable, Identifiable {
    case qiniu = "qiniu"
    case kimiCoding = "kimi-coding"
    case minimax = "minimax"
    case zai = "zai"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kimiCoding: return "Kimi Code"
        case .minimax: return "MiniMax"
        case .qiniu: return "Qiniu AI"
        case .zai: return "智谱 Z.AI"
        case .custom: return "自定义"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax: return "MiniMax API Key"
        case .qiniu: return "Qiniu API Key"
        case .zai: return "智谱 API Key"
        case .custom: return "自定义 API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax: return L10n.k("views.user_detail_view.minimax_api_key", fallback: "粘贴 MiniMax API Key")
        case .qiniu: return "sk-..."
        case .zai: return "sk-..."
        case .custom: return "留空则尝试使用 CUSTOM_API_KEY"
        }
    }

    var consoleURL: String? {
        switch self {
        case .kimiCoding: return "https://www.kimi.com/code/console"
        case .minimax: return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .qiniu: return "https://portal.qiniu.com/ai-inference/api-key?ref=clawdhome.app"
        case .zai: return "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case .custom: return nil
        }
    }

    var consoleTitle: String? {
        switch self {
        case .kimiCoding: return L10n.k("views.user_detail_view.kimi_code", fallback: "Kimi Code 控制台")
        case .minimax: return L10n.k("views.user_detail_view.minimax", fallback: "MiniMax 控制台")
        case .qiniu: return "七牛 API Key"
        case .zai: return "获取 API Key"
        case .custom: return nil
        }
    }

    var promotionURL: String? {
        switch self {
        case .minimax:
            return "https://platform.minimaxi.com/subscribe/token-plan?code=BvYUzElSu4&source=link"
        case .qiniu:
            return "https://www.qiniu.com/ai/promotion/invited?cps_key=1hdl63udiuyqa"
        case .zai:
            return "https://www.bigmodel.cn/glm-coding?ic=BXQV5BQ8BB"
        default:
            return nil
        }
    }

    var promotionTitle: String? {
        switch self {
        case .minimax:
            return "🎁 领取 9 折专属优惠"
        case .qiniu:
            return "免费领取 1000 万 Token"
        case .zai:
            return "95折优惠订阅"
        case .custom:
            return nil
        default:
            return nil
        }
    }
}

private enum DirectKimiModel: String, CaseIterable, Identifiable {
    case k2p5 = "kimi-coding/k2p5"

    var id: String { rawValue }

    var alias: String {
        switch self {
        case .k2p5: return "Kimi K2.5"
        }
    }
}

private enum DirectCustomCompatibility: String, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var apiType: String {
        switch self {
        case .openai: return "openai-completions"
        case .anthropic: return "anthropic-messages"
        }
    }
}

private enum DirectMinimaxModel: String, CaseIterable, Identifiable {
    case m27 = "minimax/MiniMax-M2.7"
    case m27Highspeed = "minimax/MiniMax-M2.7-highspeed"
    case m25 = "minimax/MiniMax-M2.5"
    case m25Highspeed = "minimax/MiniMax-M2.5-highspeed"
    case vl01 = "minimax/MiniMax-VL-01"
    case m2 = "minimax/MiniMax-M2"
    case m21 = "minimax/MiniMax-M2.1"

    var id: String { rawValue }

    var providerName: String {
        rawValue.replacingOccurrences(of: "minimax/", with: "")
    }

    var reasoning: Bool {
        switch self {
        case .vl01: return false
        default: return true
        }
    }

    var inputTypes: [String] {
        switch self {
        case .vl01: return ["text", "image"]
        default: return ["text"]
        }
    }

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "minimax/", with: "")
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": providerName,
            "reasoning": reasoning,
            "input": inputTypes,
            "cost": [
                "input": 0.3,
                "output": 1.2,
                "cacheRead": 0.03,
                "cacheWrite": 0.12,
            ],
            "contextWindow": 200000,
            "maxTokens": 8192,
        ]
    }
}

private enum DirectQiniuModel: String, CaseIterable, Identifiable {
    case glm5 = "qiniu/z-ai/glm-5"
    case kimiK25 = "qiniu/moonshotai/kimi-k2.5"
    case minimaxM25 = "qiniu/minimax/minimax-m2.5"
    case deepseekV32 = "qiniu/deepseek-v3.2-251201"

    var id: String { rawValue }

    var alias: String {
        switch self {
        case .glm5: return "GLM 5"
        case .kimiK25: return "Kimi K2.5"
        case .minimaxM25: return "Minimax M2.5"
        case .deepseekV32: return "DeepSeek V3.2"
        }
    }

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "qiniu/", with: "")
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": alias,
            "reasoning": false,
            "input": ["text"],
            "contextWindow": contextWindow,
            "maxTokens": 8192,
            "compat": [
                "supportsStore": false,
                "supportsDeveloperRole": false,
                "supportsReasoningEffort": false,
            ],
        ]
    }

    private var contextWindow: Int {
        switch self {
        case .kimiK25: return 256000
        default: return 128000
        }
    }
}

private enum DirectZAIModel: String, CaseIterable, Identifiable {
    case glm5_1 = "zai/glm-5.1"
    case glm5 = "zai/glm-5"
    case glm4_7 = "zai/glm-4.7"

    var id: String { rawValue }

    var alias: String {
        switch self {
        case .glm5_1: return "GLM-5.1"
        case .glm5: return "GLM-5"
        case .glm4_7: return "GLM-4.7"
        }
    }

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "zai/", with: "")
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": alias,
            "reasoning": true,
            "input": ["text"],
            "cost": ["input": 0.0, "output": 0.0, "cacheRead": 0.0, "cacheWrite": 0.0],
            "contextWindow": 204800,
            "maxTokens": 131072,
        ]
    }
}

private let userDetailModelConfigMaintenanceContext = "user-detail-model-config"

private struct KimiMinimaxModelConfigPanel: View {
    let user: ManagedUser
    var onApplied: (() -> Void)? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isRestartingGateway = false
    @State private var selectedProvider: DirectProviderChoice = .qiniu
    @State private var selectedKimiModel: DirectKimiModel = .k2p5
    @State private var selectedMinimaxModel: DirectMinimaxModel = .m27
    @State private var selectedQiniuModel: DirectQiniuModel = .deepseekV32
    @State private var selectedZAIModel: DirectZAIModel = .glm5
    @State private var customProviderId = ""
    @State private var customBaseURL = "https://api.example.com/v1"
    @State private var customCompatibility: DirectCustomCompatibility = .openai
    @State private var customModelId = "gpt-4.1"
    @State private var customModelSuggestions: [String] = []
    @State private var isFetchingCustomModels = false
    @State private var customModelFetchMessage: String? = nil
    @State private var customModelFetchError: String? = nil
    @State private var providerKeys: [String: String] = [:]
    @State private var isShowingApiKey = false
    @State private var saveMessage: String? = nil
    @State private var saveError: String? = nil
    @State private var currentDefaultModel: String? = nil
    @State private var currentFallbackModels: [String] = []
    @State private var configMode: ConfigMode = .builtinUI
    @State private var activeModelConfigTerminalToken: String? = nil
    @State private var showOldModelPrompt = false
    @State private var pendingApiKey: String = ""

    /// 用户选择：旧主模型如何处理
    enum OldModelAction { case keepAsFallback, replace }
    @State private var oldModelAction: OldModelAction? = nil

    private enum ConfigMode: String, CaseIterable, Identifiable {
        case builtinUI
        case cliMore
        var id: String { rawValue }
        var title: String {
            switch self {
            case .builtinUI: return "内置 UI"
            case .cliMore: return "更多模型（命令行）"
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { providerKeys[selectedProvider.rawValue] ?? "" },
            set: { providerKeys[selectedProvider.rawValue] = $0 }
        )
    }

    private var canApply: Bool {
        let apiKey = (providerKeys[selectedProvider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedProvider == .custom {
            let baseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return !baseURL.isEmpty && !effectiveCustomModelId.isEmpty
        }
        return !apiKey.isEmpty
    }

    private var effectiveCustomProviderId: String {
        let value = customProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "custom" : value
    }

    private var effectiveCustomModelId: String {
        customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let currentDefaultModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.f("views.user_detail_view.current_model", fallback: "当前：%@", String(describing: currentDefaultModel)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        currentFallbackModels.isEmpty
                        ? L10n.k("views.user_detail_view.fallback_none", fallback: "降级：无")
                        : L10n.f(
                            "views.user_detail_view.fallback_models",
                            fallback: "降级：%@",
                            String(describing: currentFallbackModels.joined(separator: " · "))
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                }
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(L10n.k("user.detail.auto.configuration", fallback: "读取当前配置…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(L10n.k("views.user_detail_view.configuration_mode", fallback: "配置方式"), selection: $configMode) {
                    ForEach(ConfigMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if configMode == .cliMore {
                    HStack(spacing: 6) {
                        Label(L10n.k("views.user_detail_view.more_models", fallback: "更多模型"), systemImage: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.k("views.user_detail_view.more_models_desc", fallback: "通过命令行交互配置，支持完整模型与回退策略。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(L10n.k("views.user_detail_view.open_cli_config", fallback: "打开命令行配置")) {
                        openModelConfigTerminal()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Picker(L10n.k("views.user_detail_view.provider", fallback: "模型提供商"), selection: $selectedProvider) {
                        ForEach(DirectProviderChoice.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    if selectedProvider != .custom {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(selectedProvider.apiKeyLabel)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                if let promotionTitle = selectedProvider.promotionTitle,
                                   let promotionURL = selectedProvider.promotionURL {
                                    Button {
                                        if let url = URL(string: promotionURL) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        Label(promotionTitle, systemImage: "gift")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Color.accentColor)
                                }
                                if let consoleURL = selectedProvider.consoleURL,
                                   let consoleTitle = selectedProvider.consoleTitle {
                                    Button {
                                        if let url = URL(string: consoleURL) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        Label(consoleTitle, systemImage: "arrow.up.right.square")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(Color.accentColor)
                                }
                            }

                            HStack(spacing: 8) {
                                Group {
                                    if isShowingApiKey {
                                        TextField(selectedProvider.apiKeyPlaceholder, text: apiKeyBinding)
                                    } else {
                                        SecureField(selectedProvider.apiKeyPlaceholder, text: apiKeyBinding)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    isShowingApiKey.toggle()
                                } label: {
                                    Image(systemName: isShowingApiKey ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.bordered)
                                .help(isShowingApiKey ? L10n.k("user.detail.auto.hide", fallback: "隐藏") : L10n.k("user.detail.auto.show", fallback: "显示"))
                            }
                        }
                    }

                    if selectedProvider == .minimax {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("user.detail.auto.minimax_models", fallback: "MiniMax 模型"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Picker(L10n.k("user.detail.auto.models", fallback: "模型"), selection: $selectedMinimaxModel) {
                                ForEach(DirectMinimaxModel.allCases) { model in
                                    Text(model.providerName).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(selectedMinimaxModel.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if selectedProvider == .kimiCoding {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("user.detail.auto.kimi_models", fallback: "Kimi 模型"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Picker(L10n.k("user.detail.auto.models", fallback: "模型"), selection: $selectedKimiModel) {
                                ForEach(DirectKimiModel.allCases) { model in
                                    Text(model.alias).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(selectedKimiModel.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if selectedProvider == .qiniu {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(L10n.k("user.detail.auto.models", fallback: "模型"), selection: $selectedQiniuModel) {
                                ForEach(DirectQiniuModel.allCases) { model in
                                    Text(model.alias).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(selectedQiniuModel.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if selectedProvider == .zai {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("views.user_detail_view.zai_models", fallback: "智谱 Z.AI 模型"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Picker(L10n.k("user.detail.auto.models", fallback: "模型"), selection: $selectedZAIModel) {
                                ForEach(DirectZAIModel.allCases) { model in
                                    Text(model.alias).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(selectedZAIModel.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if selectedProvider == .custom {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Picker(L10n.k("views.user_detail_view.custom_compatibility_picker", fallback: "兼容类型"), selection: $customCompatibility) {
                                    ForEach(DirectCustomCompatibility.allCases) { item in
                                        Text(item.title).tag(item)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.k("views.user_detail_view.base_url", fallback: "Base URL"))
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                TextField("https://api.example.com/v1", text: $customBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedProvider.apiKeyLabel)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    Group {
                                        if isShowingApiKey {
                                            TextField(selectedProvider.apiKeyPlaceholder, text: apiKeyBinding)
                                        } else {
                                            SecureField(selectedProvider.apiKeyPlaceholder, text: apiKeyBinding)
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)

                                    Button {
                                        isShowingApiKey.toggle()
                                    } label: {
                                        Image(systemName: isShowingApiKey ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.bordered)
                                    .help(isShowingApiKey ? L10n.k("user.detail.auto.hide", fallback: "隐藏") : L10n.k("user.detail.auto.show", fallback: "显示"))
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.k("views.user_detail_view.custom_model", fallback: "模型"))
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                TextField(
                                    L10n.k("views.user_detail_view.custom_model_id_placeholder", fallback: "输入模型 ID（例如 gpt-4.1 / claude-3-7-sonnet）"),
                                    text: $customModelId
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                HStack(spacing: 8) {
                                    Button(isFetchingCustomModels ? "拉取中…" : "从 API 拉取列表") {
                                        Task { await fetchCustomModels() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isFetchingCustomModels || customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    if !customModelSuggestions.isEmpty {
                                        Picker(L10n.k("views.user_detail_view.suggested_models", fallback: "可选模型"), selection: $customModelId) {
                                            ForEach(customModelSuggestions, id: \.self) { item in
                                                Text(item).tag(item)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .controlSize(.small)
                                    }
                                }
                                if let customModelFetchMessage {
                                    Text(customModelFetchMessage)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let customModelFetchError {
                                    Text(customModelFetchError)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.k("views.user_detail_view.custom_provider_id_optional", fallback: "Provider ID（可选，默认 custom）"))
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                TextField("custom", text: $customProviderId)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Text("\(effectiveCustomProviderId)/\(effectiveCustomModelId)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let saveMessage {
                        Label(saveMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if isRestartingGateway {
                        Label(L10n.k("user.detail.cron.restarting_gateway", fallback: "正在重启 Gateway，配置将在重启后生效…"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(L10n.k("user.detail.auto.reload", fallback: "重新读取")) {
                            Task { await loadCurrentState() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)

                        Spacer()

                        Button(
                            isRestartingGateway
                                ? L10n.k("views.user_detail_view.restarting_gateway", fallback: "重启中…")
                                : (isSaving
                                    ? L10n.k("user.detail.auto.save", fallback: "保存中…")
                                    : L10n.k("user.detail.auto.save", fallback: "保存并应用"))
                        ) {
                            Task { await applyConfig() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || !canApply)
                    }
                }
            }
        }
        .onChange(of: selectedProvider) { _, _ in
            saveMessage = nil
            saveError = nil
            if selectedProvider == .custom && customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                customBaseURL = "https://api.example.com/v1"
            }
        }
        .task {
            await loadCurrentState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maintenanceTerminalWindowClosed)) { notification in
            guard let userInfo = notification.userInfo,
                  let token = userInfo["token"] as? String,
                  let context = userInfo["context"] as? String,
                  context == userDetailModelConfigMaintenanceContext,
                  token == activeModelConfigTerminalToken else { return }
            activeModelConfigTerminalToken = nil
            Task {
                await loadCurrentState()
                onApplied?()
            }
        }
        .confirmationDialog(
            L10n.f("views.user_detail_view.old_model_prompt_title",
                    fallback: "当前主模型 %@ 如何处理？",
                    currentDefaultModel ?? ""),
            isPresented: $showOldModelPrompt,
            titleVisibility: .visible
        ) {
            Button(L10n.k("views.user_detail_view.old_model_keep_fallback", fallback: "保留为备选")) {
                oldModelAction = .keepAsFallback
                Task { await doApplyConfig(apiKey: pendingApiKey) }
            }
            Button(L10n.k("views.user_detail_view.old_model_replace", fallback: "直接替换")) {
                oldModelAction = .replace
                Task { await doApplyConfig(apiKey: pendingApiKey) }
            }
            Button(L10n.k("views.user_detail_view.old_model_cancel", fallback: "取消"), role: .cancel) {}
        }
    }

    private func openModelConfigTerminal() {
        let completionToken = UUID().uuidString
        activeModelConfigTerminalToken = completionToken
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("wizard.model_config.command.window_title", fallback: "模型配置命令行"),
            command: ["openclaw", "configure", "--section", "model"],
            completionToken: completionToken,
            completionContext: userDetailModelConfigMaintenanceContext
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func loadCurrentState() async {
        isLoading = true
        defer { isLoading = false }
        saveMessage = nil
        saveError = nil

        let config = await helperClient.getConfigJSON(username: user.username)
        if let status = await helperClient.getModelsStatus(username: user.username) {
            currentDefaultModel = status.resolvedDefault ?? status.defaultModel
            currentFallbackModels = status.fallbacks
        } else {
            currentDefaultModel = currentPrimaryModel(from: config)
            currentFallbackModels = []
        }
        if let primary = currentPrimaryModel(from: config) {
            if primary.hasPrefix("minimax/") {
                selectedProvider = .minimax
                if let model = DirectMinimaxModel(rawValue: primary) {
                    selectedMinimaxModel = model
                }
            } else if primary.hasPrefix("qiniu/") {
                selectedProvider = .qiniu
                if let model = DirectQiniuModel(rawValue: primary) {
                    selectedQiniuModel = model
                }
            } else if primary.hasPrefix("zai/") {
                selectedProvider = .zai
                if let model = DirectZAIModel(rawValue: primary) {
                    selectedZAIModel = model
                }
            } else if primary.hasPrefix("kimi-coding/") {
                selectedProvider = .kimiCoding
                if let model = DirectKimiModel(rawValue: primary) {
                    selectedKimiModel = model
                }
            } else if primary.contains("/") {
                selectedProvider = .custom
                let parts = primary.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    customProviderId = parts[0]
                    customModelId = parts[1]
                }
            }
        }

        let authProfiles = await readUserJSON(relativePath: ".openclaw/agents/main/agent/auth-profiles.json")
        let profiles = (authProfiles["profiles"] as? [String: Any]) ?? [:]

        let kimiKey = ((profiles["kimi-coding:default"] as? [String: Any])?["key"] as? String) ?? ""
        let minimaxKey = ((profiles["minimax:cn"] as? [String: Any])?["key"] as? String) ?? ""
        let qiniuKey = ((profiles["qiniu:default"] as? [String: Any])?["key"] as? String) ?? ""
        let zaiKey = ((profiles["zai:default"] as? [String: Any])?["key"] as? String) ?? ""
        providerKeys[DirectProviderChoice.kimiCoding.rawValue] = kimiKey
        providerKeys[DirectProviderChoice.minimax.rawValue] = minimaxKey
        providerKeys[DirectProviderChoice.qiniu.rawValue] = qiniuKey
        providerKeys[DirectProviderChoice.zai.rawValue] = zaiKey

        if selectedProvider == .custom {
            let providerId = effectiveCustomProviderId
            let customProviderConfig = (((config["models"] as? [String: Any])?["providers"] as? [String: Any])?[providerId] as? [String: Any]) ?? [:]
            if let baseUrl = customProviderConfig["baseUrl"] as? String, !baseUrl.isEmpty {
                customBaseURL = baseUrl
            }
            if let api = customProviderConfig["api"] as? String {
                customCompatibility = api.contains("anthropic") ? .anthropic : .openai
            }
            if let apiKey = customProviderConfig["apiKey"] as? String, !apiKey.isEmpty {
                providerKeys[DirectProviderChoice.custom.rawValue] = apiKey
            } else {
                providerKeys[DirectProviderChoice.custom.rawValue] = ""
            }
        }
    }

    private func applyConfig() async {
        let apiKey = (providerKeys[selectedProvider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedProvider == .custom || !apiKey.isEmpty else {
            saveError = L10n.k("user.detail.auto.input_api_key", fallback: "请先输入 API Key")
            return
        }

        // 如果已有主模型且与新选择不同，弹窗让用户选择
        if let current = currentDefaultModel, !current.isEmpty {
            let newPrimary = resolveNewPrimary()
            if current != newPrimary {
                pendingApiKey = apiKey
                oldModelAction = nil
                showOldModelPrompt = true
                return
            }
        }

        // 没有旧模型冲突，直接替换
        oldModelAction = .replace
        await doApplyConfig(apiKey: apiKey)
    }

    /// 推算当前选择将要设置的主模型 ID
    private func resolveNewPrimary() -> String {
        switch selectedProvider {
        case .kimiCoding: return selectedKimiModel.rawValue
        case .minimax: return selectedMinimaxModel.rawValue
        case .qiniu: return selectedQiniuModel.rawValue
        case .zai: return selectedZAIModel.rawValue
        case .custom: return "\(effectiveCustomProviderId)/\(effectiveCustomModelId)"
        }
    }

    private func doApplyConfig(apiKey: String) async {
        guard let action = oldModelAction else { return }

        isSaving = true
        isRestartingGateway = false
        defer {
            isSaving = false
            isRestartingGateway = false
        }
        saveMessage = nil
        saveError = nil

        do {
            // IMPORTANT:
            // Qiniu must keep legacy direct config-file writes.
            // OpenClaw does not provide built-in Qiniu models, and we rely on explicit file fields.
            // Do NOT migrate this provider to gatewayHub.configPatch().
            if selectedProvider == .qiniu {
                try await applyQiniuLegacyConfig(apiKey: apiKey, action: action)
                isRestartingGateway = true
                gatewayHub.markPendingStart(username: user.username)
                try await helperClient.restartGateway(username: user.username)
                saveMessage = L10n.k("user.detail.auto.configuration", fallback: "配置已应用")

                // 刷新当前模型显示
                let newStatus = await helperClient.getModelsStatus(username: user.username)
                currentDefaultModel = newStatus?.resolvedDefault ?? newStatus?.defaultModel
                currentFallbackModels = newStatus?.fallbacks ?? []

                onApplied?()
                return
            }

            // 1. 构建 config patch + 同步 agent 文件
            let (patch, agentFileSync) = try await buildProviderPatch(apiKey: apiKey)

            // 2. 优先走 WebSocket config.patch；Gateway 未连接时回退到本地直写
            do {
                let (cfg, baseHash) = try await gatewayHub.configGetFull(username: user.username)
                var mergedPatch = mergePatchWithExistingAliases(patch: patch, existingConfig: cfg)
                applyOldModelAction(action, to: &mergedPatch, existingConfig: cfg)

                let (noop, _) = try await gatewayHub.configPatch(
                    username: user.username,
                    patch: mergedPatch,
                    baseHash: baseHash,
                    note: "ClawdHome: apply \(selectedProvider.title) config"
                )

                // 3. 同步 agent 目录文件
                try await agentFileSync()

                if !noop {
                    isRestartingGateway = true
                    gatewayHub.markPendingStart(username: user.username)
                }
            } catch {
                guard isGatewayConnectivityError(error) else { throw error }
                let cfg = await helperClient.getConfigJSON(username: user.username)
                var mergedPatch = mergePatchWithExistingAliases(patch: patch, existingConfig: cfg)
                applyOldModelAction(action, to: &mergedPatch, existingConfig: cfg)

                try await applyPatchDirect(mergedPatch, existingConfig: cfg)
                try await agentFileSync()

                isRestartingGateway = true
                gatewayHub.markPendingStart(username: user.username)
                try await helperClient.restartGateway(username: user.username)
            }
            saveMessage = L10n.k("user.detail.auto.configuration", fallback: "配置已应用")

            // 刷新当前模型显示
            let newStatus = await helperClient.getModelsStatus(username: user.username)
            currentDefaultModel = newStatus?.resolvedDefault ?? newStatus?.defaultModel
            currentFallbackModels = newStatus?.fallbacks ?? []

            onApplied?()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// keepAsFallback 逻辑：将旧主模型保留到 fallback 首位
    private func applyOldModelAction(_ action: OldModelAction, to patch: inout [String: Any], existingConfig: [String: Any]) {
        guard action == .keepAsFallback, let oldPrimary = currentDefaultModel, !oldPrimary.isEmpty else { return }

        let existingModel = ((existingConfig["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]
        var fallbacks = (existingModel?["fallbacks"] as? [String]) ?? []
        // 将旧主模型插入 fallbacks 首位（避免重复）
        fallbacks.removeAll { $0 == oldPrimary }
        fallbacks.insert(oldPrimary, at: 0)
        // 移除新主模型（避免重复）
        let newPrimary = resolveNewPrimary()
        fallbacks.removeAll { $0 == newPrimary }

        var agentsPatch = (patch["agents"] as? [String: Any]) ?? [:]
        var defaults = (agentsPatch["defaults"] as? [String: Any]) ?? [:]
        var model = (defaults["model"] as? [String: Any]) ?? [:]
        model["fallbacks"] = fallbacks
        defaults["model"] = model
        agentsPatch["defaults"] = defaults
        patch["agents"] = agentsPatch
    }

    /// Gateway 掉线时，按 merge-patch 语义在本地合成并直写变更的顶层键
    private func applyPatchDirect(_ patch: [String: Any], existingConfig: [String: Any]) async throws {
        let merged = mergeJSON(base: existingConfig, patch: patch)
        for key in patch.keys.sorted() {
            guard let value = merged[key] else { continue }
            try await helperClient.setConfigDirect(username: user.username, path: key, value: value)
        }
    }

    private func mergeJSON(base: [String: Any], patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, patchValue) in patch {
            if patchValue is NSNull {
                result.removeValue(forKey: key)
                continue
            }
            if let patchObject = patchValue as? [String: Any] {
                let baseObject = result[key] as? [String: Any] ?? [:]
                result[key] = mergeJSON(base: baseObject, patch: patchObject)
            } else {
                result[key] = patchValue
            }
        }
        return result
    }

    private func isGatewayConnectivityError(_ error: Error) -> Bool {
        if let gatewayError = error as? GatewayClientError {
            switch gatewayError {
            case .notConnected, .connectFailed:
                return true
            case .requestFailed, .encodingError:
                return false
            }
        }
        let message = error.localizedDescription
        return message.contains("Gateway 未连接") || message.contains("连接失败")
    }

    /// Qiniu 配置必须保持 v1.6.0 的 legacy 直写方式（setConfigDirect）。
    /// 背景：OpenClaw 没有内置 Qiniu 模型；统一 patch 流程可能在后续 schema/迁移中覆盖掉这类外部模型配置。
    /// 维护要求：请勿替换为 gatewayHub.configPatch。
    private func applyQiniuLegacyConfig(apiKey: String, action: OldModelAction) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let providerModels = DirectQiniuModel.allCases.map(\.providerModelConfig)
        let newPrimary = selectedQiniuModel.rawValue

        var normalizedModelConfig = normalizedDefaultModelConfig(from: config, primary: newPrimary)
        var fallbacks = (normalizedModelConfig["fallbacks"] as? [String]) ?? []
        fallbacks.removeAll { $0 == newPrimary }
        if let oldPrimary = currentDefaultModel, !oldPrimary.isEmpty {
            fallbacks.removeAll { $0 == oldPrimary }
            if action == .keepAsFallback {
                fallbacks.insert(oldPrimary, at: 0)
            }
        }
        if fallbacks.isEmpty {
            normalizedModelConfig.removeValue(forKey: "fallbacks")
        } else {
            normalizedModelConfig["fallbacks"] = fallbacks
        }

        var aliasMap = ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:])
        for model in DirectQiniuModel.allCases {
            var aliasConfig = (aliasMap[model.rawValue] as? [String: Any]) ?? [:]
            aliasConfig["alias"] = model.alias
            aliasMap[model.rawValue] = aliasConfig
        }

        try await helperClient.setConfigDirect(username: user.username, path: "env.QINIU_API_KEY", value: apiKey)
        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.qiniu",
            value: [
                "baseUrl": "https://api.qnaigc.com/v1",
                "apiKey": "${QINIU_API_KEY}",
                "api": "openai-completions",
                "models": providerModels,
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.qiniu:default",
            value: ["provider": "qiniu", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.model",
            value: normalizedModelConfig
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.models",
            value: aliasMap
        )

        try await syncQiniuAgentFiles(apiKey: apiKey, providerModels: providerModels)
    }

    /// 构建 provider 配置 patch 和 agent 文件同步闭包
    private func buildProviderPatch(apiKey: String) async throws -> (patch: [String: Any], agentFileSync: () async throws -> Void) {
        switch selectedProvider {
        case .kimiCoding:
            return try await buildKimiPatch(apiKey: apiKey)
        case .minimax:
            return try await buildMinimaxPatch(apiKey: apiKey)
        case .qiniu:
            // NOTE: 正常应用流程由 doApplyConfig 的 qiniu legacy 分支处理。
            // 这里保留仅用于兼容/回退，勿作为默认路径。
            return try await buildQiniuPatch(apiKey: apiKey)
        case .zai:
            return try await buildZAIPatch(apiKey: apiKey)
        case .custom:
            return try buildCustomPatch(apiKey: apiKey)
        }
    }

    private func buildKimiPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let modelId = selectedKimiModel.rawValue
        let providerModelId = modelId.replacingOccurrences(of: "kimi-coding/", with: "")
        let modelDef: [String: Any] = [
            "id": providerModelId, "name": selectedKimiModel.alias,
            "reasoning": true, "input": ["text", "image"],
            "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
            "contextWindow": 262144, "maxTokens": 32768,
        ]
        let patch: [String: Any] = [
            "models": [
                "mode": "merge",
                "providers": ["kimi-coding": [
                    "api": "anthropic-messages",
                    "baseUrl": "https://api.kimi.com/coding/",
                    "apiKey": apiKey,
                    "models": [modelDef],
                ] as [String: Any]],
            ] as [String: Any],
            "auth": ["profiles": ["kimi-coding:default": ["provider": "kimi-coding", "mode": "api_key"]]],
            "agents": ["defaults": ["model": ["primary": modelId]]],
        ]
        let sync: () async throws -> Void = { [self] in
            let agentDir = ".openclaw/agents/main/agent"
            try await helperClient.createDirectory(username: user.username, relativePath: agentDir)
            var authRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
            var profiles = (authRoot["profiles"] as? [String: Any]) ?? [:]
            profiles["kimi-coding:default"] = ["type": "api_key", "provider": "kimi-coding", "key": apiKey]
            authRoot["version"] = (authRoot["version"] as? Int) ?? 1
            authRoot["profiles"] = profiles
            try await writeUserJSON(authRoot, relativePath: "\(agentDir)/auth-profiles.json")
            var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
            var provs = (modelsRoot["providers"] as? [String: Any]) ?? [:]
            provs["kimi-coding"] = [
                "baseUrl": "https://api.kimi.com/coding/", "api": "anthropic-messages",
                "models": [modelDef],
            ] as [String: Any]
            modelsRoot["providers"] = provs
            try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
        }
        return (patch, sync)
    }

    private func buildMinimaxPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let providerModels = DirectMinimaxModel.allCases.map(\.providerModelConfig)
        let patch: [String: Any] = [
            "models": [
                "mode": "merge",
                "providers": ["minimax": [
                    "api": "anthropic-messages",
                    "baseUrl": "https://api.minimaxi.com/anthropic",
                    "authHeader": true,
                    "models": providerModels,
                ] as [String: Any]],
            ] as [String: Any],
            "auth": ["profiles": ["minimax:cn": ["provider": "minimax", "mode": "api_key"]]],
            "agents": ["defaults": [
                "model": ["primary": selectedMinimaxModel.rawValue],
            ] as [String: Any]],
        ]
        let sync: () async throws -> Void = { [self] in
            try await syncMinimaxAgentFiles(apiKey: apiKey, providerModels: providerModels)
        }
        return (patch, sync)
    }

    private func buildQiniuPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let providerModels = DirectQiniuModel.allCases.map(\.providerModelConfig)
        let patch: [String: Any] = [
            "env": ["QINIU_API_KEY": apiKey],
            "models": [
                "mode": "merge",
                "providers": ["qiniu": [
                    "baseUrl": "https://api.qnaigc.com/v1",
                    "apiKey": "${QINIU_API_KEY}",
                    "api": "openai-completions",
                    "models": providerModels,
                ] as [String: Any]],
            ] as [String: Any],
            "auth": ["profiles": ["qiniu:default": ["provider": "qiniu", "mode": "api_key"]]],
            "agents": ["defaults": [
                "model": ["primary": selectedQiniuModel.rawValue],
            ] as [String: Any]],
        ]
        let sync: () async throws -> Void = { [self] in
            try await syncQiniuAgentFiles(apiKey: apiKey, providerModels: providerModels)
        }
        return (patch, sync)
    }

    private func buildZAIPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let providerModels = DirectZAIModel.allCases.map(\.providerModelConfig)
        let patch: [String: Any] = [
            "models": [
                "mode": "merge",
                "providers": ["zai": [
                    "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
                    "apiKey": apiKey,
                    "api": "openai-completions",
                    "models": providerModels,
                ] as [String: Any]],
            ] as [String: Any],
            "auth": ["profiles": ["zai:default": ["provider": "zai", "mode": "api_key"]]],
            "agents": ["defaults": [
                "model": ["primary": selectedZAIModel.rawValue],
            ] as [String: Any]],
        ]
        let sync: () async throws -> Void = { [self] in
            try await syncZAIAgentFiles(apiKey: apiKey, providerModels: providerModels)
        }
        return (patch, sync)
    }

    private func buildCustomPatch(apiKey: String) throws -> ([String: Any], () async throws -> Void) {
        let providerId = effectiveCustomProviderId
        let modelId = effectiveCustomModelId
        let baseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAPIKey = CustomModelConfigUtils.resolvedAPIKey(apiKey)

        guard !modelId.isEmpty else { throw HelperError.operationFailed("请先选择模型") }
        guard !baseURL.isEmpty else { throw HelperError.operationFailed("请先填写 Base URL") }

        let primary = "\(providerId)/\(modelId)"
        let patch: [String: Any] = [
            "models": [
                "mode": "merge",
                "providers": [providerId: [
                    "baseUrl": baseURL,
                    "apiKey": resolvedAPIKey,
                    "api": customCompatibility.apiType,
                    "models": [[
                        "id": modelId, "name": modelId,
                        "input": ["text"], "contextWindow": 128000, "maxTokens": 8192,
                    ] as [String: Any]],
                ] as [String: Any]],
            ] as [String: Any],
            "auth": ["profiles": ["\(providerId):default": ["provider": providerId, "mode": "api_key"]]],
            "agents": ["defaults": [
                "model": ["primary": primary],
            ] as [String: Any]],
        ]
        return (patch, {})
    }

    /// 将 patch 与现有配置中的 alias map 合并（保留已有别名）
    private func mergePatchWithExistingAliases(patch: [String: Any], existingConfig: [String: Any]) -> [String: Any] {
        var result = patch
        let existingAliases = ((existingConfig["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]

        // 根据提供商构建新的 alias
        var aliasMap = existingAliases ?? [:]
        switch selectedProvider {
        case .minimax:
            var a = (aliasMap[selectedMinimaxModel.rawValue] as? [String: Any]) ?? [:]
            a["alias"] = a["alias"] ?? "Minimax"
            aliasMap[selectedMinimaxModel.rawValue] = a
        case .qiniu:
            for model in DirectQiniuModel.allCases {
                var a = (aliasMap[model.rawValue] as? [String: Any]) ?? [:]
                a["alias"] = model.alias
                aliasMap[model.rawValue] = a
            }
        case .zai:
            for model in DirectZAIModel.allCases {
                var a = (aliasMap[model.rawValue] as? [String: Any]) ?? [:]
                a["alias"] = model.alias
                aliasMap[model.rawValue] = a
            }
        case .custom:
            let primary = "\(effectiveCustomProviderId)/\(effectiveCustomModelId)"
            var a = (aliasMap[primary] as? [String: Any]) ?? [:]
            a["alias"] = effectiveCustomModelId
            aliasMap[primary] = a
        default:
            break
        }

        if !aliasMap.isEmpty {
            var agentsPatch = (result["agents"] as? [String: Any]) ?? [:]
            var defaults = (agentsPatch["defaults"] as? [String: Any]) ?? [:]
            defaults["models"] = aliasMap
            agentsPatch["defaults"] = defaults
            result["agents"] = agentsPatch
        }

        // fallbacks 由 doApplyConfig 根据用户选择（保留/替换）处理，此处不自动保留

        return result
    }

    private func fetchCustomModels() async {
        let baseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            customModelFetchError = "请先填写 Base URL"
            customModelFetchMessage = nil
            return
        }

        isFetchingCustomModels = true
        customModelFetchError = nil
        customModelFetchMessage = nil
        defer { isFetchingCustomModels = false }

        do {
            let apiKey = (providerKeys[DirectProviderChoice.custom.rawValue] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = try await CustomModelConfigUtils.fetchModelIDs(baseURL: baseURL, apiKey: apiKey)
            if ids.isEmpty {
                customModelSuggestions = []
                customModelFetchMessage = "已请求成功，但未解析到可用模型 ID（该接口可能不支持标准 list）"
                return
            }

            customModelSuggestions = ids
            if effectiveCustomModelId.isEmpty, let first = ids.first {
                customModelId = first
            }
            customModelFetchMessage = "已拉取 \(ids.count) 个模型"
        } catch {
            customModelFetchError = error.localizedDescription
        }
    }

    private func syncMinimaxAgentFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["minimax:cn"] = [
            "type": "api_key",
            "provider": "minimax",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["minimax"] = [
            "baseUrl": "https://api.minimaxi.com/anthropic",
            "api": "anthropic-messages",
            "authHeader": true,
            "models": providerModels,
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func syncQiniuAgentFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["qiniu:default"] = [
            "type": "api_key",
            "provider": "qiniu",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["qiniu"] = [
            "baseUrl": "https://api.qnaigc.com/v1",
            "api": "openai-completions",
            "models": providerModels,
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func syncZAIAgentFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["zai:default"] = [
            "type": "api_key",
            "provider": "zai",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["zai"] = [
            "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
            "api": "openai-completions",
            "models": providerModels,
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func currentPrimaryModel(from config: [String: Any]) -> String? {
        ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any])?["primary"] as? String)
    }

    private func normalizedDefaultModelConfig(from config: [String: Any], primary: String) -> [String: Any] {
        // OpenClaw schema 字段名为 "fallbacks"（复数），使用 .strict() 校验
        let existingModel = ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:])
        var normalized: [String: Any] = ["primary": primary]
        if let fallbackArray = existingModel["fallbacks"] as? [String], !fallbackArray.isEmpty {
            normalized["fallbacks"] = fallbackArray
        } else if let singleFallback = existingModel["fallbacks"] as? String, !singleFallback.isEmpty {
            normalized["fallbacks"] = [singleFallback]
        }
        return normalized
    }

    private func readUserJSON(relativePath: String) async -> [String: Any] {
        guard let data = try? await helperClient.readFile(username: user.username, relativePath: relativePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return root
    }

    private func writeUserJSON(_ object: [String: Any], relativePath: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try await helperClient.writeFile(username: user.username, relativePath: relativePath, data: data)
    }
}

private final class EmbeddedGatewayConsoleCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var webView: WKWebView?
    private var pendingFileInputAccept = ""
    var onNavigationStateChanged: ((Bool) -> Void)?

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false,
              let requestURL = navigationAction.request.url else { return nil }
        webView.load(URLRequest(url: requestURL))
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.resolvesAliases = true
        // Allow arbitrary files (e.g. mp3) regardless of web input accept hints.
        panel.allowedContentTypes = [.item]

        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigationStateChanged?(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onNavigationStateChanged?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onNavigationStateChanged?(false)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.directoryURL = downloadsURL

        panel.begin { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSSound.beep()
        appLog("[EmbeddedGatewayConsoleView] download failed: \(error.localizedDescription)", level: .error)
    }
}

private final class EmbeddedGatewayConsoleStore: ObservableObject {
    private enum LoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    let coordinator = EmbeddedGatewayConsoleCoordinator()
    private(set) var webView: WKWebView?
    private var loadedURL: String?
    private var loadState: LoadState = .idle
    private var lastRetryAt: Date = .distantPast
    private let retryInterval: TimeInterval = 1.5

    func resolveWebView() -> WKWebView {
        if let webView {
            webView.navigationDelegate = coordinator
            webView.uiDelegate = coordinator
            coordinator.webView = webView
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(coordinator, name: "fileInputAccept")
        configuration.userContentController.addUserScript(.fileInputAcceptCapture)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.webView = webView
        coordinator.onNavigationStateChanged = { [weak self] success in
            guard let self else { return }
            self.loadState = success ? .loaded : .failed
        }
        self.webView = webView
        return webView
    }

    func loadIfNeeded(_ url: URL) {
        let webView = resolveWebView()
        let urlString = url.absoluteString
        if loadedURL != urlString {
            loadedURL = urlString
            loadState = .loading
            lastRetryAt = Date()
            webView.load(URLRequest(url: url))
            return
        }

        guard !webView.isLoading else { return }
        let shouldRetry = (loadState == .failed) || webView.url == nil
        guard shouldRetry else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRetryAt) >= retryInterval else { return }
        loadState = .loading
        lastRetryAt = now
        webView.load(URLRequest(url: url))
    }

    func reloadCurrent() {
        guard let webView else { return }
        loadState = .loading
        lastRetryAt = Date()
        webView.reload()
    }

    func invalidateLoadedURL() {
        loadedURL = nil
        loadState = .idle
        lastRetryAt = .distantPast
        webView?.stopLoading()
    }
}

private struct EmbeddedGatewayConsoleView: NSViewRepresentable {
    let url: URL
    @ObservedObject var store: EmbeddedGatewayConsoleStore

    func makeCoordinator() -> EmbeddedGatewayConsoleCoordinator {
        store.coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let webView = store.resolveWebView()
        attach(webView, to: container)
        store.loadIfNeeded(url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let webView = store.resolveWebView()
        attach(webView, to: nsView)
        store.loadIfNeeded(url)
    }

    private func attach(_ webView: WKWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

extension EmbeddedGatewayConsoleCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "fileInputAccept" else { return }
        guard let body = message.body as? [String: Any],
              let accept = body["accept"] as? String else { return }
        pendingFileInputAccept = accept
    }
}

private extension WKUserScript {
    static let fileInputAcceptCapture = WKUserScript(
        source: """
        (() => {
          const sendAccept = (target) => {
            const input = target && target.closest ? target.closest('input[type="file"]') : null;
            if (!input) return;
            window.webkit.messageHandlers.fileInputAccept.postMessage({ accept: input.accept || '' });
          };
          document.addEventListener('click', (event) => sendAccept(event.target), true);
          document.addEventListener('keydown', (event) => {
            if (event.key === 'Enter' || event.key === ' ') sendAccept(event.target);
          }, true);
        })();
        """,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: false
    )
}
