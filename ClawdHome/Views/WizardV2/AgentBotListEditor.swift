// ClawdHome/Views/WizardV2/AgentBotListEditor.swift
// agent 分组卡片：每个 agent 一张卡片，含可选模型 picker + IM 绑定列表 + 添加 Bot
//
// 共用于：
//   ① 初始化向导 Step 5（IM 绑定）：showModelPicker=false（模型在 Step 4 已填）
//   ② 设置面板 Agents tab：showModelPicker=true（一站式管理 agent + 模型 + IM）
//
// 设计前提（用户确认）：
//   - 1:1 绑定 — 一个 IM 入口对应一个 agent，无共享，无孤儿账号池
//   - 解绑 IM = 同时移除账号（账号脱离 agent 没有意义）
//   - 删除 agent = 级联移除该 agent 所有 binding + 关联且未被其他 agent 引用的账号

import SwiftUI

/// 用于 sheet(item:) 的添加 Bot 目标包装
fileprivate struct AddBotSheetTarget: Identifiable {
    let id = UUID()
    let agentId: String
}

/// 用于删除确认的 agent 包装
fileprivate struct PendingAgentRemoval: Identifiable {
    let id = UUID()
    let agent: AgentDef
}

struct AgentBotListEditor: View {
    @Binding var agents: [AgentDef]
    @Binding var imAccounts: [IMAccount]
    @Binding var bindings: [IMBinding]
    let username: String

    /// 是否显示每个 agent 的模型 picker（设置面板用 true，向导用 false）
    var showModelPicker: Bool = false
    /// 是否允许"添加 Agent"内联表单
    var allowAddAgent: Bool = true
    /// 任意改动回调（设置面板用来触发 isDirty）
    var onChange: (() -> Void)? = nil

    @State private var addBotTarget: AddBotSheetTarget? = nil
    @State private var pendingRemoval: PendingAgentRemoval? = nil

    // 新建 agent 内联表单状态
    @State private var newAgentInline = false
    @State private var newAgentId = ""
    @State private var newAgentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(agents) { agent in
                agentCard(for: agent)
            }
            if allowAddAgent {
                if newAgentInline {
                    addAgentInline
                } else {
                    addAgentButton
                }
            }
        }
        .sheet(item: $addBotTarget) { target in
            AddBotSheet(username: username, agentId: target.agentId) { newAccount in
                appendAccount(newAccount, for: target.agentId)
            }
        }
        .confirmationDialog(
            L10n.k("agent_bot_list.remove_agent_title", fallback: "移除 Agent？"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { item in
            Button(L10n.k("common.remove", fallback: "移除"), role: .destructive) {
                removeAgent(item.agent)
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        } message: { item in
            Text(L10n.f("agent_bot_list.remove_agent_detail",
                        fallback: "将移除 Agent「%@」及其下所有 IM 绑定与关联账号。",
                        item.agent.displayName))
        }
    }

    // MARK: - Agent 卡片

    @ViewBuilder
    private func agentCard(for agent: AgentDef) -> some View {
        let agentBindings = bindings.filter { $0.agentId == agent.id }
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：emoji + 名字 + 默认徽章 + 删除按钮
            HStack(spacing: 8) {
                Text("🤖")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.displayName)
                            .font(.headline)
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
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !agent.isDefault {
                    Button {
                        pendingRemoval = PendingAgentRemoval(agent: agent)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 模型 picker（可选）
            if showModelPicker {
                modelSection(for: agent)
            }

            Divider()

            // IM 绑定列表
            if agentBindings.isEmpty {
                Text(L10n.k("agent_bot_list.no_binding", fallback: "暂未绑定 IM"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(agentBindings) { binding in
                    bindingRow(binding)
                }
            }

            // 添加 Bot 按钮
            Button {
                addBotTarget = AddBotSheetTarget(agentId: agent.id)
            } label: {
                Label(L10n.k("agent_bot_list.add_bot", fallback: "添加 Bot"), systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - 模型 section（仅 showModelPicker=true 时渲染）

    @ViewBuilder
    private func modelSection(for agent: AgentDef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.k("agent_bot_list.model_section", fallback: "模型"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 6) {
                Text(L10n.k("agent_bot_list.primary_short", fallback: "主"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .leading)
                ModelPicker(
                    username: username,
                    selection: modelPrimaryBinding(for: agent.id),
                    allowsInheritDefault: true
                )
            }
            ForEach(modelFallbackIndices(for: agent.id), id: \.self) { idx in
                HStack(spacing: 6) {
                    Text(L10n.f("agent_bot_list.fallback_short", fallback: "备%d", idx + 1))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .leading)
                    ModelPicker(
                        username: username,
                        selection: modelFallbackBinding(for: agent.id, idx: idx),
                        allowsInheritDefault: false
                    )
                    Button {
                        removeFallback(for: agent.id, at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                appendFallback(for: agent.id)
            } label: {
                Label(L10n.k("agent_bot_list.add_fallback", fallback: "添加备用模型"), systemImage: "plus.circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - IM 绑定行

    @ViewBuilder
    private func bindingRow(_ binding: IMBinding) -> some View {
        let account = imAccounts.first { $0.id == binding.accountId }
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                let platformName = account?.platform.displayName ?? binding.channel
                let accountName = account?.displayName ?? binding.accountId ?? L10n.k("agent_bot_list.wildcard", fallback: "通配")
                Text("\(platformName) · \(accountName)")
                    .font(.callout)
                if let appId = account?.appId, !appId.isEmpty {
                    Text(appId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Menu {
                Button(role: .destructive) {
                    removeBinding(binding)
                } label: {
                    Label(L10n.k("agent_bot_list.unbind", fallback: "解绑（删除账号）"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
    }

    // MARK: - 添加 agent 内联表单

    private var addAgentButton: some View {
        Button {
            newAgentId = ""
            newAgentName = ""
            newAgentInline = true
        } label: {
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
                    newAgentInline = false
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

    private var isNewAgentValid: Bool {
        let id = newAgentId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !newAgentName.isEmpty else { return false }
        guard !agents.contains(where: { $0.id == id }) else { return false }
        return id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    // MARK: - Mutators

    private func appendAccount(_ account: IMAccount, for agentId: String) {
        if !imAccounts.contains(where: { $0.id == account.id && $0.platform == account.platform }) {
            imAccounts.append(account)
        }
        bindings.append(IMBinding(
            agentId: agentId,
            channel: account.platform.openclawChannelId,
            accountId: account.id
        ))
        onChange?()
    }

    private func removeBinding(_ binding: IMBinding) {
        bindings.removeAll { $0.id == binding.id }
        if let accountId = binding.accountId,
           !bindings.contains(where: { $0.accountId == accountId }) {
            // 1:1 模型下，账号脱离 agent 即移除
            imAccounts.removeAll { $0.id == accountId }
        }
        onChange?()
    }

    private func removeAgent(_ agent: AgentDef) {
        let removedBindings = bindings.filter { $0.agentId == agent.id }
        bindings.removeAll { $0.agentId == agent.id }
        agents.removeAll { $0.id == agent.id }
        for b in removedBindings {
            guard let accountId = b.accountId else { continue }
            if !bindings.contains(where: { $0.accountId == accountId }) {
                imAccounts.removeAll { $0.id == accountId }
            }
        }
        onChange?()
    }

    private func commitNewAgent() {
        let id = newAgentId.trimmingCharacters(in: .whitespaces)
        let name = newAgentName.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !name.isEmpty else { return }
        agents.append(AgentDef(id: id, displayName: name, isDefault: agents.isEmpty))
        newAgentInline = false
        onChange?()
    }

    // MARK: - Model picker bindings

    private func modelPrimaryBinding(for agentId: String) -> Binding<String> {
        Binding(
            get: { agents.first { $0.id == agentId }?.modelPrimary ?? "" },
            set: { newValue in
                guard let idx = agents.firstIndex(where: { $0.id == agentId }) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                agents[idx].modelPrimary = trimmed.isEmpty ? nil : trimmed
                onChange?()
            }
        )
    }

    private func modelFallbackIndices(for agentId: String) -> [Int] {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return [] }
        return Array(agent.modelFallbacks.indices)
    }

    private func modelFallbackBinding(for agentId: String, idx: Int) -> Binding<String> {
        Binding(
            get: {
                guard let agent = agents.first(where: { $0.id == agentId }),
                      idx < agent.modelFallbacks.count else { return "" }
                return agent.modelFallbacks[idx]
            },
            set: { newValue in
                guard let aIdx = agents.firstIndex(where: { $0.id == agentId }) else { return }
                guard idx < agents[aIdx].modelFallbacks.count else { return }
                agents[aIdx].modelFallbacks[idx] = newValue.trimmingCharacters(in: .whitespaces)
                onChange?()
            }
        )
    }

    private func appendFallback(for agentId: String) {
        guard let aIdx = agents.firstIndex(where: { $0.id == agentId }) else { return }
        agents[aIdx].modelFallbacks.append("")
        onChange?()
    }

    private func removeFallback(for agentId: String, at idx: Int) {
        guard let aIdx = agents.firstIndex(where: { $0.id == agentId }) else { return }
        guard idx < agents[aIdx].modelFallbacks.count else { return }
        agents[aIdx].modelFallbacks.remove(at: idx)
        onChange?()
    }
}
