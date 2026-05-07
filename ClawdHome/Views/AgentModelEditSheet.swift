// ClawdHome/Views/AgentModelEditSheet.swift
// Agent 单独模型配置弹窗：编辑主模型 + 备用模型列表

import SwiftUI

struct AgentModelEditSheet: View {
    let username: String
    let agent: AgentProfile
    var onSaved: ((AgentProfile) -> Void)? = nil

    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(\.dismiss) private var dismiss

    @State private var modelPrimary: String
    @State private var modelFallbacks: [String]
    @State private var isSaving = false
    @State private var error: String?

    init(username: String, agent: AgentProfile, onSaved: ((AgentProfile) -> Void)? = nil) {
        self.username = username
        self.agent = agent
        self.onSaved = onSaved
        _modelPrimary = State(initialValue: agent.modelPrimary ?? "")
        _modelFallbacks = State(initialValue: agent.modelFallbacks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 8) {
                Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.headline)
                    Text(L10n.k("agent.model_edit.subtitle", fallback: "模型配置"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 16)

            Form {
                Section {
                    TextField(L10n.k("agent.create.form.model", fallback: "主模型（可选）"), text: $modelPrimary)
                        .autocorrectionDisabled()

                    ForEach(modelFallbacks.indices, id: \.self) { idx in
                        HStack {
                            TextField(L10n.f("agent.create.form.fallback_model", fallback: "备用模型 %d", idx + 1), text: $modelFallbacks[idx])
                                .autocorrectionDisabled()
                            Button {
                                modelFallbacks.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        modelFallbacks.append("")
                    } label: {
                        Label(L10n.k("agent.create.form.add_fallback", fallback: "添加备用模型"), systemImage: "plus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } header: {
                    Text(L10n.k("agent.create.form.model_config", fallback: "模型配置"))
                } footer: {
                    Text(L10n.k("agent.model_edit.footer", fallback: "留空主模型则继承虾的全局默认模型。备用模型在主模型不可用时按顺序尝试。"))
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.k("common.action.save", fallback: "保存")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let primary = modelPrimary.trimmingCharacters(in: .whitespaces)
        let fallbacks = modelFallbacks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try await gatewayHub.agentsUpdate(
                username: username,
                agentId: agent.id,
                modelPrimary: primary.isEmpty ? nil : primary,
                modelFallbacks: fallbacks
            )
            var updated = agent
            updated.modelPrimary = primary.isEmpty ? nil : primary
            updated.modelFallbacks = fallbacks
            onSaved?(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
