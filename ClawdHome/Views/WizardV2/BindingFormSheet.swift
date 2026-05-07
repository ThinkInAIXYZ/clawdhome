// ClawdHome/Views/WizardV2/BindingFormSheet.swift
// Agent ↔ IM 账号绑定表单弹窗（v2）
//
// 功能：
// - 为一个 agent 新增/编辑 Binding 行
// - 选择 channel / accountId / peer（可选）

import SwiftUI

struct BindingFormSheet: View {
    let agents: [AgentDef]
    let imAccounts: [IMAccount]
    var existingBinding: IMBinding? = nil
    var onSave: ((IMBinding) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var selectedAgentId = ""
    @State private var selectedAccountId = ""
    @State private var peerKind: PeerKindOption = .none
    @State private var peerId = ""

    enum PeerKindOption: String, CaseIterable {
        case none = "整个账号"
        case direct = "单聊"
        case group = "群聊"
        case channel = "频道"

        var peerKind: Peer.Kind? {
            switch self {
            case .none: return nil
            case .direct: return .direct
            case .group: return .group
            case .channel: return .channel
            }
        }
    }

    private var selectedAgent: AgentDef? {
        agents.first { $0.id == selectedAgentId }
    }

    private var selectedAccount: IMAccount? {
        imAccounts.first { $0.id == selectedAccountId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.k("binding.agent_section", fallback: "Agent")) {
                    Picker(L10n.k("binding.agent", fallback: "Agent"), selection: $selectedAgentId) {
                        ForEach(agents) { agent in
                            Text(agent.displayName).tag(agent.id)
                        }
                    }
                }

                Section(L10n.k("binding.account_section", fallback: "IM 账号")) {
                    Picker(L10n.k("binding.account", fallback: "账号"), selection: $selectedAccountId) {
                        Text(L10n.k("binding.any_account", fallback: "通配（所有账号）")).tag("")
                        ForEach(imAccounts) { account in
                            Text("\(account.displayName) (\(account.platform.displayName))")
                                .tag(account.id)
                        }
                    }
                }

                Section(L10n.k("binding.peer_section", fallback: "路由到（可选）")) {
                    Picker(L10n.k("binding.peer_type", fallback: "类型"), selection: $peerKind) {
                        ForEach(PeerKindOption.allCases, id: \.rawValue) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)

                    if peerKind != .none {
                        HStack {
                            Text(L10n.k("binding.peer_id", fallback: "ID"))
                            TextField(peerIdPlaceholder, text: $peerId)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text(peerIdHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button(L10n.k("common.save", fallback: "保存")) {
                            save()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.k("binding.title", fallback: "配置绑定"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .onAppear { populate() }
    }

    // MARK: - Helpers

    private var isValid: Bool {
        guard !selectedAgentId.isEmpty else { return false }
        if peerKind != .none && peerId.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private var peerIdPlaceholder: String {
        switch peerKind {
        case .direct:  return "ou_xxx / @user"
        case .group:   return "oc_xxx / -100xxxx"
        case .channel: return "C1234567 / channel_id"
        case .none:    return ""
        }
    }

    private var peerIdHint: String {
        switch peerKind {
        case .direct:  return L10n.k("binding.hint.direct", fallback: "飞书：open_id（ou_开头）；微信：wxid 或 @username")
        case .group:   return L10n.k("binding.hint.group", fallback: "飞书：chat_id（oc_开头）；微信：群 chatroom_id（@chatroom）")
        case .channel: return L10n.k("binding.hint.channel", fallback: "Slack：C 开头频道 ID；Discord：频道 snowflake ID")
        case .none:    return ""
        }
    }

    private func populate() {
        guard let b = existingBinding else {
            selectedAgentId = agents.first?.id ?? ""
            return
        }
        selectedAgentId = b.agentId
        selectedAccountId = b.accountId ?? ""
        if let peer = b.peer {
            peerId = peer.id
            switch peer.kind {
            case .direct:  peerKind = .direct
            case .group:   peerKind = .group
            case .channel: peerKind = .channel
            }
        }
    }

    private func save() {
        guard let account = imAccounts.first(where: { $0.id == selectedAccountId }) ?? imAccounts.first else { return }
        let peer: Peer? = peerKind.peerKind.map {
            Peer(kind: $0, id: peerId.trimmingCharacters(in: .whitespaces))
        }
        let binding = IMBinding(
            id: existingBinding?.id ?? UUID(),
            agentId: selectedAgentId,
            channel: account.platform.openclawChannelId,
            accountId: selectedAccountId.isEmpty ? nil : selectedAccountId,
            peer: peer
        )
        onSave?(binding)
        dismiss()
    }
}
