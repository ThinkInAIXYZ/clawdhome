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
                    Text("全局模型池").font(.headline)
                    Text("配置各提供商账户可用模型，虾可快速选用为主备模型")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showAddSheet = true } label: {
                    Label("添加账户", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            if modelStore.providers.isEmpty {
                ContentUnavailableView {
                    Label("尚未配置模型", systemImage: "cpu")
                } description: {
                    Text("点击「添加账户」，选择 Provider 和模型型号。\n同一 Provider 可添加多个账户（如主账号、备用账号）。")
                } actions: {
                    Button("添加账户") { showAddSheet = true }
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
        .alert("删除「\(deleteTarget?.name ?? "")」？",
               isPresented: Binding(
                   get: { deleteConfirmId != nil },
                   set: { if !$0 { deleteConfirmId = nil } }
               )) {
            Button("删除", role: .destructive) {
                if let id = deleteConfirmId { modelStore.removeProvider(id: id) }
                deleteConfirmId = nil
            }
            Button("取消", role: .cancel) { deleteConfirmId = nil }
        } message: {
            Text("将从全局模型池中移除该账户下所有模型型号。")
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
                    Text(provider.name).font(.subheadline).fontWeight(.semibold)
                    Text(provider.providerDisplayName)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("· \(provider.modelIds.count) 个型号")
                    .font(.caption).foregroundStyle(.secondary)
                // 凭据状态
                let hasKey = AccountKeychain.hasCredential(for: provider.id)
                Image(systemName: hasKey ? "key.fill" : "key")
                    .font(.caption2)
                    .foregroundStyle(hasKey ? Color.accentColor : Color.secondary.opacity(0.4))
                    .help(hasKey ? "凭据已配置" : "尚未配置凭据")
                Spacer()
                Button { editingProvider = provider } label: {
                    Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .help("编辑型号")

                Button { deleteConfirmId = provider.id } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.red)
                .help("移除该账户")
            }
        }
    }
}
