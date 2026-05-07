// ClawdHome/Views/WizardV2/ShrimpInitWizardV2.swift
// Shrimp 初始化向导 v2（6 步，支持跳过 IM/模型配置）
//
// 步骤：
// 1. selectTemplate  —— 选择模式：Solo Agent / 团队模板
// 2. basicEnv        —— 安装 Node.js + OpenClaw（与 v1 复用）
// 3. configModel     —— 模型选择（可跳过，沿用全局配置）
// 4. configAgents    —— Agent 列表配置（名称/ID/角色）
// 5. configIM        —— 为每个 agent 绑定 IM Bot（可跳过）
// 6. done            —— 完成摘要
//
// 入口替换：直接从 UserListView / AdoptTeamSheet 跳入本 Wizard

import SwiftUI
import WebKit

// MARK: - AddBotTarget (sheet(item:) wrapper)

private struct AddBotTarget: Identifiable {
    let id = UUID()
    let agentId: String
}

// MARK: - Step Enum

enum WizardV2Step: Int, CaseIterable {
    case selectTemplate
    case basicEnv
    case configModel
    case configAgents
    case configIM
    case done

    var title: String {
        switch self {
        case .selectTemplate: return L10n.k("wizard_v2.step.select_template", fallback: "选择模式")
        case .basicEnv:       return L10n.k("wizard_v2.step.basic_env", fallback: "基础环境")
        case .configModel:    return L10n.k("wizard_v2.step.model", fallback: "模型配置")
        case .configAgents:   return L10n.k("wizard_v2.step.agents", fallback: "Agent 配置")
        case .configIM:       return L10n.k("wizard_v2.step.im", fallback: "IM 绑定")
        case .done:           return L10n.k("wizard_v2.step.done", fallback: "完成")
        }
    }

    var icon: String {
        switch self {
        case .selectTemplate: return "rectangle.3.group"
        case .basicEnv:       return "wrench.and.screwdriver"
        case .configModel:    return "cpu"
        case .configAgents:   return "person.2"
        case .configIM:       return "qrcode.viewfinder"
        case .done:           return "checkmark.seal"
        }
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

// MARK: - Main Wizard

struct ShrimpInitWizardV2: View {
    let user: ManagedUser
    var initialTeamDNA: TeamDNA? = nil
    var onDismiss: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(\.dismiss) private var dismiss

    // Navigation
    @State private var currentStep: WizardV2Step = .selectTemplate
    @State private var visitedSteps: Set<WizardV2Step> = [.selectTemplate]

    // Step 1: 从 roles.html 选团队（或单人）
    // 选完团队后 teamDNA 非 nil，agents 和 agentDNAs 已填充
    @State private var selectedTeamDNA: TeamDNA? = nil      // nil = 未选团队（solo 也是 nil，agents 手动设置）
    @State private var templateReady = false                 // 至少选了一种模式才能下一步
    @State private var didAutoAdvanceFromInitialTemplate = false

    // Step 2: basicEnv (delegates to existing init flow)
    @State private var envReady = false
    @State private var envError: String?
    @State private var isInstallingEnv = false
    @State private var envInstallingPhase: WizardV2BasicEnvPhase?
    @State private var didClearInitialEnvLog = false
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue

    // Step 4: agents
    @State private var agents: [AgentDef] = []
    @State private var agentDNAs: [String: AgentDNA] = [:]           // key = AgentDef.id
    @State private var agentModelCandidates: [String] = []

    // Step 5: IM bindings
    @State private var imAccounts: [IMAccount] = []
    @State private var bindings: [IMBinding] = []
    @State private var addBotTarget: AddBotTarget? = nil  // non-nil 时弹出 AddBotSheet

    // Step 6: done
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    // 取消确认
    @State private var showCancelConfirm = false

    /// 有未保存的配置数据（团队选择、agent 定义、IM 绑定）
    private var hasDirtyState: Bool {
        guard !saveSuccess else { return false }
        return selectedTeamDNA != nil || !agents.isEmpty || !imAccounts.isEmpty || !bindings.isEmpty
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
                            onDismiss?()
                            dismiss()
                        }
                    }
                }
            }
            .confirmationDialog(
                L10n.k("wizard_v2.cancel_confirm.title", fallback: "放弃初始化？"),
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.k("wizard_v2.cancel_confirm.discard", fallback: "放弃"), role: .destructive) {
                    onDismiss?()
                    dismiss()
                }
                Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
            } message: {
                Text(L10n.k("wizard_v2.cancel_confirm.message", fallback: "已配置的 Agent 和 IM 设置将不会保存"))
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            hydrateInitialTemplateIfNeeded()
        }
        .task {
            await autoResumeIfNeeded()
        }
        .onChange(of: initialTeamDNA?.id ?? "") { _, _ in
            hydrateInitialTemplateIfNeeded()
        }
    }

    // MARK: - Sidebar

    private var stepSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WizardV2Step.allCases, id: \.rawValue) { step in
                sidebarRow(step: step)
            }
            Spacer()
        }
        .frame(width: 180)
        .padding(.top, 20)
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
        case .selectTemplate: selectTemplateView
        case .basicEnv:       basicEnvView
        case .configModel:    configModelView
        case .configAgents:   configAgentsView
        case .configIM:       configIMView
        case .done:           doneView
        }
    }

    // MARK: - Step 1: select template（从 roles.html 团队选择）

    private var selectTemplateView: some View {
        VStack(spacing: 0) {
            // 已选团队摘要（选完后显示）
            if let team = selectedTeamDNA {
                HStack(spacing: 10) {
                    Text(team.teamEmoji).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(team.teamName).fontWeight(.semibold)
                        Text(L10n.k("wizard_v2.select_template.selected_hint",
                                    fallback: "\(team.members.count) 个 Agent 已就绪，可点下一步继续"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.k("wizard_v2.select_template.reselect", fallback: "重新选择")) {
                        selectedTeamDNA = nil
                        templateReady = false
                        agents = []
                        agentDNAs = [:]
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.06))
                Divider()
            }

            // roles.html WebView（显示团队 Tab）
            TemplateMarketWebView(
                showTeamsOnly: selectedTeamDNA == nil,
                onPickTeam: { teamDNA in
                    applyTeamTemplate(teamDNA)
                },
                onPickSolo: {
                    selectedTeamDNA = nil
                    templateReady = true
                    agents = [AgentDef(id: "main", displayName: "主 Agent", isDefault: true)]
                    agentDNAs = [:]
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button(L10n.k("common.next", fallback: "下一步")) { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!templateReady)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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

        // gateway 已配置的完整模型列表（来自 RPC，唯一源）
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

    private var basicEnvView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            Text(L10n.k("wizard_v2.basic_env.heading", fallback: "安装基础运行环境"))
                .font(.title2).fontWeight(.semibold)
                .padding(.bottom, 12)

            // 操作按钮 + 阶段进度条
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

            // 安装日志（自适应填满剩余空间）
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.k("wizard_v2.basic_env.logs", fallback: "安装日志"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                TerminalLogPanel(username: user.username, logHeight: nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 底部导航（固定）
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

    // MARK: - Step 3: configModel

    private var configModelView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ProviderModelConfigCore(user: user) { _ in
                    advance()
                }

                Button(L10n.k("wizard.model_config.skip", fallback: "稍后配置")) {
                    advance()
                }
                .buttonStyle(.bordered)
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(agents) { agent in
                        agentIMSection(agent: agent)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()
            navigationButtons(canGoNext: true, nextLabel: L10n.k("wizard_v2.im.skip_or_next", fallback: "跳过 / 下一步")) {
                advance()
            }
        }
        .padding(24)
        .sheet(item: $addBotTarget) { target in
            AddBotSheet(username: user.username, agentId: target.agentId) { newAccount in
                if !imAccounts.contains(where: { $0.id == newAccount.id && $0.platform == newAccount.platform }) {
                    imAccounts.append(newAccount)
                }
                // 使用 sheet 打开时捕获的 agentId，避免异步竞态
                let binding = IMBinding(
                    agentId: target.agentId,
                    channel: newAccount.platform.openclawChannelId,
                    accountId: newAccount.id
                )
                bindings.append(binding)
            }
        }
    }

    private func agentIMSection(agent: AgentDef) -> some View {
        let agentBindings = bindings.filter { $0.agentId == agent.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(agent.displayName)
                    .fontWeight(.semibold)
                if agent.isDefault {
                    Text(L10n.k("agents.default_badge", fallback: "默认"))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Button(action: {
                    addBotTarget = AddBotTarget(agentId: agent.id)
                }) {
                    Label(L10n.k("wizard_v2.im.add_bot", fallback: "绑定 Bot"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if agentBindings.isEmpty {
                Text(L10n.k("wizard_v2.im.no_binding", fallback: "可选，主 Agent 调度时不需要绑定"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(agentBindings) { binding in
                    let account = imAccounts.first { $0.id == binding.accountId }
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                        Text("\(account?.platform.displayName ?? binding.channel) · \(account?.displayName ?? binding.accountId ?? "通配")")
                            .font(.caption)
                        Spacer()
                        Button(action: {
                            bindings.removeAll { $0.id == binding.id }
                        }) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 6: done

    private var doneView: some View {
        VStack(spacing: 20) {
            if isSaving {
                ProgressView()
                    .scaleEffect(1.4)
                Text(L10n.k("wizard_v2.done.saving", fallback: "正在写入配置…"))
                    .foregroundStyle(.secondary)
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

    private var summaryText: String {
        let agentCount = agents.count
        let botCount = imAccounts.count
        return L10n.k("wizard_v2.done.summary",
                      fallback: "\(agentCount) 个 Agent，\(botCount) 个 IM Bot 绑定")
    }

    // MARK: - Navigation helpers

    private func navigationButtons(
        canGoNext: Bool,
        nextLabel: String = L10n.k("common.next", fallback: "下一步"),
        nextAction: @escaping () -> Void
    ) -> some View {
        HStack {
            if currentStep.rawValue > 0 {
                Button(L10n.k("common.back", fallback: "上一步")) {
                    if let prev = WizardV2Step(rawValue: currentStep.rawValue - 1) {
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

    private func advance() {
        let nextRaw = currentStep.rawValue + 1
        guard let next = WizardV2Step(rawValue: nextRaw) else { return }
        visitedSteps.insert(next)
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = next
        }
        persistV2Progress()
    }

    private func applyTeamTemplate(_ teamDNA: TeamDNA) {
        selectedTeamDNA = teamDNA
        templateReady = true
        persistTeamDNA(teamDNA)
        guard !teamDNA.members.isEmpty else {
            agents = [AgentDef(id: "main", displayName: "主 Agent", isDefault: true)]
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

    private func hydrateInitialTemplateIfNeeded() {
        guard let initialTeamDNA else { return }
        guard selectedTeamDNA == nil, agents.isEmpty else { return }
        applyTeamTemplate(initialTeamDNA)
        guard !didAutoAdvanceFromInitialTemplate else { return }
        didAutoAdvanceFromInitialTemplate = true
        visitedSteps.insert(.basicEnv)
        currentStep = .basicEnv
    }

    // MARK: - Business logic

    private func checkEnvReady() {
        Task {
            let version = await helperClient.getOpenclawVersion(username: user.username)
            let gatewayStatus = try? await helperClient.getGatewayStatus(username: user.username)
            await MainActor.run {
                envReady = version != nil && (gatewayStatus?.running == true)
            }
        }
    }

    private func clearInitialEnvLogIfNeeded() {
        guard !didClearInitialEnvLog else { return }
        guard !isInstallingEnv else { return }
        let logPath = "/tmp/clawdhome-init-\(user.username).log"
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        didClearInitialEnvLog = true
    }

    private func runEnvInstall() {
        guard !isInstallingEnv else { return }
        isInstallingEnv = true
        envError = nil
        envInstallingPhase = .repairHomebrew
        // 截断上次遗留的日志文件，让终端面板从空白开始
        let logPath = "/tmp/clawdhome-init-\(user.username).log"
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
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
                envReady = true
            } catch {
                let phaseTitle = envInstallingPhase?.title
                    ?? L10n.k("wizard_v2.basic_env.heading", fallback: "安装基础运行环境")
                isInstallingEnv = false
                envInstallingPhase = nil
                envError = "\(phaseTitle)失败：\(error.localizedDescription)"
            }
        }
    }

    private func runSave() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil

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
            let configJSON: String
            do {
                let data = try JSONEncoder().encode(config)
                configJSON = String(data: data, encoding: .utf8) ?? "{}"
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "配置序列化失败：\(error.localizedDescription)"
                }
                return
            }

            // 2. 通过 XPC 写入 openclaw.json（applyV2Config 在 Helper 侧调用 OpenclawConfigSerializerV2）
            let (ok, err) = await helperClient.applyV2Config(username: username, configJSON: configJSON)
            guard ok else {
                await MainActor.run {
                    isSaving = false
                    saveError = err ?? "写入配置失败"
                }
                return
            }

            // 3. 把 agentId → DNA 映射写入 pending_v2_agents.json，供 gateway ready 后消费
            //    格式：[{"agentDefId": "main", "dna": {...}}]
            //    gateway 启动后 UserDetailView.consumePendingV2Agents() 会找到对应 profile 写 persona 文件
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
                        saveError = "Agent 角色写入失败：\(error.localizedDescription)"
                    }
                    return
                }
            }

            // 4. 重启 gateway，使新写入的 openclaw.json 生效，并触发 UserDetailView
            //    的 consumePendingV2Agents()（由 readinessMap == .ready 的 onChange 触发）
            try? await helperClient.restartGateway(username: username)

            // 5. 标记向导已完成，清理临时文件
            var doneState = InitWizardState()
            doneState.active = false
            doneState.completedAt = Date()
            doneState.updatedAt = Date()
            doneState.currentStep = "v2:done"
            try? await helperClient.saveInitState(username: username, json: doneState.toJSON())
            try? await helperClient.writeFile(
                username: username,
                relativePath: ".openclaw/workspace/pending_v2_team.json",
                data: "{}".data(using: .utf8) ?? Data()
            )

            await MainActor.run {
                isSaving = false
                saveSuccess = true
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
            state.currentStep = "v2:\(currentStep)"
            state.updatedAt = Date()
            for s in WizardV2Step.allCases where s.rawValue < currentStep.rawValue {
                state.steps["v2_\(s)"] = "done"
            }
            state.steps["v2_\(currentStep)"] = "running"
            try? await helperClient.saveInitState(username: user.username, json: state.toJSON())
        }
    }

    /// 将团队 DNA 写入用户 workspace，供重启后恢复
    private func persistTeamDNA(_ teamDNA: TeamDNA) {
        Task {
            guard let data = try? JSONEncoder().encode(teamDNA) else { return }
            try? await helperClient.createDirectory(username: user.username, relativePath: ".openclaw/workspace")
            try? await helperClient.writeFile(
                username: user.username,
                relativePath: ".openclaw/workspace/pending_v2_team.json",
                data: data
            )
        }
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
        // 有 initialTeamDNA 说明是首次领养流程，由 hydrateInitialTemplateIfNeeded 处理
        guard initialTeamDNA == nil else { return }
        guard selectedTeamDNA == nil, agents.isEmpty else { return }

        // 尝试从磁盘恢复团队 DNA
        if let teamDNA = await loadPersistedTeamDNA() {
            applyTeamTemplate(teamDNA)
        }

        // 检测基础环境状态
        let version = await helperClient.getOpenclawVersion(username: user.username)
        let gatewayStatus = try? await helperClient.getGatewayStatus(username: user.username)
        let isEnvReady = version != nil && (gatewayStatus?.running == true)

        if isEnvReady {
            envReady = true
            // 建立 GatewayHub WebSocket 连接（需要包含 token）
            let url = await helperClient.getGatewayURL(username: user.username)
            if !url.isEmpty, url.contains("#token=") {
                await gatewayHub.connect(username: user.username, gatewayURL: url)
            }
        }

        // 跳到第一个未完成的步骤
        if isEnvReady && templateReady {
            visitedSteps = Set(WizardV2Step.allCases.filter { $0.rawValue <= WizardV2Step.configModel.rawValue })
            currentStep = .configModel
        } else if templateReady {
            visitedSteps = [.selectTemplate, .basicEnv]
            currentStep = .basicEnv
        } else if isEnvReady {
            // 环境已就绪但没有团队 DNA（可能是手动创建的用户）
            visitedSteps = [.selectTemplate, .basicEnv]
            currentStep = .basicEnv
        }
    }
}

// MARK: - Template market WebView（Step 1 嵌入，展示 roles.html 团队+单人选项）

private struct TemplateMarketWebView: NSViewRepresentable {
    var showTeamsOnly: Bool
    var onPickTeam: (TeamDNA) -> Void
    var onPickSolo: () -> Void

    func makeCoordinator() -> RoleMarketCoordinator {
        let c = RoleMarketCoordinator()
        c.onAdoptTeam = { teamDNA in
            DispatchQueue.main.async { self.onPickTeam(teamDNA) }
        }
        c.onAdoptAgent = { dna in
            // 单角色领养：用单 agent 填充 solo 模式
            let soloTeam = TeamDNA(
                id: dna.id,
                teamName: dna.name,
                teamEmoji: dna.emoji,
                suggestedInstanceID: dna.suggestedAgentID ?? "main",
                members: [dna]
            )
            DispatchQueue.main.async { self.onPickTeam(soloTeam) }
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
