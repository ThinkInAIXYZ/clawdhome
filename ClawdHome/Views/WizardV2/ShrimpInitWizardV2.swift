// ClawdHome/Views/WizardV2/ShrimpInitWizardV2.swift
// Shrimp 初始化向导 v2（6 步，支持双引擎）
//
// 步骤：
// 1. selectEngine    —— 选择引擎：OpenClaw / Hermes
// 2. basicEnv        —— 安装引擎基础环境
// 3. configModel     —— 模型选择（OpenClaw）
// 4. configAgents    —— Agent 列表配置（OpenClaw）
// 5. configIM        —— 为每个 agent 绑定 IM Bot（OpenClaw，可跳过）
// 6. done            —— 完成摘要
//
// 入口替换：直接从 UserListView / AdoptTeamSheet 跳入本 Wizard

import SwiftUI
import WebKit

private enum WizardEngine: String, CaseIterable {
    case openclaw
    case hermes

    var title: String {
        switch self {
        case .openclaw: return "OpenClaw"
        case .hermes: return "Hermes"
        }
    }

    var subtitle: String {
        switch self {
        case .openclaw: return "多 Agent 协作，角色模板与 IM 绑定"
        case .hermes: return "多平台消息代理，独立 Python 运行时"
        }
    }
}

// MARK: - Step Enum

enum WizardV2Step: Int, CaseIterable {
    case selectEngine
    case basicEnv
    case hermesSetup
    case configModel
    case configAgents
    case configIM
    case done

    var title: String {
        switch self {
        case .selectEngine:   return "选择引擎"
        case .basicEnv:       return L10n.k("wizard_v2.step.basic_env", fallback: "基础环境")
        case .hermesSetup:    return "Hermes 配置"
        case .configModel:    return L10n.k("wizard_v2.step.model", fallback: "模型配置")
        case .configAgents:   return L10n.k("wizard_v2.step.agents", fallback: "Agent 配置")
        case .configIM:       return L10n.k("wizard_v2.step.im", fallback: "IM 绑定")
        case .done:           return L10n.k("wizard_v2.step.done", fallback: "完成")
        }
    }

    var icon: String {
        switch self {
        case .selectEngine:   return "square.stack.3d.up"
        case .basicEnv:       return "wrench.and.screwdriver"
        case .hermesSetup:    return "wand.and.stars"
        case .configModel:    return "cpu"
        case .configAgents:   return "person.2"
        case .configIM:       return "qrcode.viewfinder"
        case .done:           return "checkmark.seal"
        }
    }

    var persistenceKey: String {
        switch self {
        case .selectEngine: return "selectEngine"
        case .basicEnv: return "basicEnv"
        case .hermesSetup: return "hermesSetup"
        case .configModel: return "configModel"
        case .configAgents: return "configAgents"
        case .configIM: return "configIM"
        case .done: return "done"
        }
    }

    static func fromPersistenceKey(_ raw: String?) -> WizardV2Step? {
        guard let raw else { return nil }
        let normalized = raw
            .replacingOccurrences(of: "v2:", with: "")
            .replacingOccurrences(of: "v2_", with: "")
        return allCases.first { $0.persistenceKey == normalized }
    }
}

private enum WizardV2BasicEnvPhase: Int, CaseIterable {
    case repairHomebrew = 1
    case installNode
    case setupNpmEnv
    case setNpmRegistry
    case installOpenclaw
    case startGateway

    var title: String {
        switch self {
        case .repairHomebrew:
            return L10n.k("wizard.base_env.homebrew_repair", fallback: "修复 Homebrew 权限")
        case .installNode:
            return L10n.k("wizard.base_env.install_node", fallback: "安装 Node.js")
        case .setupNpmEnv:
            return L10n.k("wizard.base_env.setup_npm_env", fallback: "配置 npm 目录")
        case .setNpmRegistry:
            return L10n.k("wizard.base_env.set_npm_registry", fallback: "设置 npm 安装源")
        case .installOpenclaw:
            return L10n.k("wizard.base_env.install_openclaw", fallback: "安装 openclaw")
        case .startGateway:
            return L10n.k("wizard.base_env.start_gateway", fallback: "启动 Gateway")
        }
    }

    var progressText: String {
        "(\(rawValue)/\(Self.allCases.count)) \(title)…"
    }
}

private enum WizardV2HermesEnvPhase: Int, CaseIterable {
    case repairHomebrew = 1
    case installHermes
    case verifyInstall
    case startGateway

    var title: String {
        switch self {
        case .repairHomebrew:
            return "修复 Homebrew 权限"
        case .installHermes:
            return "安装 Hermes"
        case .verifyInstall:
            return "验证安装"
        case .startGateway:
            return "启动 Gateway"
        }
    }
}

private enum WizardV2SavePhase: Int, CaseIterable {
    case serializeConfig = 1
    case writeConfig
    case writeAgentSnapshot
    case restartGateway
    case finalize

    var title: String {
        switch self {
        case .serializeConfig: return "序列化配置"
        case .writeConfig: return "写入 openclaw.json"
        case .writeAgentSnapshot: return "写入 Agent 角色快照"
        case .restartGateway: return "重启 Gateway"
        case .finalize: return "收尾与状态落盘"
        }
    }

    var hint: String {
        switch self {
        case .serializeConfig:
            return "正在整理 Agent、IM 与绑定矩阵。"
        case .writeConfig:
            return "通过 Helper 原子写入配置文件。"
        case .writeAgentSnapshot:
            return "写入 pending_v2_agents.json，供网关就绪后补写角色文件。"
        case .restartGateway:
            return "会执行 bootout + start，通常最慢（约 5-30 秒）。"
        case .finalize:
            return "保存完成标记并清理临时向导文件。"
        }
    }
}

struct WizardV2InitialRoles {
    var teamDNA: TeamDNA?
    var agents: [AgentDef]

    static var solo: WizardV2InitialRoles {
        WizardV2InitialRoles(
            teamDNA: nil,
            agents: [AgentDef(id: "main", displayName: "主 Agent", isDefault: true)]
        )
    }
}

// MARK: - Main Wizard

struct ShrimpInitWizardV2: View {
    let user: ManagedUser
    var initialRoles: WizardV2InitialRoles = .solo
    var onDismiss: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    // Navigation
    @State private var currentStep: WizardV2Step = .selectEngine
    @State private var visitedSteps: Set<WizardV2Step> = [.selectEngine]
    @State private var selectedEngine: WizardEngine? = nil

    // 角色输入：统一由向导入口传入（独立 agent / 团队多 agent）
    @State private var selectedTeamDNA: TeamDNA? = nil      // nil = 未选团队（solo 也是 nil，agents 手动设置）

    // Step 2: basicEnv (delegates to existing init flow)
    @State private var envReady = false
    @State private var envError: String?
    @State private var isInstallingEnv = false
    @State private var envInstallingPhase: WizardV2BasicEnvPhase?
    @State private var hermesEnvInstallingPhase: WizardV2HermesEnvPhase?
    @State private var didClearInitialEnvLog = false
    @State private var hermesInstallTerminalRunToken = UUID()
    @State private var hermesInstallTerminalControl = LocalTerminalControl()
    @State private var hermesInstallExitCode: Int32?
    @State private var openclawLogTerminalRunToken = UUID()
    @State private var openclawLogTerminalControl = LocalTerminalControl()
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue

    // Step 3 (Hermes): hermes setup 交互式向导
    @State private var hermesSetupTerminalRunToken = UUID()
    @State private var hermesSetupTerminalControl = LocalTerminalControl()
    @State private var hermesSetupExitCode: Int32?
    @State private var hermesSetupDone = false
    @State private var showHermesSetupSkipConfirm = false

    // Step 4: agents
    @State private var agents: [AgentDef] = []
    @State private var agentDNAs: [String: AgentDNA] = [:]           // key = AgentDef.id
    @State private var agentModelCandidates: [String] = []

    // Step 5: IM bindings
    @State private var imAccounts: [IMAccount] = []
    @State private var bindings: [IMBinding] = []

    // Step 6: done
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false
    @State private var savePhase: WizardV2SavePhase? = nil
    @State private var saveStartedAt: Date? = nil

    // 取消确认
    @State private var showCancelConfirm = false
    @State private var isCancellingWizard = false

    /// 有未保存的配置数据（引擎选择、团队选择、agent 定义、IM 绑定）
    private var hasDirtyState: Bool {
        guard !saveSuccess else { return false }
        return selectedEngine != nil || selectedTeamDNA != nil || !agents.isEmpty || !imAccounts.isEmpty || !bindings.isEmpty
    }

    private var hasTeamSummonPayload: Bool {
        initialRoles.teamDNA != nil || selectedTeamDNA != nil
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                stepSidebar
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(L10n.f("wizard_v2.title_with_instance", fallback: "新建实例 %@@%@", user.fullName, user.username))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) {
                        if hasDirtyState {
                            showCancelConfirm = true
                        } else {
                            Task { await cancelAndDismissWizard() }
                        }
                    }
                    .disabled(isCancellingWizard)
                }
            }
            .confirmationDialog(
                L10n.k("wizard_v2.cancel_confirm.title", fallback: "放弃初始化？"),
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.k("wizard_v2.cancel_confirm.discard", fallback: "放弃"), role: .destructive) {
                    Task { await cancelAndDismissWizard() }
                }
                Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
            } message: {
                Text(L10n.k("wizard_v2.cancel_confirm.message", fallback: "已配置的 Agent 和 IM 设置将不会保存"))
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            hydrateInitialRolesIfNeeded()
        }
        .task {
            await autoResumeIfNeeded()
        }
        .onChange(of: initialRoles.teamDNA?.id ?? "") { _, _ in
            hydrateInitialRolesIfNeeded()
        }
    }

    // MARK: - Sidebar

    private var activeSteps: [WizardV2Step] {
        if selectedEngine == .hermes {
            return [.selectEngine, .basicEnv, .hermesSetup, .done]
        }
        // OpenClaw 或尚未选择引擎时，不显示 hermesSetup
        return [.selectEngine, .basicEnv, .configModel, .configAgents, .configIM, .done]
    }

    private var stepSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(activeSteps, id: \.rawValue) { step in
                sidebarRow(step: step)
            }
            Spacer()
            maintenanceMenu
        }
        .frame(width: 180)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var maintenanceMenu: some View {
        HStack {
            Menu {
                Button {
                    openFilesWindow()
                } label: {
                    Label(L10n.k("wizard.maintenance.files", fallback: "文件"), systemImage: "folder")
                }

                Button {
                    openProcessesWindow()
                } label: {
                    Label(L10n.k("wizard.maintenance.processes", fallback: "进程"), systemImage: "cpu")
                }

                Button {
                    openMaintenanceTerminal()
                } label: {
                    Label(L10n.k("wizard.maintenance.terminal", fallback: "终端"), systemImage: "terminal")
                }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                    )
            }
            .menuStyle(.borderlessButton)
            .help(L10n.k("wizard.maintenance.section_title", fallback: "维护工具"))

            Spacer()
        }
        .padding(.horizontal, 12)
    }

    private func sidebarRow(step: WizardV2Step) -> some View {
        let isCurrent = step == currentStep
        let isVisited = visitedSteps.contains(step)
        return HStack(spacing: 10) {
            Image(systemName: step.icon)
                .frame(width: 20)
                .foregroundStyle(isCurrent ? Color.accentColor : isVisited ? Color.primary : Color.secondary.opacity(0.5))
            Text(step.title)
                .foregroundStyle(isCurrent ? Color.accentColor : isVisited ? Color.primary : Color.secondary)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .selectEngine:   selectEngineView
        case .basicEnv:       basicEnvView
        case .hermesSetup:    hermesSetupView
        case .configModel:    configModelView
        case .configAgents:   configAgentsView
        case .configIM:       configIMView
        case .done:           doneView
        }
    }

    // MARK: - Step 1: select engine

    private var selectEngineView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("选择引擎")
                    .font(.title2).fontWeight(.semibold)
                Text("先确定该虾的运行引擎，再进入后续初始化步骤。")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ForEach(WizardEngine.allCases, id: \.rawValue) { engine in
                    let hermesTeamUnavailable = engine == .hermes
                        && !HermesFeaturePolicy.canSelectHermesForTeamSummon(hasTeamDNA: hasTeamSummonPayload)
                    Button {
                        guard !hermesTeamUnavailable else { return }
                        let previous = selectedEngine
                        selectedEngine = engine
                        if previous != nil && previous != engine {
                            resetEnvStateOnEngineSwitch()
                        }
                        if engine == .openclaw {
                            ensureOpenclawRolesSeeded()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            engineLogo(for: engine)
                                .frame(width: 60, height: 60)
                            Text(engine.title)
                                .font(.title3.weight(.semibold))
                            Text(engine.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            if hermesTeamUnavailable {
                                Label(HermesFeaturePolicy.nextVersionHint, systemImage: "clock")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selectedEngine == engine ? Color.accentColor : Color.secondary.opacity(0.2),
                                    lineWidth: selectedEngine == engine ? 2 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(hermesTeamUnavailable)
                    .opacity(hermesTeamUnavailable ? 0.62 : 1)
                }
            }

            Spacer()
            navigationButtons(canGoNext: selectedEngine != nil) {
                advance()
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func engineLogo(for engine: WizardEngine) -> some View {
        switch engine {
        case .openclaw:
            OpenClawLogoMark()
        case .hermes:
            HermesLogoMark()
        }
    }

    // MARK: - Step 4: configAgents（仅做模型绑定）

    private var configAgentsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("wizard_v2.agents.heading", fallback: "Agent 模型绑定"))
                    .font(.title2).fontWeight(.semibold)
                Text(L10n.k("wizard_v2.agents.hint", fallback: "可选：为每个 Agent 指定专用模型。留空则继承全局模型配置。"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($agents) { $agent in
                        agentModelRow(agent: $agent)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()
            navigationButtons(canGoNext: !agents.isEmpty) {
                advance()
            }
        }
        .padding(24)
        .task {
            await refreshAgentModelCandidates()
        }
    }

    private func agentModelRow(agent: Binding<AgentDef>) -> some View {
        let dna = agentDNAs[agent.wrappedValue.id]
        let allChoices = mergedModelChoices(for: agent.wrappedValue.modelPrimary)
        let modelSelection = Binding<String>(
            get: { agent.wrappedValue.modelPrimary ?? "" },
            set: { newValue in
                agent.wrappedValue.modelPrimary = newValue.isEmpty ? nil : newValue
            }
        )
        return HStack(spacing: 12) {
            // 左：角色信息（DNA 来自 step 1 选团队）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let dna {
                        Text(dna.emoji).font(.body)
                    }
                    Text(agent.wrappedValue.displayName).fontWeight(.medium)
                    if agent.wrappedValue.isDefault {
                        Text(L10n.k("agents.default_badge", fallback: "默认"))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text("@\(agent.wrappedValue.id)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if let dna {
                    Text(String(dna.soul.prefix(50)) + (dna.soul.count > 50 ? "…" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            // 右：主模型选择（默认继承全局）
            Picker("", selection: modelSelection) {
                Text(L10n.k("wizard_v2.agents.model_placeholder", fallback: "继承全局模型"))
                    .tag("")
                ForEach(allChoices, id: \.self) { modelID in
                    Text(modelLabel(for: modelID)).tag(modelID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 280)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func refreshAgentModelCandidates() async {
        var ordered: [String] = []
        func appendUnique(_ modelID: String?) {
            guard let modelID else { return }
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !ordered.contains(trimmed) { ordered.append(trimmed) }
        }

        // 上一步刚写入的 agents.defaults.model.{primary,fallbacks} —— helper 直读配置，最可靠
        if let status = await helperClient.getModelsStatus(username: user.username) {
            appendUnique(status.resolvedDefault ?? status.defaultModel)
            status.fallbacks.forEach { appendUnique($0) }
        }

        // gateway 已加载的完整模型目录（若已 reload 则覆盖补齐）
        if let groups = await gatewayHub.modelsList(username: user.username) {
            for group in groups {
                for model in group.models {
                    appendUnique(model.id)
                }
            }
        }

        // agent 自身已有（保留用户之前的选择）
        agents.compactMap(\.modelPrimary).forEach { appendUnique($0) }

        await MainActor.run {
            agentModelCandidates = ordered
        }
    }

    private func mergedModelChoices(for current: String?) -> [String] {
        var choices = agentModelCandidates
        if let current {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !choices.contains(trimmed) {
                choices.insert(trimmed, at: 0)
            }
        }
        return choices
    }

    private func modelLabel(for modelID: String) -> String {
        let builtIn = builtInModelGroups.flatMap(\.models).first { $0.id == modelID }?.label
        return builtIn ?? modelID
    }

    @ViewBuilder
    private var basicEnvView: some View {
        if selectedEngine == .hermes {
            VStack(alignment: .leading, spacing: 0) {
                Text("安装 Hermes 运行环境")
                    .font(.title2).fontWeight(.semibold)
                    .padding(.bottom, 12)

                HStack(spacing: 12) {
                    if let err = envError {
                        Button(L10n.k("common.retry", fallback: "重试")) { runEnvInstall() }
                            .buttonStyle(.bordered)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if envReady {
                        Label("Hermes 环境就绪", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13, weight: .medium))
                        hermesEnvPhaseStepperView
                    } else if isInstallingEnv {
                        hermesEnvPhaseStepperView
                    } else {
                        Button("安装 Hermes") { runEnvInstall() }
                            .buttonStyle(.borderedProminent)
                        hermesEnvPhaseStepperView
                    }
                    Spacer()
                }
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("安装终端（可交互）")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label("支持键盘输入，可在异常时人工介入", systemImage: "keyboard")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Ctrl+C") {
                            hermesInstallTerminalControl.sendInterrupt()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!isInstallingEnv)
                        if let code = hermesInstallExitCode {
                            Text("最近退出码: \(code)")
                                .font(.caption2)
                                .foregroundStyle(code == 0 ? Color.secondary : Color.orange)
                        }
                    }
                    .padding(.horizontal, 4)

                    if (isInstallingEnv && hermesEnvInstallingPhase == .installHermes) || hermesInstallExitCode != nil {
                        HelperMaintenanceTerminalPanel(
                            username: user.username,
                            command: hermesInstallTerminalCommand(),
                            minHeight: 260,
                            onOutput: nil,
                            control: hermesInstallTerminalControl
                        ) { code in
                            Task { await handleHermesInstallTerminalExit(code) }
                        }
                        .id(hermesInstallTerminalRunToken)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(minHeight: 160)
                            .overlay {
                                Text("点击“安装 Hermes”后将启动可交互终端。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                navigationButtons(canGoNext: envReady, nextLabel: L10n.k("common.next", fallback: "下一步")) {
                    advance()
                }
                .padding(.top, 12)
            }
            .padding(24)
            .onAppear {
                clearInitialEnvLogIfNeeded()
                checkEnvReady()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.k("wizard_v2.basic_env.heading", fallback: "安装基础运行环境"))
                    .font(.title2).fontWeight(.semibold)
                    .padding(.bottom, 12)

                HStack(spacing: 12) {
                    if let err = envError {
                        Button(L10n.k("common.retry", fallback: "重试")) { runEnvInstall() }
                            .buttonStyle(.bordered)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if envReady {
                        Label(L10n.k("wizard_v2.basic_env.ready", fallback: "环境就绪"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13, weight: .medium))
                        envPhaseStepperView
                    } else if isInstallingEnv {
                        envPhaseStepperView
                    } else {
                        Button(L10n.k("wizard_v2.basic_env.start", fallback: "开始安装")) { runEnvInstall() }
                            .buttonStyle(.borderedProminent)
                        envPhaseStepperView
                    }
                    Spacer()
                }
                .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("安装终端（日志跟踪）")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Label("统一 SwiftTerm 显示（日志 tail 模式）", systemImage: "terminal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Ctrl+C") {
                            openclawLogTerminalControl.sendInterrupt()
                        }
                        .buttonStyle(.borderless)
                        Button("重连日志") {
                            openclawLogTerminalRunToken = UUID()
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 4)

                    HelperMaintenanceTerminalPanel(
                        username: user.username,
                        command: openclawLogTailCommand(),
                        minHeight: 260,
                        onOutput: nil,
                        control: openclawLogTerminalControl,
                        onExit: nil
                    )
                    .id(openclawLogTerminalRunToken)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                navigationButtons(canGoNext: envReady, nextLabel: L10n.k("common.next", fallback: "下一步")) {
                    advance()
                }
                .padding(.top, 12)
            }
            .padding(24)
            .onAppear {
                clearInitialEnvLogIfNeeded()
                checkEnvReady()
            }
        }
    }

    // MARK: - 安装阶段步骤指示器

    @ViewBuilder
    private var envPhaseStepperView: some View {
        HStack(spacing: 2) {
            ForEach(WizardV2BasicEnvPhase.allCases, id: \.rawValue) { phase in
                let state = envPhaseState(phase)
                HStack(spacing: 3) {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 10))
                    case .active:
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .symbolEffect(.bounce, options: .repeating)
                    case .pending:
                        Text("\(phase.rawValue)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    Text(phase.title)
                        .font(.system(size: 11))
                        .foregroundStyle(state == .active ? .primary : state == .done ? .secondary : .tertiary)
                        .lineLimit(1)
                }
                if phase != WizardV2BasicEnvPhase.allCases.last {
                    Text("›")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 1)
                }
            }
        }
    }

    private enum EnvPhaseState { case done, active, pending }

    private func envPhaseState(_ phase: WizardV2BasicEnvPhase) -> EnvPhaseState {
        guard let current = envInstallingPhase else {
            return envReady ? .done : .pending
        }
        if phase.rawValue < current.rawValue { return .done }
        if phase == current { return .active }
        return .pending
    }

    @ViewBuilder
    private var hermesEnvPhaseStepperView: some View {
        HStack(spacing: 2) {
            ForEach(WizardV2HermesEnvPhase.allCases, id: \.rawValue) { phase in
                let state = hermesEnvPhaseState(phase)
                HStack(spacing: 3) {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 10))
                    case .active:
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .symbolEffect(.bounce, options: .repeating)
                    case .pending:
                        Text("\(phase.rawValue)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    Text(phase.title)
                        .font(.system(size: 11))
                        .foregroundStyle(state == .active ? .primary : state == .done ? .secondary : .tertiary)
                        .lineLimit(1)
                }
                if phase != WizardV2HermesEnvPhase.allCases.last {
                    Text("›")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 1)
                }
            }
        }
    }

    private func hermesEnvPhaseState(_ phase: WizardV2HermesEnvPhase) -> EnvPhaseState {
        guard let current = hermesEnvInstallingPhase else {
            return envReady ? .done : .pending
        }
        if phase.rawValue < current.rawValue { return .done }
        if phase == current { return .active }
        return .pending
    }

    // MARK: - Step: hermesSetup（hermes setup 交互式向导）

    private var hermesSetupView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hermes 配置")
                .font(.title2).fontWeight(.semibold)
                .padding(.bottom, 4)
            Text("通过 hermes setup 交互式向导完成模型、密钥等配置。")
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            HStack(spacing: 12) {
                if hermesSetupDone {
                    Label("配置向导已完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))
                } else if let code = hermesSetupExitCode, code != 0 {
                    Label("向导异常退出（code \(code)），可重新运行。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("重新运行") {
                        hermesSetupExitCode = nil
                        hermesSetupDone = false
                        hermesSetupTerminalRunToken = UUID()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Ctrl+C") {
                    hermesSetupTerminalControl.sendInterrupt()
                }
                .buttonStyle(.borderless)
                .disabled(hermesSetupDone)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Label("支持键盘输入，按向导提示完成配置", systemImage: "keyboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let code = hermesSetupExitCode {
                        Text("退出码: \(code)")
                            .font(.caption2)
                            .foregroundStyle(code == 0 ? Color.secondary : Color.orange)
                    }
                }
                .padding(.horizontal, 4)

                HelperMaintenanceTerminalPanel(
                    username: user.username,
                    command: hermesSetupTerminalCommand(),
                    minHeight: 300,
                    onOutput: nil,
                    control: hermesSetupTerminalControl
                ) { code in
                    Task { await handleHermesSetupTerminalExit(code) }
                }
                .id(hermesSetupTerminalRunToken)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            navigationButtons(canGoNext: true, nextLabel: L10n.k("common.next", fallback: "下一步")) {
                if hermesSetupDone {
                    advance()
                } else {
                    showHermesSetupSkipConfirm = true
                }
            }
            .padding(.top, 12)
        }
        .padding(24)
        .confirmationDialog(
            "尚未完成 Hermes 配置",
            isPresented: $showHermesSetupSkipConfirm,
            titleVisibility: .visible
        ) {
            Button("继续创建", role: .destructive) { advance() }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        } message: {
            Text("hermes setup 尚未成功完成，模型 / API Key 等可能未配置。继续将直接创建 profile，启动后可能需要再次进入 Hermes 配置。")
        }
    }

    private func hermesSetupTerminalCommand() -> [String] {
        ["hermes", "setup"]
    }

    @MainActor
    private func handleHermesSetupTerminalExit(_ code: Int32?) async {
        hermesSetupExitCode = code
        if code == 0 {
            hermesSetupDone = true
        }
    }

    // MARK: - Step 3: configModel

    private var configModelView: some View {
        ScrollView {
            ModelConfigWizard(user: user, presentation: .wizardStep) {
                advance()
            }
            .padding(20)
        }
    }

    // MARK: - Step 5: configIM

    private var configIMView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("wizard_v2.im.heading", fallback: "绑定 IM Bot"))
                        .font(.title2).fontWeight(.semibold)
                    Text(L10n.k("wizard_v2.im.hint", fallback: "可选 — 主 Agent 调度时不需要绑定"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // banner：降低用户"必须为每个 agent 都绑 IM"的负担感知
            wizardIMBanner

            ScrollView {
                AgentBotListEditor(
                    agents: $agents,
                    imAccounts: $imAccounts,
                    bindings: $bindings,
                    username: user.username,
                    showModelPicker: false,    // Step 4 已经填过模型；这里 IM-only
                    allowAddAgent: false       // 向导这一步不让加 agent，引导用户回 Step 4
                )
                .padding(.horizontal, 4)
            }

            Spacer()
            navigationButtons(canGoNext: true, nextLabel: L10n.k("wizard_v2.im.skip_or_next", fallback: "跳过 / 下一步")) {
                advance()
            }
        }
        .padding(24)
        .task { await loadExistingChannelBindings() }
    }

    /// Step 5 顶部的"降负担"提示横幅 — 一直显示，不做"我知道了"折叠
    private var wizardIMBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Color.yellow)
                .font(.callout)
            Text(L10n.k("wizard_v2.im.banner",
                        fallback: "只绑默认 Agent 就够用了 — 可以通过主 Agent 分派任务给其他 Agent，也可以后面在设置中按需绑定 / 更新 IM。"))
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Step 6: done

    private var doneView: some View {
        VStack(spacing: 20) {
            if isSaving {
                ProgressView()
                    .scaleEffect(1.4)
                Text(savePhaseProgressText)
                    .font(.headline)
                if let phase = savePhase {
                    Text(phase.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("已耗时 \(saveElapsedText(now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let err = saveError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text(err)
                    .foregroundStyle(.red)
                Button(L10n.k("common.retry", fallback: "重试")) { runSave() }
                    .buttonStyle(.bordered)
            } else if saveSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(L10n.k("wizard_v2.done.success", fallback: "初始化完成！"))
                    .font(.title2).fontWeight(.semibold)
                Text(summaryText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L10n.k("common.done", fallback: "完成")) {
                    onDismiss?()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { runSave() }
    }

    private var savePhaseProgressText: String {
        guard let phase = savePhase else {
            return L10n.k("wizard_v2.done.saving", fallback: "正在写入配置…")
        }
        let activePhases = activeSavePhases
        let idx = activePhases.firstIndex(of: phase).map { $0 + 1 } ?? phase.rawValue
        return "(\(idx)/\(activePhases.count)) \(phase.title)…"
    }

    /// 当前引擎实际经过的 save 阶段（Hermes 跳过 serializeConfig / writeConfig）
    private var activeSavePhases: [WizardV2SavePhase] {
        if (selectedEngine ?? .openclaw) == .hermes {
            return [.writeAgentSnapshot, .restartGateway, .finalize]
        }
        return WizardV2SavePhase.allCases
    }

    private func saveElapsedText(now: Date) -> String {
        guard let start = saveStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let min = elapsed / 60
        let sec = elapsed % 60
        return String(format: "%02d:%02d", min, sec)
    }

    private var summaryText: String {
        if selectedEngine == .hermes {
            return "Hermes 引擎初始化完成"
        }
        let agentCount = agents.count
        let botCount = imAccounts.count
        return L10n.k("wizard_v2.done.summary",
                      fallback: "\(agentCount) 个 Agent，\(botCount) 个 IM Bot 绑定")
    }

    @MainActor
    private func cancelAndDismissWizard() async {
        guard !isCancellingWizard else { return }
        isCancellingWizard = true
        defer { isCancellingWizard = false }

        // 显式标记当前向导会话已结束，但不要标记 completedAt；
        // 未安装 runtime 的账号下次入口仍应被识别为未初始化。
        var cancelledState = InitWizardState()
        cancelledState.schemaVersion = 2
        cancelledState.mode = .onboarding
        cancelledState.active = false
        cancelledState.currentStep = "v2:cancelled"
        cancelledState.updatedAt = Date()

        do {
            try await helperClient.saveInitState(username: user.username, json: cancelledState.toJSON())
        } catch {
            appLog("[WizardV2] 取消初始化时落盘状态失败 @\(user.username): \(error.localizedDescription)", level: .warn)
        }

        // 放弃时清理向导草稿，避免后续再次进入时恢复到已放弃的数据。
        // Hermes 路径不使用 .openclaw，跳过写入以避免误创建该目录。
        if WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: selectedEngine?.rawValue) {
            let emptyObject = Data("{}".utf8)
            let emptyArray = Data("[]".utf8)
            for (relPath, payload) in [
                (".openclaw/workspace/pending_v2_team.json", emptyObject),
                (".openclaw/workspace/pending_v2_agent_defs.json", emptyArray),
                (".openclaw/workspace/pending_v2_agents.json", emptyArray),
            ] {
                do {
                    try await helperClient.writeFile(
                        username: user.username,
                        relativePath: relPath,
                        data: payload
                    )
                } catch {
                    appLog("[WizardV2] 取消向导清理 \(relPath) 失败 @\(user.username): \(error.localizedDescription)", level: .warn)
                }
            }
        }

        onDismiss?()
        dismiss()
    }

    // MARK: - Navigation helpers

    private func navigationButtons(
        canGoNext: Bool,
        nextLabel: String = L10n.k("common.next", fallback: "下一步"),
        nextAction: @escaping () -> Void
    ) -> some View {
        HStack {
            if previousStep(of: currentStep) != nil {
                Button(L10n.k("common.back", fallback: "上一步")) {
                    if let prev = previousStep(of: currentStep) {
                        currentStep = prev
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(nextLabel, action: nextAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canGoNext)
        }
    }

    private func previousStep(of step: WizardV2Step) -> WizardV2Step? {
        guard let idx = activeSteps.firstIndex(of: step), idx > 0 else { return nil }
        return activeSteps[idx - 1]
    }

    private func nextStep(of step: WizardV2Step) -> WizardV2Step? {
        guard let idx = activeSteps.firstIndex(of: step), idx + 1 < activeSteps.count else { return nil }
        return activeSteps[idx + 1]
    }

    private func advance() {
        guard let next = nextStep(of: currentStep) else { return }
        visitedSteps.insert(next)
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = next
        }
        persistV2Progress()
    }

    private func applyTeamTemplate(_ teamDNA: TeamDNA) {
        selectedTeamDNA = teamDNA
        persistTeamDNA(teamDNA)
        guard !teamDNA.members.isEmpty else {
            agents = initialRoles.agents.isEmpty ? WizardV2InitialRoles.solo.agents : initialRoles.agents
            agentDNAs = [:]
            return
        }

        // 规范化：主 Agent 固定为 id=main，避免后续路径/默认会话依赖出现偏差。
        var resultAgents: [AgentDef] = []
        var resultDNAs: [String: AgentDNA] = [:]
        var usedIDs = Set<String>()

        for (idx, dna) in teamDNA.members.enumerated() {
            let resolvedID: String
            if idx == 0 {
                resolvedID = "main"
            } else {
                let base = (dna.suggestedAgentID ?? dna.id).trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackBase = base.isEmpty ? "agent" : base
                var candidate = fallbackBase
                var suffix = 2
                while usedIDs.contains(candidate) {
                    candidate = "\(fallbackBase)-\(suffix)"
                    suffix += 1
                }
                resolvedID = candidate
            }

            usedIDs.insert(resolvedID)
            resultAgents.append(
                AgentDef(
                    id: resolvedID,
                    displayName: dna.name,
                    isDefault: idx == 0,
                    roleTemplateId: dna.id
                )
            )
            resultDNAs[resolvedID] = dna
        }

        agents = resultAgents
        agentDNAs = resultDNAs
    }

    private func ensureOpenclawRolesSeeded() {
        guard agents.isEmpty else { return }
        if let teamDNA = selectedTeamDNA ?? initialRoles.teamDNA {
            applyTeamTemplate(teamDNA)
            return
        }
        agents = initialRoles.agents.isEmpty ? WizardV2InitialRoles.solo.agents : initialRoles.agents
        agentDNAs = [:]
    }

    private func hydrateInitialRolesIfNeeded() {
        guard selectedTeamDNA == nil, agents.isEmpty else { return }

        if let teamDNA = initialRoles.teamDNA {
            // 团队语义只能映射到 OpenClaw，预选引擎并预填 Agent 模板；
            // 但保留在 .selectEngine 步骤让用户显式确认，避免"领养团队直接跳过引擎选择"。
            selectedEngine = .openclaw
            applyTeamTemplate(teamDNA)
            return
        }

        ensureOpenclawRolesSeeded()
    }

    // MARK: - Business logic

    /// 切换引擎时清除上一引擎的环境状态，避免 sidebar/按钮误显示"已就绪"
    private func resetEnvStateOnEngineSwitch() {
        envReady = false
        envError = nil
        envInstallingPhase = nil
        hermesEnvInstallingPhase = nil
        hermesInstallExitCode = nil
        hermesSetupExitCode = nil
        hermesSetupDone = false
        didClearInitialEnvLog = false
    }

    private func checkEnvReady() {
        Task {
            let engine = selectedEngine ?? .openclaw
            if engine == .hermes {
                let version = await helperClient.getHermesVersion(username: user.username)
                let gatewayStatus = await helperClient.getHermesGatewayStatus(username: user.username)
                await MainActor.run {
                    envReady = version != nil && gatewayStatus.running
                }
            } else {
                let version = await helperClient.getOpenclawVersion(username: user.username)
                let gatewayStatus = try? await helperClient.getGatewayStatus(username: user.username)
                await MainActor.run {
                    envReady = version != nil && (gatewayStatus?.running == true)
                }
            }
        }
    }

    private func clearInitialEnvLogIfNeeded() {
        guard !didClearInitialEnvLog else { return }
        guard !isInstallingEnv else { return }
        let logPath = envLogPath(for: selectedEngine ?? .openclaw)
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o666])
        didClearInitialEnvLog = true
    }

    private func runEnvInstall() {
        guard !isInstallingEnv else { return }
        isInstallingEnv = true
        envError = nil
        hermesInstallExitCode = nil
        let engine = selectedEngine ?? .openclaw
        if engine == .hermes {
            hermesEnvInstallingPhase = .repairHomebrew
            envInstallingPhase = nil
        } else {
            envInstallingPhase = .repairHomebrew
            hermesEnvInstallingPhase = nil
        }
        // 截断上次遗留的日志文件，让终端面板从空白开始
        let logPath = envLogPath(for: engine)
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o666])
        if engine == .hermes {
            Task { @MainActor in
                // best-effort：失败不阻断
                try? await helperClient.repairHomebrewPermission(username: user.username)
                hermesEnvInstallingPhase = .installHermes
                hermesInstallTerminalRunToken = UUID()
            }
            return
        }
        openclawLogTerminalRunToken = UUID()
        Task { @MainActor in
            do {
                // best-effort：失败不阻断
                try? await helperClient.repairHomebrewPermission(username: user.username)

                envInstallingPhase = .installNode
                try await helperClient.installNode(username: user.username, nodeDistURL: nodeDistURL)

                envInstallingPhase = .setupNpmEnv
                try await helperClient.setupNpmEnv(username: user.username)

                envInstallingPhase = .setNpmRegistry
                try await helperClient.setNpmRegistry(
                    username: user.username,
                    registry: NpmRegistryOption.defaultForInitialization.rawValue
                )

                envInstallingPhase = .installOpenclaw
                try await helperClient.installOpenclaw(username: user.username, version: nil)

                envInstallingPhase = .startGateway
                let startResult = try await helperClient.startGatewayDiagnoseNodeToolchain(username: user.username)
                if case .needsNodeRepair(let reason) = startResult {
                    throw HelperError.operationFailed(reason)
                }

                // Gateway 进程已启动，等 token 写入配置后建立 WebSocket 连接
                for _ in 0..<20 {
                    let url = await helperClient.getGatewayURL(username: user.username)
                    if !url.isEmpty, url.contains("#token=") {
                        await gatewayHub.connect(username: user.username, gatewayURL: url)
                        if gatewayHub.connectedUsernames.contains(user.username) { break }
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }

                isInstallingEnv = false
                envInstallingPhase = nil
                hermesEnvInstallingPhase = nil
                envReady = true
            } catch {
                let phaseTitle = (engine == .hermes ? hermesEnvInstallingPhase?.title : envInstallingPhase?.title)
                    ?? L10n.k("wizard_v2.basic_env.heading", fallback: "安装基础运行环境")
                isInstallingEnv = false
                envInstallingPhase = nil
                hermesEnvInstallingPhase = nil
                envError = "\(phaseTitle)失败：\(error.localizedDescription)"
            }
        }
    }

    private func hermesInstallTerminalCommand() -> [String] {
        let home = "/Users/\(user.username)"
        let hermesHome = "/Users/\(user.username)/.hermes"
        let script = """
            set -euo pipefail
            export HOME="\(home)"
            export USER="\(user.username)"
            export HERMES_HOME="\(hermesHome)"
            export HOMEBREW_PREFIX="$HOME/.brew"
            export HOMEBREW_CELLAR="$HOME/.brew/Cellar"
            export HOMEBREW_REPOSITORY="$HOME/.brew"
            export PATH="$HOME/.brew/bin:$HOME/.brew/sbin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            export UV_INSTALL_DIR="$HOME/.local/bin"
            mkdir -p "$HOME/.local/bin"
            hash -r 2>/dev/null || true
            mkdir -p "$HERMES_HOME"
            curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | /bin/bash -s -- --skip-setup --hermes-home "$HERMES_HOME"
            """
        return ["bash", "-c", script]
    }

    private func openclawLogTailCommand() -> [String] {
        let logPath = envLogPath(for: .openclaw)
        let script = """
            touch "\(logPath)"
            exec /usr/bin/tail -n +1 -f "\(logPath)"
            """
        return ["bash", "-lc", script]
    }

    private func openFilesWindow() {
        let payload = maintenanceWindowRegistry.makeToolWindowPayload(
            username: user.username,
            title: L10n.f(
                "wizard.maintenance.files.window_title",
                fallback: "@%@ · 文件",
                user.username
            ),
            kind: .files,
            scope: selectedEngine == .hermes
                ? .runtime(.hermes)
                : (selectedEngine == .openclaw ? .runtime(.openclaw) : .home)
        )
        openWindow(id: "maintenance-files", value: payload)
    }

    private func openProcessesWindow() {
        let payload = maintenanceWindowRegistry.makeToolWindowPayload(
            username: user.username,
            title: L10n.f(
                "wizard.maintenance.processes.window_title",
                fallback: "@%@ · 进程",
                user.username
            ),
            kind: .processes
        )
        openWindow(id: "maintenance-processes", value: payload)
    }

    private func openMaintenanceTerminal() {
        let engine: MaintenanceTerminalEngine? = switch selectedEngine {
        case .hermes: .hermes
        case .openclaw: .openclaw
        case nil: nil
        }
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("user.detail.auto.cli_maintenance_advanced", fallback: "命令行维护（高级）"),
            command: ["zsh", "-l"],
            engine: engine
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    @MainActor
    private func handleHermesInstallTerminalExit(_ code: Int32?) async {
        guard isInstallingEnv else { return }
        hermesInstallExitCode = code
        guard code == 0 else {
            isInstallingEnv = false
            envInstallingPhase = nil
            hermesEnvInstallingPhase = nil
            envError = "Hermes 安装失败：终端退出码 \(code ?? -1)。可在终端中修复后重试。"
            return
        }

        hermesEnvInstallingPhase = .verifyInstall
        let version = await helperClient.getHermesVersion(username: user.username)
        if version == nil {
            isInstallingEnv = false
            envInstallingPhase = nil
            hermesEnvInstallingPhase = nil
            envError = "Hermes 安装校验失败：未读取到版本号。"
            return
        }

        hermesEnvInstallingPhase = .startGateway
        do {
            try await helperClient.startHermesGateway(username: user.username)
        } catch {
            isInstallingEnv = false
            envInstallingPhase = nil
            hermesEnvInstallingPhase = nil
            envError = "Hermes Gateway 启动失败：\(error.localizedDescription)"
            return
        }

        isInstallingEnv = false
        envInstallingPhase = nil
        hermesEnvInstallingPhase = nil
        envReady = true
    }

    private func envLogPath(for engine: WizardEngine) -> String {
        switch engine {
        case .openclaw:
            return "/tmp/clawdhome-init-\(user.username).log"
        case .hermes:
            return "/tmp/clawdhome-hermes-\(user.username).log"
        }
    }

    private func runSave() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        saveStartedAt = Date()
        savePhase = .serializeConfig
        let engine = selectedEngine ?? .openclaw

        if engine == .hermes {
            let username = user.username
            let dnasSnapshot = agentDNAs
            let rolesSnapshot: [AgentDef] = agents.isEmpty
                ? [AgentDef(id: "main", displayName: "主 Agent", isDefault: true)]
                : agents
            Task {
                await MainActor.run { savePhase = .writeAgentSnapshot }
                do {
                    // 先列出已有 profile，避免重试时重复创建报错（createHermesProfile 非幂等）
                    let existingIDs: Set<String>
                    do {
                        let existing = try await helperClient.listHermesProfiles(username: username)
                        existingIDs = Set(existing.map(\.id))
                    } catch {
                        appLog("[WizardV2] listHermesProfiles 失败 @\(username)，继续按全量创建尝试：\(error.localizedDescription)", level: .warn)
                        existingIDs = []
                    }
                    for role in rolesSnapshot where !existingIDs.contains(role.id) {
                        let emoji = dnasSnapshot[role.id]?.emoji ?? (role.id == "main" ? "🎭" : "🤖")
                        let profile = AgentProfile(
                            id: role.id,
                            name: role.displayName,
                            emoji: emoji,
                            modelPrimary: role.modelPrimary,
                            modelFallbacks: role.modelFallbacks,
                            workspacePath: nil,
                            isDefault: role.isDefault
                        )
                        try await helperClient.createHermesProfile(username: username, config: profile)
                    }
                    let defaultProfileID = rolesSnapshot.first(where: \.isDefault)?.id
                        ?? rolesSnapshot.first?.id
                        ?? "main"
                    try await helperClient.setHermesActiveProfile(username: username, profileID: defaultProfileID)
                } catch {
                    await MainActor.run {
                        isSaving = false
                        saveError = "[\(WizardV2SavePhase.writeAgentSnapshot.title)] Hermes profile 初始化失败：\(error.localizedDescription)"
                    }
                    return
                }

                await MainActor.run { savePhase = .restartGateway }
                do {
                    try await helperClient.startHermesGateway(username: username)
                } catch {
                    await MainActor.run {
                        isSaving = false
                        saveError = "[\(WizardV2SavePhase.restartGateway.title)] Hermes 网关启动失败：\(error.localizedDescription)"
                    }
                    return
                }

                await MainActor.run { savePhase = .finalize }
                var doneState = InitWizardState()
                doneState.active = false
                doneState.completedAt = Date()
                doneState.updatedAt = Date()
                doneState.currentStep = "v2:done"
                do {
                    try await helperClient.saveInitState(username: username, json: doneState.toJSON())
                } catch {
                    appLog("[WizardV2] Hermes 完成态落盘失败 @\(username): \(error.localizedDescription)", level: .warn)
                }
                await MainActor.run {
                    isSaving = false
                    saveSuccess = true
                }
            }
            return
        }

        let config = ShrimpConfigV2(
            agents: agents,
            imAccounts: imAccounts,
            bindings: bindings,
            sessionDmScope: imAccounts.isEmpty ? nil : .perAccountChannelPeer
        )
        let username = user.username
        let dnasSnapshot = agentDNAs

        Task {
            // 1. 序列化 ShrimpConfigV2
            await MainActor.run { savePhase = .serializeConfig }
            let configJSON: String
            do {
                let data = try JSONEncoder().encode(config)
                configJSON = String(data: data, encoding: .utf8) ?? "{}"
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "[\(WizardV2SavePhase.serializeConfig.title)] 配置序列化失败：\(error.localizedDescription)"
                }
                return
            }

            // 2. 通过 XPC 写入 openclaw.json（applyV2Config 在 Helper 侧调用 OpenclawConfigSerializerV2）
            await MainActor.run { savePhase = .writeConfig }
            let (ok, err) = await helperClient.applyV2Config(username: username, configJSON: configJSON)
            guard ok else {
                await MainActor.run {
                    isSaving = false
                    saveError = "[\(WizardV2SavePhase.writeConfig.title)] " + (err ?? "写入配置失败")
                }
                return
            }

            // 3. 把 agentId → DNA 映射写入 pending_v2_agents.json，供 gateway ready 后消费
            //    格式：[{"agentDefId": "main", "dna": {...}}]
            //    gateway 启动后 UserDetailView.consumePendingV2Agents() 会找到对应 profile 写 persona 文件
            await MainActor.run { savePhase = .writeAgentSnapshot }
            if !dnasSnapshot.isEmpty {
                let entries: [[String: Any]] = dnasSnapshot.compactMap { (agentDefId, dna) in
                    guard let dnaData = try? JSONEncoder().encode(dna),
                          let dnaDict = try? JSONSerialization.jsonObject(with: dnaData) as? [String: Any]
                    else { return nil }
                    return ["agentDefId": agentDefId, "dna": dnaDict]
                }
                do {
                    let pendingData = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
                    let workspacePath = ".openclaw/workspace"
                    try? await helperClient.createDirectory(username: username, relativePath: workspacePath)
                    try await helperClient.writeFile(
                        username: username,
                        relativePath: "\(workspacePath)/pending_v2_agents.json",
                        data: pendingData
                    )
                } catch {
                    await MainActor.run {
                        isSaving = false
                        saveError = "[\(WizardV2SavePhase.writeAgentSnapshot.title)] Agent 角色写入失败：\(error.localizedDescription)"
                    }
                    return
                }
            }

            // 4. 重启 gateway，使新写入的 openclaw.json 生效，并触发 UserDetailView
            //    的 consumePendingV2Agents()（由 readinessMap == .ready 的 onChange 触发）
            await MainActor.run { savePhase = .restartGateway }
            do {
                try await helperClient.restartGateway(username: username)
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "[\(WizardV2SavePhase.restartGateway.title)] 网关重启失败：\(error.localizedDescription)"
                }
                return
            }

            // 5. 标记向导已完成，清理临时文件
            await MainActor.run { savePhase = .finalize }
            var doneState = InitWizardState()
            doneState.active = false
            doneState.completedAt = Date()
            doneState.updatedAt = Date()
            doneState.currentStep = "v2:done"
            do {
                try await helperClient.saveInitState(username: username, json: doneState.toJSON())
            } catch {
                appLog("[WizardV2] OpenClaw 完成态落盘失败 @\(username): \(error.localizedDescription)", level: .warn)
            }
            do {
                try await helperClient.writeFile(
                    username: username,
                    relativePath: ".openclaw/workspace/pending_v2_team.json",
                    data: "{}".data(using: .utf8) ?? Data()
                )
            } catch {
                appLog("[WizardV2] 清理 pending_v2_team.json 失败 @\(username): \(error.localizedDescription)", level: .warn)
            }

            await MainActor.run {
                isSaving = false
                saveSuccess = true
            }
        }
    }

    /// 从 gateway channel store 检测已有的 IM 绑定，填充 imAccounts + bindings
    private func loadExistingChannelBindings() async {
        // 已有数据则跳过，避免重复加载
        guard imAccounts.isEmpty else { return }

        let store = gatewayHub.channelStore(for: user.username)
        await store.refresh()

        let defaultAgentId = agents.first(where: \.isDefault)?.id ?? agents.first?.id ?? ""
        guard !defaultAgentId.isEmpty else { return }

        // 遍历所有支持扫码绑定的通道
        for flow in ChannelOnboardingFlow.allCases {
            for channelId in flow.candidateChannelIds {
                for snapshot in store.boundAccounts(channelId) {
                    let platform: IMPlatform = flow == .feishu ? .feishu : .wechat

                    // 去重
                    guard !imAccounts.contains(where: { $0.id == snapshot.accountId && $0.platform == platform }) else { continue }

                    let account = IMAccount(
                        id: snapshot.accountId,
                        platform: platform,
                        displayName: snapshot.name ?? flow.title,
                        appId: snapshot.appId,
                        allowFrom: snapshot.allowFrom ?? [],
                        domain: snapshot.domain,
                        createdAt: Date()
                    )
                    imAccounts.append(account)

                    let binding = IMBinding(
                        agentId: defaultAgentId,
                        channel: platform.openclawChannelId,
                        accountId: snapshot.accountId
                    )
                    bindings.append(binding)
                }
            }
        }
    }

    // MARK: - 进度持久化与恢复

    /// 将当前向导步骤持久化到磁盘，保证 app 重启后能路由回向导并恢复进度
    private func persistV2Progress() {
        Task {
            var state = InitWizardState()
            state.active = true
            state.mode = .onboarding
            state.currentStep = "v2:\(currentStep.persistenceKey)"
            state.updatedAt = Date()
            if let selectedEngine {
                state.steps["v2_engine"] = selectedEngine.rawValue
            }
            for s in WizardV2Step.allCases where s.rawValue < currentStep.rawValue {
                state.steps["v2_\(s.persistenceKey)"] = "done"
            }
            state.steps["v2_\(currentStep.persistenceKey)"] = "running"
            do {
                try await helperClient.saveInitState(username: user.username, json: state.toJSON())
            } catch {
                appLog("[WizardV2] 进度位图落盘失败 @\(user.username) step=\(currentStep): \(error.localizedDescription)", level: .warn)
            }

            // 同步持久化 agent 定义（含模型选择），避免二次进入时丢失
            persistAgentDefs()
        }
    }

    /// 将团队 DNA 写入用户 workspace，供重启后恢复（仅 OpenClaw 引擎）
    private func persistTeamDNA(_ teamDNA: TeamDNA) {
        guard WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: selectedEngine?.rawValue) else { return }
        Task {
            guard let data = try? JSONEncoder().encode(teamDNA) else { return }
            try? await helperClient.createDirectory(username: user.username, relativePath: ".openclaw/workspace")
            do {
                try await helperClient.writeFile(
                    username: user.username,
                    relativePath: ".openclaw/workspace/pending_v2_team.json",
                    data: data
                )
            } catch {
                appLog("[WizardV2] 团队 DNA 落盘失败 @\(user.username): \(error.localizedDescription)", level: .warn)
            }
        }
    }

    /// 将 agent 定义（含模型选择）写入用户 workspace，供重启后恢复（仅 OpenClaw 引擎）
    private func persistAgentDefs() {
        guard WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: selectedEngine?.rawValue),
              !agents.isEmpty else { return }
        Task {
            guard let data = try? JSONEncoder().encode(agents) else { return }
            try? await helperClient.createDirectory(username: user.username, relativePath: ".openclaw/workspace")
            do {
                try await helperClient.writeFile(
                    username: user.username,
                    relativePath: ".openclaw/workspace/pending_v2_agent_defs.json",
                    data: data
                )
            } catch {
                appLog("[WizardV2] Agent 定义落盘失败 @\(user.username): \(error.localizedDescription)", level: .warn)
            }
        }
    }

    /// 从磁盘加载持久化的 agent 定义
    private func loadPersistedAgentDefs() async -> [AgentDef]? {
        guard let data = try? await helperClient.readFile(
            username: user.username,
            relativePath: ".openclaw/workspace/pending_v2_agent_defs.json"
        ) else { return nil }
        return try? JSONDecoder().decode([AgentDef].self, from: data)
    }

    /// 从磁盘加载持久化的团队 DNA
    private func loadPersistedTeamDNA() async -> TeamDNA? {
        guard let data = try? await helperClient.readFile(
            username: user.username,
            relativePath: ".openclaw/workspace/pending_v2_team.json"
        ) else { return nil }
        return try? JSONDecoder().decode(TeamDNA.self, from: data)
    }

    /// app 重启后自动检测系统状态，跳过已完成的步骤
    private func autoResumeIfNeeded() async {
        // 有 initialRoles.teamDNA 说明是首次领养流程，由 hydrateInitialRolesIfNeeded 处理
        guard initialRoles.teamDNA == nil else { return }
        // 注意：不检查 agents.isEmpty——onAppear 的同步 solo 预填会先于此 task 执行，
        // 导致 agents 非空，从而误跳过磁盘恢复（二次进入时丢失多 Agent 的 bug）。
        // 只要用户未在本次会话中明确选定团队，就继续尝试从磁盘恢复。
        guard selectedTeamDNA == nil else { return }

        let persistedState = InitWizardState.from(json: await helperClient.loadInitState(username: user.username))
        let persistedV2Step = v2PersistedStep(from: persistedState)
        let persistedEngine = v2PersistedEngine(from: persistedState)

        let openclawVersion = await helperClient.getOpenclawVersion(username: user.username)
        let hermesVersion = await helperClient.getHermesVersion(username: user.username)
        if selectedEngine == nil {
            if let persistedEngine {
                selectedEngine = persistedEngine
            } else if let persistedV2Step, activeSteps(for: .openclaw).contains(persistedV2Step), persistedV2Step != .selectEngine && persistedV2Step != .basicEnv {
                selectedEngine = .openclaw
            } else if openclawVersion != nil {
                selectedEngine = .openclaw
            } else if hermesVersion != nil {
                selectedEngine = .hermes
            }
        }

        if selectedEngine == .openclaw {
            ensureOpenclawRolesSeeded()
        }

        // 尝试从磁盘恢复团队 DNA
        let restoredTeamDNA = await loadPersistedTeamDNA()
        if let teamDNA = restoredTeamDNA {
            selectedEngine = .openclaw
            applyTeamTemplate(teamDNA)
        }

        // 恢复持久化的 agent 定义（含模型选择）
        if let savedAgents = await loadPersistedAgentDefs(), !savedAgents.isEmpty {
            if restoredTeamDNA != nil {
                // 有团队 DNA：applyTeamTemplate 已建好结构，仅覆盖模型选择
                for saved in savedAgents {
                    if let idx = agents.firstIndex(where: { $0.id == saved.id }) {
                        agents[idx].modelPrimary = saved.modelPrimary
                        agents[idx].modelFallbacks = saved.modelFallbacks
                    }
                }
            } else {
                // 无团队 DNA（可能是手动添加的多 Agent）：直接整体恢复
                agents = savedAgents
            }
        }

        // 检测基础环境状态
        let engine = selectedEngine ?? .openclaw
        let isEnvReady: Bool
        if engine == .hermes {
            let gatewayStatus = await helperClient.getHermesGatewayStatus(username: user.username)
            isEnvReady = hermesVersion != nil && gatewayStatus.running
        } else {
            let gatewayStatus = try? await helperClient.getGatewayStatus(username: user.username)
            isEnvReady = openclawVersion != nil && (gatewayStatus?.running == true)
        }

        if isEnvReady, engine == .openclaw {
            envReady = true
            // 建立 GatewayHub WebSocket 连接（需要包含 token）
            let url = await helperClient.getGatewayURL(username: user.username)
            if !url.isEmpty, url.contains("#token=") {
                await gatewayHub.connect(username: user.username, gatewayURL: url)
            }
        } else {
            envReady = isEnvReady
        }

        if let persistedV2Step,
           let engine = selectedEngine,
           activeSteps(for: engine).contains(persistedV2Step) {
            visitedSteps = Set(activeSteps(for: engine).filter { $0.rawValue <= persistedV2Step.rawValue })
            currentStep = persistedV2Step
            return
        }

        // 跳到第一个未完成的步骤
        if engine == .hermes {
            if isEnvReady {
                // 环境就绪后停留在 hermesSetup 步骤，由用户完成 `hermes setup` 交互式配置
                // 后再 advance 到 done；自动跳到 done 会绕过模型/密钥配置直接落盘 profile
                visitedSteps = [.selectEngine, .basicEnv, .hermesSetup]
                currentStep = .hermesSetup
            } else {
                visitedSteps = [.selectEngine, .basicEnv]
                currentStep = .basicEnv
            }
        } else if isEnvReady && !agents.isEmpty {
            visitedSteps = [.selectEngine, .basicEnv, .configModel]
            currentStep = .configModel
        } else if selectedEngine == .openclaw && !agents.isEmpty {
            // 仅在引擎已明确检测到时才跳过引擎选择；新用户预填的 solo agent 不应触发此跳转
            visitedSteps = [.selectEngine, .basicEnv]
            currentStep = .basicEnv
        } else if isEnvReady {
            // 环境已就绪但没有团队 DNA（可能是手动创建的用户）
            visitedSteps = [.selectEngine, .basicEnv]
            currentStep = .basicEnv
        }
    }

    private func v2PersistedStep(from state: InitWizardState?) -> WizardV2Step? {
        guard let state, !state.isCompleted, state.active else { return nil }
        if let step = WizardV2Step.fromPersistenceKey(state.currentStep) {
            return step == .done ? nil : step
        }
        for step in WizardV2Step.allCases {
            if state.steps["v2_\(step.persistenceKey)"] == "running" {
                return step == .done ? nil : step
            }
        }
        return nil
    }

    private func v2PersistedEngine(from state: InitWizardState?) -> WizardEngine? {
        guard let state, !state.isCompleted, state.active else { return nil }
        guard let raw = state.steps["v2_engine"] else { return nil }
        return WizardEngine(rawValue: raw)
    }

    private func activeSteps(for engine: WizardEngine) -> [WizardV2Step] {
        switch engine {
        case .hermes:
            return [.selectEngine, .basicEnv, .hermesSetup, .done]
        case .openclaw:
            return [.selectEngine, .basicEnv, .configModel, .configAgents, .configIM, .done]
        }
    }
}

// MARK: - Role picker sheet (wizard-internal)

private struct RolePickerSheet: View {
    var onPick: (AgentDNA) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WizardRoleMarketWebView(onPick: { dna in
                onPick(dna)
                dismiss()
            })
            .navigationTitle(L10n.k("wizard_v2.agents.role_picker.title", fallback: "选择角色"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 500)
    }
}

private struct WizardRoleMarketWebView: NSViewRepresentable {
    var onPick: (AgentDNA) -> Void

    func makeCoordinator() -> RoleMarketCoordinator {
        let c = RoleMarketCoordinator()
        c.onAdoptAgent = { dna in
            DispatchQueue.main.async { self.onPick(dna) }
        }
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = makeRoleMarketConfiguration(
            coordinator: context.coordinator,
            localeIdentifier: Locale.current.identifier
        )
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "roles", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
