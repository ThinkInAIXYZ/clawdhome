// ClawdHome/Views/ModelManager/AddProviderModelSheet.swift
// 为全局模型池新增 / 编辑一个 Provider 渠道：命名 + 选提供商 + 模型/自定义参数 + 凭据

import SwiftUI

struct AddProviderModelSheet: View {
    var editing: ProviderTemplate? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var accountName: String = ""
    @State private var selectedGroupId: String = ""
    @State private var selectedModelIds: Set<String> = []
    @State private var modelSearch: String = ""

    // 自定义 provider 渠道信息
    @State private var customProviderId = ""
    @State private var customBaseURL = "https://api.example.com/v1"
    @State private var customAPIType = "openai-completions"
    @State private var customModelId = ""

    // 凭据
    @State private var credentialInput: String = ""    // 新输入的 key/url
    @State private var existingConfigured = false      // 编辑模式：已有凭据
    @State private var testContent = ""
    @State private var isTestingCredential = false
    @State private var testFeedback: String? = nil
    @State private var testFailed = false

    private var isEditMode: Bool { editing != nil }
    private var isCustomGroup: Bool { selectedGroupId == "custom" }

    private var providerGroups: [ModelGroup] {
        var groups = builtInModelGroups
        if !groups.contains(where: { $0.id == "kimi-coding" }) {
            groups.append(ModelGroup(id: "kimi-coding", provider: "Kimi Code", models: [
                ModelEntry(id: "kimi-coding/k2p5", label: "Kimi K2.5"),
            ]))
        }
        if !groups.contains(where: { $0.id == "qiniu" }) {
            groups.append(ModelGroup(id: "qiniu", provider: "Qiniu AI", models: [
                ModelEntry(id: "qiniu/deepseek-v3.2-251201", label: "DeepSeek V3.2"),
                ModelEntry(id: "qiniu/z-ai/glm-5", label: "GLM 5"),
                ModelEntry(id: "qiniu/moonshotai/kimi-k2.5", label: "Kimi K2.5"),
                ModelEntry(id: "qiniu/minimax/minimax-m2.5", label: "Minimax M2.5"),
            ]))
        }
        if !groups.contains(where: { $0.id == "zai" }) {
            groups.append(ModelGroup(id: "zai", provider: "智谱 Z.AI", models: [
                ModelEntry(id: "zai/glm-5.1", label: "GLM-5.1"),
                ModelEntry(id: "zai/glm-5", label: "GLM-5"),
                ModelEntry(id: "zai/glm-4.7", label: "GLM-4.7"),
            ]))
        }
        if !groups.contains(where: { $0.id == "custom" }) {
            groups.append(ModelGroup(id: "custom", provider: "自定义", models: []))
        }
        return groups
    }

    private var currentGroup: ModelGroup? {
        providerGroups.first { $0.id == selectedGroupId }
    }

    private var filteredModels: [ModelEntry] {
        guard let group = currentGroup else { return [] }
        guard !modelSearch.isEmpty else { return group.models }
        return group.models.filter {
            $0.label.localizedCaseInsensitiveContains(modelSearch)
            || $0.id.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    /// 当前 provider 的凭据配置（来自 supportedProviderKeys）
    private var providerKeyConfig: ProviderKeyConfig? {
        supportedProviderKeys.first { $0.id == selectedGroupId }
    }

    private var credentialLabel: String {
        if isCustomGroup { return "API Key" }
        return providerKeyConfig?.inputLabel ?? "API Key"
    }

    private var credentialPlaceholder: String {
        if isCustomGroup { return "sk-..." }
        return providerKeyConfig?.placeholder ?? "sk-..."
    }

    private var isUrlInput: Bool {
        guard !isCustomGroup else { return false }
        return providerKeyConfig?.isUrlConfig == true
    }

    private var canCommit: Bool {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedGroupId.isEmpty else { return false }
        guard modelStore.isAliasAvailable(name, excluding: editing?.id) else { return false }
        if isCustomGroup {
            return !customBaseURLTrimmed.isEmpty && !customModelIdTrimmed.isEmpty
        }
        return !selectedModelIds.isEmpty
    }

    private var hasDuplicateAlias: Bool {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return !modelStore.isAliasAvailable(name, excluding: editing?.id)
    }

    private var customProviderIdTrimmed: String {
        customProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customBaseURLTrimmed: String {
        customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customModelIdTrimmed: String {
        customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveCustomProviderId: String {
        customProviderIdTrimmed.isEmpty ? "custom" : customProviderIdTrimmed
    }

    private var customPrimaryModelId: String {
        guard !customModelIdTrimmed.isEmpty else { return "" }
        return "\(effectiveCustomProviderId)/\(customModelIdTrimmed)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题栏 ──────────────────────────────────────────
            HStack {
                Text(
                    isEditMode
                    ? L10n.k("auto.add_provider_model_sheet.edit_model", fallback: "编辑模型")
                    : L10n.k("auto.add_provider_model_sheet.add_model", fallback: "添加模型")
                )
                    .font(.headline)
                Spacer()
                Button(L10n.k("auto.add_provider_model_sheet.cancel", fallback: "取消")) { dismiss() }.keyboardShortcut(.escape)
                Button(
                    isEditMode
                    ? L10n.k("auto.add_provider_model_sheet.save", fallback: "保存")
                    : L10n.k("auto.add_provider_model_sheet.add_model", fallback: "添加模型")
                ) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canCommit)
            }
            .padding()

            Divider()

            // ── 别名 ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(L10n.k("auto.add_provider_model_sheet.alias", fallback: "别名")).font(.callout).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    TextField(L10n.k("auto.add_provider_model_sheet.alias_placeholder", fallback: "如「主线路」"), text: $accountName)
                        .textFieldStyle(.roundedBorder)
                }
                if hasDuplicateAlias {
                    HStack {
                        Spacer().frame(width: 72)
                        Text("别名已存在，请使用唯一别名")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            // ── Provider 选择 + 渠道配置 ─────────────────────────
            HSplitView {
                // 左：Provider 列表
                List(providerGroups, selection: $selectedGroupId) { group in
                    HStack(spacing: 6) {
                        Text(group.provider).lineLimit(1)
                        Spacer()
                        let count: Int = {
                            if group.id == "custom" {
                                return customModelIdTrimmed.isEmpty ? 0 : 1
                            }
                            return group.models.filter { selectedModelIds.contains($0.id) }.count
                        }()
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .tag(group.id)
                    .disabled(isEditMode && group.id != selectedGroupId)
                    .foregroundStyle(isEditMode && group.id != selectedGroupId
                                     ? Color.secondary.opacity(0.4) : .primary)
                }
                .listStyle(.sidebar)
                .frame(minWidth: 160, idealWidth: 185, maxWidth: 220)

                // 右：模型多选 / 自定义配置
                VStack(spacing: 0) {
                    if isCustomGroup {
                        customProviderForm
                    } else if let group = currentGroup {
                        // 搜索栏 + 全选
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary).font(.caption)
                            TextField(L10n.k("auto.add_provider_model_sheet.search", fallback: "搜索型号…"), text: $modelSearch)
                                .textFieldStyle(.plain).font(.callout)
                            if !modelSearch.isEmpty {
                                Button { modelSearch = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary).font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            Divider().frame(height: 14)
                            let allSel = group.models.allSatisfy { selectedModelIds.contains($0.id) }
                            Button(allSel ? L10n.k("auto.add_provider_model_sheet.select_none", fallback: "全不选") : L10n.k("auto.add_provider_model_sheet.select_all", fallback: "全选")) {
                                if allSel { group.models.forEach { selectedModelIds.remove($0.id) } }
                                else { group.models.forEach { selectedModelIds.insert($0.id) } }
                            }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.callout)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)

                        Divider()

                        List {
                            ForEach(filteredModels) { model in
                                let isSelected = selectedModelIds.contains(model.id)
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                        .font(.system(size: 16))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.label).fontWeight(isSelected ? .semibold : .regular)
                                        Text(model.id)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedModelIds.contains(model.id) { selectedModelIds.remove(model.id) }
                                    else { selectedModelIds.insert(model.id) }
                                }
                            }
                            if filteredModels.isEmpty {
                                Text(L10n.k("auto.add_provider_model_sheet.no_matching_models", fallback: "无匹配型号")).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain)
                    } else {
                        ContentUnavailableView(
                            L10n.k("auto.add_provider_model_sheet.select_provider", fallback: "选择左侧 Provider"),
                            systemImage: "sidebar.left",
                            description: Text(L10n.k("auto.add_provider_model_sheet.select_models", fallback: "选择一个提供商，然后勾选需要的模型型号"))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity)
            }

            // ── 凭据配置 ─────────────────────────────────────────
            if !selectedGroupId.isEmpty {
                Divider()
                credentialSection
            }
        }
        .frame(width: 580, height: selectedGroupId.isEmpty ? 500 : (isCustomGroup ? 650 : 580))
        .onAppear {
            if let p = editing {
                accountName = p.name
                selectedGroupId = p.providerGroupId
                selectedModelIds = Set(p.modelIds)
                existingConfigured = GlobalSecretsStore.shared.has(
                    secretKey: "\(p.providerGroupId):\(p.name)")
                customProviderId = p.customProviderId ?? ""
                customBaseURL = p.customBaseURL ?? "https://api.example.com/v1"
                customAPIType = p.customAPIType ?? "openai-completions"
                if let customPrimary = p.modelIds.first, p.providerGroupId == "custom" {
                    let parts = customPrimary.split(separator: "/", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        customProviderId = p.customProviderId ?? parts[0]
                        customModelId = parts[1]
                    }
                }
            } else {
                selectedGroupId = providerGroups.first?.id ?? ""
                accountName = ""
            }
        }
        .onChange(of: selectedGroupId) { _, newId in
            // 新增模式切换 provider 时清空别名，由用户输入唯一别名
            if !isEditMode, providerGroups.contains(where: { $0.id == newId }) {
                accountName = ""
            }
            modelSearch = ""
            credentialInput = ""
            testFeedback = nil
            testFailed = false
            if newId == "custom" {
                selectedModelIds.removeAll()
                if customBaseURLTrimmed.isEmpty {
                    customBaseURL = "https://api.example.com/v1"
                }
            }
            if let p = editing {
                existingConfigured = GlobalSecretsStore.shared.has(
                    secretKey: "\(p.providerGroupId):\(p.name)")
            }
        }
    }

    @ViewBuilder
    private var customProviderForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("兼容类型")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Picker("兼容类型", selection: $customAPIType) {
                    Text("OpenAI").tag("openai-completions")
                    Text("Anthropic").tag("anthropic-messages")
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Base URL")
                    .font(.caption)
                    .foregroundStyle(.primary)
                TextField("https://api.example.com/v1", text: $customBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Provider ID（可选，默认 custom）")
                    .font(.caption)
                    .foregroundStyle(.primary)
                TextField("custom", text: $customProviderId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("模型 ID")
                    .font(.caption)
                    .foregroundStyle(.primary)
                TextField("例如 gpt-4.1 / claude-3-7-sonnet", text: $customModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text("主模型：\(customPrimaryModelId.isEmpty ? "-" : customPrimaryModelId)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    // MARK: - 凭据区域

    @ViewBuilder
    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Text(credentialLabel).font(.callout).fontWeight(.medium)
                Spacer()
                if isEditMode && existingConfigured && credentialInput.isEmpty {
                    Label(L10n.k("auto.add_provider_model_sheet.configuration", fallback: "已配置"), systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }

            if isUrlInput {
                TextField(credentialPlaceholder, text: $credentialInput)
                    .textFieldStyle(.roundedBorder).font(.callout)
            } else {
                SecureField(
                    isEditMode && existingConfigured ? L10n.k("auto.add_provider_model_sheet.input", fallback: "输入新值可更换，留空保持不变") : credentialPlaceholder,
                    text: $credentialInput
                )
                .textFieldStyle(.roundedBorder).font(.callout)
            }

            Text(isEditMode && existingConfigured
                 ? L10n.k("auto.add_provider_model_sheet.leave_blank_to_keep_current_credentials", fallback: "留空则保持现有凭据不变")
                 : L10n.k("auto.add_provider_model_sheet.configurationfile_sync_openclaw_configuration", fallback: "凭据存储在本机配置文件，点击「同步凭据」可写入虾的 openclaw 配置"))
                .font(.caption2).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                TextField("测试内容（留空默认：请发送你好）", text: $testContent)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                HStack(spacing: 10) {
                    Button(isTestingCredential ? "测试中…" : "测试配置") {
                        Task { await testCredential() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTestingCredential)
                    if let testFeedback {
                        Label(testFeedback, systemImage: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(testFailed ? .red : .green)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 提交

    private func commit() {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCommit else { return }
        guard modelStore.isAliasAvailable(name, excluding: editing?.id) else { return }

        let group = providerGroups.first { $0.id == selectedGroupId }
        let displayName = group?.provider ?? selectedGroupId

        let ordered: [String]
        let customProviderIdToSave: String?
        let customBaseURLToSave: String?
        let customAPITypeToSave: String?
        if isCustomGroup {
            ordered = [customPrimaryModelId].filter { !$0.isEmpty }
            customProviderIdToSave = effectiveCustomProviderId
            customBaseURLToSave = customBaseURLTrimmed
            customAPITypeToSave = customAPIType
        } else {
            ordered = (group?.models.map(\.id) ?? []).filter { selectedModelIds.contains($0) }
            customProviderIdToSave = nil
            customBaseURLToSave = nil
            customAPITypeToSave = nil
        }

        let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if var p = editing {
            let oldName = p.name
            let oldSecretKey = "\(p.providerGroupId):\(p.name)"
            p.name = name
            p.providerDisplayName = displayName
            p.modelIds = ordered
            p.customProviderId = customProviderIdToSave
            p.customBaseURL = customBaseURLToSave
            p.customAPIType = customAPITypeToSave
            modelStore.updateProvider(p)

            // 仅当有新输入时才更新凭据
            if !trimmed.isEmpty {
                let newEntry = SecretEntry(
                    provider: p.providerGroupId,
                    accountName: name,
                    value: trimmed
                )
                if oldSecretKey != newEntry.secretKey {
                    // 渠道名变化：迁移旧条目
                    GlobalSecretsStore.shared.rename(oldKey: oldSecretKey, newEntry: newEntry)
                } else {
                    GlobalSecretsStore.shared.save(entry: newEntry)
                }
            } else if oldName != name {
                // 无新凭据但渠道名变化：重命名 secrets 条目
                let oldEntry = GlobalSecretsStore.shared.allEntries()
                    .first { $0.secretKey == oldSecretKey }
                if let old = oldEntry {
                    let renamed = SecretEntry(provider: old.provider, accountName: name, value: old.value)
                    GlobalSecretsStore.shared.rename(oldKey: oldSecretKey, newEntry: renamed)
                }
            }
        } else {
            let entry = ProviderTemplate(
                name: name,
                providerGroupId: selectedGroupId,
                providerDisplayName: displayName,
                modelIds: ordered,
                customProviderId: customProviderIdToSave,
                customBaseURL: customBaseURLToSave,
                customAPIType: customAPITypeToSave
            )
            modelStore.addProvider(entry)
            // 保存凭据（若有输入）
            if !trimmed.isEmpty {
                GlobalSecretsStore.shared.save(entry: SecretEntry(
                    provider: selectedGroupId,
                    accountName: name,
                    value: trimmed
                ))
            }
        }
        dismiss()
    }

    private var selectedTestModelId: String? {
        if isCustomGroup {
            let primary = customPrimaryModelId
            return primary.isEmpty ? nil : primary
        }
        if let group = currentGroup {
            return group.models.first(where: { selectedModelIds.contains($0.id) })?.id
        }
        return selectedModelIds.first
    }

    private func resolvedCredentialForTest() -> String? {
        let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let editing {
            let secretKey = "\(editing.providerGroupId):\(editing.name)"
            return GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: editing.providerGroupId)
        }
        guard !selectedGroupId.isEmpty else { return nil }
        return GlobalSecretsStore.shared.uniqueProviderValue(provider: selectedGroupId)
    }

    @MainActor
    private func testCredential() async {
        testFeedback = nil
        testFailed = false

        guard let modelId = selectedTestModelId else {
            testFailed = true
            testFeedback = isCustomGroup ? "请先填写自定义模型 ID" : "请先选择至少一个模型"
            return
        }
        guard let apiKey = resolvedCredentialForTest(), !apiKey.isEmpty else {
            testFailed = true
            testFeedback = "请先填写或保留可用凭据"
            return
        }

        let prompt = testContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "请发送你好"
            : testContent.trimmingCharacters(in: .whitespacesAndNewlines)

        let route = routeOptions(for: modelId)
        isTestingCredential = true
        let result = await ModelPingService.shared.ping(
            modelId: modelId,
            apiKey: apiKey,
            message: prompt,
            baseURL: route.baseURL,
            apiType: route.apiType,
            authHeader: route.authHeader
        )
        isTestingCredential = false

        if result.success {
            let response = (result.responseText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if response.isEmpty {
                testFeedback = String(format: "测试成功（%.0fms）", result.latencyMs)
            } else {
                testFeedback = String(format: "测试成功（%.0fms）：%@", result.latencyMs, response)
            }
            testFailed = false
        } else {
            testFeedback = result.errorMessage ?? "测试失败"
            testFailed = true
        }
    }

    private func routeOptions(for modelId: String) -> (baseURL: String?, apiType: String?, authHeader: Bool) {
        if isCustomGroup {
            let base = customBaseURLTrimmed
            return (base.isEmpty ? nil : base, customAPIType, false)
        }
        if modelId.hasPrefix("minimax/") {
            return ("https://api.minimaxi.com/anthropic", "anthropic-messages", true)
        }
        if modelId.hasPrefix("qiniu/") {
            return ("https://api.qnaigc.com/v1", "openai-completions", false)
        }
        if modelId.hasPrefix("zai/") {
            return ("https://open.bigmodel.cn/api/paas/v4", "openai-completions", false)
        }
        if modelId.hasPrefix("kimi-coding/") {
            return ("https://api.kimi.com/coding", "anthropic-messages", false)
        }
        return (nil, nil, false)
    }
}
