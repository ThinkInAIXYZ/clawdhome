// ClawdHome/Views/ModelManager/AddProviderModelSheet.swift
// 为全局模型池新增 / 编辑一个 Provider 账户：命名 + 选提供商 + 多选型号 + 凭据

import SwiftUI

struct AddProviderModelSheet: View {
    var editing: ProviderTemplate? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var accountName: String = ""
    @State private var selectedGroupId: String = ""
    @State private var selectedModelIds: Set<String> = []
    @State private var modelSearch: String = ""

    // 凭据
    @State private var credentialInput: String = ""    // 新输入的 key/url
    @State private var existingConfigured = false      // 编辑模式：已有凭据

    private var isEditMode: Bool { editing != nil }

    private var currentGroup: ModelGroup? {
        builtInModelGroups.first { $0.id == selectedGroupId }
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
        providerKeyConfig?.inputLabel ?? "API Key"
    }

    private var credentialPlaceholder: String {
        providerKeyConfig?.placeholder ?? "sk-..."
    }

    private var isUrlInput: Bool { providerKeyConfig?.isUrlConfig == true }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题栏 ──────────────────────────────────────────
            HStack {
                Text(isEditMode ? L10n.k("auto.add_provider_model_sheet.account", fallback: "编辑账户") : L10n.k("auto.add_provider_model_sheet.provider_account", fallback: "添加 Provider 账户"))
                    .font(.headline)
                Spacer()
                Button(L10n.k("auto.add_provider_model_sheet.cancel", fallback: "取消")) { dismiss() }.keyboardShortcut(.escape)
                Button(isEditMode ? L10n.k("auto.add_provider_model_sheet.save", fallback: "保存") : L10n.k("auto.add_provider_model_sheet.add", fallback: "添加")) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty
                              || selectedGroupId.isEmpty
                              || selectedModelIds.isEmpty)
            }
            .padding()

            Divider()

            // ── 账户名称 ─────────────────────────────────────────
            HStack(spacing: 8) {
                Text(L10n.k("auto.add_provider_model_sheet.accountname", fallback: "账户名称")).font(.callout).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                TextField(L10n.k("auto.add_provider_model_sheet.anthropic", fallback: "如「Anthropic 主账号」"), text: $accountName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            // ── Provider 选择 + 模型多选 ─────────────────────────
            HSplitView {
                // 左：Provider 列表
                List(builtInModelGroups, selection: $selectedGroupId) { group in
                    HStack(spacing: 6) {
                        Text(group.provider).lineLimit(1)
                        Spacer()
                        let count = group.models.filter { selectedModelIds.contains($0.id) }.count
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

                // 右：模型多选 + 搜索
                VStack(spacing: 0) {
                    if let group = currentGroup {
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
                .frame(minWidth: 260, maxWidth: .infinity)
            }

            // ── 凭据配置 ─────────────────────────────────────────
            if providerKeyConfig != nil {
                Divider()
                credentialSection
            }
        }
        .frame(width: 540, height: providerKeyConfig != nil ? 560 : 500)
        .onAppear {
            if let p = editing {
                accountName = p.name
                selectedGroupId = p.providerGroupId
                selectedModelIds = Set(p.modelIds)
                existingConfigured = GlobalSecretsStore.shared.has(
                    secretKey: "\(p.providerGroupId):\(p.name)")
            } else {
                selectedGroupId = builtInModelGroups.first?.id ?? ""
                accountName = builtInModelGroups.first?.provider ?? ""
            }
        }
        .onChange(of: selectedGroupId) { _, newId in
            // 新增模式切换 provider 时建议账户名；同时清空搜索和凭据输入
            if !isEditMode, let group = builtInModelGroups.first(where: { $0.id == newId }) {
                accountName = group.provider
            }
            modelSearch = ""
            credentialInput = ""
            if let p = editing {
                existingConfigured = GlobalSecretsStore.shared.has(
                    secretKey: "\(p.providerGroupId):\(p.name)")
            }
        }
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
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 提交

    private func commit() {
        let name = accountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !selectedGroupId.isEmpty, !selectedModelIds.isEmpty else { return }
        let group = builtInModelGroups.first { $0.id == selectedGroupId }
        let displayName = group?.provider ?? selectedGroupId
        let ordered = (group?.models.map(\.id) ?? []).filter { selectedModelIds.contains($0) }

        let trimmed = credentialInput.trimmingCharacters(in: .whitespaces)
        if var p = editing {
            let oldSecretKey = "\(p.providerGroupId):\(p.name)"
            p.name = name
            p.modelIds = ordered
            modelStore.updateProvider(p)
            // 仅当有新输入时才更新凭据
            if !trimmed.isEmpty {
                let newEntry = SecretEntry(
                    provider: p.providerGroupId,
                    accountName: name,
                    value: trimmed
                )
                if oldSecretKey != newEntry.secretKey {
                    // 账户名变化：迁移旧条目
                    GlobalSecretsStore.shared.rename(oldKey: oldSecretKey, newEntry: newEntry)
                } else {
                    GlobalSecretsStore.shared.save(entry: newEntry)
                }
            } else if p.name != name {
                // 无新凭据但账户名变化：重命名 secrets 条目
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
                modelIds: ordered
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
}
