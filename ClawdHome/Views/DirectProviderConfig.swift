// ClawdHome/Views/DirectProviderConfig.swift

import AppKit
import SwiftUI
import WebKit

enum DirectProviderChoice: String, CaseIterable, Identifiable {
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
        case .zai: return L10n.k("views.detail.provider_zai", fallback: "智谱 Z.AI")
        case .custom: return L10n.k("views.detail.provider_custom", fallback: "自定义")
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax: return "MiniMax API Key"
        case .qiniu: return "Qiniu API Key"
        case .zai: return L10n.k("views.detail.provider_zai_api_key", fallback: "智谱 API Key")
        case .custom: return L10n.k("views.detail.provider_custom_api_key", fallback: "自定义 API Key")
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax: return L10n.k("views.user_detail_view.minimax_api_key", fallback: "粘贴 MiniMax API Key")
        case .qiniu: return "sk-..."
        case .zai: return "sk-..."
        case .custom: return L10n.k("views.detail.provider_custom_placeholder", fallback: "留空则尝试使用 CUSTOM_API_KEY")
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
        case .qiniu: return L10n.k("views.detail.provider_qiniu_console", fallback: "七牛 API Key")
        case .zai: return L10n.k("views.detail.provider_zai_console", fallback: "获取 API Key")
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
            return L10n.k("views.detail.promo_minimax", fallback: "🎁 领取 9 折专属优惠")
        case .qiniu:
            return L10n.k("views.detail.promo_qiniu", fallback: "免费领取 1000 万 Token")
        case .zai:
            return L10n.k("views.detail.promo_zai", fallback: "95折优惠订阅")
        case .custom:
            return nil
        default:
            return nil
        }
    }
}

// DirectKimiModel / DirectMinimaxModel / DirectQiniuModel / DirectZAIModel 已统一到
// ModelsStatus.swift 的 builtInModelGroups，使用 builtInModels(for:) 查询

enum DirectCustomCompatibility: String, CaseIterable, Identifiable {
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

let userDetailModelConfigMaintenanceContext = "user-detail-model-config"

// MARK: - ProviderModelConfigCore（可复用核心）

struct ProviderModelConfigCore: View {
    let user: ManagedUser
    var onSaved: ((String) -> Void)? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isRestartingGateway = false
    @State private var selectedProvider: DirectProviderChoice = .qiniu
    @State private var selectedKimiModelId: String = "kimi-coding/k2p5"
    @State private var selectedMinimaxModelId: String = "minimax/MiniMax-M2.7"
    @State private var selectedQiniuModelId: String = "qiniu/deepseek-v3.2-251201"
    @State private var selectedZAIModelId: String = "zai/glm-5"
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

    /// 已有配置 / 新增配置 切换
    private enum ConfigSource: String, CaseIterable, Identifiable {
        case existing
        case new
        var id: String { rawValue }
        var title: String {
            switch self {
            case .existing: return L10n.k("views.detail.config_source_existing", fallback: "已有配置")
            case .new: return L10n.k("views.detail.config_source_new", fallback: "新增配置")
            }
        }
    }
    @State private var configSource: ConfigSource = .new
    @State private var selectedTemplateId: UUID? = nil
    @State private var selectedTemplateModelId: String = ""

    /// 保存成功后 —— 全局模型池同步提示
    @State private var showGlobalPoolPrompt = false
    @State private var lastSavedProviderGroupId: String = ""
    @State private var lastSavedProviderDisplayName: String = ""
    @State private var lastSavedModelIds: [String] = []
    @State private var lastSavedApiKey: String = ""
    @State private var lastSavedCustomProviderId: String? = nil
    @State private var lastSavedCustomBaseURL: String? = nil
    @State private var lastSavedCustomAPIType: String? = nil

    /// 用户选择：旧主模型如何处理
    enum OldModelAction { case keepAsFallback, replace }
    @State private var oldModelAction: OldModelAction? = nil

    private enum ConfigMode: String, CaseIterable, Identifiable {
        case builtinUI
        case cliMore
        var id: String { rawValue }
        var title: String {
            switch self {
            case .builtinUI: return L10n.k("views.detail.config_mode_builtin", fallback: "内置 UI")
            case .cliMore: return L10n.k("views.detail.config_mode_cli", fallback: "更多模型（命令行）")
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

    /// 全局模型池中可用模板（非空 modelIds）
    private var availableTemplates: [ProviderTemplate] {
        modelStore.providers.filter { !$0.modelIds.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(L10n.k("user.detail.auto.configuration", fallback: "读取当前配置…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // 已有配置/新增配置 切换（仅在全局池有可用模板时显示）
                if modelStore.hasTemplate {
                    Picker(L10n.k("views.detail.config_source_picker", fallback: "配置来源"), selection: $configSource) {
                        ForEach(ConfigSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if configSource == .existing && modelStore.hasTemplate {
                    existingTemplateView
                } else {
                    newConfigView
                }

                // 全局模型池同步提示
                if showGlobalPoolPrompt {
                    HStack(spacing: 8) {
                        Text(L10n.k("views.detail.global_pool_sync_prompt", fallback: "保存到全局模型池？"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.k("views.detail.global_pool_sync_confirm", fallback: "保存")) {
                            saveToGlobalPool()
                            showGlobalPoolPrompt = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        Button(L10n.k("views.detail.global_pool_sync_dismiss", fallback: "不了")) {
                            showGlobalPoolPrompt = false
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .foregroundStyle(.secondary)
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
        .onChange(of: configSource) { _, _ in
            saveMessage = nil
            saveError = nil
            showGlobalPoolPrompt = false
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
                if let model = currentDefaultModel {
                    onSaved?(model)
                }
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

    // MARK: - 已有配置视图

    @ViewBuilder
    private var existingTemplateView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.k("views.detail.template_picker", fallback: "选择账户"), selection: $selectedTemplateId) {
                Text(L10n.k("views.detail.template_picker_placeholder", fallback: "请选择…")).tag(nil as UUID?)
                ForEach(availableTemplates) { template in
                    Text(template.displayNameWithAlias).tag(template.id as UUID?)
                }
            }
            .pickerStyle(.menu)

            if let templateId = selectedTemplateId,
               let template = modelStore.providerTemplate(id: templateId) {
                Picker(L10n.k("views.detail.template_model_picker", fallback: "模型"), selection: $selectedTemplateModelId) {
                    ForEach(template.modelIds, id: \.self) { modelId in
                        let label = builtInModel(for: modelId)?.label ?? modelId
                        Text(label).tag(modelId)
                    }
                }
                .pickerStyle(.menu)

                if !selectedTemplateModelId.isEmpty {
                    Text(selectedTemplateModelId)
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
                    Task { await applyExistingTemplate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || selectedTemplateId == nil || selectedTemplateModelId.isEmpty)
            }
        }
        .onChange(of: selectedTemplateId) { _, newId in
            saveMessage = nil
            saveError = nil
            showGlobalPoolPrompt = false
            if let newId, let template = modelStore.providerTemplate(id: newId) {
                selectedTemplateModelId = template.modelIds.first ?? ""
            } else {
                selectedTemplateModelId = ""
            }
        }
    }

    // MARK: - 新增配置视图

    @ViewBuilder
    private var newConfigView: some View {
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
                directModelPicker(providerId: "minimax", title: L10n.k("user.detail.auto.minimax_models", fallback: "MiniMax 模型"), selection: $selectedMinimaxModelId)
            } else if selectedProvider == .kimiCoding {
                directModelPicker(providerId: "kimi-coding", title: L10n.k("user.detail.auto.kimi_models", fallback: "Kimi 模型"), selection: $selectedKimiModelId)
            } else if selectedProvider == .qiniu {
                directModelPicker(providerId: "qiniu", selection: $selectedQiniuModelId)
            } else if selectedProvider == .zai {
                directModelPicker(providerId: "zai", title: L10n.k("views.user_detail_view.zai_models", fallback: "智谱 Z.AI 模型"), selection: $selectedZAIModelId)
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
                            Button(isFetchingCustomModels ? L10n.k("views.detail.custom_fetching", fallback: "拉取中…") : L10n.k("views.detail.custom_fetch_list", fallback: "从 API 拉取列表")) {
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

    // MARK: - 已有配置应用

    private func applyExistingTemplate() async {
        guard let templateId = selectedTemplateId,
              let template = modelStore.providerTemplate(id: templateId),
              !selectedTemplateModelId.isEmpty else {
            saveError = L10n.k("views.detail.error_select_template", fallback: "请先选择配置和模型")
            return
        }

        // 从 GlobalSecretsStore 获取凭据
        let secretKey = "\(template.providerGroupId):\(template.name)"
        let apiKey = GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: template.providerGroupId) ?? ""

        // 映射 providerGroupId 到 DirectProviderChoice
        let providerChoice: DirectProviderChoice
        switch template.providerGroupId {
        case "qiniu": providerChoice = .qiniu
        case "kimi-coding": providerChoice = .kimiCoding
        case "minimax": providerChoice = .minimax
        case "zai": providerChoice = .zai
        default: providerChoice = .custom
        }

        // 设置相关状态
        selectedProvider = providerChoice
        providerKeys[providerChoice.rawValue] = apiKey
        switch providerChoice {
        case .qiniu: selectedQiniuModelId = selectedTemplateModelId
        case .kimiCoding: selectedKimiModelId = selectedTemplateModelId
        case .minimax: selectedMinimaxModelId = selectedTemplateModelId
        case .zai: selectedZAIModelId = selectedTemplateModelId
        case .custom:
            if let customPid = template.customProviderId {
                customProviderId = customPid
            }
            if let baseURL = template.customBaseURL {
                customBaseURL = baseURL
            }
            if let apiType = template.customAPIType {
                customCompatibility = apiType.contains("anthropic") ? .anthropic : .openai
            }
            let parts = selectedTemplateModelId.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                customModelId = parts[1]
            } else {
                customModelId = selectedTemplateModelId
            }
        }

        // 走统一的应用流程
        if selectedProvider == .custom || !apiKey.isEmpty {
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
            oldModelAction = .replace
            await doApplyConfig(apiKey: apiKey)
        } else {
            saveError = L10n.k("views.detail.error_template_no_key", fallback: "该账户未存储 API Key，请切换到新增配置手动输入")
        }
    }

    // MARK: - 全局模型池同步

    private func saveToGlobalPool() {
        let template = ProviderTemplate(
            name: lastSavedProviderDisplayName,
            providerGroupId: lastSavedProviderGroupId,
            providerDisplayName: lastSavedProviderDisplayName,
            modelIds: lastSavedModelIds,
            customProviderId: lastSavedCustomProviderId,
            customBaseURL: lastSavedCustomBaseURL,
            customAPIType: lastSavedCustomAPIType
        )

        // 确保名称唯一
        var finalTemplate = template
        if !modelStore.isAliasAvailable(finalTemplate.name) {
            var counter = 2
            while !modelStore.isAliasAvailable("\(finalTemplate.name) \(counter)") {
                counter += 1
            }
            finalTemplate.name = "\(finalTemplate.name) \(counter)"
        }

        modelStore.addProvider(finalTemplate)

        // 保存 API Key 到 GlobalSecretsStore
        if !lastSavedApiKey.isEmpty {
            let entry = SecretEntry(
                provider: lastSavedProviderGroupId,
                accountName: finalTemplate.name,
                value: lastSavedApiKey
            )
            GlobalSecretsStore.shared.save(entry: entry)
        }
    }

    // MARK: - directModelPicker

    @ViewBuilder
    private func directModelPicker(providerId: String, title: String? = nil, selection: Binding<String>) -> some View {
        let models = builtInModels(for: providerId)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Picker(L10n.k("user.detail.auto.models", fallback: "模型"), selection: selection) {
                ForEach(models) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            Text(selection.wrappedValue)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 逻辑函数

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
        showGlobalPoolPrompt = false

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
                selectedMinimaxModelId = primary
            } else if primary.hasPrefix("qiniu/") {
                selectedProvider = .qiniu
                selectedQiniuModelId = primary
            } else if primary.hasPrefix("zai/") {
                selectedProvider = .zai
                selectedZAIModelId = primary
            } else if primary.hasPrefix("kimi-coding/") {
                selectedProvider = .kimiCoding
                selectedKimiModelId = primary
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

        // 根据已有状态设置初始 configSource
        if modelStore.hasTemplate {
            configSource = .existing
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
        case .kimiCoding: return selectedKimiModelId
        case .minimax: return selectedMinimaxModelId
        case .qiniu: return selectedQiniuModelId
        case .zai: return selectedZAIModelId
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
        showGlobalPoolPrompt = false

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

                let resolvedModel = resolveNewPrimary()
                recordLastSaved(apiKey: apiKey, modelId: resolvedModel)
                onSaved?(resolvedModel)
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

            let resolvedModel = resolveNewPrimary()
            recordLastSaved(apiKey: apiKey, modelId: resolvedModel)
            onSaved?(resolvedModel)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// 记录最近一次保存的信息，用于全局模型池同步提示
    private func recordLastSaved(apiKey: String, modelId: String) {
        lastSavedApiKey = apiKey
        lastSavedModelIds = [modelId]

        switch selectedProvider {
        case .qiniu:
            lastSavedProviderGroupId = "qiniu"
            lastSavedProviderDisplayName = "Qiniu AI"
            lastSavedCustomProviderId = nil
            lastSavedCustomBaseURL = nil
            lastSavedCustomAPIType = nil
        case .kimiCoding:
            lastSavedProviderGroupId = "kimi-coding"
            lastSavedProviderDisplayName = "Kimi Code"
            lastSavedCustomProviderId = nil
            lastSavedCustomBaseURL = nil
            lastSavedCustomAPIType = nil
        case .minimax:
            lastSavedProviderGroupId = "minimax"
            lastSavedProviderDisplayName = "MiniMax"
            lastSavedCustomProviderId = nil
            lastSavedCustomBaseURL = nil
            lastSavedCustomAPIType = nil
        case .zai:
            lastSavedProviderGroupId = "zai"
            lastSavedProviderDisplayName = L10n.k("views.detail.provider_zai", fallback: "智谱 Z.AI")
            lastSavedCustomProviderId = nil
            lastSavedCustomBaseURL = nil
            lastSavedCustomAPIType = nil
        case .custom:
            lastSavedProviderGroupId = "custom"
            lastSavedProviderDisplayName = effectiveCustomProviderId
            lastSavedCustomProviderId = effectiveCustomProviderId
            lastSavedCustomBaseURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            lastSavedCustomAPIType = customCompatibility.apiType
        }

        // 如果当前用的是"已有配置"模式，不弹出全局池同步提示（已经在池中了）
        if configSource == .existing {
            showGlobalPoolPrompt = false
        } else {
            // 检查全局池中是否已有相同 provider + 相同 key 的配置
            let existingKeys = modelStore.providers
                .filter { $0.providerGroupId == lastSavedProviderGroupId }
                .compactMap { GlobalSecretsStore.shared.value(for: "\($0.providerGroupId):\($0.name)") }
            if existingKeys.contains(apiKey) {
                showGlobalPoolPrompt = false
            } else {
                showGlobalPoolPrompt = true
            }
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
        let qiniuModels = builtInModels(for: "qiniu")
        let providerModels = qiniuModels.map(\.providerModelConfig)
        let newPrimary = selectedQiniuModelId

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
        for model in qiniuModels {
            var aliasConfig = (aliasMap[model.id] as? [String: Any]) ?? [:]
            aliasConfig["alias"] = model.label
            aliasMap[model.id] = aliasConfig
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
        let modelId = selectedKimiModelId
        let entry = builtInModel(for: modelId)
        let modelDef = entry?.providerModelConfig ?? [
            "id": modelId.replacingOccurrences(of: "kimi-coding/", with: ""),
            "name": entry?.label ?? modelId,
            "reasoning": true, "input": ["text", "image"],
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
        let providerModels = builtInModels(for: "minimax").map(\.providerModelConfig)
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
                "model": ["primary": selectedMinimaxModelId],
            ] as [String: Any]],
        ]
        let sync: () async throws -> Void = { [self] in
            try await syncMinimaxAgentFiles(apiKey: apiKey, providerModels: providerModels)
        }
        return (patch, sync)
    }

    private func buildQiniuPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let providerModels = builtInModels(for: "qiniu").map(\.providerModelConfig)
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
                "model": ["primary": selectedQiniuModelId],
            ] as [String: Any]],
        ]
        let sync: () async throws -> Void = { [self] in
            try await syncQiniuAgentFiles(apiKey: apiKey, providerModels: providerModels)
        }
        return (patch, sync)
    }

    private func buildZAIPatch(apiKey: String) async throws -> ([String: Any], () async throws -> Void) {
        let providerModels = builtInModels(for: "zai").map(\.providerModelConfig)
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
                "model": ["primary": selectedZAIModelId],
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

        guard !modelId.isEmpty else { throw HelperError.operationFailed(L10n.k("views.detail.error_select_model", fallback: "请先选择模型")) }
        guard !baseURL.isEmpty else { throw HelperError.operationFailed(L10n.k("views.detail.error_fill_base_url", fallback: "请先填写 Base URL")) }

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
            var a = (aliasMap[selectedMinimaxModelId] as? [String: Any]) ?? [:]
            a["alias"] = a["alias"] ?? "Minimax"
            aliasMap[selectedMinimaxModelId] = a
        case .qiniu:
            for model in builtInModels(for: "qiniu") {
                var a = (aliasMap[model.id] as? [String: Any]) ?? [:]
                a["alias"] = model.label
                aliasMap[model.id] = a
            }
        case .zai:
            for model in builtInModels(for: "zai") {
                var a = (aliasMap[model.id] as? [String: Any]) ?? [:]
                a["alias"] = model.label
                aliasMap[model.id] = a
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
            customModelFetchError = L10n.k("views.detail.error_fill_base_url", fallback: "请先填写 Base URL")
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
                customModelFetchMessage = L10n.k("views.detail.custom_fetch_empty", fallback: "已请求成功，但未解析到可用模型 ID（该接口可能不支持标准 list）")
                return
            }

            customModelSuggestions = ids
            if effectiveCustomModelId.isEmpty, let first = ids.first {
                customModelId = first
            }
            customModelFetchMessage = L10n.f("views.detail.custom_fetch_success", fallback: "已拉取 %d 个模型", ids.count)
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

// MARK: - ProviderModelConfigPanel（状态头 + Core 的薄包装）

struct ProviderModelConfigPanel: View {
    let user: ManagedUser
    var onApplied: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient

    @State private var currentDefaultModel: String? = nil
    @State private var currentFallbackModels: [String] = []
    @State private var isLoadingStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 状态头
            if isLoadingStatus {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(L10n.k("user.detail.auto.configuration", fallback: "读取当前配置…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let currentDefaultModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.f("views.user_detail_view.current_model", fallback: "当前：%@", currentDefaultModel))
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
                                currentFallbackModels.joined(separator: " · ")
                            )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                }
            }

            // 嵌入核心
            ProviderModelConfigCore(user: user) { _ in
                Task { await refreshStatus() }
                onApplied?()
            }
        }
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        if let status = await helperClient.getModelsStatus(username: user.username) {
            currentDefaultModel = status.resolvedDefault ?? status.defaultModel
            currentFallbackModels = status.fallbacks
        }
    }
}

// MARK: - EmbeddedGatewayConsoleCoordinator

final class EmbeddedGatewayConsoleCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var webView: WKWebView?
    var pendingFileInputAccept = ""
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

final class EmbeddedGatewayConsoleStore: ObservableObject {
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
