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
    @State private var customModelIds: [String] = []
    @State private var customModelInput = ""
    @State private var customAllVisibleModels: [String] = []

    // 凭据
    @State private var credentialInput: String = ""    // 新输入的 key/url
    @State private var existingConfigured = false      // 编辑模式：已有凭据
    @State private var testContent = ""
    @State private var isTestingCredential = false
    @State private var testFeedback: String? = nil
    @State private var testFailed = false

    // 自定义 provider 模型拉取
    @State private var isFetchingCustomModels = false
    @State private var customModelSuggestions: [String] = []
    @State private var customFetchMessage: String? = nil
    @State private var customFetchError: String? = nil
    @State private var showCustomAdvanced = false
    @State private var isShowingCustomApiKey = false
    @State private var isShowingNonCustomApiKey = false

    private var isEditMode: Bool { editing != nil }
    private var isCustomGroup: Bool { selectedGroupId == "custom" }

    private var providerGroups: [ModelGroup] {
        // 模型 (id, label) 统一来自 builtInModelGroups，仅追加"自定义"空组
        var groups = builtInModelGroups
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

    private var savedCredential: String? {
        if let editing {
            let secretKey = "\(editing.providerGroupId):\(editing.name)"
            return GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: editing.providerGroupId)
        }
        guard !selectedGroupId.isEmpty else { return nil }
        return GlobalSecretsStore.shared.uniqueProviderValue(provider: selectedGroupId)
    }

    private var providerTheme: DesignSystem.GradientTheme {
        switch selectedGroupId.lowercased() {
        case "kimi": return .emerald
        case "openai": return .teal
        case "anthropic": return .purple
        case "qiniu": return .orange
        case "custom": return .blue
        default: return .blue
        }
    }

    private var providerIconName: String {
        switch selectedGroupId.lowercased() {
        case "kimi": return "bolt.shield.fill"
        case "openai": return "cpu.fill"
        case "anthropic": return "brain.head.profile"
        case "qiniu": return "cloud.fill"
        case "custom": return "gearshape.2.fill"
        default: return "cpu"
        }
    }

    @ViewBuilder
    private var providerHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(providerTheme.mainColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                
                Image(systemName: providerIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(providerTheme.gradient)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                let displayName = currentGroup?.provider ?? selectedGroupId
                Text(displayName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                
                Text(isCustomGroup 
                     ? L10n.k("add_provider_model.custom_gateway", fallback: "自定义接口网关")
                     : L10n.k("add_provider_model.official_service_provider", fallback: "官方原生服务商"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 优雅的只读锁定徽章
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text(L10n.k("add_provider_model.channel_locked", fallback: "服务商已锁定"))
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    private var canCommit: Bool {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedGroupId.isEmpty else { return false }
        guard modelStore.isAliasAvailable(name, excluding: editing?.id) else { return false }
        if isCustomGroup {
            return !customBaseURLTrimmed.isEmpty && !customModelIds.isEmpty
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

    private var effectiveCustomProviderId: String {
        customProviderIdTrimmed.isEmpty ? "custom" : customProviderIdTrimmed
    }

    private var customPrimaryModelId: String {
        guard let first = customModelIds.first else { return "" }
        return "\(effectiveCustomProviderId)/\(first)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题栏（仅标题）──────────────────────────────────
            HStack {
                Text(
                    isEditMode
                    ? L10n.k("auto.add_provider_model_sheet.edit_model", fallback: "编辑模型")
                    : L10n.k("auto.add_provider_model_sheet.add_model", fallback: "添加模型")
                )
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // ── 主体：左 Provider 列表 / 右滚动表单 ──────────────
            if isEditMode {
                // 编辑模式：单栏布局，无 sidebar 列表，带有精致 Header 且宽度更精致
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        providerHeader
                        
                        aliasField
                        
                        Divider()
                        
                        if isCustomGroup {
                            customProviderForm
                        } else if let group = currentGroup {
                            nonCustomCredentialField
                            Divider()
                            modelMultiSelect(group: group)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            } else {
                // 添加模式：两栏 HSplitView 布局
                HSplitView {
                    // 左：Provider 列表
                    List(providerGroups, selection: $selectedGroupId) { group in
                        HStack(spacing: 6) {
                            Text(group.provider).lineLimit(1)
                            Spacer()
                            let count: Int = {
                                if group.id == "custom" {
                                    return customModelIds.count
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
                        .foregroundStyle(.primary)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 160, idealWidth: 185, maxWidth: 220)

                    // 右：滚动表单
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            aliasField
                            Divider()
                            if isCustomGroup {
                                customProviderForm
                            } else if let group = currentGroup {
                                nonCustomCredentialField
                                Divider()
                                modelMultiSelect(group: group)
                            } else {
                                emptyPlaceholder
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 360, maxWidth: .infinity)
                }
            }

            Divider()

            // ── 底部固定栏：测试 + 取消/添加 ─────────────────────
            bottomBar
        }
        .frame(width: isEditMode ? 620 : 680, height: 640)
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
                if p.providerGroupId == "custom" {
                    customProviderId = p.customProviderId ?? ""
                    customModelIds = p.modelIds.compactMap { fullId in
                        let parts = fullId.split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            if customProviderId.isEmpty {
                                customProviderId = parts[0]
                            }
                            return parts[1]
                        } else if parts.count == 1 {
                            return parts[0]
                        }
                        return nil
                    }
                    customAllVisibleModels = customModelIds
                }
                if let saved = savedCredential {
                    credentialInput = saved
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
            testFeedback = nil
            testFailed = false
            if newId == "custom" {
                selectedModelIds.removeAll()
                if customBaseURLTrimmed.isEmpty {
                    customBaseURL = "https://api.example.com/v1"
                }
            } else {
                customModelIds.removeAll()
                customAllVisibleModels.removeAll()
                customModelSuggestions.removeAll()
                customModelInput = ""
            }
            if let p = editing {
                existingConfigured = GlobalSecretsStore.shared.has(
                    secretKey: "\(p.providerGroupId):\(p.name)")
                // 编辑模式：重新加载当前 provider 的已存 key（覆盖任何之前的清空）
                let secretKey = "\(p.providerGroupId):\(p.name)"
                credentialInput = GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: p.providerGroupId) ?? ""
            } else {
                // 添加模式：若该 provider 下有唯一已存 key，预填进来
                credentialInput = GlobalSecretsStore.shared.uniqueProviderValue(provider: newId) ?? ""
            }
        }
    }

    // MARK: - 别名

    @ViewBuilder
    private var aliasField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("auto.add_provider_model_sheet.alias", fallback: "渠道别名"))
                .font(.caption)
                .foregroundStyle(.primary)
            TextField(
                L10n.k("auto.add_provider_model_sheet.alias_placeholder", fallback: "随便起一个，例如：个人阿里云"),
                text: $accountName
            )
            .textFieldStyle(.roundedBorder)
            if hasDuplicateAlias {
                Text(L10n.k("add_provider_model.duplicate_alias", fallback: "别名已存在，请使用唯一别名"))
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text(L10n.k("add_provider_model.alias_hint", fallback: "用来区分同一服务商的多个账号"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 非自定义场景的 API Key 输入

    @ViewBuilder
    private var nonCustomCredentialField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Text(credentialLabel)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                if isEditMode && existingConfigured && credentialInput.isEmpty {
                    Label(L10n.k("auto.add_provider_model_sheet.configuration", fallback: "已配置"), systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            HStack(spacing: 8) {
                Group {
                    if isUrlInput {
                        TextField(credentialPlaceholder, text: $credentialInput)
                    } else if isShowingNonCustomApiKey {
                        TextField(credentialPlaceholder, text: $credentialInput)
                    } else {
                        SecureField(credentialPlaceholder, text: $credentialInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)

                if !isUrlInput {
                    Button {
                        isShowingNonCustomApiKey.toggle()
                    } label: {
                        Image(systemName: isShowingNonCustomApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(isShowingNonCustomApiKey
                          ? L10n.k("user.detail.auto.hide", fallback: "隐藏")
                          : L10n.k("user.detail.auto.show", fallback: "显示"))
                }
            }
            Text(L10n.k("auto.add_provider_model_sheet.credential_storage_hint", fallback: "凭据加密存储于本机 Keychain，仅本应用可读"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 非自定义模型多选

    @ViewBuilder
    private func modelMultiSelect(group: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Button(allSel
                       ? L10n.k("auto.add_provider_model_sheet.select_none", fallback: "全不选")
                       : L10n.k("auto.add_provider_model_sheet.select_all", fallback: "全选")) {
                    if allSel { group.models.forEach { selectedModelIds.remove($0.id) } }
                    else { group.models.forEach { selectedModelIds.insert($0.id) } }
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.callout)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(spacing: 0) {
                ForEach(filteredModels) { model in
                    let isSelected = selectedModelIds.contains(model.id)
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
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
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedModelIds.contains(model.id) { selectedModelIds.remove(model.id) }
                        else { selectedModelIds.insert(model.id) }
                    }
                }
                if filteredModels.isEmpty {
                    Text(L10n.k("auto.add_provider_model_sheet.no_matching_models", fallback: "无匹配型号"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 空状态

    @ViewBuilder
    private var emptyPlaceholder: some View {
        VStack {
            Spacer(minLength: 60)
            ContentUnavailableView(
                L10n.k("auto.add_provider_model_sheet.select_provider", fallback: "选择左侧 Provider"),
                systemImage: "sidebar.left",
                description: Text(L10n.k("auto.add_provider_model_sheet.select_models", fallback: "选择一个提供商，然后勾选需要的模型型号"))
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - 自定义 Provider 表单（无外层 padding，由父视图统一管理）

    @ViewBuilder
    private var customProviderForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("add_provider_model.compat_type", fallback: "兼容类型"))
                    .font(.caption)
                    .foregroundStyle(.primary)
                Picker(L10n.k("add_provider_model.compat_type", fallback: "兼容类型"), selection: $customAPIType) {
                    Text("OpenAI").tag("openai-completions")
                    Text("Anthropic").tag("anthropic-messages")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isEditMode && existingConfigured && credentialInput.isEmpty {
                        Label(L10n.k("auto.add_provider_model_sheet.configuration", fallback: "已配置"), systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                HStack(spacing: 8) {
                    Group {
                        if isShowingCustomApiKey {
                            TextField("sk-...", text: $credentialInput)
                        } else {
                            SecureField("sk-...", text: $credentialInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    Button {
                        isShowingCustomApiKey.toggle()
                    } label: {
                        Image(systemName: isShowingCustomApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(isShowingCustomApiKey
                          ? L10n.k("user.detail.auto.hide", fallback: "隐藏")
                          : L10n.k("user.detail.auto.show", fallback: "显示"))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.k("add_provider_model.model_id", fallback: "模型 ID"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                
                HStack(spacing: 8) {
                    TextField(L10n.k("add_provider_model.custom_model_input_placeholder", fallback: "输入模型 ID，回车或点击 + 添加"), text: $customModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            addCustomModel()
                        }
                    
                    Button {
                        addCustomModel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // 拉取模型 API 的操作栏
                HStack(spacing: 8) {
                    Button(isFetchingCustomModels
                           ? L10n.k("views.custom_provider.fetching", fallback: "拉取中…")
                           : L10n.k("views.custom_provider.fetch_from_api", fallback: "从 API 拉取列表")) {
                        Task { await fetchCustomModels() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isFetchingCustomModels || customBaseURLTrimmed.isEmpty)
                }
                .padding(.top, 2)

                if let customFetchMessage {
                    Text(customFetchMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let customFetchError {
                    Text(customFetchError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                // 合二为一：统一模型列表展示与打勾选择
                if !customAllVisibleModels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.k("add_provider_model.custom_model_id_list", fallback: "模型列表") + " (\(customModelIds.count)/\(customAllVisibleModels.count))")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            
                            let allSel = customAllVisibleModels.allSatisfy { customModelIds.contains($0) }
                            Button(allSel
                                   ? L10n.k("auto.add_provider_model_sheet.select_none", fallback: "全不选")
                                   : L10n.k("auto.add_provider_model_sheet.select_all", fallback: "全选")) {
                                if allSel {
                                    for item in customAllVisibleModels {
                                        customModelIds.removeAll { $0 == item }
                                    }
                                } else {
                                    for item in customAllVisibleModels {
                                        if !customModelIds.contains(item) {
                                            customModelIds.append(item)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 12))
                        }
                        .padding(.top, 4)

                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(customAllVisibleModels, id: \.self) { item in
                                    let isSelected = customModelIds.contains(item)
                                    HStack(spacing: 10) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                            .font(.system(size: 16))
                                        
                                        Text(item)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        
                                        Spacer()
                                        
                                        Button {
                                            customModelIds.removeAll { $0 == item }
                                            customAllVisibleModels.removeAll { $0 == item }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.k("add_provider_model.remove_model", fallback: "从列表移除"))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isSelected {
                                            customModelIds.removeAll { $0 == item }
                                        } else {
                                            customModelIds.append(item)
                                        }
                                    }
                                    .background(Color.secondary.opacity(isSelected ? 0.04 : 0.0))
                                    .cornerRadius(4)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .padding(.top, 6)
                }
            }

            DisclosureGroup(isExpanded: $showCustomAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("add_provider_model.provider_id_optional", fallback: "Provider ID（可选，默认 custom）"))
                            .font(.caption)
                            .foregroundStyle(.primary)
                        TextField("custom", text: $customProviderId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        
                        Text(L10n.k("add_provider_model.provider_id_optional_hint", fallback: "API 调用时的模型名前缀。如前缀为 custom，则客户端调用模型名为 custom/模型ID。如无特殊要求请保持默认。"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let allMapped = customModelIds.map { "\(effectiveCustomProviderId)/\($0)" }
                    Text(L10n.k("add_provider_model.custom_model_id_list", fallback: "模型列表") + ": " + (allMapped.isEmpty ? "-" : allMapped.joined(separator: ", ")))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text(L10n.k("add_provider_model.advanced", fallback: "高级"))
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 底部固定按钮栏（测试 + 取消/添加）

    @ViewBuilder
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !selectedGroupId.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.k("add_provider_model.test_content", fallback: "测试内容（留空默认：请发送你好）"), text: $testContent)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    HStack(alignment: .top, spacing: 10) {
                        Button(isTestingCredential
                               ? L10n.k("add_provider_model.testing", fallback: "测试中…")
                               : L10n.k("add_provider_model.test_config", fallback: "测试配置")) {
                            Task { await testCredential() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isTestingCredential)
                        if let testFeedback {
                            Label(testFeedback, systemImage: testFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(testFailed ? .red : .green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(4)
                                .truncationMode(.tail)
                        }
                    }
                }
                Divider()
            }
            HStack(spacing: 10) {
                Button(L10n.k("auto.add_provider_model_sheet.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(
                    isEditMode
                    ? L10n.k("auto.add_provider_model_sheet.save", fallback: "保存")
                    : L10n.k("auto.add_provider_model_sheet.add_model", fallback: "添加模型")
                ) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(!canCommit)
            }
        }
        .padding(14)
    }

    private func addCustomModel() {
        let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !customModelIds.contains(trimmed) {
            customModelIds.append(trimmed)
        }
        if !customAllVisibleModels.contains(trimmed) {
            customAllVisibleModels.insert(trimmed, at: 0)
        }
        customModelInput = ""
    }

    // MARK: - 拉取自定义模型列表

    @MainActor
    private func fetchCustomModels() async {
        let trimmedURL = customBaseURLTrimmed
        guard !trimmedURL.isEmpty else {
            customFetchError = L10n.k("views.custom_provider.invalid_base_url", fallback: "请先填写有效的 Base URL")
            customFetchMessage = nil
            return
        }
        isFetchingCustomModels = true
        customFetchError = nil
        customFetchMessage = nil
        defer { isFetchingCustomModels = false }
        do {
            let key = (resolvedCredentialForTest() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = try await CustomModelConfigUtils.fetchModelIDs(
                baseURL: trimmedURL,
                apiKey: key.isEmpty ? nil : key
            )
            if ids.isEmpty {
                customModelSuggestions = []
                customFetchMessage = L10n.k("views.custom_provider.no_models_found", fallback: "已请求成功，但未解析到可用模型 ID（该接口可能不支持标准 list）")
                return
            }
            customModelSuggestions = ids
            for id in ids {
                if !customAllVisibleModels.contains(id) {
                    customAllVisibleModels.append(id)
                }
            }
            customFetchMessage = L10n.f("views.custom_provider.models_fetched", fallback: "已拉取 %d 个模型", ids.count)
        } catch {
            customFetchError = error.localizedDescription
        }
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
            ordered = customModelIds.map { "\(effectiveCustomProviderId)/\($0)" }
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
            testFeedback = isCustomGroup ? L10n.k("add_provider_model.validate.no_model_id", fallback: "请先填写自定义模型 ID") : L10n.k("add_provider_model.validate.no_model_selected", fallback: "请先选择至少一个模型")
            return
        }
        guard let apiKey = resolvedCredentialForTest(), !apiKey.isEmpty else {
            testFailed = true
            testFeedback = L10n.k("add_provider_model.validate.no_credential", fallback: "请先填写或保留可用凭据")
            return
        }

        let prompt = testContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.k("add_provider_model.test.default_prompt", fallback: "请发送你好")
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
                testFeedback = String(format: L10n.k("add_provider_model.test.success", fallback: "测试成功（%.0fms）"), result.latencyMs)
            } else {
                testFeedback = String(format: L10n.k("add_provider_model.test.success_with_response", fallback: "测试成功（%.0fms）：%@"), result.latencyMs, response)
            }
            testFailed = false
        } else {
            testFeedback = result.errorMessage ?? L10n.k("add_provider_model.test.failed", fallback: "测试失败")
            testFailed = true
        }
    }

    private func routeOptions(for modelId: String) -> (baseURL: String?, apiType: String?, authHeader: Bool) {
        if isCustomGroup {
            let base = customBaseURLTrimmed
            return (base.isEmpty ? nil : base, customAPIType, false)
        }
        if modelId.hasPrefix("bailian/") {
            return ("https://coding.dashscope.aliyuncs.com/v1", "openai-completions", false)
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
