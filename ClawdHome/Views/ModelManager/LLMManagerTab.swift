// ClawdHome/Views/ModelManager/LLMManagerTab.swift
// 全局模型池：按 Provider 账户展示已选模型，供虾配置主备模型时快速选用

import SwiftUI

struct LLMManagerTab: View {
    @Environment(GlobalModelStore.self) private var modelStore
    @State private var showAddSheet = false
    @State private var editingProvider: ProviderTemplate? = nil
    @State private var deleteConfirmId: UUID? = nil

    private var deleteTarget: ProviderTemplate? {
        guard let id = deleteConfirmId else { return nil }
        return modelStore.providers.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool", fallback: "全局模型池")).font(.headline)
                    Text(L10n.k("views.model_manager.llmmanager_tab.configuration_account", fallback: "配置各提供商账户可用模型，虾可快速选用为主备模型"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showAddSheet = true } label: {
                    Label(
                        L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

                if modelStore.providers.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.k("views.model_manager.llmmanager_tab.configuration", fallback: "尚未配置模型"), systemImage: "cpu")
                    } description: {
                        Text(
                            L10n.k(
                                "models.llm_manager.empty.add_model_desc",
                                fallback: "点击「添加模型」，选择 Provider 并一次勾选多个模型。"
                            )
                        )
                    } actions: {
                        Button(
                            L10n.k("views.model_manager.llmmanager_tab.add_model", fallback: "添加模型")
                        ) { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(modelStore.providers) { provider in
                            providerCard(provider)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderModelSheet()
        }
        .sheet(item: $editingProvider) { provider in
            AddProviderModelSheet(editing: provider)
        }
        .alert(L10n.f("views.model_manager.llmmanager_tab.delete_confirm", fallback: "删除「%@」？", deleteTarget?.name ?? ""),
               isPresented: Binding(
                   get: { deleteConfirmId != nil },
                   set: { if !$0 { deleteConfirmId = nil } }
               )) {
            Button(L10n.k("views.model_manager.llmmanager_tab.delete", fallback: "删除"), role: .destructive) {
                if let id = deleteConfirmId { modelStore.removeProvider(id: id) }
                deleteConfirmId = nil
            }
            Button(L10n.k("views.model_manager.llmmanager_tab.cancel", fallback: "取消"), role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text(L10n.k("views.model_manager.llmmanager_tab.global_model_pool_account", fallback: "将从全局模型池中移除该账户下所有模型型号。"))
        }
    }

    @ViewBuilder
    private func providerCard(_ provider: ProviderTemplate) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // 型号列表
                ForEach(provider.modelIds, id: \.self) { modelId in
                    let entry = builtInModelGroups.flatMap(\.models).first { $0.id == modelId }
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry?.label ?? modelId)
                                .font(.callout)
                            Text(modelId)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayNameWithAlias).font(.subheadline).fontWeight(.semibold)
                    Text(provider.providerGroupId)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(L10n.f("views.model_manager.llmmanager_tab.text_498748aa", fallback: "· %@ 个型号", String(describing: provider.modelIds.count)))
                    .font(.caption).foregroundStyle(.secondary)
                // 凭据状态
                let hasKey = AccountKeychain.hasCredential(for: provider.id)
                Image(systemName: hasKey ? "key.fill" : "key")
                    .font(.caption2)
                    .foregroundStyle(hasKey ? Color.accentColor : Color.secondary.opacity(0.4))
                    .help(hasKey ? L10n.k("views.model_manager.llmmanager_tab.credential_configuration", fallback: "凭据已配置") : L10n.k("views.model_manager.llmmanager_tab.configuration_credential", fallback: "尚未配置凭据"))
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
        }
    }
}
