// ClawdHome/Views/ModelConfigWizard.swift
// 统一模型配置向导：模型池管理 + 添加/编辑模型 + Provider 配置 + CLI 执行

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
    @State private var showFallbackManager = false
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

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if embedded {
                        embeddedHeader
                    }

                    modelPoolSection

                    actionButtons

                    if embedded {
                        embeddedFooter
                    }
                }
                .padding(embedded ? 0 : 16)
            }
        }
        .frame(width: embedded ? nil : 480)
        .task { await loadStatus() }
        .sheet(isPresented: $showAddModel) {
            ModelAddSheet(
                user: user,
                currentDefault: currentDefault,
                currentFallbacks: currentFallbacks,
                dynamicModelGroups: dynamicModelGroups
            ) {
                Task { await loadStatus() }
            }
            .environment(helperClient)
        }
        .sheet(isPresented: $showFallbackManager) {
            FallbackManagerSheet(username: user.username, fallbacks: $currentFallbacks)
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
            Label(L10n.k("auto.model_config_wizard.configurationmodels", fallback: "配置模型"), systemImage: "cpu")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(L10n.k("auto.model_config_wizard.ai_models_models", fallback: "添加要使用的 AI 模型，最后添加的自动成为主模型。"))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var embeddedFooter: some View {
        HStack(spacing: 12) {
            Button(L10n.k("auto.model_config_wizard.doneconfiguration", fallback: "完成配置")) {
                onDone?()
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentDefault == nil)

            Button(L10n.k("auto.model_config_wizard.configuration", fallback: "跳过配置")) {
                onDone?()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model Pool Section

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
                Text(L10n.k("auto.model_config_wizard.configurationmodels", fallback: "还没有配置模型"))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.k("auto.model_config_wizard.modelsconfiguration", fallback: "点击下方「添加模型」开始配置"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(modelPool.enumerated()), id: \.element) { idx, modelId in
                    modelRow(modelId: modelId, index: idx)
                    if idx < modelPool.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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

            Text(isPrimary ? L10n.k("auto.model_config_wizard.models", fallback: "主模型") : "备用 \(index)")
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
            Button {
                showAddModel = true
            } label: {
                Label(L10n.k("auto.model_config_wizard.models", fallback: "添加模型"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)

            if currentFallbacks.count > 1 {
                Button {
                    showFallbackManager = true
                } label: {
                    Label(L10n.k("auto.model_config_wizard.manage_fallback_order", fallback: "管理备用顺序"), systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
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

    enum Step { case selectModel, providerSetup, executing, result }

    @State private var step: Step = .selectModel

    // Step 1: Select
    @State private var filter = ""
    @State private var selectedModel = ""
    @State private var useCustom = false
    @State private var customModel = ""

    // Step 2: Provider
    @State private var providerConfig: ProviderKeyConfig? = nil
    @State private var apiKeyInput = ""
    @State private var sideValues: [String: String] = [:]  // sideConfig key → value
    @State private var providerReady = false  // API key already configured
    @State private var isCheckingProvider = false
    @State private var isCustomProvider = false  // 未知 provider → OpenAI 兼容模式

    // Step 3: Executing
    @State private var commands: [CommandRun] = []
    @State private var executionDone = false

    // Step 4: Result
    @State private var allSuccess = true

    private var chosenModel: String {
        useCustom ? customModel.trimmingCharacters(in: .whitespaces) : selectedModel
    }

    private var activeModelGroups: [ModelGroup] {
        dynamicModelGroups ?? builtInModelGroups
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
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var addSheetTitleBar: some View {
        HStack {
            Text(L10n.k("auto.model_config_wizard.models", fallback: "添加模型"))
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
        HStack(spacing: 8) {
            if useCustom {
                TextField("provider/model-id", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
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
                filter = ""; customModel = ""; selectedModel = ""
            }
            .buttonStyle(.bordered).font(.caption)
        }

        if useCustom {
            customModelGuidance
        } else {
            selectModelList
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
            .disabled(chosenModel.isEmpty || (useCustom && !chosenModel.contains("/")))
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
                    Text(L10n.k("auto.model_config_wizard.models", fallback: "无匹配模型")).font(.caption).foregroundStyle(.secondary).padding()
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
                // Provider 已配置，直接执行模型切换命令
                buildAndExecute(providerCommands: [])
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func providerInputForm(_ config: ProviderKeyConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.f("views.model_config_wizard.text_1dc29306", fallback: "%@ 配置", String(describing: config.displayName)), systemImage: isCustomProvider ? "link" : "key.fill")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if providerReady && isCustomProvider {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text(L10n.k("auto.model_config_wizard.configuration_configuration", fallback: "已配置，可直接添加或修改配置后添加")).font(.caption).foregroundStyle(.secondary)
                }
            }

            // sideConfigs (baseUrl etc.; skip `.api` — auto-set, not user-editable)
            ForEach(config.sideConfigs.compactMap { side -> (key: String, value: String)? in
                guard case .string(let value) = side.value else { return nil }
                guard !side.key.hasSuffix(".api") else { return nil }
                return (side.key, value)
            }, id: \.key) { side in
                let label = side.key.components(separatedBy: ".").last ?? side.key
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCustomProvider ? "Base URL" : label)
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(side.value, text: sideBinding(for: side.key, default: side.value))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            // API Key / URL
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
                    buildAndExecute(providerCommands: [])
                }
                .buttonStyle(.bordered)
            }
            Button(L10n.k("auto.model_config_wizard.configuration", fallback: "应用配置")) {
                // 所有 provider 字段合并为单条 JSON-object 命令
                // 分字段写入会因 provider 对象不完整而导致 Zod 验证失败
                let provCmds = providerConfig.map { buildProviderJSONCommand(config: $0) } ?? []
                buildAndExecute(providerCommands: provCmds)
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
                Button(L10n.k("auto.model_config_wizard.done", fallback: "完成")) {
                    onComplete?()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ cmd: CommandRun) -> some View {
        HStack(spacing: 8) {
            statusIcon(cmd.status)
            VStack(alignment: .leading, spacing: 2) {
                Text("$ openclaw \(cmd.display)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !cmd.output.isEmpty && cmd.status == .failed {
                    Text(cmd.output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .lineLimit(3)
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
        step = .providerSetup
        sideValues = [:]

        let provider = chosenModel.components(separatedBy: "/").first ?? ""
        providerConfig = supportedProviderKeys.first { $0.id == provider }

        if let config = providerConfig {
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
        isCheckingProvider = false
    }

    private func buildAndExecute(providerCommands: [(display: String, args: [String])]) {
        step = .executing
        commands = []
        executionDone = false
        allSuccess = true

        // 1. Provider commands (sideConfigs first, then apiKey)
        for cmd in providerCommands {
            commands.append(CommandRun(display: cmd.display, args: cmd.args))
        }

        // 2. Reorder: old primary → first fallback
        if let oldDefault = currentDefault {
            let newFallbacks = [oldDefault] + currentFallbacks
            let jsonArray = "[" + newFallbacks.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            commands.append(CommandRun(
                display: "config set agents.defaults.model.fallback [\(newFallbacks.count) models]",
                args: ["config", "set", "agents.defaults.model.fallback", jsonArray]
            ))
        }

        // 3. Set new primary
        commands.append(CommandRun(
            display: "config set agents.defaults.model.primary \(chosenModel)",
            args: ["config", "set", "agents.defaults.model.primary", chosenModel]
        ))

        Task { await executeCommands() }
    }

    private func executeCommands() async {
        for i in commands.indices {
            commands[i].status = .running
            let (ok, out) = await helperClient.runOpenclawCommand(
                username: user.username,
                args: commands[i].args
            )
            commands[i].output = out
            commands[i].status = ok ? .success : .failed
            if !ok { allSuccess = false }
        }
        executionDone = true
    }

    // MARK: - Helpers

    /// 将 provider 所有字段合并为单条 JSON-object config set 命令
    /// openclaw config set 每次写入都做完整 Zod 验证，分字段写入会因 provider 对象不完整而失败
    private func buildProviderJSONCommand(
        config: ProviderKeyConfig
    ) -> [(display: String, args: [String])] {
        let provider = config.id
        let providerPath = "models.providers.\(provider)"

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

        // apiKey / URL（取 configPath 最后一个分量作为字段名）
        let keyVal = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if !keyVal.isEmpty {
            let fieldName = config.configPath.components(separatedBy: ".").last ?? "apiKey"
            fields[fieldName] = keyVal
        }

        guard !fields.isEmpty else { return [] }

        // 序列化为 JSON（按 key 排序保证确定性）
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let jsonStr = String(data: data, encoding: .utf8) else { return [] }

        // 显示字符串：对 apiKey 做 mask
        var displayFields = fields
        if let apiKeyField = config.configPath.components(separatedBy: ".").last,
           let v = displayFields[apiKeyField] as? String, !config.isUrlConfig {
            displayFields[apiKeyField] = maskKey(v)
        }
        let displayStr = (try? JSONSerialization.data(
            withJSONObject: displayFields, options: [.sortedKeys])
        ).flatMap { String(data: $0, encoding: .utf8) } ?? "{…}"

        return [(
            display: "config set \(providerPath) \(displayStr)",
            args: ["config", "set", providerPath, jsonStr]
        )]
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

    /// L10n.k("views.model_config_wizard.configuration", fallback: "应用配置")按钮禁用条件
    private var applyDisabled: Bool {
        let keyVal = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if isCustomProvider {
            // Custom provider: need at least baseUrl OR apiKey to be new
            let hasNewKey = !keyVal.isEmpty
            let hasBaseUrl = providerConfig?.sideConfigs.first(where: { $0.key.hasSuffix(".baseUrl") }).map { side in
                let val = sideValues[side.key] ?? ""
                return !val.trimmingCharacters(in: .whitespaces).isEmpty
            } ?? false
            return !hasNewKey && !hasBaseUrl
        }
        return keyVal.isEmpty
    }
}

// MARK: - Command Run Model

struct CommandRun: Identifiable {
    let id = UUID()
    let display: String
    let args: [String]
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

                Text(isPrimary ? L10n.k("auto.model_config_wizard.models", fallback: "当前为主模型") : L10n.k("auto.model_config_wizard.models", fallback: "当前为备用模型"))
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
                    Button(L10n.k("auto.model_config_wizard.models", fallback: "设为主模型")) {
                        Task { await promoteToDefault() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                }

                Button(L10n.k("auto.model_config_wizard.models", fallback: "移除模型")) {
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
        // Remove from fallbacks, add old default to fallbacks
        var newFallbacks = currentFallbacks.filter { $0 != modelId }
        if let old = currentDefault { newFallbacks.insert(old, at: 0) }

        let fallbackJSON = "[" + newFallbacks.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let (ok1, out1) = await helperClient.runOpenclawCommand(
            username: user.username,
            args: ["config", "set", "agents.defaults.model.fallback", fallbackJSON]
        )
        guard ok1 else { errorMsg = out1; isBusy = false; return }

        let (ok2, out2) = await helperClient.runOpenclawCommand(
            username: user.username,
            args: ["config", "set", "agents.defaults.model.primary", modelId]
        )
        guard ok2 else { errorMsg = out2; isBusy = false; return }

        successMsg = L10n.k("views.model_config_wizard.models", fallback: "已设为主模型")
        isBusy = false
        onComplete?()
        try? await Task.sleep(for: .milliseconds(600))
        dismiss()
    }

    private func removeModel() async {
        isBusy = true; errorMsg = nil; successMsg = nil

        if isPrimary {
            // Promote first fallback
            if let newDefault = currentFallbacks.first {
                let newFallbacks = Array(currentFallbacks.dropFirst())
                let fallbackJSON = "[" + newFallbacks.map { "\"\($0)\"" }.joined(separator: ",") + "]"
                let (ok1, _) = await helperClient.runOpenclawCommand(
                    username: user.username,
                    args: ["config", "set", "agents.defaults.model.fallback", fallbackJSON]
                )
                if ok1 {
                    let (ok2, out2) = await helperClient.runOpenclawCommand(
                        username: user.username,
                        args: ["config", "set", "agents.defaults.model.primary", newDefault]
                    )
                    if !ok2 { errorMsg = out2; isBusy = false; return }
                }
            } else {
                // No fallbacks, clear primary
                let (ok, out) = await helperClient.runOpenclawCommand(
                    username: user.username,
                    args: ["config", "set", "agents.defaults.model.primary", ""]
                )
                if !ok { errorMsg = out; isBusy = false; return }
            }
        } else {
            // Remove from fallbacks
            let newFallbacks = currentFallbacks.filter { $0 != modelId }
            let fallbackJSON = "[" + newFallbacks.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            let (ok, out) = await helperClient.runOpenclawCommand(
                username: user.username,
                args: ["config", "set", "agents.defaults.model.fallback", fallbackJSON]
            )
            if !ok { errorMsg = out; isBusy = false; return }
        }

        successMsg = L10n.k("views.model_config_wizard.removed", fallback: "已移除")
        isBusy = false
        onComplete?()
        try? await Task.sleep(for: .milliseconds(600))
        dismiss()
    }
}
