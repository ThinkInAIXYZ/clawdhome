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
        case none = "none"
        case direct = "direct"
        case group = "group"
        case channel = "channel"

        var peerKind: Peer.Kind? {
            switch self {
            case .none: return nil
            case .direct: return .direct
            case .group: return .group
            case .channel: return .channel
            }
        }

        var localizedTitle: String {
            switch self {
            case .none: return L10n.k("binding.peer_kind.none", fallback: "Whole Account")
            case .direct: return L10n.k("binding.peer_kind.direct", fallback: "Direct Message")
            case .group: return L10n.k("binding.peer_kind.group", fallback: "Group Chat")
            case .channel: return L10n.k("binding.peer_kind.channel", fallback: "Channel")
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

                Section(L10n.k("binding.account_section", fallback: "IM Account")) {
                    Picker(L10n.k("binding.account", fallback: "Account"), selection: $selectedAccountId) {
                        Text(L10n.k("binding.any_account", fallback: "Wildcard (All Accounts)")).tag("")
                        ForEach(imAccounts) { account in
                            Text("\(account.displayName) (\(account.platform.displayName))")
                                .tag(account.id)
                        }
                    }
                }

                Section(L10n.k("binding.peer_section", fallback: "Route To (Optional)")) {
                    Picker(L10n.k("binding.peer_type", fallback: "Type"), selection: $peerKind) {
                        ForEach(PeerKindOption.allCases, id: \.rawValue) { opt in
                            Text(opt.localizedTitle).tag(opt)
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
                        Button(L10n.k("common.save", fallback: "Save")) {
                            save()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValid)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.k("binding.title", fallback: "Configure Binding"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "Cancel")) { dismiss() }
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
        case .direct:  return L10n.k("binding.hint.direct", fallback: "Feishu: open_id (prefix `ou_`); WeChat: wxid or @username")
        case .group:   return L10n.k("binding.hint.group", fallback: "Feishu: chat_id (prefix `oc_`); WeChat: group chatroom_id (`@chatroom`)")
        case .channel: return L10n.k("binding.hint.channel", fallback: "Slack: channel ID starting with C; Discord: channel snowflake ID")
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
