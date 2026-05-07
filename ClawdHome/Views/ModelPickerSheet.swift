// ClawdHome/Views/ModelPickerSheet.swift
// 选择/修改默认模型：内置精选清单 + 手动输入

import SwiftUI

struct ModelPickerSheet: View {
    let username: String
    let current: String?
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var selected: String = ""
    @State private var customInput: String = ""
    @State private var useCustom = false
    @State private var filterText = ""
    // 确认后运行 openclaw models set
    @State private var applyingModel: String? = nil

    private var isCustomMode: Bool { useCustom || !customInput.isEmpty }

    /// 优先展示全局模型池，无内容时 fallback 到完整内置清单
    private var displayGroups: [ModelGroup] {
        if modelStore.hasTemplate {
            return modelStore.providers.compactMap { p in
                let models = p.modelIds.compactMap { id in
                    builtInModelGroups.flatMap(\.models).first { $0.id == id }
                        ?? ModelEntry(id: id, label: id)
                }
                return models.isEmpty ? nil
                    : ModelGroup(id: p.id.uuidString, provider: p.name, models: models)
            }
        }
        return builtInModelGroups
    }

    private var filteredGroups: [ModelGroup] {
        guard !filterText.isEmpty else { return displayGroups }
        return displayGroups.compactMap { group in
            let hits = group.models.filter {
                $0.id.localizedCaseInsensitiveContains(filterText)
                || $0.label.localizedCaseInsensitiveContains(filterText)
            }
            return hits.isEmpty ? nil : ModelGroup(id: group.id, provider: group.provider, models: hits)
        }
    }

    private var confirmModel: String {
        isCustomMode ? customInput.trimmingCharacters(in: .whitespaces) : selected
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text(L10n.k("views.model_picker_sheet.select_default_model", fallback: "选择默认模型")).font(.headline)
                Spacer()
                Button(L10n.k("views.model_picker_sheet.cancel", fallback: "取消")) { dismiss() }.keyboardShortcut(.escape)
                Button(applyingModel == nil ? L10n.k("views.model_picker_sheet.confirm", fallback: "确认") : L10n.k("views.model_picker_sheet.applying", fallback: "应用中…")) {
                    let m = confirmModel
                    guard !m.isEmpty else { return }
                    applyingModel = m
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(confirmModel.isEmpty || applyingModel != nil)
            }
            .padding()

            Divider()

            // 来源提示
            if modelStore.hasTemplate && !useCustom {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(Color.accentColor)
                    Text(L10n.k("views.model_picker_sheet.global_model_pool", fallback: "来自全局模型池")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal).padding(.top, 6)
            }

            // 当前值提示
            if let cur = current, !cur.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text(L10n.k("views.model_picker_sheet.current_colon", fallback: "当前：")).foregroundStyle(.secondary).font(.caption)
                    Text(cur).font(.system(.caption, design: .monospaced))
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                .background(Color.green.opacity(0.05))
            }

            // 搜索 + 手动输入切换
            HStack(spacing: 8) {
                if useCustom {
                    TextField(L10n.k("views.model_picker_sheet.input_model_id_example", fallback: "输入模型 ID，如 anthropic/claude-opus-4-6"), text: $customInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.k("views.model_picker_sheet.search_models", fallback: "搜索模型…"), text: $filterText)
                        .textFieldStyle(.plain)
                }
                Button(useCustom ? L10n.k("views.model_picker_sheet.choose_from_list", fallback: "从清单选") : L10n.k("views.model_picker_sheet.manual_input", fallback: "手动输入")) {
                    useCustom.toggle()
                    filterText = ""
                    if !useCustom { customInput = "" }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

            // 内置精选清单
            if !useCustom {
                List(filteredGroups) { group in
                    Section(group.provider) {
                        ForEach(group.models) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.label).fontWeight(selected == model.id ? .semibold : .regular)
                                    Text(model.id)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.id == current {
                                    Text(L10n.k("views.model_picker_sheet.current", fallback: "当前")).font(.caption2).foregroundStyle(.secondary)
                                } else if model.id == selected {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selected = model.id }
                            .listRowBackground(selected == model.id
                                ? Color.accentColor.opacity(0.08) : Color.clear)
                        }
                    }
                }
                .listStyle(.bordered)
            } else {
                // 手动输入时展示格式提示
                VStack(spacing: 12) {
                    Image(systemName: "keyboard").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.k("views.model_picker_sheet.input_full_model_id", fallback: "输入完整模型 ID")).font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("views.model_picker_sheet.format_provider_model_id", fallback: "格式：provider/model-id")).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.k("views.model_picker_sheet.example_anthropic_opus", fallback: "示例：anthropic/claude-opus-4-6")).font(.system(.caption, design: .monospaced))
                        Text(L10n.k("views.model_picker_sheet.example_openrouter_deepseek", fallback: "示例：openrouter/deepseek/deepseek-r1")).font(.system(.caption, design: .monospaced))
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 确认后：展示终端执行 openclaw models set
            if let model = applyingModel {
                Divider()
                CommandTerminalPanel(
                    username: username,
                    subcommandArgs: ["models", "set", model],
                    minHeight: 140
                ) { exitCode in
                    if exitCode == 0 {
                        onConfirm(model)
                        dismiss()
                    }
                }
                .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(width: 480, height: applyingModel == nil ? 520 : 680)
        .onAppear { selected = current ?? "" }
    }
}
