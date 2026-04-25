// ClawdHome/Views/ModelConfigWizard.swift
// 统一模型配置向导：模型池管理 + 添加/编辑模型 + Provider 配置 + RPC 执行

import SwiftUI

// MARK: - 主视图（Overview）

struct ModelConfigWizard: View {
    let user: ManagedUser
    var embedded: Bool = false
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub

    @State private var currentDefault: String? = nil
    @State private var currentFallbacks: [String] = []
    @State private var isLoadingStatus = true
    @State private var dynamicModelGroups: [ModelGroup]? = nil

    // Sheet 状态
    @State private var showAddModel = false
    @State private var isSavingOrder = false
    @State private var editingModel: String? = nil  // 非 nil 时弹出编辑 sheet


    /// 模型池 = 主模型 + 备用模型
    private var modelPool: [String] {
        var pool: [String] = []
        if let d = currentDefault { pool.append(d) }
        pool.append(contentsOf: currentFallbacks)
        return pool
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { titleBar }

            if embedded {
                // ── Embedded 模式：固定 header + 内容区 + 固定 footer ──
                embeddedHeader
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isLoadingStatus {
                    Spacer()
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text(L10n.k("auto.model_config_wizard.loading", fallback: "加载中…"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else if modelPool.isEmpty {
                    // ── 空状态：居中引导 ──
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(L10n.k("auto.model_config_wizard.no_models_yet", fallback: "还没有配置模型"))
                            .font(.callout).foregroundStyle(.secondary)
                        Text(L10n.k("auto.model_config_wizard.add_model_cta_hint", fallback: "添加 AI 模型以启用对话能力"))
                            .font(.caption).foregroundStyle(.tertiary)
                        Button {
                            showAddModel = true
                        } label: {
                            Label(L10n.k("model.config.add_model", fallback: "添加模型"), systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    // ── 有模型：列表 + 操作按钮 ──
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            modelListView
                            actionButtons
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                }

                Divider()
                embeddedFooter
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                // ── 独立窗口模式（从详情页打开） ──
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modelPoolSection
                        actionButtons
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: embedded ? nil : 480)
        .task { await loadStatus() }
        .sheet(isPresented: $showAddModel) {
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.k("model.config.add_model", fallback: "添加模型"))
                        .font(.headline)
                    Spacer()
                    Button(L10n.k("auto.model_config_wizard.cancel", fallback: "取消")) {
                        showAddModel = false
                    }
                    .keyboardShortcut(.escape)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
                ScrollView {
                    ProviderModelConfigCore(user: user) { _ in
                        showAddModel = false
                        Task { await loadStatus() }
                    }
                    .padding(16)
                }
            }
            .frame(width: 460, height: 500)
        }
        .sheet(item: editingModelBinding) { item in
            ModelEditSheet(
                user: user,
                modelId: item.id,
                isPrimary: item.id == currentDefault,
                currentDefault: currentDefault,
                currentFallbacks: currentFallbacks
            ) {
                Task { await loadStatus() }
            }
            .environment(helperClient)
            .environment(gatewayHub)
        }
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var titleBar: some View {
        HStack {
            Text(L10n.k("auto.model_config_wizard.model_configuration", fallback: "模型配置"))
                .font(.headline)
            Spacer()
            Button(L10n.k("auto.model_config_wizard.done", fallback: "完成")) { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        Divider()
    }

    // MARK: - Embedded Header/Footer (for init wizard)

    @ViewBuilder
    private var embeddedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.k("auto.model_config_wizard.model_configuration", fallback: "模型配置"), systemImage: "cpu")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(L10n.k("auto.model_config_wizard.ai_models_models", fallback: "添加要使用的 AI 模型，最后添加的自动成为主模型。"))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var embeddedFooter: some View {
        HStack(spacing: 12) {
            Button(L10n.k("common.next", fallback: "下一步")) {
                onDone?()
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentDefault == nil)

            Button(L10n.k("wizard.model_config.skip_step", fallback: "跳过")) {
                onDone?()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model Pool Section

    /// 独立窗口模式：含加载/空/列表三态
    @ViewBuilder
    private var modelPoolSection: some View {
        if isLoadingStatus {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text(L10n.k("auto.model_config_wizard.loading", fallback: "加载中…")).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if modelPool.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text(L10n.k("auto.model_config_wizard.no_models_yet", fallback: "还没有配置模型"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.k("auto.model_config_wizard.modelsconfiguration", fallback: "点击下方「添加模型」开始配置"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            modelListView
        }
    }

    /// 模型列表（支持拖动排序）
    @ViewBuilder
    private var modelListView: some View {
        List {
            ForEach(Array(modelPool.enumerated()), id: \.element) { idx, modelId in
                modelRow(modelId: modelId, index: idx)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            .onMove(perform: moveModelInPool)
        }
        .listStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: CGFloat(modelPool.count * 52))
    }

    @ViewBuilder
    private func modelRow(modelId: String, index: Int) -> some View {
        let label = builtInModelGroups.flatMap(\.models)
            .first { $0.id == modelId }?.label ?? modelId
        let isPrimary = modelId == currentDefault

        HStack(spacing: 10) {
            if isPrimary {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .frame(width: 20)
            } else {
                Text("②③④⑤⑥⑦⑧⑨⑩".map(String.init)[safe: index - 1] ?? "\(index)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.callout)
                Text(modelId)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isPrimary ? L10n.k("model.config.primary", fallback: "主模型") : L10n.f("model.config.fallback_index", fallback: "备用 %@", String(index)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { editingModel = modelId }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if embedded {
                Button {
                    showAddModel = true
                } label: {
                    Label(L10n.k("model.config.add_model", fallback: "添加模型"), systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    showAddModel = true
                } label: {
                    Label(L10n.k("model.config.add_model", fallback: "添加模型"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button {
                Task { await loadStatus() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.k("auto.model_config_wizard.refresh", fallback: "刷新"))
        }
    }

    // MARK: - Data Loading

    private func loadStatus() async {
        isLoadingStatus = true
        async let statusTask = helperClient.getModelsStatus(username: user.username)
        async let modelsTask = gatewayHub.modelsList(username: user.username)
        let (status, models) = await (statusTask, modelsTask)
        if let status {
            currentDefault = status.resolvedDefault ?? status.defaultModel
            currentFallbacks = status.fallbacks
        }
        if let models {
            dynamicModelGroups = models
        }
        isLoadingStatus = false
    }

    // MARK: - 拖动排序

    private func moveModelInPool(from source: IndexSet, to destination: Int) {
        var pool = modelPool
        pool.move(fromOffsets: source, toOffset: destination)
        currentDefault = pool.first
        currentFallbacks = Array(pool.dropFirst())
        Task { await saveModelOrder() }
    }

    private func saveModelOrder() async {
        guard let primary = currentDefault else { return }
        isSavingOrder = true
        defer { isSavingOrder = false }

        var modelPatch: [String: Any] = ["primary": primary]
        if !currentFallbacks.isEmpty {
            modelPatch["fallbacks"] = currentFallbacks
        }

        do {
            let (_, baseHash) = try await gatewayHub.configGetFull(username: user.username)
            try await gatewayHub.configPatch(
                username: user.username,
                patch: ["agents": ["defaults": ["model": modelPatch]]],
                baseHash: baseHash,
                note: "ClawdHome: reorder model priority"
            )
        } catch {
            // Gateway 未连接时回退到直写
            try? await helperClient.setConfigDirectJSON(
                username: user.username,
                path: "agents.defaults.model",
                valueJSON: (try? JSONSerialization.data(withJSONObject: modelPatch))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            )
        }
    }

    // MARK: - Helpers

    private var editingModelBinding: Binding<ModelIdentifier?> {
        Binding(
            get: { editingModel.map { ModelIdentifier(id: $0) } },
            set: { editingModel = $0?.id }
        )
    }
}

// MARK: - Identifiable wrapper for sheet(item:)

private struct ModelIdentifier: Identifiable {
    let id: String
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 添加模型 Sheet

struct ModelAddSheet: View {
    let user: ManagedUser
    let currentDefault: String?
    let currentFallbacks: [String]
    let dynamicModelGroups: [ModelGroup]?
    var onComplete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(GlobalModelStore.self) private var modelStore

    enum Step { case selectModel, providerSetup, executing, result }
    enum ConfigSource: String, CaseIterable, Identifiable {
        case existing
        case new

        var id: String { rawValue }
        var title: String {
            switch self {
            case .existing: return L10n.k("wizard.model_config.source.existing", fallback: "已有配置")
            case .new: return L10n.k("wizard.model_config.source.new", fallback: "新增配置")
            }
        }
    }
    enum CustomCompatibility: String, CaseIterable, Identifiable {
        case openai
        case anthropic

        var id: String { rawValue }
        var apiType: String {
            switch self {
            case .openai: return "openai-completions"
            case .anthropic: return "anthropic-messages"
            }
        }

        var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Anthropic"
            }
        }
    }

    enum CustomAuthChoice: String, CaseIterable, Identifiable {
        case customAPIKey
        case secretReference

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .customAPIKey: return L10n.k("views.model_config_wizard.auth_paste_key", fallback: "粘贴 API Key")
            case .secretReference: return L10n.k("views.model_config_wizard.auth_secret_ref", fallback: "使用 Secret Reference")
            }
        }
    }

    struct CustomProviderConfigInput {
        var baseUrl: String
        var modelId: String
        var providerId: String?
        var compatibility: CustomCompatibility
    }

    @State private var step: Step = .selectModel

    // Step 1: Select
    @State private var configSource: ConfigSource = .new
    @State private var selectedTemplateID: UUID? = nil
    @State private var selectedTemplateModelID: String = ""
    @State private var filter = ""
    @State private var selectedModel = ""
    @State private var useCustom = false
    @State private var customProviderId = ""
    @State private var customModelId = ""
    @State private var customBaseURL = ""
    @State private var customCompatibility: CustomCompatibility = .openai
    @State private var customProviderInput = CustomProviderConfigInput(baseUrl: "", modelId: "", providerId: nil, compatibility: .openai)

    // Step 2: Provider
    @State private var providerConfig: ProviderKeyConfig? = nil
    @State private var apiKeyInput = ""
    @State private var secretReferenceInput = ""
    @State private var customAuthChoice: CustomAuthChoice = .customAPIKey
    @State private var sideValues: [String: String] = [:]  // sideConfig key → value
    @State private var providerReady = false  // API key already configured
    @State private var isCheckingProvider = false
    @State private var isCustomProvider = false  // 未知 provider → OpenAI 兼容模式
    @State private var providerErrorMsg = ""
    @State private var showAdvancedSide = false  // 已知 provider 的高级设置折叠状态

    // Step 3: Executing
    @State private var commands: [CommandRun] = []
    @State private var executionDone = false

    // Step 4: Result
    @State private var allSuccess = true

    private var resolvedCustomProviderId: String {
        customProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveCustomProviderId: String {
        let v = resolvedCustomProviderId
        return v.isEmpty ? "custom" : v
    }

    private var resolvedCustomModelId: String {
        customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var chosenModel: String {
        if usingExistingTemplate {
            return selectedTemplateModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if useCustom {
            guard !resolvedCustomModelId.isEmpty else { return "" }
            return "\(effectiveCustomProviderId)/\(resolvedCustomModelId)"
        }
        return selectedModel
    }

    private var activeModelGroups: [ModelGroup] {
        dynamicModelGroups ?? builtInModelGroups
    }

    private var availableTemplates: [ProviderTemplate] {
        modelStore.providers.filter { !$0.modelIds.isEmpty }
    }

    private var selectedTemplate: ProviderTemplate? {
        if let id = selectedTemplateID,
           let matched = availableTemplates.first(where: { $0.id == id }) {
            return matched
        }
        return availableTemplates.first
    }

    private var usingExistingTemplate: Bool {
        configSource == .existing && !availableTemplates.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            addSheetTitleBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case .selectModel:   selectModelView
                    case .providerSetup: providerSetupView
                    case .executing:     executingView
                    case .result:        resultView
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 500)
        .onAppear {
            syncTemplateSelection()
        }
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var addSheetTitleBar: some View {
        HStack {
            Text(L10n.k("model.config.add_model", fallback: "添加模型"))
                .font(.headline)
            Spacer()
            switch step {
            case .selectModel, .providerSetup:
                Button(L10n.k("auto.model_config_wizard.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.escape)
            case .executing:
                EmptyView()
            case .result:
                Button(L10n.k("auto.model_config_wizard.done", fallback: "完成")) {
                    onComplete?()
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Step 1: Select Model

    @ViewBuilder
    private var selectModelView: some View {
        if modelStore.hasTemplate {
            Picker(L10n.k("wizard.model_config.source", fallback: "配置来源"), selection: $configSource) {
                ForEach(ConfigSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: configSource) { _, _ in
                syncTemplateSelection()
            }
        }

        if usingExistingTemplate {
            existingTemplateSelector
        } else {
            HStack(spacing: 8) {
                if useCustom {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.k("wizard.model_config.custom_provider_id_placeholder", fallback: "providerId (可选 custom-provider-id)"), text: $customProviderId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        TextField("modelId (custom-model-id)", text: $customModelId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.k("auto.model_config_wizard.searchmodels", fallback: "搜索模型…"), text: $filter)
                        .textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                        }.buttonStyle(.plain)
                    }
                }
                Button(useCustom ? L10n.k("auto.model_config_wizard.choose_from_list", fallback: "从清单选") : L10n.k("auto.model_config_wizard.input", fallback: "手动输入")) {
                    useCustom.toggle()
                    filter = ""; selectedModel = ""
                }
                .buttonStyle(.bordered).font(.caption)
            }

            if useCustom {
                customModelGuidance
            } else {
                selectModelList
            }
        }

        HStack {
            if !chosenModel.isEmpty {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor).font(.caption)
                Text(chosenModel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L10n.k("auto.model_config_wizard.next", fallback: "下一步")) {
                Task { await checkProvider() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosenModel.isEmpty)
        }
    }

    @ViewBuilder
    private var existingTemplateSelector: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    L10n.k("wizard.model_config.existing_channel", fallback: "全局渠道"),
                    selection: Binding<UUID?>(
                        get: { selectedTemplate?.id },
                        set: { newValue in
                            selectedTemplateID = newValue
                            syncTemplateSelection()
                        }
                    )
                ) {
                    ForEach(availableTemplates) { template in
                        Text(template.displayNameWithAlias).tag(Optional(template.id))
                    }
                }
                .pickerStyle(.menu)

                if let template = selectedTemplate {
                    Picker(
                        L10n.k("wizard.model_config.existing_model", fallback: "模型"),
                        selection: $selectedTemplateModelID
                    ) {
                        ForEach(template.modelIds, id: \.self) { modelID in
                            Text(modelLabel(for: modelID)).tag(modelID)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedTemplateModelID) { _, newValue in
                        selectedModel = newValue
                    }

                    Text(L10n.k("wizard.model_config.existing_hint", fallback: "将复用该全局渠道的模型与凭据配置。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(L10n.k("views.model_picker_sheet.global_model_pool", fallback: "来自全局模型池"), systemImage: "tray.full")
                .font(.caption)
        }
    }

    /// 自定义模型输入提示
    @ViewBuilder
    private var customModelGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.k("auto.model_config_wizard.format_provider_model_id", fallback: "格式：provider/model-id"))
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                guidanceExample("anthropic/claude-opus-4-6", note: L10n.k("auto.model_config_wizard.provider", fallback: "直连 Provider"))
                guidanceExample("openrouter/deepseek/deepseek-r1", note: L10n.k("auto.model_config_wizard.openrouter", fallback: "经 OpenRouter 转发"))
                guidanceExample("groq/llama-3.3-70b-versatile", note: L10n.k("auto.model_config_wizard.openai_api", fallback: "OpenAI 兼容 API"))
                guidanceExample("ollama/qwen3:32b", note: L10n.k("auto.model_config_wizard.local_ollama", fallback: "本地 Ollama"))
            }
            Text(L10n.k("auto.model_config_wizard.unknown_provider_openai_configuration_base_url_api_key", fallback: "未知 provider 将进入 OpenAI 兼容配置，需填写 Base URL 和 API Key。"))
                .font(.caption2).foregroundStyle(.tertiary)
            Text(L10n.k("wizard.model_config.custom_compatibility_hint", fallback: "自定义支持 `openai` / `anthropic` 兼容类型；默认 `openai`。"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func guidanceExample(_ id: String, note: String) -> some View {
        HStack(spacing: 6) {
            Text(id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("— \(note)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var selectModelList: some View {
        let groups = filteredGroups(filter)
        let existingIds = Set(([currentDefault].compactMap { $0 }) + currentFallbacks)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Text(group.provider)
                        .font(.caption).foregroundStyle(.tertiary).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)

                    ForEach(group.models) { model in
                        let isExisting = existingIds.contains(model.id)
                        let isSelected = selectedModel == model.id
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.label)
                                    .font(.callout)
                                    .foregroundStyle(isExisting ? .secondary : .primary)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                Text(model.id)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isExisting {
                                Text(L10n.k("auto.model_config_wizard.added", fallback: "已添加")).font(.caption2).foregroundStyle(.tertiary)
                            } else if isSelected {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isExisting { selectedModel = model.id }
                        }
                        Divider().padding(.leading, 14)
                    }
                }
                if groups.isEmpty {
                    Text(L10n.k("model.config.no_matching_models", fallback: "无匹配模型")).font(.caption).foregroundStyle(.secondary).padding()
                }
            }
        }
        .frame(height: 190)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 2: Provider Setup

    @ViewBuilder
    private var providerSetupView: some View {
        if isCheckingProvider {
            HStack {
                ProgressView().scaleEffect(0.7)
                Text(L10n.k("auto.model_config_wizard.provider_configuration", fallback: "检查 Provider 配置…")).font(.callout).foregroundStyle(.secondary)
            }
        } else if providerReady && !isCustomProvider {
            providerReadyView
        } else if let config = providerConfig {
            providerInputForm(config)
        } else {
            providerReadyView
        }
    }

    @ViewBuilder
    private var providerReadyView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(L10n.k("auto.model_config_wizard.provider_configured", fallback: "Provider 已配置")).font(.callout)
        }
        Text(L10n.f("views.model_config_wizard.text_200224ab", fallback: "即将添加 %@ 为主模型。", String(describing: chosenModel)))
            .font(.caption).foregroundStyle(.secondary)
        if let old = currentDefault {
            Text(L10n.f("views.model_config_wizard.text_e15076fd", fallback: "当前主模型 %@ 将变为第一备用。", String(describing: old)))
                .font(.caption).foregroundStyle(.tertiary)
        }
        HStack {
            Button(L10n.k("auto.model_config_wizard.back", fallback: "返回")) { step = .selectModel }
                .buttonStyle(.bordered)
            Spacer()
            Button(L10n.k("auto.model_config_wizard.execute", fallback: "执行")) {
                // Provider 已配置，直接通过 configPatch 切换模型
                buildAndExecute(includeProviderConfig: false)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func providerInputForm(_ config: ProviderKeyConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                isCustomProvider
                    ? L10n.f("views.model_config_wizard.text_1dc29306", fallback: "%@ 配置", effectiveCustomProviderId)
                    : L10n.f("views.model_config_wizard.text_1dc29306", fallback: "%@ 配置", String(describing: config.displayName)),
                systemImage: isCustomProvider ? "link" : "key.fill"
            )
            .font(.subheadline).fontWeight(.semibold)
            .foregroundStyle(.secondary)

            if !providerErrorMsg.isEmpty {
                Text(providerErrorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if providerReady && isCustomProvider {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text(L10n.k("auto.model_config_wizard.configuration_configuration", fallback: "已配置，可直接添加或修改配置后添加")).font(.caption).foregroundStyle(.secondary)
                }
            }

            if isCustomProvider {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("wizard.model_config.api_protocol", fallback: "接口协议"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.k("wizard.model_config.api_protocol", fallback: "接口协议"), selection: $customCompatibility) {
                        ForEach(CustomCompatibility.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("wizard.model_config.auth_method", fallback: "认证方式"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.k("wizard.model_config.auth_method", fallback: "认证方式"), selection: $customAuthChoice) {
                        ForEach(CustomAuthChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // sideConfigs (baseUrl etc.; skip `.api` — auto-set, not user-editable)
            // 自定义 provider: Base URL 必填，直接展示；已知 provider: 预填默认值，折叠到高级设置
            if isCustomProvider {
                let baseUrlEntries = config.sideConfigs.compactMap { side -> (key: String, value: String)? in
                    guard case .string(let value) = side.value else { return nil }
                    guard !side.key.hasSuffix(".api") else { return nil }
                    return (side.key, value)
                }
                ForEach(baseUrlEntries, id: \.key) { side in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(side.value, text: sideBinding(for: side.key, default: side.value))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            } else {
                let knownSideEntries = config.sideConfigs.compactMap { side -> (key: String, value: String)? in
                    guard case .string(let value) = side.value else { return nil }
                    guard !side.key.hasSuffix(".api") else { return nil }
                    return (side.key, value)
                }
                if !knownSideEntries.isEmpty {
                    DisclosureGroup(
                        isExpanded: $showAdvancedSide,
                        content: {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(knownSideEntries, id: \.key) { side in
                                    let label = side.key.components(separatedBy: ".").last ?? side.key
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(label)
                                            .font(.caption).foregroundStyle(.secondary)
                                        TextField(side.value, text: sideBinding(for: side.key, default: side.value))
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                }
                            }
                            .padding(.top, 6)
                        },
                        label: {
                            Text(L10n.k("wizard.model_config.advanced_settings", fallback: "高级设置"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    )
                }
            }

            // API Key / URL
            if isCustomProvider && customAuthChoice == .secretReference {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secret Reference")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(L10n.k("wizard.model_config.secret_reference_placeholder", fallback: "env:MY_API_KEY 或 provider:accountName"), text: $secretReferenceInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text(L10n.k("wizard.model_config.secret_reference_hint", fallback: "支持 `env:VAR` / `${VAR}` / `provider:accountName`。应用前会做预检查。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.inputLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    if config.isUrlConfig {
                        TextField(config.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(config.placeholder, text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if isCustomProvider {
                VStack(alignment: .leading, spacing: 2) {
                    Text("custom-provider-id: \(effectiveCustomProviderId)")
                    Text("custom-model-id: \(resolvedCustomModelId)")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }

        Text(L10n.f("views.model_config_wizard.text_c7e02018", fallback: "添加 %@ 为主模型。", String(describing: chosenModel)))
            .font(.caption).foregroundStyle(.secondary)
        if let old = currentDefault {
            Text(L10n.f("views.model_config_wizard.text_e15076fd", fallback: "当前主模型 %@ 将变为第一备用。", String(describing: old)))
                .font(.caption).foregroundStyle(.tertiary)
        }

        HStack {
            Button(L10n.k("auto.model_config_wizard.back", fallback: "返回")) { step = .selectModel }
                .buttonStyle(.bordered)
            Spacer()
            if providerReady && isCustomProvider {
                // Custom provider already configured — can skip or update
                Button(L10n.k("auto.model_config_wizard.add_directly", fallback: "直接添加")) {
                    providerErrorMsg = ""
                    buildAndExecute(includeProviderConfig: false)
                }
                .buttonStyle(.bordered)
            }
            Button(L10n.k("auto.model_config_wizard.configuration", fallback: "应用配置")) {
                Task {
                    providerErrorMsg = ""
                    if let err = await validateCustomSecretReferenceIfNeeded() {
                        providerErrorMsg = err
                        return
                    }
                    buildAndExecute(includeProviderConfig: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(applyDisabled)
        }
    }

    // MARK: - Step 3: Executing

    @ViewBuilder
    private var executingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(commands) { cmd in
                commandRow(cmd)
            }
        }

        if executionDone {
            HStack {
                Spacer()
                if allSuccess {
                    Button(L10n.k("auto.model_config_wizard.done", fallback: "完成")) {
                        onComplete?()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                } else {
                    Button(L10n.k("auto.model_config_wizard.back", fallback: "返回")) {
                        step = .providerSetup
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ cmd: CommandRun) -> some View {
        HStack(spacing: 8) {
            statusIcon(cmd.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.label)
                    .font(.callout)
                if !cmd.output.isEmpty && cmd.status == .failed {
                    Text(cmd.output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(backgroundFor(cmd.status))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func statusIcon(_ status: CommandRun.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        case .running:
            ProgressView().scaleEffect(0.6)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private func backgroundFor(_ status: CommandRun.Status) -> Color {
        switch status {
        case .success: return Color.green.opacity(0.05)
        case .failed:  return Color.red.opacity(0.05)
        default:       return Color(nsColor: .controlBackgroundColor)
        }
    }

    // MARK: - Step 4: Result (merged into executing done state)

    @ViewBuilder
    private var resultView: some View {
        EmptyView() // result is shown inline in executingView
    }

    // MARK: - Logic

    private func checkProvider() async {
        isCheckingProvider = true
        isCustomProvider = false
        providerErrorMsg = ""
        step = .providerSetup
        sideValues = [:]
        apiKeyInput = ""
        secretReferenceInput = ""
        customAuthChoice = .customAPIKey

        let provider = chosenModel.components(separatedBy: "/").first ?? ""
        providerConfig = supportedProviderKeys.first { $0.id == provider }

        if useCustom {
            isCustomProvider = true
            let apiKeyPath = "models.providers.\(provider).apiKey"
            let baseUrlPath = "models.providers.\(provider).baseUrl"
            let apiPath = "models.providers.\(provider).api"

            // Check existing values
            let existingKey = await helperClient.getConfig(username: user.username, key: apiKeyPath)
            let existingUrl = await helperClient.getConfig(username: user.username, key: baseUrlPath)
            let existingApi = await helperClient.getConfig(username: user.username, key: apiPath)
            let hasKey = existingKey != nil && !existingKey!.isEmpty
            let hasUrl = existingUrl != nil && !existingUrl!.isEmpty
            providerReady = hasKey && hasUrl

            if let existingApi {
                customCompatibility = existingApi.contains("anthropic") ? .anthropic : .openai
            }
            customBaseURL = existingUrl ?? customBaseURL
            if customBaseURL.isEmpty {
                customBaseURL = "https://api.example.com/v1"
            }
            customProviderInput = CustomProviderConfigInput(
                baseUrl: customBaseURL,
                modelId: resolvedCustomModelId,
                providerId: resolvedCustomProviderId.isEmpty ? nil : resolvedCustomProviderId,
                compatibility: customCompatibility
            )

            providerConfig = ProviderKeyConfig(
                id: provider,
                displayName: "\(provider)（Custom）",
                configPath: apiKeyPath,
                placeholder: "sk-...",
                isUrlConfig: false,
                supportsOAuth: false,
                sideConfigs: [
                    (apiPath, .string(customCompatibility.apiType)),
                    (baseUrlPath, .string(customBaseURL)),
                ]
            )
            sideValues[baseUrlPath] = customBaseURL
        } else if let config = providerConfig {
            // Known provider — check if already configured
            let existing = await helperClient.getConfig(
                username: user.username,
                key: config.configPath
            )
            providerReady = (existing != nil && !existing!.isEmpty)
            // Pre-fill sideConfig defaults
            for side in config.sideConfigs {
                if case .string(let value) = side.value {
                    sideValues[side.key] = value
                }
            }
        } else {
            // Unknown provider → OpenAI 兼容模式
            isCustomProvider = true
            let apiKeyPath = "models.providers.\(provider).apiKey"
            let baseUrlPath = "models.providers.\(provider).baseUrl"

            // Check if already configured
            let existingKey = await helperClient.getConfig(username: user.username, key: apiKeyPath)
            let existingUrl = await helperClient.getConfig(username: user.username, key: baseUrlPath)
            let hasKey = existingKey != nil && !existingKey!.isEmpty
            let hasUrl = existingUrl != nil && !existingUrl!.isEmpty
            providerReady = hasKey && hasUrl

            // Create dynamic ProviderKeyConfig for this custom provider
            let apiPath = "models.providers.\(provider).api"
            providerConfig = ProviderKeyConfig(
                id: provider,
                displayName: L10n.f("views.model_config_wizard.openai", fallback: "%@（OpenAI 兼容）", String(describing: provider)),
                configPath: apiKeyPath,
                placeholder: "sk-...",
                isUrlConfig: false,
                supportsOAuth: false,
                sideConfigs: [
                    (apiPath, .string("openai-completions")),
                    (baseUrlPath, .string(existingUrl ?? "https://api.example.com/v1")),
                ]
            )
            // Pre-fill sideConfig (api is auto, only baseUrl editable)
            sideValues[baseUrlPath] = existingUrl ?? ""
        }

        if usingExistingTemplate, let template = selectedTemplate {
            let secretKey = "\(template.providerGroupId):\(template.name)"
            if let secret = GlobalSecretsStore.shared.value(
                for: secretKey,
                fallbackProvider: template.providerGroupId
            ), !secret.isEmpty {
                apiKeyInput = secret
            }

            if template.providerGroupId == "custom" {
                if let providerId = template.customProviderId, !providerId.isEmpty {
                    customProviderId = providerId
                }
                if let baseURL = template.customBaseURL, !baseURL.isEmpty {
                    customBaseURL = baseURL
                    sideValues["models.providers.\(provider).baseUrl"] = baseURL
                }
                if let apiType = template.customAPIType, !apiType.isEmpty {
                    customCompatibility = apiType.contains("anthropic") ? .anthropic : .openai
                }
            }

            if apiKeyInput.isEmpty, !providerReady {
                providerErrorMsg = L10n.k("wizard.model_config.existing_missing_key", fallback: "所选已有配置未设置 API Key")
            }
        }
        isCheckingProvider = false
    }

    /// 通过 gateway JSON-RPC config.patch 一次性写入所有配置变更。
    /// config.patch 使用 JSON Merge Patch 语义（深度合并），只更新指定字段，
    /// 不会覆盖 provider 的 models 数组等未提及的字段。
    /// Gateway 收到 patch 后自动热重载配置，无需手动重启。
    private func buildAndExecute(includeProviderConfig: Bool = false) {
        step = .executing
        commands = []
        executionDone = false
        allSuccess = true

        var patch: [String: Any] = [:]

        // 1. Provider 配置（apiKey, api, baseUrl 等）
        if includeProviderConfig, let config = providerConfig {
            let providerFields = buildProviderFields(config: config)
            if !providerFields.isEmpty {
                let provider = config.id
                commands.append(CommandRun(
                    label: L10n.f("model.exec.configure_provider", fallback: "配置 %@ 凭据", config.displayName)
                ))
                patch["models"] = ["providers": [provider: providerFields]]
            }
        }

        // 2. 模型切换（主模型 + 备用列表）
        var modelPatch: [String: Any] = ["primary": chosenModel]
        if let oldDefault = currentDefault {
            let newFallbacks = [oldDefault] + currentFallbacks
            modelPatch["fallbacks"] = newFallbacks
            let oldLabel = activeModelGroups.flatMap(\.models).first { $0.id == oldDefault }?.label ?? oldDefault
            commands.append(CommandRun(
                label: L10n.f("model.exec.demote_to_fallback", fallback: "将 %@ 设为备用", oldLabel)
            ))
        }
        let newModelLabel = activeModelGroups.flatMap(\.models).first { $0.id == chosenModel }?.label ?? chosenModel
        commands.append(CommandRun(
            label: L10n.f("model.exec.set_primary", fallback: "设置主模型：%@", newModelLabel)
        ))
        patch["agents"] = ["defaults": ["model": modelPatch]]

        Task { await executePatch(patch) }
    }

    /// 优先走 WebSocket config.patch（含 hash 重试）；Gateway 未连接时回退到本地直写
    private func executePatch(_ patch: [String: Any]) async {
        for i in commands.indices { commands[i].status = .running }
        do {
            do {
                try await executePatchViaGateway(patch, maxRetries: 2)
            } catch {
                guard isGatewayConnectivityError(error) else { throw error }
                // 回退：本地直写 + 重启 gateway
                let cfg = await helperClient.getConfigJSON(username: user.username)
                try await applyPatchDirect(patch, existingConfig: cfg)
                try await helperClient.restartGateway(username: user.username)
            }
            for i in commands.indices { commands[i].status = .success }
        } catch {
            for i in commands.indices { commands[i].status = .failed }
            if let last = commands.indices.last {
                commands[last].output = error.localizedDescription
            }
            allSuccess = false
        }
        executionDone = true
    }

    /// 通过 Gateway RPC 执行 configPatch，hash 冲突时自动重试
    private func executePatchViaGateway(_ patch: [String: Any], maxRetries: Int) async throws {
        var lastError: Error?
        for _ in 0...maxRetries {
            do {
                let (_, baseHash) = try await gatewayHub.configGetFull(username: user.username)
                try await gatewayHub.configPatch(
                    username: user.username,
                    patch: patch,
                    baseHash: baseHash,
                    note: "ClawdHome: add model \(chosenModel)"
                )
                return
            } catch let error as GatewayClientError {
                if case .requestFailed = error {
                    // hash mismatch 等请求级错误，重试
                    lastError = error
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? GatewayClientError.requestFailed(code: nil, message: "config.patch retries exhausted")
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

    // MARK: - Helpers

    /// 构建 provider 配置字段（用于 configPatch 深度合并，只包含变更字段）
    private func buildProviderFields(config: ProviderKeyConfig) -> [String: Any] {
        let provider = config.id
        var fields: [String: Any] = [:]

        // sideConfigs（api, baseUrl 等）
        for side in config.sideConfigs {
            let fieldName = side.key.components(separatedBy: ".").last ?? side.key
            switch side.value {
            case .string(let defaultValue):
                let val = sideValues[side.key] ?? defaultValue
                guard !val.isEmpty else { continue }
                fields[fieldName] = val
            case .bool(let b):
                fields[fieldName] = b
            }
        }

        if isCustomProvider {
            customProviderInput = CustomProviderConfigInput(
                baseUrl: sideValues["models.providers.\(provider).baseUrl"] ?? customBaseURL,
                modelId: resolvedCustomModelId,
                providerId: resolvedCustomProviderId.isEmpty ? nil : resolvedCustomProviderId,
                compatibility: customCompatibility
            )
            fields["api"] = customProviderInput.compatibility.apiType
        }

        if let keyValue = resolvedProviderSecretValue() {
            let fieldName = config.configPath.components(separatedBy: ".").last ?? "apiKey"
            fields[fieldName] = keyValue
        }

        // 某些 provider（如 kimi-coding）要求 provider.models 必填；缺失会导致 config 校验失败。
        if let providerModels = providerModelsForPatch(providerId: provider), !providerModels.isEmpty {
            fields["models"] = providerModels
        }

        return fields
    }

    /// 生成 models.providers.<id>.models 的最小合法数组，避免 provider schema 校验失败
    private func providerModelsForPatch(providerId: String) -> [[String: Any]]? {
        if isCustomProvider {
            let modelId = resolvedCustomModelId
            guard !modelId.isEmpty else { return nil }
            let displayModel = modelId
            return [[
                "id": modelId,
                "name": displayModel,
                "reasoning": true,
                "input": ["text", "image"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 262_144,
                "maxTokens": 32_768,
            ]]
        }

        let providerModels = builtInModels(for: providerId).map(\.providerModelConfig)
        guard !providerModels.isEmpty else { return nil }
        return providerModels
    }

    private func filteredGroups(_ text: String) -> [ModelGroup] {
        let groups = activeModelGroups
        guard !text.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.models.filter {
                $0.id.localizedCaseInsensitiveContains(text)
                    || $0.label.localizedCaseInsensitiveContains(text)
            }
            return hits.isEmpty ? nil : ModelGroup(id: group.id, provider: group.provider, models: hits)
        }
    }

    private func sideBinding(for key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { sideValues[key] ?? defaultValue },
            set: { sideValues[key] = $0 }
        )
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return "***" }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }

    private func syncTemplateSelection() {
        guard !availableTemplates.isEmpty else {
            configSource = .new
            selectedTemplateID = nil
            selectedTemplateModelID = ""
            return
        }
        if selectedTemplateID == nil,
           selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           customModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configSource = .existing
        }
        if selectedTemplateID == nil || availableTemplates.contains(where: { $0.id == selectedTemplateID }) == false {
            selectedTemplateID = availableTemplates.first?.id
        }
        guard let template = selectedTemplate else { return }
        if !template.modelIds.contains(selectedTemplateModelID) {
            selectedTemplateModelID = template.modelIds.first ?? ""
        }
        if configSource == .existing {
            selectedModel = selectedTemplateModelID
            useCustom = false
        }
    }

    private func modelLabel(for modelID: String) -> String {
        activeModelGroups
            .flatMap(\.models)
            .first(where: { $0.id == modelID })?.label ?? modelID
    }

    /// L10n.k("views.model_config_wizard.configuration", fallback: "应用配置")按钮禁用条件
    private var applyDisabled: Bool {
        let keyVal = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if isCustomProvider {
            let hasNewKey = resolvedProviderSecretValue() != nil
            let hasBaseUrl = providerConfig?.sideConfigs.first(where: { $0.key.hasSuffix(".baseUrl") }).map { side in
                let val = sideValues[side.key] ?? ""
                return !val.trimmingCharacters(in: .whitespaces).isEmpty
            } ?? false
            return !hasBaseUrl || !hasNewKey
        }
        return keyVal.isEmpty
    }

    private func resolvedProviderSecretValue() -> String? {
        if isCustomProvider && customAuthChoice == .secretReference {
            let raw = secretReferenceInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if raw.hasPrefix("${"), raw.hasSuffix("}") {
                return raw
            }
            if raw.hasPrefix("env:") {
                let envName = String(raw.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !envName.isEmpty else { return nil }
                return "${\(envName)}"
            }
            return raw
        }

        let keyVal = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return keyVal.isEmpty ? nil : keyVal
    }

    private func validateCustomSecretReferenceIfNeeded() async -> String? {
        guard isCustomProvider, customAuthChoice == .secretReference else { return nil }
        let raw = secretReferenceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return L10n.k("views.model_config_wizard.error_secret_ref_empty", fallback: "Secret Reference 不能为空。")
        }
        if raw.hasPrefix("${"), raw.hasSuffix("}") {
            let envName = String(raw.dropFirst(2).dropLast())
            guard !envName.isEmpty else { return L10n.k("views.model_config_wizard.error_env_ref_format", fallback: "环境变量引用格式错误。示例：${CUSTOM_API_KEY}") }
            let existing = await helperClient.getConfig(username: user.username, key: "env.\(envName)")
            if existing == nil || existing?.isEmpty == true {
                return L10n.f("views.model_config_wizard.error_env_not_configured", fallback: "环境变量 %@ 未配置（预检失败）。", envName)
            }
            return nil
        }
        if raw.hasPrefix("env:") {
            let envName = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !envName.isEmpty else { return L10n.k("views.model_config_wizard.error_env_format", fallback: "env 引用格式错误。示例：env:CUSTOM_API_KEY") }
            let existing = await helperClient.getConfig(username: user.username, key: "env.\(envName)")
            if existing == nil || existing?.isEmpty == true {
                return L10n.f("views.model_config_wizard.error_env_not_configured", fallback: "环境变量 %@ 未配置（预检失败）。", envName)
            }
            return nil
        }

        if raw.contains(":") {
            if !GlobalSecretsStore.shared.has(secretKey: raw) {
                return L10n.f("views.model_config_wizard.error_provider_ref_missing", fallback: "provider ref %@ 不存在于全局 secrets（预检失败）。", raw)
            }
            return nil
        }

        return L10n.k("views.model_config_wizard.error_secret_ref_unsupported", fallback: "Secret Reference 格式不支持。请使用 env:VAR / ${VAR} / provider:account。")
    }
}

// MARK: - Command Run Model

/// 视觉进度项（仅用于展示，实际执行通过单次 configPatch）
struct CommandRun: Identifiable {
    let id = UUID()
    let label: String       // 用户友好描述
    var status: Status = .pending
    var output: String = ""

    enum Status { case pending, running, success, failed }
}

// MARK: - 编辑模型 Sheet

struct ModelEditSheet: View {
    let user: ManagedUser
    let modelId: String
    let isPrimary: Bool
    let currentDefault: String?
    let currentFallbacks: [String]
    var onComplete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub

    @State private var isBusy = false
    @State private var errorMsg: String? = nil
    @State private var successMsg: String? = nil

    private var label: String {
        builtInModelGroups.flatMap(\.models)
            .first { $0.id == modelId }?.label ?? modelId
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Button(L10n.k("auto.model_config_wizard.close", fallback: "关闭")) { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: isPrimary ? "star.fill" : "circle")
                        .foregroundStyle(isPrimary ? Color.orange : Color(nsColor: .tertiaryLabelColor))
                    Text(modelId)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(isPrimary
                     ? L10n.k("model.config.current_primary", fallback: "当前为主模型")
                     : L10n.k("model.config.current_fallback", fallback: "当前为备用模型"))
                    .font(.caption).foregroundStyle(.tertiary)

                if isBusy {
                    HStack { ProgressView().scaleEffect(0.7); Text(L10n.k("auto.model_config_wizard.processing", fallback: "处理中…")).font(.caption) }
                }

                if let err = errorMsg {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let msg = successMsg {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(msg).font(.caption)
                    }
                }

                Divider()

                if !isPrimary {
                    Button(L10n.k("model.config.set_as_primary", fallback: "设为主模型")) {
                        Task { await promoteToDefault() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }

                Button(L10n.k("auto.model_config_wizard.remove_model", fallback: "移除模型")) {
                    Task { await removeModel() }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
                .disabled(isBusy)
            }
            .padding(16)

            Spacer()
        }
        .frame(width: 360, height: 280)
    }

    private func promoteToDefault() async {
        isBusy = true; errorMsg = nil; successMsg = nil
        var newFallbacks = currentFallbacks.filter { $0 != modelId }
        if let old = currentDefault { newFallbacks.insert(old, at: 0) }

        do {
            var modelPatch: [String: Any] = ["primary": modelId]
            if !newFallbacks.isEmpty { modelPatch["fallbacks"] = newFallbacks }
            let (_, baseHash) = try await gatewayHub.configGetFull(username: user.username)
            try await gatewayHub.configPatch(
                username: user.username,
                patch: ["agents": ["defaults": ["model": modelPatch]]],
                baseHash: baseHash,
                note: "ClawdHome: promote \(modelId) to default"
            )
            successMsg = L10n.k("views.model_config_wizard.models", fallback: "已设为主模型")
        } catch {
            errorMsg = error.localizedDescription
        }

        isBusy = false
        onComplete?()
        try? await Task.sleep(for: .milliseconds(600))
        dismiss()
    }

    private func removeModel() async {
        isBusy = true; errorMsg = nil; successMsg = nil

        do {
            var modelPatch: [String: Any]
            if isPrimary {
                if let newDefault = currentFallbacks.first {
                    let newFallbacks = Array(currentFallbacks.dropFirst())
                    modelPatch = ["primary": newDefault]
                    if !newFallbacks.isEmpty { modelPatch["fallbacks"] = newFallbacks }
                } else {
                    modelPatch = ["primary": ""]
                }
            } else {
                let newFallbacks = currentFallbacks.filter { $0 != modelId }
                modelPatch = ["fallbacks": newFallbacks]
            }

            let (_, baseHash) = try await gatewayHub.configGetFull(username: user.username)
            try await gatewayHub.configPatch(
                username: user.username,
                patch: ["agents": ["defaults": ["model": modelPatch]]],
                baseHash: baseHash,
                note: "ClawdHome: remove model \(modelId)"
            )
            successMsg = L10n.k("views.model_config_wizard.removed", fallback: "已移除")
        } catch {
            errorMsg = error.localizedDescription
        }

        isBusy = false
        onComplete?()
        try? await Task.sleep(for: .milliseconds(600))
        dismiss()
    }
}
