// ClawdHome/Views/ModelPrioritySheet.swift
// 模型优先级管理 Sheet — 管理主模型与备选降级链

import SwiftUI

// MARK: - 模型链条目

/// 降级链中的一个条目（主模型或备选模型）
struct ModelChainEntry: Identifiable, Equatable {
    let id: String          // provider/model-id
    var providerLabel: String  // 提供商显示名

    /// 从模型 ID 中提取提供商前缀
    static func providerLabel(for modelId: String) -> String {
        let prefix = modelId.components(separatedBy: "/").first ?? modelId
        // 已知提供商的友好名映射
        switch prefix {
        case "minimax": return "MiniMax"
        case "kimi-coding": return "Kimi Code"
        case "qiniu": return "Qiniu AI"
        case "zai": return "智谱 Z.AI"
        default: return prefix
        }
    }
}

// MARK: - 提供商配置信息（添加表单用）

/// 内联添加表单的提供商选择
enum AddModelProvider: String, CaseIterable, Identifiable {
    case qiniu = "qiniu"
    case kimiCoding = "kimi-coding"
    case minimax = "minimax"
    case zai = "zai"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qiniu: return "Qiniu AI"
        case .kimiCoding: return "Kimi Code"
        case .minimax: return "MiniMax"
        case .zai: return "智谱 Z.AI"
        case .custom: return L10n.k("model_priority.provider_custom", fallback: "自定义")
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax: return "MiniMax API Key"
        case .qiniu: return "sk-..."
        case .zai: return "sk-..."
        case .custom: return L10n.k("model_priority.custom_key_hint", fallback: "留空则使用环境变量")
        }
    }

    /// 该提供商预设的模型列表
    var presetModels: [(id: String, label: String)] {
        switch self {
        case .kimiCoding:
            return [("kimi-coding/k2p5", "Kimi K2.5")]
        case .minimax:
            return [
                ("minimax/MiniMax-M2.7", "MiniMax M2.7"),
                ("minimax/MiniMax-M2.7-highspeed", "MiniMax M2.7 Highspeed"),
                ("minimax/MiniMax-M2.5", "MiniMax M2.5"),
                ("minimax/MiniMax-M2.5-highspeed", "MiniMax M2.5 Highspeed"),
                ("minimax/MiniMax-VL-01", "MiniMax VL-01"),
                ("minimax/MiniMax-M2", "MiniMax M2"),
                ("minimax/MiniMax-M2.1", "MiniMax M2.1"),
            ]
        case .qiniu:
            return [
                ("qiniu/deepseek-v3.2-251201", "DeepSeek V3.2"),
                ("qiniu/z-ai/glm-5", "GLM 5"),
                ("qiniu/moonshotai/kimi-k2.5", "Kimi K2.5"),
                ("qiniu/minimax/minimax-m2.5", "Minimax M2.5"),
            ]
        case .zai:
            return [
                ("zai/glm-5.1", "GLM-5.1"),
                ("zai/glm-5", "GLM-5"),
                ("zai/glm-4.7", "GLM-4.7"),
            ]
        case .custom:
            return []
        }
    }

    var baseURL: String {
        switch self {
        case .kimiCoding: return "https://api.kimi.com/coding/"
        case .minimax: return "https://api.minimaxi.com/anthropic"
        case .qiniu: return "https://api.qnaigc.com/v1"
        case .zai: return "https://open.bigmodel.cn/api/paas/v4"
        case .custom: return ""
        }
    }

    var apiType: String {
        switch self {
        case .kimiCoding, .minimax: return "anthropic-messages"
        case .qiniu, .zai: return "openai-completions"
        case .custom: return "openai-completions"
        }
    }

    var authHeader: Bool {
        self == .minimax
    }
}

// MARK: - 主 Sheet

struct ModelPrioritySheet: View {
    let user: ManagedUser
    var onApplied: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ModelChainEntry] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isShowingAddForm = false
    @State private var hasChanges = false
    @State private var saveError: String? = nil
    @State private var showRestartConfirm = false

    // 添加表单状态
    @State private var addProvider: AddModelProvider = .qiniu
    @State private var addSelectedModelId: String = ""
    @State private var addApiKey: String = ""
    @State private var addCustomBaseURL: String = "https://api.example.com/v1"
    @State private var addCustomModelId: String = ""
    @State private var addCustomCompatibility: String = "openai-completions"
    @State private var addCustomProviderId: String = ""

    // 已有配置中各提供商的 API Key（用于判断是否已配置）
    @State private var existingProviderKeys: [String: Bool] = [:]
    // config.patch 乐观锁
    @State private var configBaseHash: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.k("model_priority.title", fallback: "模型优先级"))
                    .font(.headline)
                Spacer()
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                } else if hasChanges && !entries.isEmpty {
                    Button(L10n.k("model_priority.apply", fallback: "应用")) {
                        showRestartConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button(L10n.k("model_priority.close", fallback: "关闭")) {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if isLoading {
                Spacer()
                ProgressView(L10n.k("model_priority.loading", fallback: "读取模型配置…"))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 模型链列表
                        modelChainList

                        Divider().padding(.vertical, 4)

                        // 添加模型
                        addModelSection
                    }
                    .padding(16)
                }
            }

            // 保存错误
            if let saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 300)
        .task { await loadModels() }
        .alert(L10n.k("model_priority.restart_title", fallback: "应用模型配置"), isPresented: $showRestartConfirm) {
            Button(L10n.k("model_priority.restart_confirm", fallback: "应用")) {
                Task { await applyChanges() }
            }
            Button(L10n.k("model_priority.cancel", fallback: "取消"), role: .cancel) {}
        } message: {
            Text(L10n.k("model_priority.restart_message", fallback: "保存后 Gateway 将自动热重启以生效。"))
        }
    }

    // MARK: - 模型链列表

    private var modelChainList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text(L10n.k("model_priority.empty", fallback: "尚未配置模型"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    ModelPriorityRow(
                        entry: entry,
                        index: index,
                        total: entries.count,
                        onMoveUp: { moveEntry(at: index, direction: -1) },
                        onMoveDown: { moveEntry(at: index, direction: 1) },
                        onPromote: { promoteEntry(at: index) },
                        onRemove: { removeEntry(at: index) }
                    )
                    if index < entries.count - 1 {
                        Divider().padding(.leading, 32)
                    }
                }
            }
        }
    }

    // MARK: - 添加模型区域

    private var addModelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isShowingAddForm {
                addModelForm
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingAddForm = true
                        // 默认选中第一个可用模型
                        updateDefaultSelection()
                    }
                } label: {
                    Label(
                        L10n.k("model_priority.add_model", fallback: "添加模型"),
                        systemImage: "plus.circle"
                    )
                    .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var addModelForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 提供商选择
            Picker(L10n.k("model_priority.provider", fallback: "提供商"), selection: $addProvider) {
                ForEach(AddModelProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: addProvider) { _, _ in updateDefaultSelection() }

            if addProvider == .custom {
                // 自定义：复用 CustomProviderFormFields 组件
                CustomProviderFormFields(
                    compatibility: $addCustomCompatibility,
                    baseURL: $addCustomBaseURL,
                    apiKey: $addApiKey,
                    modelId: $addCustomModelId,
                    providerId: $addCustomProviderId
                )
            } else {
                // 预设提供商：模型下拉
                let models = addProvider.presetModels
                if !models.isEmpty {
                    Picker(L10n.k("model_priority.model", fallback: "模型"), selection: $addSelectedModelId) {
                        ForEach(models, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }
            }

            // API Key（自定义模式已包含在 CustomProviderFormFields 中）
            if addProvider != .custom {
                HStack {
                    SecureField(addProvider.apiKeyPlaceholder, text: $addApiKey)
                        .textFieldStyle(.roundedBorder)

                    if existingProviderKeys[addProvider.rawValue] == true {
                        Text(L10n.k("model_priority.key_exists", fallback: "已有密钥"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            // 按钮行
            HStack {
                Button(L10n.k("model_priority.cancel", fallback: "取消")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingAddForm = false
                        resetAddForm()
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(L10n.k("model_priority.add_to_chain", fallback: "添加到备选链")) {
                    addModelToChain()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdd)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 操作

    private var canAdd: Bool {
        let modelId = resolvedAddModelId
        guard !modelId.isEmpty else { return false }
        // 不能添加已存在的模型
        guard !entries.contains(where: { $0.id == modelId }) else { return false }

        if addProvider == .custom {
            return !addCustomBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 预设提供商：如果已有 Key 则不强制填
        if existingProviderKeys[addProvider.rawValue] == true {
            return true
        }
        return !addApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedAddModelId: String {
        if addProvider == .custom {
            return addCustomModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return addSelectedModelId
    }

    private func updateDefaultSelection() {
        if addProvider != .custom, let first = addProvider.presetModels.first {
            addSelectedModelId = first.id
        }
    }

    private func resetAddForm() {
        addApiKey = ""
        addCustomBaseURL = "https://api.example.com/v1"
        addCustomModelId = ""
        addCustomCompatibility = "openai-completions"
        addCustomProviderId = ""
        updateDefaultSelection()
    }

    private func addModelToChain() {
        let modelId = resolvedAddModelId
        guard !modelId.isEmpty, !entries.contains(where: { $0.id == modelId }) else { return }

        let label = ModelChainEntry.providerLabel(for: modelId)
        let entry = ModelChainEntry(id: modelId, providerLabel: label)
        withAnimation(.easeInOut(duration: 0.2)) {
            entries.append(entry)
            hasChanges = true
            isShowingAddForm = false
        }
        // 记住新提供商需要写入的配置
        let key = addApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if addProvider == .custom {
            // 自定义提供商：即使 apiKey 为空也需保存 baseURL 等配置
            let rawPid = addCustomProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
            let configKey = rawPid.isEmpty ? "custom" : rawPid
            pendingProviderConfigs[configKey] = PendingProviderConfig(
                provider: addProvider,
                apiKey: key,
                customBaseURL: addCustomBaseURL,
                customModelId: addCustomModelId,
                customApiType: addCustomCompatibility,
                customProviderId: addCustomProviderId
            )
        } else if !key.isEmpty {
            pendingProviderConfigs[addProvider.rawValue] = PendingProviderConfig(
                provider: addProvider,
                apiKey: key,
                customBaseURL: nil,
                customModelId: nil,
                customApiType: nil,
                customProviderId: nil
            )
        }
        resetAddForm()
    }

    @State private var pendingProviderConfigs: [String: PendingProviderConfig] = [:]

    private func moveEntry(at index: Int, direction: Int) {
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < entries.count else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            entries.swapAt(index, newIndex)
            hasChanges = true
        }
    }

    private func promoteEntry(at index: Int) {
        guard index > 0 else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            hasChanges = true
        }
    }

    private func removeEntry(at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            entries.remove(at: index)
            hasChanges = true
        }
    }

    // MARK: - 加载

    private func loadModels() async {
        isLoading = true
        defer { isLoading = false }

        // 优先通过 WebSocket 读取（带 baseHash），降级到 XPC
        do {
            let (config, hash) = try await gatewayHub.configGetFull(username: user.username)
            configBaseHash = hash
            parseConfigIntoEntries(config)
            parseExistingProviders(config)
        } catch {
            // Gateway 未连接，降级到 XPC 读取
            guard let status = await helperClient.getModelsStatus(username: user.username) else { return }
            let primary = status.resolvedDefault ?? status.defaultModel
            var loaded: [ModelChainEntry] = []
            if let p = primary {
                loaded.append(ModelChainEntry(id: p, providerLabel: ModelChainEntry.providerLabel(for: p)))
            }
            for fb in status.fallbacks where fb != primary {
                loaded.append(ModelChainEntry(id: fb, providerLabel: ModelChainEntry.providerLabel(for: fb)))
            }
            entries = loaded

            let config = await helperClient.getConfigJSON(username: user.username)
            parseExistingProviders(config)
        }
    }

    private func parseConfigIntoEntries(_ config: [String: Any]) {
        let model = (config["agents"] as? [String: Any])
            .flatMap { $0["defaults"] as? [String: Any] }
            .flatMap { $0["model"] as? [String: Any] }
        let primary = model?["primary"] as? String
        let fallbacks: [String] = (model?["fallbacks"] as? [String]) ?? []

        var loaded: [ModelChainEntry] = []
        if let p = primary {
            loaded.append(ModelChainEntry(id: p, providerLabel: ModelChainEntry.providerLabel(for: p)))
        }
        for fb in fallbacks where fb != primary {
            loaded.append(ModelChainEntry(id: fb, providerLabel: ModelChainEntry.providerLabel(for: fb)))
        }
        entries = loaded
    }

    private func parseExistingProviders(_ config: [String: Any]) {
        if let providers = (config["models"] as? [String: Any])?["providers"] as? [String: Any] {
            for key in providers.keys {
                existingProviderKeys[key] = true
            }
        }
    }

    // MARK: - 保存

    private func applyChanges() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            // 构建单一 patch 对象，包含所有变更
            var patch: [String: Any] = [:]

            // 1. 模型降级链
            let primary = entries.first?.id ?? ""
            if !primary.isEmpty {
                var modelConfig: [String: Any] = ["primary": primary]
                let fallbacks = Array(entries.dropFirst().map(\.id))
                if !fallbacks.isEmpty {
                    modelConfig["fallbacks"] = fallbacks
                }
                patch["agents"] = ["defaults": ["model": modelConfig]]
            }

            // 2. 新增的提供商配置
            if !pendingProviderConfigs.isEmpty {
                var providersDict: [String: Any] = [:]
                var authDict: [String: Any] = [:]

                for (_, config) in pendingProviderConfigs {
                    let (providerId, providerPayload, authPayload) = buildProviderPatch(config)
                    providersDict[providerId] = providerPayload
                    if let authPayload {
                        authDict["\(providerId):default"] = authPayload
                    }
                }

                // 合并到 patch（models.mode + models.providers）
                var modelsPatch: [String: Any] = ["mode": "merge"]
                modelsPatch["providers"] = providersDict
                patch["models"] = modelsPatch

                if !authDict.isEmpty {
                    var authPatch = (patch["auth"] as? [String: Any]) ?? [:]
                    authPatch["profiles"] = authDict
                    patch["auth"] = authPatch
                }
            }

            guard !patch.isEmpty else { return }

            // 优先走 WebSocket config.patch；Gateway 未连接时回退到本地直写
            do {
                let (noop, _) = try await gatewayHub.configPatch(
                    username: user.username,
                    patch: patch,
                    baseHash: configBaseHash,
                    note: "ClawdHome: model priority update"
                )
                if !noop {
                    gatewayHub.markPendingStart(username: user.username)
                }
            } catch {
                guard isGatewayConnectivityError(error) else { throw error }
                let cfg = await helperClient.getConfigJSON(username: user.username)
                try await applyPatchDirect(patch, existingConfig: cfg)
                gatewayHub.markPendingStart(username: user.username)
                try await helperClient.restartGateway(username: user.username)
            }

            hasChanges = false
            pendingProviderConfigs.removeAll()
            onApplied?()
        } catch {
            saveError = error.localizedDescription
        }
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

    /// 将 PendingProviderConfig 转为 patch 所需的字典
    private func buildProviderPatch(_ config: PendingProviderConfig) -> (id: String, provider: [String: Any], auth: [String: Any]?) {
        let provider = config.provider

        if provider == .custom {
            let rawId = (config.customProviderId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let providerId = rawId.isEmpty ? "custom" : rawId
            let baseURL = (config.customBaseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelId = (config.customModelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let apiType = config.customApiType ?? "openai-completions"
            let resolvedKey = CustomModelConfigUtils.resolvedAPIKey(config.apiKey)

            let payload: [String: Any] = [
                "baseUrl": baseURL,
                "apiKey": resolvedKey,
                "api": apiType,
                "models": [[
                    "id": modelId,
                    "name": modelId,
                    "input": ["text"],
                    "contextWindow": 128000,
                    "maxTokens": 8192,
                ] as [String: Any]],
            ]
            let auth: [String: Any] = ["provider": providerId, "mode": "api_key"]
            return (providerId, payload, auth)
        } else {
            var payload: [String: Any] = [
                "baseUrl": provider.baseURL,
                "apiKey": config.apiKey,
                "api": provider.apiType,
            ]
            if provider.authHeader {
                payload["authHeader"] = true
            }
            payload["models"] = provider.presetModels.map { model -> [String: Any] in
                [
                    "id": model.id.components(separatedBy: "/").last ?? model.id,
                    "name": model.label,
                    "input": ["text"],
                    "contextWindow": 128000,
                    "maxTokens": 8192,
                ]
            }
            let auth: [String: Any] = ["provider": provider.rawValue, "mode": "api_key"]
            return (provider.rawValue, payload, auth)
        }
    }
}

// MARK: - 待写入的提供商配置

private struct PendingProviderConfig {
    let provider: AddModelProvider
    let apiKey: String
    let customBaseURL: String?
    let customModelId: String?
    let customApiType: String?
    let customProviderId: String?
}

// MARK: - 单行 View

private struct ModelPriorityRow: View {
    let entry: ModelChainEntry
    let index: Int
    let total: Int
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onPromote: () -> Void
    var onRemove: () -> Void

    private var isPrimary: Bool { index == 0 }

    var body: some View {
        HStack(spacing: 10) {
            // 排序按钮
            VStack(spacing: 2) {
                Button { onMoveUp() } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)

                Button { onMoveDown() } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(index == total - 1)
            }
            .frame(width: 20)

            // 主模型标记
            if isPrimary {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            // 模型信息
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.id)
                    .font(.callout)
                    .fontWeight(isPrimary ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isPrimary
                     ? L10n.f("model_priority.primary_label", fallback: "%@ · 主模型", entry.providerLabel)
                     : L10n.f("model_priority.fallback_label", fallback: "%@ · 备选 #%ld", entry.providerLabel, index))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 操作菜单
            Menu {
                if !isPrimary {
                    Button {
                        onPromote()
                    } label: {
                        Label(L10n.k("model_priority.set_primary", fallback: "设为主模型"), systemImage: "star")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label(L10n.k("model_priority.remove", fallback: "移除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
