// ClawdHome/Views/UserListView.swift
// 文件名保留，struct 名为 ClawPoolView

import Darwin
import AppKit
import SwiftUI

extension Notification.Name {
    static let openUpgradeSheet = Notification.Name("ClawdHome.openUpgradeSheet")
}

private enum UserEntryWindowTarget: String {
    case detail = "claw-detail"
    case initWizard = "user-init-wizard"
}

private enum UserEntryWindowResolver {
    private static func hasRecoverableWizardProgress(_ state: InitWizardState) -> Bool {
        guard !state.isCompleted else { return false }

        if state.active {
            return true
        }

        return InitStep.allCases.contains { step in
            let raw = state.steps[step.key] ?? state.steps[step.title] ?? "pending"
            return raw != "pending"
        }
    }

    private static func shouldTreatAsUnfinishedWizardState(
        _ state: InitWizardState,
        hasInstalledRuntime: Bool
    ) -> Bool {
        guard !state.isCompleted else { return false }
        if hasRecoverableWizardProgress(state) { return true }
        // 全 pending 的 pre-start 会话仅在未安装任何运行时（OpenClaw/Hermes）时才视为"待初始化"。
        return !hasInstalledRuntime
    }

    static func resolve(
        user: ManagedUser,
        helperClient: HelperClient,
        readiness: GatewayReadiness?,
        hasForcedOnboarding: Bool
    ) async -> UserEntryWindowTarget {
        guard !user.isAdmin, user.clawType == .macosUser else {
            return .detail
        }

        if hasForcedOnboarding || user.initStep != nil {
            return .initWizard
        }

        guard helperClient.isConnected else {
            return .detail
        }

        async let openclawVersionResult = helperClient.getOpenclawVersion(username: user.username)
        async let hermesVersionResult = helperClient.getHermesVersion(username: user.username)
        async let stateJSONResult = helperClient.loadInitState(username: user.username)

        let hasOpenclawRuntime = await openclawVersionResult != nil
        let hasHermesRuntime = await hermesVersionResult != nil
        let hasInstalledRuntime = hasOpenclawRuntime || hasHermesRuntime
        let isGatewayOperational = user.isRunning || readiness == .starting || readiness == .ready
        let state = InitWizardState.from(json: await stateJSONResult)

        let hasRecoverableProgress = state.map { state in
            hasRecoverableWizardProgress(state)
        } ?? false
        let hasUnfinishedWizardState = state.map {
            shouldTreatAsUnfinishedWizardState($0, hasInstalledRuntime: hasInstalledRuntime)
        } ?? false

        return shouldOpenUserInitWizardFromEntry(
            hasForcedOnboarding: hasForcedOnboarding,
            hasUnfinishedWizardState: hasUnfinishedWizardState,
            hasRecoverableWizardProgress: hasRecoverableProgress,
            hasInstalledOpenClaw: hasInstalledRuntime,
            isGatewayOperational: isGatewayOperational,
            isAdmin: user.isAdmin,
            isMacOSUser: user.clawType == .macosUser
        ) ? .initWizard : .detail
    }
}

struct ClawPoolView: View {
    var onLoadUsers: () -> Void = {}
    var onGoToRoleMarket: () -> Void = {}

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self)   private var pool
    @Environment(UpdateChecker.self) private var updater
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @State private var selectedClaw: ManagedUser.ID?
    @State private var showAddSheet = false
    @State private var isCreatingUser = false
    @AppStorage("clawPoolIsCardView") private var isCardView = true
    @AppStorage("clawPoolShowCurrentAdmin") private var showCurrentAdmin = false
    @AppStorage("debugForceEmptyClawPool") private var debugForceEmptyClawPool = false
    @Environment(\.openWindow) private var openWindow

    // MARK: 右键菜单 — 快速操作
    @State private var quickActionError: String?
    @State private var showGatewayNodeRepairSheet = false
    @State private var gatewayNodeRepairUsername: String?
    @State private var gatewayNodeRepairReason = ""
    @State private var isGatewayNodeRepairing = false
    @State private var gatewayNodeRepairCompletedSteps = 0
    @State private var gatewayNodeRepairCurrentStep = ""
    @State private var gatewayNodeRepairError: String?
    @State private var gatewayNodeRepairReadyToRetryStart = false
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue

    // MARK: 右键菜单 — 工具 sheet（枚举合并避免类型检查超时）
    @State private var toolSheet: ToolSheet?

    // MARK: 右键菜单 — 删除流程（item: 绑定，避免 isPresented+可选值 时序 bug）
    @State private var contextMenuUser: ManagedUser?
    @State private var contextDeleteOption: DeleteHomeOption = .deleteHome
    @State private var contextDeleteAdminPassword = ""
    @State private var contextDeleteError: String?
    @State private var contextIsDeleting = false
    @State private var pendingFlashFreezeClawID: ManagedUser.ID?
    @State private var quickTransferAlertMessage: String?
    @State private var quickTransferClipboardText = ""
    @State private var windowOpenInFlightUsernames: Set<String> = []
    @State private var webUIOpenInFlightUsernames: Set<String> = []
    @State private var lastWindowOpenAtByUsername: [String: Date] = [:]
    // MARK: Gateway 分组 — Agent 卡片
    @State private var agentsByUser: [String: [AgentProfile]] = [:]
    @State private var expandedUsername: String?  // 当前展开角色面板的卡片
    private var currentUsername: String { NSUserName() }
    /// 默认仅展示标准用户；可在设置中显式开启当前管理员展示。
    private var displayedUsers: [ManagedUser] {
        #if DEBUG
        if debugForceEmptyClawPool {
            return []
        }
        #endif
        return pool.users.filter {
            ClawPoolVisibilityPolicy.shouldShowUser(
                username: $0.username,
                isAdmin: $0.isAdmin,
                currentUsername: currentUsername,
                showCurrentAdmin: showCurrentAdmin
            )
        }
    }

    private var selectedUser: ManagedUser? {
        guard let id = selectedClaw else { return nil }
        return displayedUsers.first { $0.id == id }
    }

    private var pendingActionMessage: String? {
        if let username = webUIOpenInFlightUsernames.sorted().first {
            return L10n.f("views.user_list.opening_web_ui", fallback: "正在打开 @%@ 的 Web UI…", username)
        }
        if let username = windowOpenInFlightUsernames.sorted().first {
            return L10n.f("views.user_list.opening_overview", fallback: "正在打开 @%@ 的概览…", username)
        }
        return nil
    }

    private func visibleProfileDescription(for claw: ManagedUser) -> String? {
        let description = claw.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }

        let fullName = claw.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty, description.caseInsensitiveCompare(fullName) == .orderedSame {
            return nil
        }

        if description.caseInsensitiveCompare(claw.username) == .orderedSame {
            return nil
        }
        if description.caseInsensitiveCompare("@\(claw.username)") == .orderedSame {
            return nil
        }
        return description
    }

    private func loadAllAgents() async {
        for user in pool.users where !user.isAdmin {
            let hermesInstalled = await helperClient.getHermesVersion(username: user.username) != nil
            if hermesInstalled {
                if let profiles = try? await helperClient.listHermesProfiles(username: user.username) {
                    agentsByUser[user.username] = profiles
                }
                continue
            }

            if user.isRunning, let rpcAgents = await gatewayHub.agentsList(username: user.username) {
                agentsByUser[user.username] = rpcAgents
            } else if let fileAgents = try? await helperClient.listAgents(username: user.username) {
                agentsByUser[user.username] = fileAgents
            }
        }
    }

    @ViewBuilder
    private func toolSheetContent(_ sheet: ToolSheet) -> some View {
        switch sheet {
        case .log(let u, let runtime): LogViewerSheet(username: u, runtime: runtime)
        case .password(let u): UserPasswordSheet(username: u)
        }
    }

    var body: some View {
        baseContent
            .sheet(item: $toolSheet, content: toolSheetContent)
            .sheet(item: $contextMenuUser) { claw in
                DeleteUserSheet(
                    username: claw.username,
                    adminUser: NSUserName(),
                    option: $contextDeleteOption,
                    adminPassword: $contextDeleteAdminPassword,
                    isDeleting: contextIsDeleting,
                    error: contextDeleteError,
                    onConfirm: {
                        Task { await performContextDelete(for: claw) }
                    },
                    onCancel: {
                        contextMenuUser = nil
                        contextDeleteError = nil
                        contextDeleteAdminPassword = ""
                    }
                )
                .interactiveDismissDisabled(contextIsDeleting)
            }
    }

    // 主体内容（拆出来避免 body 类型检查超时）
    private var baseContent: some View {
        mainContentBody
        // 点击行/卡片时打开独立详情窗口（同一用户已开则置前）
        .onChange(of: selectedClaw) { _, newValue in
            guard let id = newValue,
                  let claw = displayedUsers.first(where: { $0.id == id }) else { return }
            openPreferredWindow(for: claw)
            // 短暂延迟后取消选中，避免行持续高亮
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                selectedClaw = nil
            }
        }
        .onChange(of: showCurrentAdmin) { _, _ in
            if let selected = selectedClaw,
               !displayedUsers.contains(where: { $0.id == selected }) {
                selectedClaw = nil
            }
        }
        .navigationTitle(L10n.k("views.user_list_view.claw_pool", fallback: "虾塘"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker(L10n.k("views.user_list_view.view_mode", fallback: "视图模式"), selection: $isCardView) {
                    Label(L10n.k("views.user_list_view.cards", fallback: "卡片"), systemImage: "square.grid.2x2").tag(true)
                    Label(L10n.k("views.user_list_view.list", fallback: "列表"), systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .help(isCardView ? L10n.k("views.user_list_view.switch_list_view", fallback: "切换到列表视图") : L10n.k("views.user_list_view.switch_card_view", fallback: "切换到卡片视图"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: { Label(L10n.k("views.user_list_view.add", fallback: "添加"), systemImage: "plus") }
                    .disabled(isCreatingUser)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddClawSheet(
                existingUsers: pool.users.map {
                    UserAdoptionExistingUser(username: $0.username, fullName: $0.fullName)
                },
                isCreatingUser: isCreatingUser,
                onGoToRoleMarket: {
                    showAddSheet = false
                    onGoToRoleMarket()
                },
                onCreateMacosUser: { username, fullName, description in
                    let normalized = try UserAdoptionInputValidator.validate(
                        username: username,
                        fullName: fullName,
                        existingUsers: pool.users.map {
                            UserAdoptionExistingUser(username: $0.username, fullName: $0.fullName)
                        }
                    )

                    isCreatingUser = true
                    defer { isCreatingUser = false }

                    let password = try UserPasswordStore.generateAndSave(for: normalized.username)
                    do {
                        try await helperClient.createUser(
                            username: normalized.username,
                            fullName: normalized.fullName,
                            password: password
                        )
                    } catch {
                        throw mapCreateMacOSUserError(
                            error,
                            username: normalized.username,
                            fullName: normalized.fullName
                        )
                    }

                    // 新建同名账号时，清理可能遗留的初始化进度，避免向导误跳步骤。
                    try? await helperClient.saveInitState(username: normalized.username, json: "{}")

                    try? await helperClient.applySavedProxySettingsIfAny(username: normalized.username)

                    pool.loadUsers()
                    let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    pool.setDescription(trimmedDescription, for: normalized.username)
                    pool.markNeedsOnboarding(username: normalized.username)
                    openWindow(id: "user-init-wizard", value: normalized.username)
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let err = quickActionError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
            } else if let pending = pendingActionMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pending)
                        .font(.caption)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .confirmationDialog(
            L10n.k("views.user_list_view.confirm_flash_freeze", fallback: "确认速冻"),
            isPresented: Binding(
                get: { pendingFlashFreezeClawID != nil },
                set: { newValue in
                    if !newValue { pendingFlashFreezeClawID = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.k("models.managed_user.flash_freeze", fallback: "速冻"), role: .destructive) {
                guard let id = pendingFlashFreezeClawID,
                      let claw = displayedUsers.first(where: { $0.id == id }) else {
                    pendingFlashFreezeClawID = nil
                    return
                }
                pendingFlashFreezeClawID = nil
                Task { await freezeClaw(claw, mode: .flash) }
            }
            Button(L10n.k("views.user_list_view.cancel", fallback: "取消"), role: .cancel) {
                pendingFlashFreezeClawID = nil
            }
        } message: { Text(flashFreezeConfirmMessage) }
        .alert(
            L10n.k("views.user_list_view.file", fallback: "文件快传结果"),
            isPresented: Binding(
                get: { quickTransferAlertMessage != nil },
                set: { show in if !show { quickTransferAlertMessage = nil } }
            )
        ) {
            Button(L10n.k("views.user_list_view.copy_path", fallback: "复制路径")) {
                QuickFileTransferService.copyToPasteboard(quickTransferClipboardText)
            }
            Button(L10n.k("views.user_list_view.got", fallback: "知道了"), role: .cancel) {
                quickTransferAlertMessage = nil
            }
        } message: {
            Text(quickTransferAlertMessage ?? "")
        }
        .sheet(isPresented: $showGatewayNodeRepairSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.k("user.list.gateway.node_missing.title", fallback: "检测到 Node.js 环境缺失"))
                    .font(.headline)
                Text(L10n.k("user.list.gateway.node_missing.message", fallback: "将执行基础环境修复。修复完成后，请手动点击\u{201C}再次启动 Gateway\u{201D}。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(value: Double(gatewayNodeRepairCompletedSteps), total: 4) {
                    Text(L10n.f("user.list.gateway.repair.progress", fallback: "修复进度：%d/4", gatewayNodeRepairCompletedSteps))
                        .font(.subheadline.weight(.medium))
                } currentValueLabel: {
                    Text("\(Int((Double(gatewayNodeRepairCompletedSteps) / 4) * 100))%")
                }

                if !gatewayNodeRepairCurrentStep.isEmpty {
                    Text(L10n.f("user.list.gateway.repair.current_step", fallback: "当前步骤：%@", gatewayNodeRepairCurrentStep))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !gatewayNodeRepairReason.isEmpty {
                    Text(L10n.f("user.list.gateway.repair.reason", fallback: "触发原因：%@", gatewayNodeRepairReason))
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
                        Button(L10n.k("user.list.gateway.repair.retry_start", fallback: "再次启动 Gateway")) {
                            Task { await retryGatewayStartAfterRepairFromListSheet() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGatewayNodeRepairing)
                    } else {
                        Button(isGatewayNodeRepairing
                               ? L10n.k("user.list.gateway.repair.in_progress", fallback: "修复中…")
                               : L10n.k("user.list.gateway.repair.start", fallback: "开始修复")) {
                            Task { await runGatewayRepairFromListSheet() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGatewayNodeRepairing)
                    }
                    Spacer()
                    Button(L10n.k("user.list.gateway.repair.close", fallback: "关闭")) { showGatewayNodeRepairSheet = false }
                        .disabled(isGatewayNodeRepairing)
                }
            }
            .padding(18)
            .frame(minWidth: 520)
        }
    }

    private var flashFreezeConfirmMessage: String {
        guard let id = pendingFlashFreezeClawID,
              let claw = displayedUsers.first(where: { $0.id == id }) else {
            return L10n.k(
                "views.user_list_view.userprocess_openclaw_process_start",
                fallback: "将紧急终止该虾的用户空间进程（优先 openclaw 相关），已终止进程不可恢复，只能重新启动。"
            )
        }
        if runtime(for: claw) == .hermes {
            return L10n.k(
                "views.user_list_view.userprocess_hermes_process_start",
                fallback: "将紧急终止该虾的用户空间进程（优先 Hermes 相关），已终止进程不可恢复，只能重新启动。"
            )
        }
        return L10n.k(
            "views.user_list_view.userprocess_openclaw_process_start",
            fallback: "将紧急终止该虾的用户空间进程（优先 openclaw 相关），已终止进程不可恢复，只能重新启动。"
        )
    }

    private var emptyStateContent: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.025)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ClawPoolEmptyStateCard {
                onGoToRoleMarket()
            }
            .padding(32)
        }
    }

    private func mapCreateMacOSUserError(_ error: Error, username: String, fullName: String) -> Error {
        let rawMessage = error.localizedDescription
        let lowercased = rawMessage.lowercased()
        let hasDirectoryConflict = lowercased.contains("edspermissionerror")
            || lowercased.contains("ds error: -14120")
            || lowercased.contains("/users/\(username.lowercased())")
        if hasDirectoryConflict {
            return UserAdoptionValidationError.duplicateUsername(username)
        }
        let hasFullNameConflict = lowercased.contains(fullName.lowercased())
            && lowercased.contains("recordname")
        if hasFullNameConflict {
            return UserAdoptionValidationError.duplicateFullName(fullName)
        }
        return error
    }

    // MARK: - 右键菜单内容

    private func runtime(for claw: ManagedUser) -> ProcessEmergencyFreezeResolver.Runtime? {
        if claw.hermesVersion != nil { return .hermes }
        if claw.openclawVersion != nil { return .openclaw }
        return nil
    }

    private func effectiveReadiness(for claw: ManagedUser) -> GatewayReadiness {
        guard runtime(for: claw) != .hermes else {
            return claw.isRunning ? .ready : .stopped
        }
        return gatewayHub.readinessMap[claw.username] ?? (claw.isRunning ? .ready : .stopped)
    }

    private func isRunning(for claw: ManagedUser) -> Bool {
        let readiness = effectiveReadiness(for: claw)
        return readiness == .ready || readiness == .starting || claw.isRunning
    }

    @ViewBuilder
    private func clawContextMenu(for claw: ManagedUser) -> some View {
        let isRunning = isRunning(for: claw)
        gatewayMenuItems(for: claw, isRunning: isRunning, isFrozen: claw.isFrozen)
        Divider()
        sessionMenuItems(for: claw)
        Divider()
        toolMenuItems(for: claw)
        if !claw.isAdmin {
            Divider()
            dangerMenuItems(for: claw, isRunning: isRunning)
        }
    }

    @ViewBuilder
    private func gatewayMenuItems(for claw: ManagedUser, isRunning: Bool, isFrozen: Bool) -> some View {
        let runtime = runtime(for: claw)

        if let runtime {
            if isFrozen {
                Button { Task { await unfreezeClaw(claw) } } label: {
                    Label(L10n.k("views.user_list_view.freeze", fallback: "解除冻结"), systemImage: "snowflake.slash")
                }
                if claw.hasFreezeWarning, let mode = claw.freezeMode {
                    if mode == .flash {
                        Button(role: .destructive) {
                            pendingFlashFreezeClawID = claw.id
                        } label: {
                            Label(L10n.k("views.user_list_view.mode_title", fallback: "重新执行\(mode.title)"), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    } else {
                        Button {
                            Task { await freezeClaw(claw, mode: mode) }
                        } label: {
                            Label(L10n.k("views.user_list_view.mode_title", fallback: "重新执行\(mode.title)"), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                }
            } else {
                if !isRunning {
                    Button {
                        Task {
                            do {
                                if runtime == .hermes {
                                    try await helperClient.startHermesGateway(username: claw.username)
                                    claw.isRunning = true
                                } else {
                                    gatewayHub.markPendingStart(username: claw.username)
                                    let result = try await helperClient.startGatewayDiagnoseNodeToolchain(username: claw.username)
                                    switch result {
                                    case .started:
                                        claw.isRunning = true
                                    case .needsNodeRepair(let reason):
                                        appLog("[gateway-repair] detected missing base env user=\(claw.username) reason=\(reason)", level: .warn)
                                        gatewayNodeRepairUsername = claw.username
                                        gatewayNodeRepairReason = reason
                                        gatewayNodeRepairCompletedSteps = 0
                                        gatewayNodeRepairCurrentStep = ""
                                        gatewayNodeRepairError = nil
                                        gatewayNodeRepairReadyToRetryStart = false
                                        showGatewayNodeRepairSheet = true
                                    }
                                }
                            } catch {
                                quickActionError = String(format: L10n.k("views.user_list_view.start_failed_detail", fallback: "启动失败：%@"), error.localizedDescription)
                            }
                        }
                    } label: { Label(L10n.k("views.user_list_view.start_gateway", fallback: "启动 Gateway"), systemImage: "play.fill") }
                } else {
                    Button {
                        Task {
                            do {
                                if runtime == .hermes {
                                    try await helperClient.stopHermesGateway(username: claw.username)
                                } else {
                                    try await helperClient.stopGateway(username: claw.username)
                                }
                                claw.isRunning = false
                            } catch { quickActionError = String(format: L10n.k("views.user_list_view.stop_failed_detail", fallback: "停止失败：%@"), error.localizedDescription) }
                        }
                    } label: { Label(L10n.k("views.user_list_view.stop_gateway", fallback: "停止 Gateway"), systemImage: "stop.fill") }

                    Button {
                        Task {
                            do {
                                if runtime == .hermes {
                                    try await helperClient.stopHermesGateway(username: claw.username)
                                    try await helperClient.startHermesGateway(username: claw.username)
                                } else {
                                    try await helperClient.restartGateway(username: claw.username)
                                }
                            }
                            catch { quickActionError = String(format: L10n.k("views.user_list_view.restart_failed_detail", fallback: "重启失败：%@"), error.localizedDescription) }
                        }
                    } label: { Label(L10n.k("views.user_list_view.restart_gateway", fallback: "重启 Gateway"), systemImage: "arrow.clockwise") }
                }

                Divider()
                Menu(L10n.k("views.user_list_view.freeze_menu_title", fallback: "冻结…")) {
                    Button {
                        Task { await freezeClaw(claw, mode: .pause) }
                    } label: { Label(L10n.k("views.user_list_view.pause_freeze_recoverable", fallback: "暂停冻结（可恢复）"), systemImage: "pause.circle") }
                    Button {
                        Task { await freezeClaw(claw, mode: .normal) }
                    } label: { Label(L10n.k("views.user_list_view.freeze_stop_gateway", fallback: "普通冻结（停止 Gateway）"), systemImage: "snowflake") }
                    Button(role: .destructive) {
                        pendingFlashFreezeClawID = claw.id
                    } label: { Label(L10n.k("views.user_list_view.flash_freeze_emergency_kill", fallback: "速冻（紧急终止进程）"), systemImage: "bolt.fill") }
                }
            }
            if runtime == .openclaw {
                Button { Task { await openWebUI(for: claw) } } label: {
                    if webUIOpenInFlightUsernames.contains(claw.username.lowercased()) {
                        Label(L10n.k("views.user_list.opening", fallback: "打开中…"), systemImage: "hourglass")
                    } else {
                        Label(L10n.k("views.user_list_view.open_web_ui", fallback: "打开 Web UI"), systemImage: "globe")
                    }
                }
                .disabled(claw.isFrozen || webUIOpenInFlightUsernames.contains(claw.username.lowercased()))
            }
        }
    }

    @ViewBuilder
    private var mainContentBody: some View {
        if pool.didFinishInitialUserLoad && displayedUsers.isEmpty {
            emptyStateContent
        } else if isCardView {
            cardContent
        } else {
            tableContent
        }
    }

    @ViewBuilder
    private func sessionMenuItems(for claw: ManagedUser) -> some View {
        Button {
            openPreferredWindow(for: claw)
        } label: { Label(L10n.k("views.user_list_view.open", fallback: "在新窗口打开"), systemImage: "macwindow.on.rectangle") }

        Button { openTerminal(for: claw) } label: {
            Label(L10n.k("views.user_list_view.open_terminal_action", fallback: "打开终端"), systemImage: "terminal")
        }
    }

    @ViewBuilder
    private func toolMenuItems(for claw: ManagedUser) -> some View {
        Button {
            toolSheet = .log(claw.username, runtime(for: claw) == .hermes ? .hermes : .openclaw)
        } label: { Label(L10n.k("views.user_list_view.logs", fallback: "查看日志"), systemImage: "doc.text") }
        Button { toolSheet = .password(claw.username) } label: { Label(L10n.k("views.user_list_view.password", fallback: "查看密码"), systemImage: "key")           }
        if NSEvent.modifierFlags.contains(.control) {
            Button {
                openWindow(id: "clone-claw", value: claw.username)
            } label: {
                Label(L10n.k("views.user_list_view.clone_shrimp", fallback: "克隆新虾…"), systemImage: "doc.on.doc")
            }
            .disabled(claw.openclawVersion == nil)
        }
    }

    @ViewBuilder
    private func dangerMenuItems(for claw: ManagedUser, isRunning: Bool) -> some View {
        if isRunning {
            Button(role: .destructive) {
                Task {
                    do {
                        try await helperClient.logoutUser(username: claw.username)
                        claw.isRunning = false
                    } catch { quickActionError = String(format: L10n.k("views.user_list_view.logout_failed_detail", fallback: "注销失败：%@"), error.localizedDescription) }
                }
            } label: { Label(L10n.k("views.user_list_view.session", fallback: "注销会话"), systemImage: "arrow.uturn.left") }
            Divider()
        }
        Button(role: .destructive) {
            contextDeleteOption = .deleteHome
            contextDeleteAdminPassword = ""
            contextDeleteError = nil
            contextMenuUser = claw   // 设置 item，sheet 自动弹出
        } label: { Label(L10n.k("views.user_list_view.deleteuser", fallback: "删除用户…"), systemImage: "trash") }
    }

    // MARK: - 列表视图

    private var tableContent: some View {
        Table(displayedUsers, selection: $selectedClaw) {
            TableColumn("") { claw in
                if claw.clawType == .macosUser {
                    if claw.prefersHermesRuntime {
                        HermesLogoMark()
                            .frame(width: 16, height: 16)
                    } else {
                        OpenClawLogoMark()
                            .frame(width: 16, height: 16)
                    }
                } else {
                    Image(systemName: claw.clawType.icon)
                        .foregroundStyle(.secondary)
                }
            }
            .width(24)

            TableColumn(L10n.k("views.user_list_view.name", fallback: "名称")) { claw in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(claw.fullName.isEmpty ? claw.username : claw.fullName)
                            .fontWeight(.medium)
                        if claw.isAdmin {
                            Text(L10n.k("views.user_list_view.admin", fallback: "管理员"))
                                .font(.caption2).fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.85), in: Capsule())
                        }
                    }
                    if let profileDescription = visibleProfileDescription(for: claw) {
                        Text(profileDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    openPreferredWindow(for: claw)
                }
            }
            .width(min: 100, ideal: 140)

            TableColumn(L10n.k("views.user_list_view.type", fallback: "类型")) { claw in
                Text(claw.clawType.displayName).foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn(L10n.k("views.user_list_view.secondary_id", fallback: "副标识")) { claw in
                Text(claw.identifier)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn(L10n.k("views.user_list_view.version", fallback: "版本")) { claw in
                if let v = claw.runtimeVersionLabel {
                    HStack(spacing: 3) {
                        Text(claw.runtimeDisplayName)
                            .foregroundStyle(.secondary)
                        Text(v).monospacedDigit()
                            .foregroundStyle((!claw.prefersHermesRuntime && updater.needsUpdate(claw.openclawVersion)) ? .orange : .primary)
                        if !claw.prefersHermesRuntime && updater.needsUpdate(claw.openclawVersion) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .help((!claw.prefersHermesRuntime && updater.needsUpdate(claw.openclawVersion))
                          ? L10n.k("views.user_list_view.upgrade_v_updater_latestversion", fallback: "可升级到 v\(updater.latestVersion ?? "")")
                          : "")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(110)

            TableColumn(L10n.k("views.user_list_view.status", fallback: "状态")) { claw in
                clawStatusView(claw)
            }
            .width(90)

            TableColumn(L10n.k("views.user_list_view.runtime", fallback: "运行时长")) { claw in
                if let started = claw.startedAt {
                    Text(started, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(80)

            TableColumn(L10n.k("views.user_list_view.resource_usage", fallback: "资源占用")) { claw in
                let hasStorage = claw.openclawDirBytes > 0
                if claw.cpuPercent != nil || claw.memRssMB != nil || hasStorage {
                    HStack(spacing: 5) {
                        if let cpu = claw.cpuPercent {
                            HStack(spacing: 2) {
                                Image(systemName: "cpu").font(.system(size: 8)).foregroundStyle(.blue)
                                Text(String(format: "%.0f%%", cpu)).foregroundStyle(.blue)
                            }
                        }
                        if let mem = claw.memRssMB {
                            HStack(spacing: 2) {
                                Image(systemName: "memorychip").font(.system(size: 8)).foregroundStyle(.purple)
                                Text(mem >= 1024
                                     ? String(format: "%.1fG", mem / 1024)
                                     : String(format: "%.0fM", mem)).foregroundStyle(.purple)
                            }
                        }
                        if hasStorage {
                            HStack(spacing: 2) {
                                Image(systemName: "internaldrive").font(.system(size: 8)).foregroundStyle(.green)
                                Text(FormatUtils.formatBytes(claw.openclawDirBytes)).foregroundStyle(.green)
                            }
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(150)

            TableColumn(L10n.k("views.user_list_view.actions", fallback: "操作")) { claw in
                let isOpeningWebUI = webUIOpenInFlightUsernames.contains(claw.username.lowercased())
                HStack(spacing: 10) {
                    if claw.openclawVersion != nil, !claw.prefersHermesRuntime {
                        Button { Task { await openWebUI(for: claw) } } label: {
                            if isOpeningWebUI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "globe").foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(L10n.k("views.user_list_view.open_web_ui", fallback: "打开 Web UI"))
                        .disabled(claw.isFrozen || isOpeningWebUI)
                    }
                    Button { openTerminal(for: claw) } label: {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("views.user_list_view.open_terminal_action", fallback: "打开终端"))
                }
            }
            .width(88)
        }
        .contextMenu(forSelectionType: ManagedUser.ID.self) { ids in
            if let id = ids.first,
               let claw = displayedUsers.first(where: { $0.id == id }) {
                clawContextMenu(for: claw)
            }
        }
    }

    // MARK: - 卡片视图（LazyVGrid 固定宽度网格）

    private var cardContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)],
                spacing: 12
            ) {
                ForEach(displayedUsers) { claw in
                    expandableClawCard(for: claw)
                        .contextMenu { clawContextMenu(for: claw) }
                }
                // 领养虾苗按钮
                AddClawCard { showAddSheet = true }
            }
            .padding(16)
        }
        .task { await loadAllAgents() }
    }

    // MARK: - 卡片（使用 ClawCard，多 agent 时右侧展开角色面板）

    @ViewBuilder
    private func expandableClawCard(for claw: ManagedUser) -> some View {
        let userAgents = agentsByUser[claw.username] ?? []
        let isExpanded = expandedUsername == claw.username
        let isOpeningWebUI = webUIOpenInFlightUsernames.contains(claw.username.lowercased())

        ClawCard(
            claw: claw,
            isSelected: selectedClaw == claw.id,
            isOpeningWebUI: isOpeningWebUI,
            agents: userAgents,
            isAgentExpanded: isExpanded,
            onTap: { openPreferredWindow(for: claw) },
            onDoubleClick: { openPreferredWindow(for: claw) },
            onUpgrade: {
                openPreferredWindow(for: claw)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(
                        name: .openUpgradeSheet,
                        object: nil,
                        userInfo: ["username": claw.username]
                    )
                }
            },
            onAgentTap: { agent in
                pool.pendingAgentSelection[claw.username] = agent.id
                openPreferredWindow(for: claw)
            },
            onAgentExpand: userAgents.count > 1 ? {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedUsername = isExpanded ? nil : claw.username
                }
            } : nil,
            onOpenWebUI: { Task { await openWebUI(for: claw) } },
            onTerminal: { openTerminal(for: claw) },
            onOpenVault: { openVault(for: claw) },
            onDropFiles: { urls in handleQuickTransferDrop(for: claw, droppedURLs: urls) }
        )
        .overlay(alignment: .topTrailing) {
            if isExpanded && userAgents.count > 1 {
                agentExpandPanel(user: claw, agents: userAgents)
                    .offset(x: 165)
                    .zIndex(100)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
            }
        }
        .zIndex(isExpanded ? 10 : 0)
    }

    // MARK: - 角色展开面板（浮动在卡片右侧）

    @ViewBuilder
    private func agentExpandPanel(user: ManagedUser, agents: [AgentProfile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(agents) { agent in
                Button {
                    pool.pendingAgentSelection[user.username] = agent.id
                    openPreferredWindow(for: user)
                } label: {
                    HStack(spacing: 6) {
                        Text(agent.emoji.isEmpty ? "\u{1F916}" : agent.emoji)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if let model = agent.modelPrimary {
                                Text(model.components(separatedBy: "/").last ?? model)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 160)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    private func handleQuickTransferDrop(for claw: ManagedUser, droppedURLs: [URL]) {
        Task {
            let result = await QuickFileTransferService.uploadDroppedItems(
                droppedURLs,
                username: claw.username,
                helperClient: helperClient
            )
            quickTransferClipboardText = result.clipboardText
            QuickFileTransferService.copyToPasteboard(result.clipboardText)
            quickTransferAlertMessage = result.summaryMessage
        }
    }

    private func openPreferredWindow(for claw: ManagedUser) {
        let usernameKey = claw.username.lowercased()
        let now = Date()
        if windowOpenInFlightUsernames.contains(usernameKey) {
            return
        }
        if let lastOpenedAt = lastWindowOpenAtByUsername[usernameKey],
           now.timeIntervalSince(lastOpenedAt) < 0.6 {
            return
        }

        windowOpenInFlightUsernames.insert(usernameKey)
        lastWindowOpenAtByUsername[usernameKey] = now
        quickActionError = nil
        let hasForcedOnboarding = pool.consumeNeedsOnboarding(username: claw.username)
        Task { @MainActor in
            defer {
                windowOpenInFlightUsernames.remove(usernameKey)
                lastWindowOpenAtByUsername[usernameKey] = Date()
            }
            // 限制解析超时为 1.2 秒，避免点击后长时间无反馈
            // 超时则直接打开详情窗口
            let target: UserEntryWindowTarget = await withTaskGroup(of: UserEntryWindowTarget.self) { group in
                group.addTask {
                    await UserEntryWindowResolver.resolve(
                        user: claw,
                        helperClient: self.helperClient,
                        readiness: self.gatewayHub.readinessMap[claw.username],
                        hasForcedOnboarding: hasForcedOnboarding
                    )
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(1200))
                    return .detail
                }
                let result = await group.next() ?? .detail
                group.cancelAll()
                return result
            }
            openWindow(id: target.rawValue, value: claw.username)
        }
    }

    // MARK: - 共用状态视图

    @ViewBuilder
    private func clawStatusView(_ claw: ManagedUser) -> some View {
        if let step = claw.initStep {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)
                    .font(.system(size: 9))
                Text(step).foregroundStyle(.secondary).font(.caption)
            }
        } else if claw.hasFreezeWarning {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.k("views.user_list_view.freeze_warning", fallback: "冻结异常"))
                    .foregroundStyle(.orange)
            }
            .help(claw.freezeWarning ?? "")
        } else if claw.isFrozen {
            let mode = claw.freezeMode ?? .normal
            HStack(spacing: 5) {
                Image(systemName: freezeSymbol(for: mode))
                    .foregroundStyle(freezeColor(for: mode))
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.statusLabel)
                    .foregroundStyle(freezeColor(for: mode))
            }
        } else {
            let readiness = effectiveReadiness(for: claw)
            HStack(spacing: 5) {
                GatewayStatusDot(readiness: readiness)
                Text(readiness.label)
                    .foregroundStyle(readiness == .ready ? .primary : .secondary)
            }
        }
    }

    // MARK: - 右键删除流程

    private func performContextDelete(for claw: ManagedUser) async {
        contextIsDeleting = true
        contextDeleteError = nil

        let keepHome = contextDeleteOption == .keepHome
        let adminPassword = contextDeleteAdminPassword
        contextDeleteAdminPassword = ""
        let targetUsername = claw.username

        do {
            // 删除前预清理：停止/卸载 gateway、移除群组、归档 vault
            try? await helperClient.prepareDeleteUser(username: targetUsername)
            // 执行 sysadminctl 删除（使用管理员凭据）
            try await UserDeleteService.deleteUserViaSysadminctl(username: targetUsername, keepHome: keepHome, adminPassword: adminPassword)
            // 删除后清理：移除状态文件
            try? await helperClient.cleanupDeletedUser(username: targetUsername)

            contextIsDeleting = false
            if selectedClaw == claw.id { selectedClaw = nil }
            pool.removeUser(username: claw.username)
            contextMenuUser = nil
            contextDeleteError = nil
            contextDeleteAdminPassword = ""
        } catch {
            contextDeleteError = error.localizedDescription
            contextIsDeleting = false
            contextMenuUser = claw   // 重新打开 sheet 显示错误
        }
    }

    private func verifyAdminPassword(user: String, password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HelperError.operationFailed(L10n.k("views.user_list_view.inputadminpassword", fallback: "请输入管理员登录密码"))
        }
        try await Task.detached(priority: .userInitiated) {
            let nodes = ["/Local/Default", "/Search"]
            var lastError = L10n.k("views.user_list_view.password_error_or_no_permission", fallback: "密码错误或无权限")

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

            throw HelperError.operationFailed(L10n.k("views.user_list_view.adminpassword_lasterror_macos_accountpassword_username", fallback: "管理员密码校验失败：\(lastError)\n请填写该 macOS 账户的登录密码（不是用户名）"))
        }.value
    }


    // MARK: - 打开 Web UI

    private func openWebUI(for claw: ManagedUser) async {
        let usernameKey = claw.username.lowercased()
        guard !webUIOpenInFlightUsernames.contains(usernameKey) else { return }
        webUIOpenInFlightUsernames.insert(usernameKey)
        defer { webUIOpenInFlightUsernames.remove(usernameKey) }
        quickActionError = nil

        guard !claw.isFrozen else {
            quickActionError = L10n.k("views.user_list_view.claw_username_claw_freezemode_statuslabel", fallback: "@\(claw.username) \(claw.freezeMode?.statusLabel ?? "已冻结")，请先解除冻结再启动 Gateway")
            return
        }
        if !claw.isRunning {
            gatewayHub.markPendingStart(username: claw.username)
            do {
                let result = try await helperClient.startGatewayDiagnoseNodeToolchain(username: claw.username)
                switch result {
                case .started:
                    claw.isRunning = true
                case .needsNodeRepair(let reason):
                    appLog("[gateway-repair] detected missing base env user=\(claw.username) reason=\(reason)", level: .warn)
                    gatewayNodeRepairUsername = claw.username
                    gatewayNodeRepairReason = reason
                    gatewayNodeRepairCompletedSteps = 0
                    gatewayNodeRepairCurrentStep = ""
                    gatewayNodeRepairError = nil
                    gatewayNodeRepairReadyToRetryStart = false
                    showGatewayNodeRepairSheet = true
                    return
                }
            } catch {
                quickActionError = String(format: L10n.k("views.user_list_view.start_failed_detail", fallback: "启动失败：%@"), error.localizedDescription)
                return
            }
        }
        let urlString = await helperClient.getGatewayURL(username: claw.username)
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            quickActionError = L10n.k(
                "views.user_list_view.open_web_ui_url_unavailable",
                fallback: "打开 Web UI 失败：未获取到可用地址，请稍后重试"
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 打开终端

    private func openTerminal(for claw: ManagedUser) {
        let payload = maintenanceWindowRegistry.makePayload(
            username: claw.username,
            title: L10n.k("views.user_list_view.cli_maintenance_advanced", fallback: "命令行维护（高级）"),
            command: ["zsh", "-l"],
            engine: claw.prefersHermesRuntime ? .hermes : .openclaw
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func openVault(for claw: ManagedUser) {
        let vaultPath = "/Users/Shared/ClawdHome/vaults/\(claw.username)"
        let url = URL(fileURLWithPath: vaultPath)
        if FileManager.default.fileExists(atPath: vaultPath) {
            NSWorkspace.shared.open(url)
        } else {
            Task {
                try? await helperClient.setupVault(username: claw.username)
                if FileManager.default.fileExists(atPath: vaultPath) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func runGatewayRepairFromListSheet() async {
        guard !isGatewayNodeRepairing, let username = gatewayNodeRepairUsername, !username.isEmpty else { return }
        quickActionError = nil
        isGatewayNodeRepairing = true
        gatewayNodeRepairError = nil
        gatewayNodeRepairReadyToRetryStart = false
        gatewayNodeRepairCompletedSteps = 0
        gatewayNodeRepairCurrentStep = "修复 Homebrew 权限"
        appLog("[gateway-repair] start user=\(username)")
        defer { isGatewayNodeRepairing = false }
        do {
            appLog("[gateway-repair] step 1/4 homebrew-permission user=\(username)")
            try? await helperClient.repairHomebrewPermission(username: username)
            gatewayNodeRepairCompletedSteps = 1
            gatewayNodeRepairCurrentStep = "安装/修复 Node.js"
            appLog("[gateway-repair] step 2/4 install-node user=\(username)")
            try await helperClient.installNode(username: username, nodeDistURL: nodeDistURL)
            gatewayNodeRepairCompletedSteps = 2
            gatewayNodeRepairCurrentStep = "配置 npm 目录"
            appLog("[gateway-repair] step 3/4 setup-npm-env user=\(username)")
            try await helperClient.setupNpmEnv(username: username)
            gatewayNodeRepairCompletedSteps = 3
            gatewayNodeRepairCurrentStep = "执行体检修复"
            appLog("[gateway-repair] step 4/4 health-check-fix user=\(username)")
            _ = await helperClient.runHealthCheck(username: username, fix: true)
            gatewayNodeRepairCompletedSteps = 4
            gatewayNodeRepairCurrentStep = "修复完成，等待再次启动"
            gatewayNodeRepairReadyToRetryStart = true
            appLog("[gateway-repair] completed user=\(username)")
        } catch {
            appLog("[gateway-repair] failed user=\(username) error=\(error.localizedDescription)", level: .error)
            gatewayNodeRepairError = error.localizedDescription
        }
    }

    private func retryGatewayStartAfterRepairFromListSheet() async {
        guard !isGatewayNodeRepairing, let username = gatewayNodeRepairUsername, !username.isEmpty else { return }
        isGatewayNodeRepairing = true
        gatewayNodeRepairError = nil
        gatewayNodeRepairCurrentStep = "正在启动 Gateway"
        appLog("[gateway-repair] retry-start user=\(username)")
        defer { isGatewayNodeRepairing = false }
        do {
            gatewayHub.markPendingStart(username: username)
            try await helperClient.startGateway(username: username)
            if let idx = pool.users.firstIndex(where: { $0.username == username }) {
                pool.users[idx].isRunning = true
            }
            pool.loadUsers()
            showGatewayNodeRepairSheet = false
            appLog("[gateway-repair] retry-start success user=\(username)")
        } catch {
            gatewayNodeRepairError = error.localizedDescription
            appLog("[gateway-repair] retry-start failed user=\(username) error=\(error.localizedDescription)", level: .error)
        }
    }

    private func freezeClaw(_ claw: ManagedUser, mode: FreezeMode) async {
        quickActionError = nil
        appLog("freeze start user=\(claw.username) mode=\(mode.statusLabel)")
        do {
            let freezeRuntime: ProcessEmergencyFreezeResolver.Runtime =
                (claw.hermesVersion != nil) ? .hermes : .openclaw
            if mode != .pause {
                gatewayHub.markPendingStopped(username: claw.username)
                do {
                    if freezeRuntime == .hermes {
                        try await helperClient.stopHermesGateway(username: claw.username)
                    } else {
                        try await helperClient.stopGateway(username: claw.username)
                    }
                } catch {
                    // 速冻为兜底路径：即使 stopGateway 失败也继续强制终止进程。
                    if mode != .flash { throw error }
                }
            }

            if mode == .pause {
                let processes = await helperClient.getProcessList(username: claw.username)
                let targets = ProcessEmergencyFreezeResolver.resolvePauseTargets(
                    processes: processes,
                    runtime: freezeRuntime
                )
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
                    throw HelperError.operationFailed(L10n.k("views.user_list_view.claw_username_freeze_pid_pidlist", fallback: "@\(claw.username) 暂停冻结部分失败，未挂起 PID: \(pidList)"))
                }
                pool.setFrozen(
                    true,
                    mode: mode,
                    pausedPIDs: pausedPIDs,
                    previousAutostartEnabled: nil,
                    for: claw.username
                )
                appLog("freeze success user=\(claw.username) mode=\(mode.statusLabel) paused=\(pausedPIDs.count)")
                return
            }

            if mode == .flash {
                let processes = await helperClient.getProcessList(username: claw.username)
                let targets = ProcessEmergencyFreezeResolver.resolveTargets(
                    processes: processes,
                    runtime: freezeRuntime
                )
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
                    throw HelperError.operationFailed(L10n.k("views.user_list_view.claw_username_pid_pidlist", fallback: "@\(claw.username) 速冻部分失败，未终止 PID: \(pidList)"))
                }
                // 二次 stop，防止状态滞后导致 launchd/job 被重新拉起。
                if freezeRuntime == .hermes {
                    try? await helperClient.stopHermesGateway(username: claw.username)
                } else {
                    try? await helperClient.stopGateway(username: claw.username)
                }
                // 速冻后立即复核：若关键进程被外部拉起，给出明确提示。
                try? await Task.sleep(for: .milliseconds(250))
                let remaining = await helperClient.getProcessList(username: claw.username)
                    .filter { ProcessEmergencyFreezeResolver.isRuntimeRelated($0, runtime: freezeRuntime) }
                if !remaining.isEmpty {
                    let pidList = remaining.prefix(8).map { String($0.pid) }.joined(separator: ",")
                    throw HelperError.operationFailed(L10n.k("views.user_list_view.claw_username_processes_still_running_after_flash_freeze", fallback: "@\(claw.username) 速冻后检测到进程仍在运行（可能被自动拉起），PID: \(pidList)"))
                }
            }
            pool.setFrozen(
                true,
                mode: mode,
                pausedPIDs: [],
                previousAutostartEnabled: nil,
                for: claw.username
            )
            appLog("freeze success user=\(claw.username) mode=\(mode.statusLabel)")
        } catch {
            quickActionError = String(format: L10n.k("views.user_list_view.action_failed_for_user_mode", fallback: "@%@ %@失败：%@"), claw.username, mode.title, error.localizedDescription)
            appLog("freeze failed user=\(claw.username) mode=\(mode.statusLabel) error=\(error.localizedDescription)", level: .error)
        }
    }

    private func unfreezeClaw(_ claw: ManagedUser) async {
        quickActionError = nil
        let mode = claw.freezeMode
        let pausedPIDs = claw.pausedProcessPIDs
        appLog("unfreeze start user=\(claw.username) mode=\(mode?.statusLabel ?? L10n.k("views.user_list_view.unknown", fallback: "未知"))")
        do {
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
                    throw HelperError.operationFailed(L10n.k("views.user_list_view.unpause_partial_failed_pid_list", fallback: "@\(claw.username) 解除暂停部分失败，未恢复 PID: \(pidList)"))
                }
            }
            pool.setFrozen(false, for: claw.username)
            appLog("unfreeze success user=\(claw.username)")
        } catch {
            quickActionError = String(format: L10n.k("views.user_list_view.unfreeze_failed_for_user", fallback: "@%@ 解除冻结失败：%@"), claw.username, error.localizedDescription)
            appLog("unfreeze failed user=\(claw.username) error=\(error.localizedDescription)", level: .error)
        }
    }

    private func freezeSymbol(for mode: FreezeMode) -> String {
        switch mode {
        case .pause: "pause.circle"
        case .normal: "snowflake"
        case .flash: "bolt.fill"
        }
    }

    private func freezeColor(for mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .blue
        case .normal: .cyan
        case .flash: .orange
        }
    }

}

// MARK: - 右键工具 Sheet 枚举

private enum ToolSheet: Identifiable {
    case log(String, GatewayLogRuntime)
    case password(String)

    var id: String {
        switch self {
        case .log(let u, let runtime): "log-\(runtime.rawValue)-\(u)"
        case .password(let u): "pw-\(u)"
        }
    }
}

// MARK: - 虾卡片

private struct ClawCard: View {
    let claw: ManagedUser
    let isSelected: Bool
    var isOpeningWebUI: Bool = false
    var agents: [AgentProfile] = []
    var isAgentExpanded: Bool = false
    let onTap: () -> Void
    var onDoubleClick: (() -> Void)? = nil
    var onUpgrade: (() -> Void)? = nil
    var onAgentTap: ((AgentProfile) -> Void)? = nil
    var onAgentExpand: (() -> Void)? = nil
    let onOpenWebUI: () -> Void
    let onTerminal: () -> Void
    let onOpenVault: () -> Void
    let onDropFiles: ([URL]) -> Void

    @Environment(UpdateChecker.self) private var updater
    @State private var isDropTargeted = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                // 图标 + 状态角标
                ZStack(alignment: .bottomTrailing) {
                    if claw.clawType == .macosUser {
                        if claw.prefersHermesRuntime {
                            HermesLogoMark()
                                .frame(width: 32, height: 32)
                                .frame(width: 44, height: 44)
                        } else {
                            OpenClawLogoMark()
                                .frame(width: 32, height: 32)
                                .frame(width: 44, height: 44)
                        }
                    } else {
                        Image(systemName: claw.clawType.icon)
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    statusDot
                }

                // 用户名（仅 @username，角色信息统一在底部 pill 区域展示）
                HStack(spacing: 4) {
                    Text("@\(claw.username)")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if claw.isAdmin {
                        Image(systemName: "shield.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                // 副标签（版本 / 初始化步骤 / 未初始化）
                Group {
                    if claw.hasFreezeWarning {
                        Label(L10n.k("views.user_list_view.freeze_warning", fallback: "冻结异常"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(claw.freezeWarning ?? "")
                    } else if claw.isFrozen {
                        let mode = claw.freezeMode ?? .normal
                        Label(mode.statusLabel, systemImage: freezeSymbol(mode))
                            .foregroundStyle(freezeColor(mode))
                    } else if let step = claw.initStep {
                        Text(step).foregroundStyle(.blue)
                    } else if claw.isWizardCompleted == false {
                        Text(L10n.k("views.user_list_view.init_pending", fallback: "初始化待完成")).foregroundStyle(.secondary)
                    } else if let v = claw.runtimeVersionLabel {
                        let outdated = !claw.prefersHermesRuntime && updater.needsUpdate(claw.openclawVersion)
                        HStack(spacing: 2) {
                            Text("\(claw.runtimeDisplayName) \(v)").monospacedDigit()
                                .foregroundStyle(outdated ? Color.orange : Color.secondary.opacity(0.6))
                            if outdated {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(Color.orange)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if outdated, let onUpgrade {
                                onUpgrade()
                            }
                        }
                    } else if !claw.versionChecked {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(L10n.k("views.user_list_view.not_initialized", fallback: "未初始化")).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2)
                .lineLimit(1)

                // 角色摘要（向导未完成时隐藏，避免误导）
                if claw.initStep == nil && claw.isWizardCompleted != false {
                    agentSummarySection
                }

                // 操作按钮行
                HStack(spacing: 8) {
                    if claw.openclawVersion != nil, !claw.prefersHermesRuntime {
                        Button { onOpenWebUI() } label: {
                            if isOpeningWebUI {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "globe")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(L10n.k("views.user_list_view.open_web_ui", fallback: "打开 Web UI"))
                        .disabled(claw.isFrozen || isOpeningWebUI)
                    }
                    Button { onTerminal() } label: {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("views.user_list_view.open_terminal_action", fallback: "打开终端"))

                    Button { onOpenVault() } label: {
                        Image(systemName: "folder.badge.person.crop")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("views.user_list_view.open_vault", fallback: "打开共享文件夹"))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .saturation(claw.isFrozen ? saturationForFrozen(mode: claw.freezeMode ?? .normal) : 1)
            .overlay {
                if claw.isFrozen {
                    let mode = claw.freezeMode ?? .normal
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    freezeColor(mode).opacity(0.20),
                                    Color.white.opacity(0.06),
                                    freezeShadowColor(mode).opacity(0.16)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        claw.isFrozen
                            ? freezeColor(claw.freezeMode ?? .normal).opacity(0.8)
                            : (isSelected ? Color.accentColor : Color.secondary.opacity(0.18)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        )
                        .overlay(
                            Label(L10n.k("views.user_list_view.release_quick_transfer", fallback: "松手快传"), systemImage: "arrow.down.doc.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            onDoubleClick?()
        })
        .dropDestination(for: URL.self) { droppedURLs, _ in
            let fileURLs = droppedURLs.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            onDropFiles(fileURLs)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .help(L10n.k("views.user_list_view.filefolder_openclaw_clawdhome_upload", fallback: "可将文件或文件夹拖入该虾卡片，快传到 ~/.openclaw/clawdhome_upload"))
    }

    @Environment(GatewayHub.self) private var gatewayHub

    @ViewBuilder
    private var statusDot: some View {
        if claw.isFrozen {
            let mode = claw.freezeMode ?? .normal
            Image(systemName: freezeSymbol(mode))
                .foregroundStyle(freezeColor(mode))
                .font(.system(size: 10, weight: .semibold))
        } else if let _ = claw.initStep {
            Image(systemName: "circle.fill")
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)
                .font(.system(size: 9))
        } else if claw.isWizardCompleted == false {
            EmptyView()
        } else {
            let readiness: GatewayReadiness = if claw.prefersHermesRuntime {
                claw.isRunning ? .ready : .stopped
            } else {
                gatewayHub.readinessMap[claw.username] ?? (claw.isRunning ? .ready : .stopped)
            }
            GatewayStatusDot(readiness: readiness)
        }
    }

    // MARK: 角色摘要（单 agent 显示名称，多 agent 显示数量 + 展开入口）

    @ViewBuilder
    private var agentSummarySection: some View {
        // 始终显示角色数量（含展开按钮）
        let count = max(agents.count, 1)
        let hasMultiple = agents.count > 1
        let roleName: String = {
            if agents.count == 1, let first = agents.first {
                return first.emoji.isEmpty ? first.name : "\(first.emoji) \(first.name)"
            }
            if agents.isEmpty {
                return claw.fullName.isEmpty ? claw.username : claw.fullName
            }
            return ""
        }()

        HStack(spacing: 4) {
            Text("\(count)\(L10n.k("views.user_list_view.agent_count_suffix", fallback: "个角色"))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !roleName.isEmpty {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(roleName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if hasMultiple {
                Button {
                    onAgentExpand?()
                } label: {
                    Image(systemName: isAgentExpanded ? "chevron.left" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func freezeSymbol(_ mode: FreezeMode) -> String {
        switch mode {
        case .pause: "pause.circle"
        case .normal: "snowflake"
        case .flash: "bolt.fill"
        }
    }

    private var visibleProfileDescription: String? {
        let description = claw.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }

        let fullName = claw.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fullName.isEmpty, description.caseInsensitiveCompare(fullName) == .orderedSame {
            return nil
        }
        if description.caseInsensitiveCompare(claw.username) == .orderedSame {
            return nil
        }
        if description.caseInsensitiveCompare("@\(claw.username)") == .orderedSame {
            return nil
        }
        return description
    }

    private func freezeColor(_ mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .blue
        case .normal: .cyan
        case .flash: .orange
        }
    }

    private func freezeShadowColor(_ mode: FreezeMode) -> Color {
        switch mode {
        case .pause: .indigo
        case .normal: .blue
        case .flash: .red
        }
    }

    private func saturationForFrozen(mode: FreezeMode) -> Double {
        switch mode {
        case .pause: 0.25
        case .normal: 0.12
        case .flash: 0.04
        }
    }
}

// MARK: - 新增虾卡片

private struct AddClawCard: View {
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("\u{1F99E}")
                    .font(.system(size: 28))
                Text(L10n.k("views.user_list_view.adopt_shrimp", fallback: "领养虾苗"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.6))
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160)
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.06)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundStyle(
                        isHovered ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct ClawPoolEmptyStateCard: View {
    let onGoToRoleMarket: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                Color.accentColor.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    )
                    .shadow(color: Color.accentColor.opacity(0.10), radius: 28, x: 0, y: 14)
                    .frame(width: 160, height: 160)

                OpenClawLogoMark()
                    .frame(width: 68, height: 68)
            }

            VStack(spacing: 12) {
                Text(L10n.k("views.user_list_view.empty.title", fallback: "池塘空空如也"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Text(L10n.k("views.user_list_view.empty.subtitle", fallback: "在这里，你可以养育并管理拥有不同技能的数字生命。\n立刻领养你的第一只虾，开启自动化之旅。"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button(action: onGoToRoleMarket) {
                HStack(spacing: 10) {
                    Text(L10n.k("views.user_list_view.empty.cta", fallback: "前往角色中心领养"))
                        .font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: [
                            Color.accentColor,
                            Color.accentColor.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.22), radius: 18, x: 0, y: 10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 添加 Claw 流程

/// 顶层 sheet：两个大按钮选择领养路径
private struct AddClawSheet: View {
    let existingUsers: [UserAdoptionExistingUser]
    let isCreatingUser: Bool
    /// 用户点击"去角色中心领养"
    let onGoToRoleMarket: () -> Void
    /// macOS 用户创建回调 (username, fullName, description)
    let onCreateMacosUser: (String, String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDirectCreate = false

    var body: some View {
        VStack(spacing: 0) {
            // 标题区
            VStack(spacing: 6) {
                OpenClawLogoMark()
                    .frame(width: 40, height: 40)
                Text(L10n.k("views.user_list_view.adopt_shrimp", fallback: "领养虾苗"))
                    .font(.system(size: 20, weight: .bold))
                Text(L10n.k("views.user_list_view.adopt_sheet_subtitle", fallback: "从角色中心挑选一个数字生命，或直接创建空白账号"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 28)
            .padding(.horizontal, 24)

            // 两个大按钮
            VStack(spacing: 12) {
                // 主按钮：去角色中心
                Button(action: onGoToRoleMarket) {
                    HStack(spacing: 14) {
                        Text("🎭")
                            .font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.k("views.user_list_view.go_to_role_market", fallback: "去角色中心领养"))
                                .font(.system(size: 15, weight: .semibold))
                            Text(L10n.k("views.user_list_view.go_to_role_market_desc", fallback: "浏览并挑选预设角色，个性化定制后唤醒"))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                // 次级按钮：直接创建
                Button(action: { showDirectCreate = true }) {
                    HStack(spacing: 14) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 24))
                            .foregroundStyle(.primary)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.k("views.user_list_view.create_directly", fallback: "直接创建"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(L10n.k("views.user_list_view.create_blank_macos_account", fallback: "创建一个空白 macOS 账号，自行配置"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer()

            // 取消
            Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
        }
        .frame(width: 400)
        .frame(minHeight: 400)
        .sheet(isPresented: $showDirectCreate) {
            NavigationStack {
                AddMacosUserForm(
                    existingUsers: existingUsers,
                    isSubmitting: isCreatingUser
                ) { username, fullName, description in
                    try await onCreateMacosUser(username, fullName, description)
                    showDirectCreate = false
                    dismiss()
                }
            }
            .frame(width: 440, height: 420)
            .interactiveDismissDisabled(isCreatingUser)
        }
    }
}

/// macOS 标准用户创建表单
private struct AddMacosUserForm: View {
    let existingUsers: [UserAdoptionExistingUser]
    let isSubmitting: Bool
    let onConfirm: (String, String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var fullName = ""
    @State private var descriptionText = ""
    @State private var submitError: String? = nil

    private var usernameValid: Bool {
        username.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }
    private var isValid: Bool { usernameValid }

    var body: some View {
        Form {
            Section {
                TextField(L10n.k("user.add.form.username", fallback: "用户名"), text: $username)
                    .textContentType(.username)
                    .disabled(isSubmitting)
                if !username.isEmpty && !usernameValid {
                    Text(L10n.k("user.add.form.username.validation", fallback: "用户名只能包含小写字母、数字和下划线，且须以字母开头"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField(L10n.k("user.add.form.full_name", fallback: "全名（显示用）"), text: $fullName)
                    .disabled(isSubmitting)
                TextField(L10n.k("user.add.form.description", fallback: "描述（可选，用于备注用途）"), text: $descriptionText)
                    .disabled(isSubmitting)
            } header: { Text(L10n.k("user.add.form.account_info", fallback: "账户信息")) }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "lock.rotation")
                        .foregroundStyle(.secondary)
                    Text(L10n.k("user.add.form.password_hint", fallback: "密码将自动随机生成并安全存储，可在用户详情中查看"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: { Text(L10n.k("user.add.form.password", fallback: "密码")) }

            if let submitError {
                Section {
                    Text(submitError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.k("user.add.form.title", fallback: "添加 macOS 用户"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.k("common.action.cancel", fallback: "取消")) {
                    dismiss()
                }
                .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSubmitting ? L10n.k("views.user_list_view.processing", fallback: "创建中…") : L10n.k("common.action.create", fallback: "创建")) {
                    submitError = nil
                    Task {
                        do {
                            let normalized = try UserAdoptionInputValidator.validate(
                                username: username,
                                fullName: fullName,
                                existingUsers: existingUsers
                            )
                            try await onConfirm(
                                normalized.username,
                                normalized.fullName,
                                descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        } catch {
                            await MainActor.run {
                                submitError = error.localizedDescription
                            }
                        }
                    }
                }
                .disabled(!isValid || isSubmitting)
            }
        }
    }
}

// MARK: - FlowLayout（自适应换行布局，macOS 14+ Layout protocol）

private struct FlowLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                // 换行
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        let totalWidth = maxX > 0 ? maxX - spacing : 0
        return (positions, CGSize(width: totalWidth, height: y + rowHeight))
    }
}

/// SSH Claw 样例表单（逻辑未实现，提交按钮禁用）
private struct AddSSHSampleForm: View {
    @State private var host = ""
    @State private var sshUser = ""
    @State private var port = "22"
    @State private var identityFile = ""

    var body: some View {
        Form {
            Section {
                TextField(L10n.k("user.add.ssh.host", fallback: "主机名 / IP"), text: $host)
                TextField(L10n.k("user.add.ssh.username", fallback: "SSH 用户名"), text: $sshUser)
                TextField(L10n.k("user.add.ssh.port", fallback: "端口"), text: $port)
            } header: { Text(L10n.k("user.add.ssh.connection_info", fallback: "连接信息")) }

            Section {
                TextField(L10n.k("user.add.ssh.key_path", fallback: "私钥路径（可选）"), text: $identityFile)
            } header: { Text(L10n.k("user.add.ssh.auth", fallback: "认证")) }

            Section {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(L10n.k("user.add.ssh.preview_hint", fallback: "SSH 类型的 Claw 即将支持，目前仅作预览展示"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.k("user.add.ssh.title", fallback: "添加 SSH Claw"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // 即将支持，暂时禁用
                Button(L10n.k("common.action.add", fallback: "添加")) { }.disabled(true)
            }
        }
    }
}
