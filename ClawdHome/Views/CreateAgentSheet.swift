// ClawdHome/Views/CreateAgentSheet.swift
// 新建 Agent 弹窗：选择来源 → 从零创建表单

import SwiftUI

struct CreateAgentSheet: View {
    let username: String
    var onCreated: ((AgentProfile) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .chooseSource
    @State private var name = ""
    @State private var emoji = ""
    @State private var agentId = ""
    @State private var modelPrimary = ""
    @State private var isCreating = false
    @State private var error: String?
    @State private var showMarketAlert = false

    enum Step { case chooseSource, createManual }

    // MARK: - 校验

    /// Agent ID 规则：小写字母/数字/下划线/短横线，1-32 位
    private var agentIdValid: Bool {
        let id = effectiveAgentId
        return id.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }

    private var effectiveAgentId: String {
        agentId.isEmpty ? name.lowercased().replacingOccurrences(of: " ", with: "_") : agentId
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && agentIdValid
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .chooseSource:
                chooseSourceView
            case .createManual:
                createManualView
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert(L10n.k("agent.create.market_coming_soon.title", fallback: "即将推出"), isPresented: $showMarketAlert) {
            Button(L10n.k("common.action.ok", fallback: "好的"), role: .cancel) {}
        } message: {
            Text(L10n.k("agent.create.market_coming_soon.message", fallback: "角色市场正在开发中，敬请期待！"))
        }
    }

    // MARK: - 模式1：选择来源

    private var chooseSourceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            Text(L10n.k("agent.create.title", fallback: "新建角色"))
                .font(.title2)
                .fontWeight(.semibold)
            Text(L10n.k("agent.create.subtitle", fallback: "为你的虾添加一个新的专业角色"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 选项卡片
            VStack(spacing: 12) {
                // 从角色市场选择
                Button {
                    showMarketAlert = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "storefront")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.k("agent.create.from_market", fallback: "从角色市场选择"))
                                .fontWeight(.medium)
                            Text(L10n.k("agent.create.from_market.desc", fallback: "浏览预设角色模板，快速上手"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // 从零创建
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .createManual
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.square")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.k("agent.create.from_scratch", fallback: "从零创建"))
                                .fontWeight(.medium)
                            Text(L10n.k("agent.create.from_scratch.desc", fallback: "自定义角色的所有细节"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            // 取消按钮
            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - 模式2：从零创建

    private var createManualView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题 + 返回
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .chooseSource
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)

                Text(L10n.k("agent.create.manual.title", fallback: "创建角色"))
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.bottom, 16)

            Form {
                Section {
                    TextField(L10n.k("agent.create.form.name", fallback: "角色名称"), text: $name)
                    TextField(L10n.k("agent.create.form.emoji", fallback: "Emoji 图标"), text: $emoji)
                        .onChange(of: emoji) { _, newValue in
                            // 只保留第一个 emoji/字符
                            if newValue.count > 1 {
                                emoji = String(newValue.prefix(1))
                            }
                        }
                } header: {
                    Text(L10n.k("agent.create.form.basic_info", fallback: "基本信息"))
                }

                Section {
                    TextField(L10n.k("agent.create.form.agent_id", fallback: "Agent ID"), text: $agentId)
                        .textContentType(.username)
                    if !name.isEmpty || !agentId.isEmpty {
                        Text(L10n.k("agent.create.form.agent_id.preview", fallback: "实际 ID：") + effectiveAgentId)
                            .font(.caption)
                            .foregroundColor(agentIdValid ? .secondary : .red)
                    }
                } header: {
                    Text(L10n.k("agent.create.form.identifier", fallback: "标识符"))
                } footer: {
                    Text(L10n.k("agent.create.form.agent_id.hint", fallback: "留空则根据名称自动生成。仅限小写字母、数字、下划线和短横线。"))
                        .font(.caption)
                }

                Section {
                    TextField(L10n.k("agent.create.form.model", fallback: "模型（可选）"), text: $modelPrimary)
                } header: {
                    Text(L10n.k("agent.create.form.model_config", fallback: "模型配置"))
                } footer: {
                    Text(L10n.k("agent.create.form.model.hint", fallback: "留空则使用默认模型。例如：claude-sonnet-4-20250514"))
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            // 错误提示
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            // 按钮
            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.k("common.action.create", fallback: "创建")) {
                    Task { await createAgent() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding(.top, 16)
        }
    }

    // MARK: - 创建逻辑

    private func createAgent() async {
        isCreating = true
        defer { isCreating = false }

        let id = effectiveAgentId
        let profile = AgentProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            emoji: emoji,
            modelPrimary: modelPrimary.isEmpty ? nil : modelPrimary,
            workspacePath: nil,
            isDefault: false
        )

        do {
            try await helperClient.createAgent(username: username, config: profile)
            onCreated?(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
