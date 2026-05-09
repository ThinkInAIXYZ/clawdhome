// ClawdHome/Views/ModelManager/LLMManagerTab.swift
// 全局模型池：按 Provider 类型聚合展示已选模型，供虾配置主备模型时快速选用

import SwiftUI

struct LLMManagerTab: View {
    @Environment(GlobalModelStore.self) private var modelStore
    @State private var showAddSheet = false
    @State private var editingProvider: ProviderTemplate? = nil
    @State private var deleteConfirmId: UUID? = nil
    @State private var configuredSecretKeys: Set<String> = []
    @State private var searchText: String = ""
    @State private var collapsedGroups: Set<String> = []

    private var deleteTarget: ProviderTemplate? {
        guard let id = deleteConfirmId else { return nil }
        return modelStore.providers.first { $0.id == id }
    }

    /// 按 group 排序的内置顺序：先内置（按 builtInModelGroups 顺序），再 custom，再其它未知 ID
    private var groupedProviders: [(groupId: String, displayName: String, providers: [ProviderTemplate])] {
        let providers = modelStore.providers
        let knownOrder: [String] = builtInModelGroups.map(\.id)
        let groupIds = Array(NSOrderedSet(array: providers.map(\.providerGroupId))) as? [String] ?? []
        let sortedIds = groupIds.sorted { a, b in
            let ai = knownOrder.firstIndex(of: a) ?? Int.max
            let bi = knownOrder.firstIndex(of: b) ?? Int.max
            if ai == bi { return a < b }
            return ai < bi
        }
        return sortedIds.map { gid in
            let bucket = providers.filter { $0.providerGroupId == gid }
            let displayName = bucket.first?.providerDisplayName
                ?? builtInModelGroups.first(where: { $0.id == gid })?.provider
                ?? gid
            return (gid, displayName, filterProviders(bucket))
        }.filter { !$0.providers.isEmpty }
    }

    /// 搜索过滤：匹配别名 / customBaseURL / 任一 modelId
    private func filterProviders(_ providers: [ProviderTemplate]) -> [ProviderTemplate] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return providers }
        return providers.filter { p in
            if p.name.lowercased().contains(q) { return true }
            if let url = p.customBaseURL?.lowercased(), url.contains(q) { return true }
            if p.modelIds.contains(where: { $0.lowercased().contains(q) }) { return true }
            return false
        }
    }

    private var hasAnyResults: Bool {
        groupedProviders.contains { !$0.providers.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderModelSheet()
        }
        .sheet(item: $editingProvider) { provider in
            AddProviderModelSheet(editing: provider)
        }
        .task { refreshConfiguredSecrets() }
        .onChange(of: modelStore.revision) { _, _ in
            refreshConfiguredSecrets()
        }
        .alert(
            L10n.f("views.model_manager.llmmanager_tab.delete_confirm", fallback: "删除「%@」？", deleteTarget?.name ?? ""),
            isPresented: Binding(
                get: { deleteConfirmId != nil },
                set: { if !$0 { deleteConfirmId = nil } }
            )
        ) {
            Button(L10n.k("views.model_manager.llmmanager_tab.delete", fallback: "删除"), role: .destructive) {
                if let id = deleteConfirmId { modelStore.removeProvider(id: id) }
                deleteConfirmId = nil
            }
            Button(L10n.k("views.model_manager.llmmanager_tab.cancel", fallback: "取消"), role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool_account", fallback: "将从全局模型池中移除该账户下所有模型型号。"))
        }
    }

    // MARK: - 顶部 Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool", fallback: "全局模型池"))
                        .font(.headline)
                    Text(L10n.k("views.model_manager.llmmanager_tab.configuration_account", fallback: "添加 OpenAI / Anthropic / 本地模型等服务商账号，每只虾可挑选其中之一使用"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // 搜索框
            if !modelStore.providers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary).font(.caption)
                    TextField(
                        L10n.k("views.model_manager.llmmanager_tab.search_placeholder", fallback: "搜索别名、URL 或模型 ID…"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain).font(.callout)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if modelStore.providers.isEmpty {
            ContentUnavailableView {
                Label(L10n.k("views.model_manager.llmmanager_tab.configuration", fallback: "尚未配置模型"), systemImage: "cpu")
            } description: {
                Text(L10n.k("models.llm_manager.empty.add_model_desc",
                            fallback: "点击「添加模型」，选择 Provider 并一次勾选多个模型。"))
            } actions: {
                Button(L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型")) {
                    showAddSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasAnyResults {
            ContentUnavailableView {
                Label(L10n.k("views.model_manager.llmmanager_tab.no_results", fallback: "无匹配结果"), systemImage: "magnifyingglass")
            } description: {
                Text(L10n.k("views.model_manager.llmmanager_tab.no_results_hint", fallback: "换个关键词或清空搜索框"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedProviders, id: \.groupId) { section in
                        groupSection(groupId: section.groupId,
                                     displayName: section.displayName,
                                     providers: section.providers)
                    }
                    Color.clear.frame(height: 60) // 给浮动按钮让位
                }
                .padding(16)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(
                        L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型"),
                        systemImage: "plus"
                    )
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                .padding(20)
            }
        }
    }

    // MARK: - Provider 分组 Section

    @ViewBuilder
    private func groupSection(groupId: String, displayName: String, providers: [ProviderTemplate]) -> some View {
        let isCollapsed = collapsedGroups.contains(groupId)
        let totalModels = providers.reduce(0) { $0 + $1.modelIds.count }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isCollapsed { collapsedGroups.remove(groupId) }
                        else { collapsedGroups.insert(groupId) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text(displayName).font(.subheadline).fontWeight(.semibold)
                        Text(L10n.f(
                            "views.model_manager.llmmanager_tab.collapsed_summary",
                            fallback: "%1$d 个账号 · %2$d 个模型",
                            providers.count,
                            totalModels
                        ))
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if !isCollapsed {
                VStack(spacing: 8) {
                    ForEach(providers) { provider in
                        providerCard(provider)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    // MARK: - Provider 卡片

    @ViewBuilder
    private func providerCard(_ provider: ProviderTemplate) -> some View {
        let isCustom = provider.providerGroupId == "custom"
        let secretKey = "\(provider.providerGroupId):\(provider.name)"
        let hasKey = configuredSecretKeys.contains(secretKey)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name.isEmpty ? provider.providerDisplayName : provider.name)
                            .font(.callout).fontWeight(.semibold)
                        Image(systemName: hasKey ? "key.fill" : "key")
                            .font(.caption2)
                            .foregroundStyle(hasKey ? Color.accentColor : Color.secondary.opacity(0.4))
                            .help(hasKey
                                  ? L10n.k("views.model_manager.llmmanager_tab.credential_configuration", fallback: "凭据已配置")
                                  : L10n.k("views.model_manager.llmmanager_tab.configuration_credential", fallback: "尚未配置凭据"))
                        if provider.modelIds.count > 1 {
                            Text("\(provider.modelIds.count)")
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isCustom, let url = provider.customBaseURL, !url.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(url)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer()
                Button { editingProvider = provider } label: {
                    Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .help(L10n.k("views.model_manager.llmmanager_tab.edit_models", fallback: "编辑型号"))

                Button { deleteConfirmId = provider.id } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help(L10n.k("views.model_manager.llmmanager_tab.account_78fbf7", fallback: "移除该账户"))
            }

            // 模型列表（去重显示）
            VStack(alignment: .leading, spacing: 4) {
                ForEach(provider.modelIds, id: \.self) { modelId in
                    let entry = builtInModelGroups.flatMap(\.models).first { $0.id == modelId }
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                        if let label = entry?.label, label != modelId {
                            HStack(spacing: 6) {
                                Text(label).font(.caption)
                                Text(modelId)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            // 自定义场景：label 与 id 相同，只显示一行
                            Text(modelId)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func refreshConfiguredSecrets() {
        configuredSecretKeys = Set(GlobalSecretsStore.shared.allEntries().map(\.secretKey))
    }
}
