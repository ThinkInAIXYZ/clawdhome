// ClawdHome/Views/WizardV2/IMAccountListEditor.swift
// 展示 + 管理某平台的 IM 账号列表（add / remove）

import SwiftUI

struct IMAccountListEditor: View {
    @Binding var accounts: [IMAccount]
    let username: String
    var onAdd: (() -> Void)? = nil

    @State private var showAddBot = false
    @State private var accountToDelete: IMAccount?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
            addButton
        }
        .sheet(isPresented: $showAddBot) {
            AddBotSheet(username: username, agentId: "") { newAccount in
                if !accounts.contains(where: { $0.id == newAccount.id && $0.platform == newAccount.platform }) {
                    accounts.append(newAccount)
                }
            }
        }
        .confirmationDialog(
            L10n.k("im_accounts.delete_confirm_title", fallback: "确认移除"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.k("common.remove", fallback: "移除"), role: .destructive) {
                if let a = accountToDelete {
                    accounts.removeAll { $0.id == a.id }
                }
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        } message: {
            if let a = accountToDelete {
                Text(L10n.k("im_accounts.delete_confirm_detail", fallback: "将移除 \(a.displayName)（\(a.platform.displayName)）"))
            }
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        Text(L10n.k("im_accounts.empty", fallback: "暂无 IM 账号，点击 + 添加"))
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.vertical, 4)
    }

    private var accountList: some View {
        ForEach(accounts) { account in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .fontWeight(.medium)
                    Text(account.platform.displayName + (account.appId.map { " · \($0.prefix(12))" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: {
                    accountToDelete = account
                    showDeleteConfirm = true
                }) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            Divider()
        }
    }

    private var addButton: some View {
        Button(action: {
            onAdd?()
            showAddBot = true
        }) {
            Label(L10n.k("im_accounts.add", fallback: "添加 Bot 账号"), systemImage: "plus.circle")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
