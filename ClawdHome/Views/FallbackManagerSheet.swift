// ClawdHome/Views/FallbackManagerSheet.swift
// 管理备用模型列表：从模型池快速搜索添加 / 拖序 / 删除

import SwiftUI

struct FallbackManagerSheet: View {
    let username: String
    @Binding var fallbacks: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(HelperClient.self) private var helperClient
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var searchText = ""
    @State private var isBusy = false
    @State private var errorMsg: String? = nil

    // 模型池：有全局配置时用池，否则用内置清单
    private var poolGroups: [(name: String, models: [ModelEntry])] {
        if modelStore.hasTemplate {
            return modelStore.providers.compactMap { p in
                let entries = p.modelIds.compactMap { id in
                    builtInModelGroups.flatMap(\.models).first { $0.id == id }
                        ?? ModelEntry(id: id, label: id)
                }
                return entries.isEmpty ? nil : (name: p.name, models: entries)
            }
        }
        return builtInModelGroups.map { g in (name: g.provider, models: g.models) }
    }

    private var filteredGroups: [(name: String, models: [ModelEntry])] {
        guard !searchText.isEmpty else { return poolGroups }
        return poolGroups.compactMap { group in
            let hits = group.models.filter {
                $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
            }
            return hits.isEmpty ? nil : (name: group.name, models: hits)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题栏 ──────────────────────────────────────────
            HStack {
                Text(L10n.k("auto.fallback_manager_sheet.models", fallback: "备用模型")).font(.headline)
                Spacer()
                if isBusy { ProgressView().scaleEffect(0.7) }
                Button(L10n.k("auto.fallback_manager_sheet.done", fallback: "完成")) { dismiss() }.keyboardShortcut(.return)
            }
            .padding()

            if let err = errorMsg {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { errorMsg = nil } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }

            Divider()

            // ── 当前备用列表（上半区，可拖序 + 删除）──────────────
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L10n.f("views.fallback_manager_sheet.text_47189925", fallback: "当前备用（%@ 个）", String(describing: fallbacks.count))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !fallbacks.isEmpty {
                        Text(L10n.k("auto.fallback_manager_sheet.drag_to_reorder", fallback: "拖动可排序")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

                if fallbacks.isEmpty {
                    Text(L10n.k("auto.fallback_manager_sheet.models", fallback: "暂无备用模型")).font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                } else {
                    List {
                        ForEach(fallbacks, id: \.self) { modelId in
                            let label = builtInModelGroups.flatMap(\.models)
                                .first { $0.id == modelId }?.label ?? modelId
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(label).font(.callout)
                                    Text(modelId)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .onMove { from, to in
                            fallbacks.move(fromOffsets: from, toOffset: to)
                            Task { await reorder() }
                        }
                        .onDelete { idx in
                            let toRemove = idx.map { fallbacks[$0] }
                            fallbacks.remove(atOffsets: idx)
                            Task {
                                for m in toRemove {
                                    try? await helperClient.removeFallbackModel(username: username, model: m)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(height: min(CGFloat(fallbacks.count) * 46 + 8, 180))
                }
            }

            Divider()

            // ── 从模型池快速添加（下半区）──────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(modelStore.hasTemplate ? L10n.k("auto.fallback_manager_sheet.searchmodels", fallback: "搜索模型池…") : L10n.k("auto.fallback_manager_sheet.searchmodels", fallback: "搜索内置模型…"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary).font(.caption)
                    }.buttonStyle(.plain)
                }
                if modelStore.hasTemplate {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(Color.accentColor)
                        .help(L10n.k("auto.fallback_manager_sheet.models", fallback: "来自全局模型池"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            List {
                ForEach(filteredGroups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.models) { model in
                            let isAdded = fallbacks.contains(model.id)
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.label).font(.callout)
                                        .foregroundStyle(isAdded ? .secondary : .primary)
                                    Text(model.id)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isAdded {
                                    Text(L10n.k("auto.fallback_manager_sheet.added", fallback: "已添加")).font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        Task { await quickAdd(model.id) }
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                }
                if filteredGroups.isEmpty {
                    Text(L10n.k("auto.fallback_manager_sheet.models", fallback: "无匹配模型")).font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 460, height: 540)
    }

    // MARK: - Actions

    private func quickAdd(_ modelId: String) async {
        guard !fallbacks.contains(modelId) else { return }
        isBusy = true; errorMsg = nil
        do {
            try await helperClient.addFallbackModel(username: username, model: modelId)
            fallbacks.append(modelId)
        } catch {
            errorMsg = error.localizedDescription
        }
        isBusy = false
    }

    private func reorder() async {
        isBusy = true; errorMsg = nil
        do {
            try await helperClient.setFallbackModels(username: username, models: fallbacks)
        } catch {
            errorMsg = error.localizedDescription
        }
        isBusy = false
    }
}
