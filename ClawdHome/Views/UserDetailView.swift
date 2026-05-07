// ClawdHome/Views/UserDetailView.swift

import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI

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
            blocks.append("未检测到可上传项目。")
        } else {
            let shownPaths = uploadedTopLevelPaths.prefix(2).map(Self.displayPath)
            var uploadedBlock = "已上传 \(uploadedTopLevelPaths.count) 项。"
            if let first = shownPaths.first {
                uploadedBlock += "\n\n路径：\n\(first)"
                if shownPaths.count > 1 {
                    uploadedBlock += "\n\(shownPaths[1])"
                }
            }
            if uploadedTopLevelPaths.count > 2 {
                uploadedBlock += "\n…以及另外 \(uploadedTopLevelPaths.count - 2) 项"
            }
            blocks.append(uploadedBlock)
        }
        if !failures.isEmpty {
            let shownFailures = failures.prefix(2).joined(separator: "\n")
            var failedBlock = "失败 \(failures.count) 项：\n\(shownFailures)"
            if failures.count > 2 {
                failedBlock += "\n…以及另外 \(failures.count - 2) 项"
            }
            blocks.append(failedBlock)
        }
        blocks.append("Tips：已复制到剪贴板，可以贴给你的虾，来处理文件。")
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
                failures: ["创建目录失败：\(error.localizedDescription)"]
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
                userInfo: [NSLocalizedDescriptionKey: "无法读取文件夹内容"]
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
    case overview, files, logs, processes, cron, skills, persona, sessions, memory
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
        if user.isFrozen { return user.freezeMode?.statusLabel ?? "已冻结" }
        switch gatewayHub.readinessMap[user.username] {
        case .ready:    return "运行中"
        case .starting:
            if user.isRunning,
               let startedAt = user.startedAt,
               Date().timeIntervalSince(startedAt) > 20 {
                return "状态同步中…"
            }
            return "启动中…"
        case .zombie:   return "异常（无响应）"
        case .stopped:  return "未运行"
        case .none:     return user.isRunning ? "运行中" : "未运行"
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
    @State private var isAdvancedConfigExpanded = false
    @State private var isMoreActionsExpanded = false
    @State private var npmRegistryOption: NpmRegistryOption = .defaultForInitialization
    @State private var npmRegistryCustomURL: String? = nil
    @State private var npmRegistryError: String? = nil
    @State private var isUpdatingNpmRegistry = false
    @State private var isNodeInstalledReady = false
    @State private var xcodeEnvStatus: XcodeEnvStatus? = nil
    @State private var isInstallingXcodeCLT = false
    @State private var isAcceptingXcodeLicense = false
    @State private var xcodeFixMessage: String? = nil
    @State private var isReopeningInitWizard = false
    @State private var suppressNpmRegistryOnChange = false
    @State private var showHealthCheck = false
    @State private var lastHealthCheck: HealthCheckResult? = nil
    @State private var showUpgradeConfirm = false
    @State private var pendingUpgradeVersion: String? = nil
    // 版本回退（记录升级前版本，支持降级）
    @State private var preUpgradeVersion: String? = nil
    @State private var showRollbackConfirm = false
    @State private var isRollingBack = false
    @State private var showInstallConsole = false
    @State private var showLogoutConfirm = false
    @State private var isLoggingOut = false
    @State private var showFlashFreezeConfirm = false
    @State private var autostartEnabled = true
    // 密码
    @State private var showPassword = false
    @State private var logSearchText = ""
    @State private var isQuickTransferDropTargeted = false
    @State private var quickTransferAlertMessage: String?
    @State private var quickTransferClipboardText = ""
    @State private var quickTransferLastPaths: [String] = []
    // Tab
    @State private var selectedTab: ClawTab = .overview

    var body: some View {
        tabbedContent
        .navigationTitle(user.fullName.isEmpty ? user.username : user.fullName)
        .navigationSubtitle("@\(user.username)")
        .onAppear {
            descriptionDraft = user.profileDescription
        }
        .onChange(of: user.username) { _, _ in
            versionChecked = false
            descriptionDraft = user.profileDescription
            logSearchText = ""
            gatewayURLTokenPollTask?.cancel()
            gatewayURLTokenPollTask = nil
            gatewayURL = nil
        }
        .onDisappear {
            gatewayURLTokenPollTask?.cancel()
            gatewayURLTokenPollTask = nil
        }
    }

    // MARK: - Tab 容器

    private let allTabs: [ClawTab] = [.overview, .files, .processes, .logs, .cron, .skills, .persona, .sessions, .memory]

    private func tabInfo(_ tab: ClawTab) -> (label: String, icon: String) {
        switch tab {
        case .overview:  return ("概览", "gauge.with.dots.needle.33percent")
        case .files:     return ("文件", "folder")
        case .logs:      return ("日志", "doc.text.magnifyingglass")
        case .cron:      return ("定时", "clock")
        case .skills:    return ("Skills", "star.leadinghalf.filled")
        case .persona:   return ("人格", "person.text.rectangle")
        case .sessions:  return ("会话", "bubble.left.and.bubble.right")
        case .memory:    return ("记忆", "brain.head.profile")
        case .processes: return ("进程", "square.3.layers.3d")
        }
    }

    @ViewBuilder private func tabBarButton(_ tab: ClawTab) -> some View {
        let info = tabInfo(tab)
        let selected = selectedTab == tab
        Button { selectedTab = tab } label: {
            VStack(spacing: 2) {
                Label(info.label, systemImage: info.icon)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6).padding(.top, 5).padding(.bottom, 3)
                Rectangle()
                    .fill(selected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(allTabs, id: \.self) { tabBarButton($0) }
            Spacer()
        }
        .background(.bar)
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .overview:  overviewContent
        case .files:     UserFilesView(users: [user], preselectedUser: user)
        case .logs:
            GatewayLogViewer(username: user.username, externalSearchQuery: $logSearchText)
                .searchable(text: $logSearchText, prompt: "搜索日志（空格分词）")
        case .cron:      CronTabView(username: user.username)
        case .skills:    SkillsTabView(username: user.username)
        case .persona:   PersonaTabView(username: user.username)
        case .sessions:  SessionsTabView(username: user.username)
        case .memory:    MemoryTabView(username: user.username)
        case .processes:
            ProcessTabView(
                username: user.username,
                freezeMode: user.freezeMode,
                pausedProcessPIDs: user.pausedProcessPIDs
            )
        }
    }

    private var tabbedContent: some View {
        VStack(spacing: 0) {
            customTabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refreshStatus() }
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
            }
        }
        .onChange(of: gatewayHub.readinessMap[user.username]) { _, newReadiness in
            if newReadiness == .ready, user.pid == nil {
                Task { await refreshStatus() }
            } else if newReadiness == .stopped, !user.isRunning {
                Task { await gatewayHub.disconnect(username: user.username) }
                gatewayURLTokenPollTask?.cancel()
                gatewayURLTokenPollTask = nil
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
        .sheet(isPresented: $showHealthCheck) {
            HealthCheckSheet(user: user) { result in
                lastHealthCheck = result
            }
        }
        .sheet(isPresented: $showUpgradeConfirm) {
            UpgradeConfirmSheet(
                username: user.username,
                currentVersion: user.openclawVersion,
                targetVersion: pendingUpgradeVersion ?? "",
                releaseURL: updater.latestReleaseURL
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
                onCancel: { showDeleteConfirm = false; deleteError = nil; deleteAdminPassword = "" }
            )
            .interactiveDismissDisabled(isDeleting)
        }
        .confirmationDialog(
            "确认速冻",
            isPresented: $showFlashFreezeConfirm,
            titleVisibility: .visible
        ) {
            Button("速冻", role: .destructive) {
                showFlashFreezeConfirm = false
                performAction { try await freezeUser(mode: .flash) }
            }
            Button("取消", role: .cancel) {
                showFlashFreezeConfirm = false
            }
        } message: {
            Text("将紧急终止该虾的用户空间进程（优先 openclaw 相关），已终止进程不可恢复，只能重新启动。")
        }
        .alert(
            "文件快传结果",
            isPresented: Binding(
                get: { quickTransferAlertMessage != nil },
                set: { show in if !show { quickTransferAlertMessage = nil } }
            )
        ) {
            Button("复制路径") {
                QuickFileTransferService.copyToPasteboard(quickTransferClipboardText)
            }
            Button("知道了", role: .cancel) {
                quickTransferAlertMessage = nil
            }
        } message: {
            Text(quickTransferAlertMessage ?? "")
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
    private var overviewContent: some View {
        if !versionChecked && user.initStep == nil {
            // 正在检查环境
            ProgressView("检查环境…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await refreshStatus() }
        } else if !user.isAdmin
            && user.clawType == .macosUser
            && (user.initStep != nil || (hasPendingInitWizard && user.openclawVersion == nil)) {
            // 初始化向导
            UserInitWizardView(user: user) { active in
                hasPendingInitWizard = active
                if !active {
                    user.initStep = nil
                    Task { await refreshStatus() }
                }
            }
        } else if user.isAdmin && versionChecked && user.openclawVersion == nil {
            ContentUnavailableView(
                "管理员账号未安装 openclaw",
                systemImage: "shield.lefthalf.filled",
                description: Text("管理员账号仅支持基础管理，不支持在该账号执行安装或初始化。")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    quickTransferSection
                    configSection
                    actionsSection
                    dangerZoneSection
                }
                .padding(20)
            }
        }
    }

    // MARK: - 状态卡片

    @ViewBuilder
    private var statusSection: some View {
        GroupBox {
            let readiness = gatewayHub.readinessMap[user.username] ?? (user.isRunning ? .starting : .stopped)
            let freezeSymbol: String = {
                switch user.freezeMode {
                case .pause: "pause.circle"
                case .flash: "bolt.fill"
                case .normal, .none: "snowflake"
                }
            }()
            let freezeTint: Color = {
                switch user.freezeMode {
                case .pause: .blue
                case .flash: .orange
                case .normal, .none: .cyan
                }
            }()
            VStack(alignment: .leading, spacing: 8) {
                // Gateway 运行状态
                HStack(spacing: 12) {
                    Text("Gateway").foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
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
                }
                if readiness == .starting, user.isRunning {
                    Text("服务已启动，正在同步就绪状态…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 84)
                }
                if let warning = user.freezeWarning {
                    HStack(spacing: 12) {
                        Text("冻结质检").foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // 版本
                versionRow

                // PID
                HStack(spacing: 12) {
                    Text("PID").foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    if let pid = user.pid {
                        Text("\(pid)").monospacedDigit()
                    } else if isEffectivelyRunning {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                // 启动时间
                HStack(spacing: 12) {
                    Text("启动时间").foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    if let started = user.startedAt {
                        Text(started, style: .relative).foregroundStyle(.secondary)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                // CPU / 内存
                HStack(spacing: 12) {
                    Text("CPU / 内存").foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    if let cpu = user.cpuPercent, let mem = user.memRssMB {
                        Text(String(format: "%.1f%%  /  %.0f MB", cpu, mem))
                            .monospacedDigit()
                    } else if isEffectivelyRunning {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }

                networkRow
                StorageRow(snapshot: pool.snapshot, username: user.username)
                addressRow
                healthCheckRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack {
                Text("状态")
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
        }
    }

    @ViewBuilder
    private var versionRow: some View {
        HStack(spacing: 12) {
            Text("版本").foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            if let v = user.openclawVersionLabel {
                Text(v)
                    .foregroundStyle(updater.needsUpdate(user.openclawVersion) ? .orange : .primary)
                if isInstalling || isRollingBack {
                    Text(isRollingBack ? "回退中…" : "升级中…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if !user.isAdmin,
                       updater.needsUpdate(user.openclawVersion),
                       let latest = updater.latestVersion {
                        Button("↑ v\(latest)") {
                            pendingUpgradeVersion = latest
                            showUpgradeConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(!helperClient.isConnected)
                    }
                    if !user.isAdmin, preUpgradeVersion != nil {
                        Button("↩ 回退") { showRollbackConfirm = true }
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
    private var networkRow: some View {
        HStack(spacing: 12) {
            Text("网络").foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            if let shrimp = pool.snapshot?.shrimps.first(where: { $0.username == user.username }) {
                let rateIn  = FormatUtils.formatBps(shrimp.netRateInBps)
                let rateOut = FormatUtils.formatBps(shrimp.netRateOutBps)
                let totalIn  = FormatUtils.formatTotalBytes(shrimp.netBytesIn)
                let totalOut = FormatUtils.formatTotalBytes(shrimp.netBytesOut)
                VStack(alignment: .leading, spacing: 2) {
                    Text("↓ \(rateIn)  ↑ \(rateOut)")
                        .monospacedDigit()
                    Text("累计  ↓ \(totalIn)  ↑ \(totalOut)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if isEffectivelyRunning {
                ProgressView().scaleEffect(0.6)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var addressRow: some View {
        HStack(spacing: 12) {
            Text("地址").foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            if isEffectivelyRunning, let urlStr = gatewayURL, !urlStr.isEmpty,
               gatewayToken(from: urlStr) != nil,
               let nsURL = URL(string: urlStr) {
                Button {
                    NSWorkspace.shared.open(nsURL)
                } label: {
                    Text(urlStr)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("点击在浏览器中打开")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlStr, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("复制地址")
            } else if isEffectivelyRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("等待地址 Token…").foregroundStyle(.secondary)
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var healthCheckRow: some View {
        HStack(spacing: 12) {
            Text("体检").foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            if let check = lastHealthCheck {
                let issueCount = check.criticalCount + check.warnCount
                HStack(spacing: 4) {
                    if issueCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.system(size: 11))
                        Text("\(issueCount) 个问题").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.system(size: 11))
                        Text("正常").foregroundStyle(.green)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(Date(timeIntervalSince1970: check.checkedAt), style: .relative)
                        .foregroundStyle(.secondary).font(.callout)
                    Text("前").foregroundStyle(.secondary).font(.callout)
                }
            } else {
                Text("从未体检").foregroundStyle(.tertiary)
            }
            Spacer()
            Button(lastHealthCheck == nil ? "体检" : "重新体检") {
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
        GroupBox("文件快传") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                    Text("支持拖入文件/文件夹，或点击下方区域选择后上传")
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
                        Label("复制路径", systemImage: "doc.on.doc")
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
                        Text("拖入文件到这里，或点击选择文件")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Select a File…")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Color.accentColor.opacity(0.9))
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
                        Text("最近上传：")
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
    }

    // MARK: - 配置区

    @ViewBuilder
    private var configSection: some View {
        GroupBox("配置") {
            VStack(alignment: .leading, spacing: 10) {
                Text("核心配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("模型配置").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    if let def = defaultModel {
                        Text(def)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if !fallbackModels.isEmpty {
                            Text("+ \(fallbackModels.count) 备用")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("未配置").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("管理") { showModelConfig = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!helperClient.isConnected)
                }
                Divider()
                HStack {
                    Text("频道").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text("Feishu / Weixin")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("飞书配对") {
                        openWindow(
                            id: "channel-onboarding",
                            value: "\(ChannelOnboardingFlow.feishu.rawValue):\(user.username)"
                        )
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!helperClient.isConnected)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("微信配对") {
                        openWindow(
                            id: "channel-onboarding",
                            value: "\(ChannelOnboardingFlow.weixin.rawValue):\(user.username)"
                        )
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(!helperClient.isConnected)
                }
                Text("飞书/微信均通过独立流程扫码绑定，支持首次配置和重新绑定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let status = xcodeEnvStatus, !status.isHealthy {
                    Divider().padding(.top, 2)
                    xcodeEnvironmentCard
                }

                Divider().padding(.top, 2)
                DisclosureGroup("高级配置", isExpanded: $isAdvancedConfigExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("描述").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            TextField("例如：客厅 iMac / 儿童账号", text: $descriptionDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("保存") { saveDescription() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines) == user.profileDescription)
                        }
                        if !user.isAdmin && user.clawType == .macosUser {
                            HStack {
                                Text("初始化向导").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text("可回到模型/频道步骤重新配置")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                if isReopeningInitWizard {
                                    ProgressView().scaleEffect(0.6)
                                }
                                Button("重新进入") {
                                    Task { await reopenInitWizardAtModelStep() }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(!helperClient.isConnected || isReopeningInitWizard)
                            }
                        }
                        HStack {
                            Text("npm 源").foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Picker("npm 源", selection: $npmRegistryOption) {
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
                                npmRegistryError = "Node.js 未安装就绪，暂不允许切换 npm 源"
                                setDisplayedNpmRegistry(oldValue)
                                return
                            }
                            Task { await updateNpmRegistry(to: newValue) }
                        }
                        if !isNodeInstalledReady {
                            Text("Node.js 未安装就绪，暂不允许切换 npm 源。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let customURL = npmRegistryCustomURL, !customURL.isEmpty {
                            Text("检测到自定义源：\(customURL)。切换后将覆盖为上方选项。")
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
    }

    // MARK: - 操作区

    @ViewBuilder
    private var actionsSection: some View {
        GroupBox("操作") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if user.isFrozen {
                        Button("解冻") {
                            performAction {
                                try await unfreezeUser()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if user.isRunning {
                        Button("重启") {
                            gatewayHub.markPendingStart(username: user.username)
                            performAction {
                                try await helperClient.restartGateway(username: user.username)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("停止", role: .destructive) {
                            gatewayHub.markPendingStopped(username: user.username)
                            performAction {
                                try await helperClient.stopGateway(username: user.username)
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("启动") {
                            gatewayHub.markPendingStart(username: user.username)
                            performAction {
                                try await helperClient.startGateway(username: user.username)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button { openTerminal() } label: {
                        Label("终端", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)

                    Menu {
                        Button {
                            performAction { try await freezeUser(mode: .pause) }
                        } label: { Label("暂停冻结（可恢复）", systemImage: "pause.circle") }
                        Button {
                            performAction { try await freezeUser(mode: .normal) }
                        } label: { Label("普通冻结（停止 Gateway）", systemImage: "snowflake") }
                        Button(role: .destructive) {
                            showFlashFreezeConfirm = true
                        } label: { Label("速冻（紧急终止进程）", systemImage: "bolt.fill") }
                    } label: {
                        Label("冻结…", systemImage: "snowflake")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
                .disabled(isLoading || !helperClient.isConnected)

                DisclosureGroup("更多操作", isExpanded: $isMoreActionsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button { showPassword = true } label: {
                                Label("密码", systemImage: "key")
                            }
                            .buttonStyle(.bordered)

                            if !user.isAdmin {
                                Button(isLoggingOut ? "注销中…" : "注销") {
                                    showLogoutConfirm = true
                                }
                                .buttonStyle(.bordered)
                                .disabled(isLoggingOut)
                            }

                            Spacer()
                        }

                        if !user.isAdmin {
                            Toggle(autostartEnabled ? "自启已开" : "自启已关", isOn: $autostartEnabled)
                                .toggleStyle(.button)
                                .controlSize(.small)
                                .tint(autostartEnabled ? .green : .secondary)
                                .help(autostartEnabled ? "开机自动启动此虾的 Gateway（点击关闭）" : "开机不自动启动此虾的 Gateway（点击开启）")
                                .onChange(of: autostartEnabled) { _, newValue in
                                    Task { try? await helperClient.setUserAutostart(username: user.username, enabled: newValue) }
                                }
                        } else {
                            Text("管理员：基础管理模式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }

                if !helperClient.isConnected {
                    Text("Helper 未连接，请先安装 ClawdHome 系统服务")
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
                } else {
                    freezeModeGuide
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
                            Text("命令输出")
                                .font(.caption).fontWeight(.medium)
                            Spacer()
                            if (isInstalling || isRollingBack) && !showInstallConsole {
                                Circle().fill(.blue).frame(width: 6, height: 6)
                                    .symbolEffect(.pulse, options: .repeating)
                            }
                            if isInstalling || isRollingBack {
                                Text(isRollingBack ? "回退中…" : "升级中…")
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
    }

    @ViewBuilder
    private var modelConfigSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("模型配置").font(.headline)
                Spacer()
                Button("关闭") { showModelConfig = false }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()

            ScrollView {
                KimiMinimaxModelConfigPanel(user: user) {
                    Task { await refreshModelStatusSummary() }
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

    // MARK: - 操作封装

    private func performAction(_ action: @escaping () async throws -> Void) {
        Task {
            isLoading = true
            actionError = nil
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
            await refreshStatus()
            isLoading = false
        }
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
                    throw HelperError.operationFailed("@\(user.username) 暂停冻结部分失败，未挂起 PID: \(pidList)")
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
                    throw HelperError.operationFailed("@\(user.username) 速冻部分失败，未终止 PID: \(pidList)")
                }
                // 二次 stop，防止状态滞后导致 launchd/job 被重新拉起。
                try? await helperClient.stopGateway(username: user.username)
                // 速冻后立即复核：若关键进程被外部拉起，给出明确提示。
                try? await Task.sleep(for: .milliseconds(250))
                let remaining = await helperClient.getProcessList(username: user.username)
                    .filter(ProcessEmergencyFreezeResolver.isOpenclawRelated)
                if !remaining.isEmpty {
                    let pidList = remaining.prefix(8).map { String($0.pid) }.joined(separator: ",")
                    throw HelperError.operationFailed("@\(user.username) 速冻后检测到进程仍在运行（可能被自动拉起），PID: \(pidList)")
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
        appLog("unfreeze start user=\(user.username) mode=\(mode?.statusLabel ?? "未知")")
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
                    throw HelperError.operationFailed("@\(user.username) 解除暂停部分失败，未恢复 PID: \(pidList)")
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
            return "该虾已暂停冻结：openclaw 进程被挂起，解除冻结后会继续执行（内存不会释放）。"
        case .flash:
            return "该虾已速冻：已紧急终止用户空间进程，解除冻结后需手动重新启动服务。"
        case .normal:
            return "该虾已冻结：Gateway 已停止，解除冻结后可再次启动。"
        case .none:
            return "该虾已冻结。"
        }
    }

    private var frozenHintColor: Color {
        switch user.freezeMode {
        case .pause: .blue
        case .flash: .orange
        case .normal, .none: .cyan
        }
    }

    @ViewBuilder
    private var freezeModeGuide: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("冻结级别参考：")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("暂停冻结：挂起 openclaw 进程，可恢复继续执行（内存不释放）")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("普通冻结：停止 Gateway，最稳妥")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("速冻：紧急终止用户空间进程（openclaw 优先），用于异常兜底")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() async {
        guard helperClient.isConnected else {
            // Helper 未连接时也要完成检查，避免 ProgressView 永久卡死
            versionChecked = true
            hasPendingInitWizard = false
            isNodeInstalledReady = false
            xcodeEnvStatus = nil
            return
        }
        async let statusResult = helperClient.getGatewayStatus(username: user.username)
        async let versionResult = helperClient.getOpenclawVersion(username: user.username)
        async let wizardStateResult = loadWizardState()
        async let nodeInstalledResult = helperClient.isNodeInstalled()
        async let xcodeStatusResult = helperClient.getXcodeEnvStatus()

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
        user.openclawVersion = await versionResult
        let wizardState = await wizardStateResult
        let ensuredPending = await ensureOnboardingWizardSessionIfNeeded(existingState: wizardState)
        hasPendingInitWizard = ensuredPending
        versionChecked = true
        isNodeInstalledReady = await nodeInstalledResult
        xcodeEnvStatus = await xcodeStatusResult

        // 并行加载 Gateway 地址和模型状态（snapshot 由 ShrimpPool 全局维护，无需单独拉取）
        async let urlResult = helperClient.getGatewayURL(username: user.username)
        async let modelsStatusResult = helperClient.getModelsStatus(username: user.username)
        async let npmRegistryResult = helperClient.getNpmRegistry(username: user.username)
        let (url, modelsStatus, registryURL) = await (urlResult, modelsStatusResult, npmRegistryResult)
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
        autostartEnabled = await helperClient.getUserAutostart(username: user.username)

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
    private func ensureOnboardingWizardSessionIfNeeded(existingState: InitWizardState?) async -> Bool {
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
                    try? await helperClient.saveInitState(username: user.username, json: repaired.toJSON())
                }
                return true
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
        guard user.openclawVersion == nil else {
            user.initStep = nil
            return false
        }
        let readiness = gatewayHub.readinessMap[user.username]
        if user.isRunning || readiness == .starting || readiness == .ready {
            // Gateway 已运行/启动中时，说明该用户不是“未初始化”状态，不应自动回流到初始化向导。
            user.initStep = nil
            return false
        }

        var state = InitWizardState()
        state.schemaVersion = 2
        state.mode = .onboarding
        state.active = true
        state.currentStep = InitStep.basicEnvironment.key
        state.steps = [
            InitStep.basicEnvironment.key: "running",
            InitStep.configureModel.key: "pending",
            InitStep.configureChannel.key: "pending",
            InitStep.finish.key: "pending",
        ]
        state.npmRegistry = npmRegistryOption.rawValue
        state.updatedAt = Date()

        do {
            try await helperClient.saveInitState(username: user.username, json: state.toJSON())
            user.initStep = InitStep.basicEnvironment.title
            return true
        } catch {
            actionError = "初始化向导状态写入失败：\(error.localizedDescription)"
            user.initStep = nil
            return false
        }
    }

    /// 在已初始化状态下重新进入初始化向导，从“模型配置”步骤继续。
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
        } catch {
            actionError = "重新进入初始化向导失败：\(error.localizedDescription)"
        }
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
            npmRegistryError = "Helper 未连接，无法切换 npm 源"
            return
        }
        guard isNodeInstalledReady else {
            npmRegistryError = "Node.js 未安装就绪，暂不允许切换 npm 源"
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
                Text("开发环境")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isInstallingXcodeCLT || isAcceptingXcodeLicense {
                    ProgressView().scaleEffect(0.6)
                }
                Text(status == nil ? "检查中…" : (healthy ? "环境正常" : "需要修复"))
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            if let status, !status.isHealthy {
                VStack(alignment: .leading, spacing: 4) {
                    Label(status.commandLineToolsInstalled ? "CLT 已安装" : "CLT 未安装", systemImage: status.commandLineToolsInstalled ? "checkmark" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(status.commandLineToolsInstalled ? Color.secondary : Color.orange)
                    Label(status.licenseAccepted ? "Xcode license 已接受" : "Xcode license 未接受", systemImage: status.licenseAccepted ? "checkmark" : "xmark")
                        .font(.caption2)
                        .foregroundStyle(status.licenseAccepted ? Color.secondary : Color.orange)
                    HStack(spacing: 8) {
                        Button(isInstallingXcodeCLT ? "安装中…" : "安装开发工具") {
                            Task { await installXcodeCommandLineTools() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)

                        Button(isAcceptingXcodeLicense ? "处理中…" : "同意 Xcode 许可") {
                            Task { await acceptXcodeLicense() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)

                        Button("打开软件更新") {
                            openSoftwareUpdate()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)
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
            xcodeFixMessage = "已触发系统安装窗口，请按提示完成安装。"
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
            xcodeFixMessage = "已执行 license 接受，正在刷新状态。"
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
        isAcceptingXcodeLicense = false
    }

    private func openSoftwareUpdate() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") else {
            return
        }
        NSWorkspace.shared.open(url)
        xcodeFixMessage = "已打开“软件更新”。若未看到安装弹窗，可在系统设置中手动安装 Command Line Tools。"
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
            try? await Task.sleep(for: .milliseconds(700))
            isDeleting = false
            showDeleteConfirm = false
            onDeleted?()
        } catch {
            deleteError = error.localizedDescription
            deleteStep = nil
            isDeleting = false
            showDeleteConfirm = true   // 重新打开 sheet 显示错误
        }
    }

    private func verifyAdminPassword(user: String, password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed("请输入管理员登录密码")
        }
        try await Task.detached(priority: .userInitiated) {
            let nodes = ["/Local/Default", "/Search"]
            var lastError = "密码错误或无权限"

            for node in nodes {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
                proc.arguments = [node, "-authonly", user, trimmed]
                let pipe = Pipe()
                proc.standardError = pipe
                proc.standardOutput = pipe
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    return
                }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty { lastError = out }
            }

            throw HelperError.operationFailed("管理员密码校验失败：\(lastError)\n请填写该 macOS 账户的登录密码（不是用户名）")
        }.value
    }

    private func deleteUserViaSysadminctl(username: String, keepHome: Bool, adminPassword: String) async throws {
        let trimmed = adminPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed("请输入管理员登录密码")
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
                throw HelperError.operationFailed("管理员权限校验超时，请重试")
            }

            if verify.status != 0 {
                let verifyOutput = verify.output
                let normalized = verifyOutput.lowercased()
                if normalized.contains("incorrect password") || normalized.contains("sorry, try again") {
                    throw HelperError.operationFailed("管理员密码错误，请重试")
                }
                if !verifyOutput.isEmpty {
                    throw HelperError.operationFailed("管理员权限校验失败：\(verifyOutput)")
                }
                throw HelperError.operationFailed("管理员权限校验失败")
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
                    throw HelperError.operationFailed("删除用户失败：sysadminctl exit \(result.status)")
                }
                throw HelperError.operationFailed("删除用户失败：\(output)")
            }

            if !waitForUserRecordRemoval(username: username, retries: 40, sleepMs: 250) {
                appLog("[user-delete] record still exists after command @\(username)", level: .warn)
                throw HelperError.operationFailed("删除用户 \(username) 后校验失败：系统记录仍存在")
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

        let lock = NSLock()
        var collected = Data()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            collected.append(chunk)
            lock.unlock()
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
        lock.lock()
        collected.append(tail)
        let data = collected
        lock.unlock()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, output)
    }

    private func openTerminal() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: "命令行维护（高级）",
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
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
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if user.isAdmin {
                    Text("管理员账号仅支持基础管理，已禁用重置与删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button(isResetting ? "重置中…" : "重置生存空间", role: .destructive) {
                            showResetConfirm = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .disabled(isResetting || !helperClient.isConnected)
                    }
                    Divider()
                    HStack {
                        Button("删除用户", role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelf ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.red))
                        .disabled(isDeleting || !helperClient.isConnected || isSelf)
                        .help(isSelf ? "无法删除当前登录的管理员账号" : "")
                    }
                    if isDeleting { deleteProgressView }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var deleteProgressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            switch deleteStep {
            case .deleting:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.65)
                    Text("删除账户中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case nil:
                EmptyView()
            }
        }
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
            .alert("回退到 v\(preUpgradeVersion ?? "")?", isPresented: $showRollbackConfirm) {
                Button("回退", role: .destructive) {
                    Task { await performRollback() }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("将把 @\(user.username) 的 openclaw 降级到 v\(preUpgradeVersion ?? "")\n\n此操作会短暂停止并重启 Gateway。")
            }
            .alert("注销 @\(user.username) 的登录会话？", isPresented: $showLogoutConfirm) {
                Button("取消", role: .cancel) { }
                Button("注销", role: .destructive) {
                    Task { await performLogout() }
                }
            } message: {
                Text("将停止 Gateway 并退出该用户的登录会话（launchctl bootout）。\n\n用户数据不会被删除，可随时重新启动 Gateway。")
            }
            .alert("重置 @\(user.username) 的生存空间？", isPresented: $showResetConfirm) {
                Button("取消", role: .cancel) { }
                Button("重置", role: .destructive) {
                    Task { await performReset() }
                }
            } message: {
                Text("这将删除：\n• ~/.npm-global（openclaw 及所有 npm 全局包）\n• ~/.openclaw（配置、API Key、会话历史）\n\n建议先备份 /Users/\(user.username)/.openclaw/，其中包含 API Key 和历史记录。\n\n重置后需要重新初始化生存空间。")
            }
    }
}

// MARK: - 存储空间行

private struct StorageRow: View {
    let snapshot: DashboardSnapshot?
    let username: String

    var body: some View {
        HStack(spacing: 12) {
            Text("存储").foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
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
                            Text("家目录").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
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
    @State private var showAdminPassword = false
    @FocusState private var isAdminPasswordFocused: Bool
    let isDeleting: Bool
    let error: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题
            VStack(alignment: .leading, spacing: 3) {
                Text("删除用户 \"@\(username)\"")
                    .font(.headline)
                Text("账户将被永久删除，请选择个人文件夹的处理方式：")
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

            if isDeleting {
                HStack(alignment: .top, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("删除中，请稍候…")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("如果系统弹出授权窗口，请点击“允许”。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // 选项
            VStack(alignment: .leading, spacing: 0) {
                optionRow(
                    value: .keepHome,
                    title: "保留个人文件夹",
                    desc: "/Users/\(username)/ 保持不变"
                )
                Divider().padding(.leading, 28)
                optionRow(
                    value: .deleteHome,
                    title: "删除个人文件夹",
                    desc: "/Users/\(username)/ 及全部内容将被永久删除"
                )
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .disabled(isDeleting)

            // 管理员密码
            VStack(alignment: .leading, spacing: 4) {
                Text("管理员密码").font(.subheadline)
                Text("账号：\(adminUser)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    if showAdminPassword {
                        TextField("请输入管理员登录密码", text: $adminPassword)
                            .textFieldStyle(.roundedBorder)
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
                        SecureField("请输入管理员登录密码", text: $adminPassword)
                            .textFieldStyle(.roundedBorder)
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
                    .help(showAdminPassword ? "隐藏密码" : "显示密码")
                }
            }
            .disabled(isDeleting)

            // 按钮
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button("删除用户", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(adminPassword.isEmpty || isDeleting)
            }
        }
        .padding(24)
        .frame(width: 440)
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
            Text("@\(username) 的登录密码")
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
                        .help("复制密码")

                        Button { isRevealed.toggle() } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(isRevealed ? "隐藏密码" : "显示密码")
                    }
                    .padding(4)
                }
            } else {
                GroupBox {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("未找到已存储的密码")
                                .fontWeight(.medium)
                            Text("该用户可能在密码管理功能上线前创建，点击下方按钮重置密码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
                Button(isResetting ? "重置中…" : "生成新密码并重置") {
                    Task { await resetPassword() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResetting || !helperClient.isConnected)
                if let err = resetError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Text("此密码用于该用户登录图形界面")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if storedPassword != nil {
                    Button(isResetting ? "重置中…" : "重置密码") {
                        Task { await resetPassword() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isResetting || !helperClient.isConnected)
                }
                Spacer()
                Button("关闭") { dismiss() }
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
private struct GatewayProbeModifier: ViewModifier {
    let username: String
    let uid: Int
    let gatewayURL: String?
    let hub: GatewayHub
    @Environment(ShrimpPool.self) private var pool

    func body(content: Content) -> some View {
        content.task(id: "\(username)#\(gatewayURL ?? "")") {
            while !Task.isCancelled {
                // 优先使用 getGatewayURL() 的真实端口，避免快照端口滞后导致误判“启动中”
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

// MARK: - 定时任务 Tab

private struct CronTabView: View {
    let username: String
    @State private var runId = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("定时任务")
                    .font(.headline)
                Spacer()
                Button { runId += 1 } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            Divider()

            // .id(runId) 变化时 SwiftUI 重建视图，触发新一次命令执行
            CommandOutputPanel(username: username, args: ["cron", "list"])
                .id(runId)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text("使用 \u{2018}openclaw cron add\u{2019} 或 \u{2018}openclaw cron remove\u{2019} 管理定时任务")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
        }
        .onAppear { runId += 1 }
    }
}

// MARK: - Skills Tab

private struct SkillsTabView: View {
    let username: String
    @State private var runId = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Skills")
                    .font(.headline)
                Spacer()
                Button { runId += 1 } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            CommandOutputPanel(username: username, args: ["skills", "list"])
                .id(runId)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text("使用 \u{2018}openclaw skills install <name>\u{2019} 安装，\u{2018}openclaw skills remove <name>\u{2019} 卸载")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .onAppear { runId += 1 }
    }
}

// MARK: - 人格 Tab

private struct PersonaTabView: View {
    let username: String
    @Environment(HelperClient.self) private var helperClient
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let relPath = ".openclaw/workspace/SOUL.md"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("人格 (SOUL.md)")
                    .font(.headline)
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await load() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isLoading || isSaving)
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLoading || isSaving)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let err = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text("编辑 SOUL.md 文件，定义 Agent 的人格与语气风格")
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
            content = String(data: data, encoding: .utf8) ?? ""
        } catch {
            // 文件不存在时提供模板
            content = "# SOUL.md\n\nYou are a helpful assistant.\n"
            errorMessage = nil  // 不存在不报错，直接用模板
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        guard let data = content.data(using: .utf8) else { return }
        do {
            try await helperClient.writeFile(username: username, relativePath: relPath, data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 配置 Tab (openclaw.json)

private struct ConfigTabView: View {
    let username: String
    @Environment(HelperClient.self) private var helperClient
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var jsonError: String?

    private let relPath = ".openclaw/openclaw.json"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("openclaw.json")
                    .font(.headline)
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await load() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isLoading || isSaving)
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLoading || isSaving || jsonError != nil)
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
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .onChange(of: content) { _, newVal in validateJSON(newVal) }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text("编辑 .openclaw/openclaw.json 主配置。JSON 校验错误时保存按钮将禁用。")
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
            errorMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        guard jsonError == nil else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        guard let data = content.data(using: .utf8) else { return }
        do {
            try await helperClient.writeFile(username: username, relativePath: relPath, data: data)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func validateJSON(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            jsonError = nil; return
        }
        guard let data = text.data(using: .utf8) else { jsonError = "编码错误"; return }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            jsonError = nil
        } catch {
            let desc = error.localizedDescription
            if let r = desc.range(of: "line ") {
                jsonError = "JSON 语法错误：\(desc[r.lowerBound...])"
            } else {
                jsonError = "JSON 语法错误"
            }
        }
    }
}

// MARK: - 进程管理 Tab

private struct ProcessTabView: View {
    let username: String
    let freezeMode: FreezeMode?
    let pausedProcessPIDs: [Int32]

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
        case flat = "列表"; case tree = "树状"
        var id: String { rawValue }
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

    private var pausedPIDSet: Set<Int32> {
        freezeMode == .pause ? Set(pausedProcessPIDs) : []
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
                Text("进程管理").font(.headline)
                if searchText.isEmpty {
                    Text("\(processes.count) 个进程").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(filtered.count) / \(processes.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                if !selectedTargets.isEmpty {
                    Text("已选 \(selectedTargets.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Text("⌘/Ctrl 多选")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if isActive {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                    }
                    Text(isActive ? "实时" : "已暂停").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            if !selectedTargets.isEmpty {
                HStack(spacing: 8) {
                    Text("已选 \(selectedTargets.count) 个进程")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("终止已选 (\(selectedTargets.count))") {
                        killTargets = selectedTargets
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        Task { await doKill(selectedTargets, signal: 9) }
                    } label: {
                        Text("强制结束已选 (\(selectedTargets.count))")
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
                TextField("搜索进程名或命令行…", text: $searchText)
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
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty && isActive {
                Text(searchText.isEmpty ? "暂无进程" : "无匹配进程").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .flat {
                List(sorted, selection: $selectedPIDs) { proc in
                    ProcessRow(
                        proc: proc,
                        depth: 0,
                        hasChildren: false,
                        isCollapsed: false,
                        widths: columnWidths,
                        freezeMode: freezeMode,
                        pausedPIDSet: pausedPIDSet,
                        onToggle: nil
                    )
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
                        freezeMode: freezeMode,
                        pausedPIDSet: pausedPIDSet,
                        onToggle: {
                            if collapsedPIDs.contains(node.entry.pid) {
                                collapsedPIDs.remove(node.entry.pid)
                            } else {
                                collapsedPIDs.insert(node.entry.pid)
                            }
                        }
                    )
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
                    Text("更新于 \(Self.statusTimeFormatter.string(from: t))")
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
                Button("发送 SIGTERM", role: .destructive) { Task { await doKill(killTargets, signal: 15) } }
                Button("取消", role: .cancel) { killTargets = [] }
            }
        }
        .alert("操作失败", isPresented: Binding(
            get: { killError != nil }, set: { if !$0 { killError = nil } }
        )) {
            Button("确定", role: .cancel) { killError = nil }
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
            Label("查看详情", systemImage: "info.circle")
        }
        Divider()
        Button { killTargets = targets } label: {
            Label(count > 1 ? "终止选中进程 (\(count), SIGTERM)" : "终止进程 (SIGTERM)",
                  systemImage: "stop.circle")
        }
        .disabled(targets.isEmpty)
        Button(role: .destructive) { Task { await doKill(targets, signal: 9) } } label: {
            Label(count > 1 ? "强制结束选中进程 (\(count), SIGKILL)" : "强制结束 (SIGKILL)",
                  systemImage: "xmark.circle.fill")
        }
        .disabled(targets.isEmpty)
    }

    private var killDialogTitle: String {
        if killTargets.count == 1, let first = killTargets.first {
            return "终止进程 \(first.name)（PID \(first.pid)）？"
        }
        return "终止已选中的 \(killTargets.count) 个进程？"
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
            : "以下进程操作失败：\n" + failures.joined(separator: "\n")
    }

    private var statusText: String {
        if isLoading { return "正在加载进程基础信息…" }
        if portsLoading { return "基础信息已就绪，正在补充端口信息…" }
        if processes.isEmpty { return "暂无进程数据" }
        return "进程与端口数据已就绪（\(processes.count)）"
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
                Text("进程详情 · PID \(base.pid)").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }

            if isLoading {
                ProgressView("正在读取详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("进程名", value: resolved.name)
                        detailRow("命令行", value: resolved.cmdline)
                        detailRow("父进程 PID", value: "\(resolved.ppid)")
                        detailRow("状态", value: resolved.stateLabel)
                        detailRow("CPU", value: String(format: "%.1f%%", resolved.cpuPercent))
                        detailRow("内存", value: resolved.memLabel)
                        detailRow("运行时长", value: resolved.uptimeLabel)
                        detailRow("启动时间", value: formatTime(resolved.startTime))
                        detailRow("监听端口", value: resolved.listeningPorts.isEmpty ? "—" : resolved.listeningPorts.joined(separator: ", "))
                        Divider().padding(.vertical, 2)
                        detailRow("可执行文件", value: resolved.executablePath ?? "—")
                        detailRow("文件存在", value: resolved.executableExists ? "是" : "否")
                        detailRow("文件大小", value: resolved.executableFileSizeBytes.map(FormatUtils.formatBytes) ?? "—")
                        detailRow("创建时间", value: formatTime(resolved.executableCreatedAt))
                        detailRow("修改时间", value: formatTime(resolved.executableModifiedAt))
                        detailRow("访问时间", value: formatTime(resolved.executableAccessedAt))
                        detailRow("元数据变更", value: formatTime(resolved.executableMetadataChangedAt))
                        detailRow("inode", value: resolved.executableInode.map(String.init) ?? "—")
                        detailRow("硬链接数", value: resolved.executableLinkCount.map(String.init) ?? "—")
                        detailRow("属主", value: resolved.executableOwner ?? "—")
                        detailRow("权限", value: resolved.executablePermissions ?? "—")
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
                loadError = "进程可能已退出，无法读取详情。"
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
    var pid: CGFloat = 56
    var name: CGFloat = 128
    var command: CGFloat = 420
    var cpu: CGFloat = 52
    var mem: CGFloat = 60
    var state: CGFloat = 44
    var uptime: CGFloat = 56
    var ports: CGFloat = 140
    var purpose: CGFloat = 180
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
            nameCol(right: $widths.command) { onSort(.name) }
            commandCol(right: $widths.cpu)
            cpuCol(right: $widths.mem) { onSort(.cpu) }
            memCol(right: $widths.state) { onSort(.mem) }
            resizableText("状态", width: $widths.state, min: 40, max: 120, rightWidth: $widths.uptime, rightMin: 48, rightMax: 160)
            uptimeCol(right: $widths.ports) { onSort(.uptime) }
            resizableText("端口", width: $widths.ports, min: 90, max: 360, rightWidth: $widths.purpose, rightMin: 100, rightMax: 420)
            resizableText("说明", width: $widths.purpose, min: 100, max: 420)
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
    @ViewBuilder private func nameCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        if viewMode == .flat {
            sortBtn("进程名", field: .name, width: $widths.name, min: 96, max: 320, align: .leading,
                    rightWidth: right, rightMin: 220, rightMax: 900, action: action)
        } else {
            resizableText("进程名", width: $widths.name, min: 96, max: 320,
                          rightWidth: right, rightMin: 220, rightMax: 900)
        }
    }
    @ViewBuilder private func commandCol(right: Binding<CGFloat>) -> some View {
        resizableText("Command", width: $widths.command, min: 220, max: 900,
                      rightWidth: right, rightMin: 48, rightMax: 120)
    }
    @ViewBuilder private func cpuCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("CPU%", field: .cpu, width: $widths.cpu, min: 48, max: 120, align: .trailing,
                rightWidth: right, rightMin: 54, rightMax: 160, action: action)
    }
    @ViewBuilder private func memCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("内存", field: .mem, width: $widths.mem, min: 54, max: 160, align: .trailing,
                rightWidth: right, rightMin: 40, rightMax: 120, action: action)
    }
    @ViewBuilder private func uptimeCol(right: Binding<CGFloat>, action: @escaping () -> Void) -> some View {
        sortBtn("时长", field: .uptime, width: $widths.uptime, min: 48, max: 160, align: .trailing,
                rightWidth: right, rightMin: 90, rightMax: 360, action: action)
    }

    @ViewBuilder
    private func sortBtn(_ label: String, field: ProcessTabView.SortField,
                         width: Binding<CGFloat>, min: CGFloat, max: CGFloat, align: Alignment,
                         rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0,
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
        .padding(.horizontal, 6)
        .overlay(alignment: .trailing) {
            resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax)
        }
    }

    private func resizableText(_ label: String, width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                               rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0) -> some View {
        Text(label)
            .lineLimit(1)
            .frame(width: width.wrappedValue, alignment: .leading)
            .padding(.horizontal, 6)
            .overlay(alignment: .trailing) {
                resizeHandle(width: width, min: min, max: max, rightWidth: rightWidth, rightMin: rightMin, rightMax: rightMax)
            }
    }

    private func resizeHandle(width: Binding<CGFloat>, min: CGFloat, max: CGFloat,
                              rightWidth: Binding<CGFloat>? = nil, rightMin: CGFloat = 0, rightMax: CGFloat = 0) -> some View {
        ResizeGrip(width: width, minWidth: min, maxWidth: max,
                   rightWidth: rightWidth, rightMinWidth: rightMin, rightMaxWidth: rightMax)
    }
}

// MARK: - 进程行

private struct ProcessRow: View {
    let proc: ProcessEntry
    let depth: Int
    let hasChildren: Bool
    let isCollapsed: Bool
    let widths: ProcessColumnWidths
    let freezeMode: FreezeMode?
    let pausedPIDSet: Set<Int32>
    let onToggle: (() -> Void)?

    private var stateText: String {
        if freezeMode == .pause, pausedPIDSet.contains(proc.pid) {
            return "已暂停(冻结)"
        }
        return proc.stateLabel
    }

    private var stateColor: Color {
        if freezeMode == .pause, pausedPIDSet.contains(proc.pid) {
            return .blue
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 0) {
            // PID
            Text(verbatim: "\(proc.pid)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.pid, alignment: .trailing)
                .padding(.horizontal, 6)

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
            .padding(.horizontal, 6)

            // Command — 弹性列，可选中，居中截断
            Text(proc.cmdline.isEmpty ? "—" : proc.cmdline)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(width: widths.command, alignment: .leading)
                .padding(.horizontal, 6)

            // CPU%
            Text(String(format: "%.1f", proc.cpuPercent))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(proc.cpuPercent > 50 ? .orange : .primary)
                .frame(width: widths.cpu, alignment: .trailing)
                .padding(.horizontal, 6)

            // 内存
            Text(proc.memLabel)
                .font(.system(.caption, design: .monospaced))
                .frame(width: widths.mem, alignment: .trailing)
                .padding(.horizontal, 6)

            // 状态
            Text(stateText)
                .font(.caption2)
                .foregroundStyle(stateColor)
                .frame(width: widths.state, alignment: .leading)
                .padding(.horizontal, 6)

            // 时长
            Text(proc.uptimeLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: widths.uptime, alignment: .trailing)
                .padding(.horizontal, 6)

            // 监听端口
            Text(proc.portsLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: widths.ports, alignment: .leading)
                .padding(.horizontal, 6)

            // 进程说明
            Text(proc.purposeDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: widths.purpose, alignment: .leading)
                .padding(.horizontal, 6)
                .help(proc.purposeDescription)
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
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 1)
            }
    }
}

private enum DirectProviderChoice: String, CaseIterable, Identifiable {
    case kimiCoding = "kimi-coding"
    case minimax = "minimax"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kimiCoding: return "Kimi Code"
        case .minimax: return "MiniMax"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax: return "MiniMax API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax: return "粘贴 MiniMax API Key"
        }
    }

    var consoleURL: String {
        switch self {
        case .kimiCoding: return "https://www.kimi.com/code/console"
        case .minimax: return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        }
    }

    var consoleTitle: String {
        switch self {
        case .kimiCoding: return "Kimi Code 控制台"
        case .minimax: return "MiniMax 控制台"
        }
    }
}

private enum DirectMinimaxModel: String, CaseIterable, Identifiable {
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

private struct KimiMinimaxModelConfigPanel: View {
    let user: ManagedUser
    var onApplied: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var selectedProvider: DirectProviderChoice = .kimiCoding
    @State private var selectedMinimaxModel: DirectMinimaxModel = .m25
    @State private var providerKeys: [String: String] = [:]
    @State private var isShowingApiKey = false
    @State private var saveMessage: String? = nil
    @State private var saveError: String? = nil

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { providerKeys[selectedProvider.rawValue] ?? "" },
            set: { providerKeys[selectedProvider.rawValue] = $0 }
        )
    }

    private var canApply: Bool {
        !(providerKeys[selectedProvider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("直接配置模型与 API Key（当前支持 Kimi / MiniMax）")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("读取当前配置…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(DirectProviderChoice.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(selectedProvider.apiKeyLabel)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            if let url = URL(string: selectedProvider.consoleURL) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label(selectedProvider.consoleTitle, systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
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
                        .help(isShowingApiKey ? "隐藏" : "显示")
                    }
                }

                if selectedProvider == .minimax {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MiniMax 模型")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Picker("模型", selection: $selectedMinimaxModel) {
                            ForEach(DirectMinimaxModel.allCases) { model in
                                Text(model.providerName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        Text(selectedMinimaxModel.rawValue)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kimi 当前固定模型")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("kimi-coding/k2p5")
                            .font(.system(.caption, design: .monospaced))
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

                HStack {
                    Button("重新读取") {
                        Task { await loadCurrentState() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                    Spacer()

                    Button(isSaving ? "保存中…" : "保存并应用") {
                        Task { await applyConfig() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || !canApply)
                }
            }
        }
        .onChange(of: selectedProvider) { _, _ in
            saveMessage = nil
            saveError = nil
        }
        .task {
            await loadCurrentState()
        }
    }

    private func loadCurrentState() async {
        isLoading = true
        defer { isLoading = false }
        saveMessage = nil
        saveError = nil

        let config = await helperClient.getConfigJSON(username: user.username)
        if let primary = currentPrimaryModel(from: config) {
            if primary.hasPrefix("minimax/") {
                selectedProvider = .minimax
                if let model = DirectMinimaxModel(rawValue: primary) {
                    selectedMinimaxModel = model
                }
            } else if primary.hasPrefix("kimi-coding/") {
                selectedProvider = .kimiCoding
            }
        }

        let authProfiles = await readUserJSON(relativePath: ".openclaw/agents/main/agent/auth-profiles.json")
        let profiles = (authProfiles["profiles"] as? [String: Any]) ?? [:]

        let kimiKey = ((profiles["kimi-coding:default"] as? [String: Any])?["key"] as? String) ?? ""
        let minimaxKey = ((profiles["minimax:cn"] as? [String: Any])?["key"] as? String) ?? ""
        providerKeys[DirectProviderChoice.kimiCoding.rawValue] = kimiKey
        providerKeys[DirectProviderChoice.minimax.rawValue] = minimaxKey
    }

    private func applyConfig() async {
        let apiKey = (providerKeys[selectedProvider.rawValue] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            saveError = "请先输入 API Key"
            return
        }

        isSaving = true
        defer { isSaving = false }
        saveMessage = nil
        saveError = nil

        do {
            switch selectedProvider {
            case .kimiCoding:
                try await applyKimiConfig(apiKey: apiKey)
            case .minimax:
                try await applyMinimaxConfig(apiKey: apiKey)
            }
            saveMessage = "配置已应用"
            onApplied?()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func applyKimiConfig(apiKey: String) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let modelId = "kimi-coding/k2p5"
        let normalizedModelConfig = normalizedDefaultModelConfig(from: config, primary: modelId)
        let agentDir = ".openclaw/agents/main/agent"

        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)
        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.kimi-coding",
            value: [
                "api": "anthropic-messages",
                "baseUrl": "https://api.kimi.com/coding/",
                "apiKey": apiKey,
                "models": [[
                    "id": "k2p5",
                    "name": "Kimi for Coding",
                    "reasoning": true,
                    "input": ["text", "image"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 262144,
                    "maxTokens": 32768,
                ]],
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.kimi-coding:default",
            value: ["provider": "kimi-coding", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.model",
            value: normalizedModelConfig
        )

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["kimi-coding:default"] = [
            "type": "api_key",
            "provider": "kimi-coding",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["kimi-coding"] = [
            "baseUrl": "https://api.kimi.com/coding/",
            "api": "anthropic-messages",
            "models": [[
                "id": "k2p5",
                "name": "Kimi for Coding",
                "reasoning": true,
                "input": ["text", "image"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 262144,
                "maxTokens": 32768,
            ]],
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func applyMinimaxConfig(apiKey: String) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let providerModels = DirectMinimaxModel.allCases.map(\.providerModelConfig)
        var modelAliasMap = ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:])
        var selectedAlias = (modelAliasMap[selectedMinimaxModel.rawValue] as? [String: Any]) ?? [:]
        selectedAlias["alias"] = selectedAlias["alias"] ?? "Minimax"
        modelAliasMap[selectedMinimaxModel.rawValue] = selectedAlias
        let normalizedModelConfig = normalizedDefaultModelConfig(from: config, primary: selectedMinimaxModel.rawValue)

        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.minimax",
            value: [
                "api": "anthropic-messages",
                "baseUrl": "https://api.minimaxi.com/anthropic",
                "authHeader": true,
                "models": providerModels,
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.minimax:cn",
            value: ["provider": "minimax", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.model",
            value: normalizedModelConfig
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.models",
            value: modelAliasMap
        )

        try await syncMinimaxAgentFiles(apiKey: apiKey, providerModels: providerModels)
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

    private func currentPrimaryModel(from config: [String: Any]) -> String? {
        ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any])?["primary"] as? String)
    }

    private func normalizedDefaultModelConfig(from config: [String: Any], primary: String) -> [String: Any] {
        let existingModel = ((((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:])
        var normalized: [String: Any] = ["primary": primary]
        if let fallbackArray = existingModel["fallback"] as? [String], !fallbackArray.isEmpty {
            normalized["fallback"] = fallbackArray
        } else if let singleFallback = existingModel["fallback"] as? String, !singleFallback.isEmpty {
            normalized["fallback"] = [singleFallback]
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
