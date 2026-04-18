// ClawdHome/Views/WizardV2/AgentListEditor.swift
// Agent 列表编辑器：展示 agents，支持 add / remove / set-default

import SwiftUI

struct AgentListEditor: View {
    @Binding var agents: [AgentDef]
    var canRemove: Bool = true
    var onAdd: (() -> Void)? = nil

    @State private var agentToRemove: AgentDef?
    @State private var showRemoveConfirm = false
    @State private var showAddAgent = false

    // 新建 agent 临时表单
    @State private var newAgentId = ""
    @State private var newAgentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if agents.isEmpty {
                Text(L10n.k("agents.empty", fallback: "暂无 Agent"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.vertical, 4)
            } else {
                agentList
            }
            if showAddAgent {
                addAgentInline
            } else {
                addButton
            }
        }
        .confirmationDialog(
            L10n.k("agents.remove_confirm_title", fallback: "确认移除"),
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.k("common.remove", fallback: "移除"), role: .destructive) {
                if let a = agentToRemove {
                    agents.removeAll { $0.id == a.id }
                }
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        } message: {
            if let a = agentToRemove {
                Text(L10n.k("agents.remove_confirm_detail", fallback: "将移除 Agent「\(a.displayName)」"))
            }
        }
    }

    // MARK: - Sub-views

    private var agentList: some View {
        ForEach(agents) { agent in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(agent.displayName)
                            .fontWeight(.medium)
                        if agent.isDefault {
                            Text(L10n.k("agents.default_badge", fallback: "默认"))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text("id: \(agent.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !agent.isDefault && canRemove {
                    Button(action: {
                        agentToRemove = agent
                        showRemoveConfirm = true
                    }) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            Divider()
        }
    }

    private var addButton: some View {
        Button(action: {
            newAgentId = ""
            newAgentName = ""
            showAddAgent = true
        }) {
            Label(L10n.k("agents.add", fallback: "添加 Agent"), systemImage: "plus.circle")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private var addAgentInline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.k("agents.add_id", fallback: "ID"))
                    .frame(width: 60, alignment: .trailing)
                TextField("dev / qa / support", text: $newAgentId)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(L10n.k("agents.add_name", fallback: "名称"))
                    .frame(width: 60, alignment: .trailing)
                TextField(L10n.k("agents.add_name_placeholder", fallback: "开发助手"), text: $newAgentName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(L10n.k("common.cancel", fallback: "取消")) {
                    showAddAgent = false
                }
                .buttonStyle(.plain)
                Button(L10n.k("common.add", fallback: "添加")) {
                    commitNewAgent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isNewAgentValid)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private var isNewAgentValid: Bool {
        let id = newAgentId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !newAgentName.isEmpty else { return false }
        guard !agents.contains(where: { $0.id == id }) else { return false }
        return id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    private func commitNewAgent() {
        let id = newAgentId.trimmingCharacters(in: .whitespaces)
        let name = newAgentName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else { return }
        let agent = AgentDef(id: id, displayName: name, isDefault: agents.isEmpty)
        agents.append(agent)
        showAddAgent = false
        onAdd?()
    }
}
