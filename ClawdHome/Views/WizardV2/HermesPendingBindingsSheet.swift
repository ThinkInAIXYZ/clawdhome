// ClawdHome/Views/WizardV2/HermesPendingBindingsSheet.swift
// PR-5 T5.3：待完成扫码绑定列表 Sheet
//
// 从 HermesDetailView 的"继续绑定"按钮打开。
// 列出所有 profile 中 status == .deferred 的平台，每行可点击立即绑定。

import SwiftUI

// MARK: - 待绑定项

struct PendingBindingItem: Identifiable {
    let id: String           // "\(profileID)_\(platformKey)"
    let profileID: String
    let profileDisplayName: String
    let profileEmoji: String
    let platform: HermesIMPlatformInfo
}

// MARK: - Sheet

struct HermesPendingBindingsSheet: View {
    let username: String
    let pendingItems: [PendingBindingItem]
    /// 某个 platform 绑定完成后的回调（供 parent 刷新状态）
    let onBindingDone: (String, String) -> Void   // (profileID, platformKey)
    let onBindingDeferred: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 当前正在绑定的 item（展开内嵌 HermesQRBindingStep）
    @State private var activeItemID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("hermes.pending_bindings.title", fallback: "继续绑定"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.k("hermes.pending_bindings.subtitle", fallback: "以下平台扫码配对未完成，点击【立即绑定】继续"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.k("common.action.close", fallback: "关闭")) { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if pendingItems.isEmpty {
                ContentUnavailableView(
                    L10n.k("hermes.pending_bindings.empty_title", fallback: "没有待完成的绑定"),
                    systemImage: "checkmark.circle",
                    description: Text(L10n.k("hermes.pending_bindings.empty_desc", fallback: "所有扫码平台均已配对完成"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(pendingItems) { item in
                            itemCard(item)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    // MARK: - 单行卡片

    @ViewBuilder
    private func itemCard(_ item: PendingBindingItem) -> some View {
        let isActive = activeItemID == item.id

        VStack(alignment: .leading, spacing: 0) {
            // 卡头：profile + 平台 + "立即绑定" 按钮
            HStack(spacing: 10) {
                Text(item.profileEmoji.isEmpty ? "🤖" : item.profileEmoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.profileDisplayName.isEmpty ? item.profileID : item.profileDisplayName)
                        .font(.callout.weight(.medium))
                    Text("@\(item.profileID) · \(item.platform.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if isActive {
                    Button(L10n.k("hermes.pending_bindings.collapse", fallback: "收起")) {
                        withAnimation { activeItemID = nil }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(L10n.k("hermes.pending_bindings.bind_now", fallback: "立即绑定")) {
                        withAnimation { activeItemID = item.id }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // 展开区：嵌入 HermesQRBindingStep
            if isActive {
                Divider()
                HermesQRBindingStep(
                    username: username,
                    profileID: item.profileID,
                    platform: item.platform,
                    onCompleted: {
                        withAnimation { activeItemID = nil }
                        onBindingDone(item.profileID, item.platform.key)
                    },
                    onDeferred: {
                        withAnimation { activeItemID = nil }
                        onBindingDeferred(item.profileID, item.platform.key)
                    }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
