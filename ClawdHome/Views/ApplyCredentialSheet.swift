// ClawdHome/Views/ApplyCredentialSheet.swift
// 将全局模型池账户的凭据同步到指定虾（External Secrets Management 模式）
// 使用 openclaw 2026.2.26+ 的 keyRef 格式，不再直接写明文 key 到 config

import SwiftUI

struct ApplyCredentialSheet: View {
    let username: String

    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(HelperClient.self) private var helperClient

    /// 是否正在整体同步（L10n.k("views.apply_credential_sheet.sync_all", fallback: "同步全部")按钮使用）
    @State private var isSyncingAll = false
    /// 单个账户同步中（accountId → 是否在进行）
    @State private var syncingId: UUID? = nil
    @State private var errorMsg: String? = nil
    @State private var successMsg: String? = nil

    // 账户分三类
    private enum CredentialState {
        case apiKey    // GlobalSecretsStore 中有 value
        case oauth     // 支持 OAuth，暂未实现
        case missing   // 未配置凭据
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 标题栏 ─────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("views.apply_credential_sheet.sync_credentials", fallback: "同步凭据")).font(.headline)
                    Text(L10n.k("views.apply_credential_sheet.secrets_openclaw", fallback: "将全局 secrets 写入虾的 ~/.openclaw/"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSyncingAll {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button(L10n.k("views.apply_credential_sheet.sync_all", fallback: "同步全部")) {
                        Task { await syncAll() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSyncAny)
                }
                Button(L10n.k("views.apply_credential_sheet.done", fallback: "完成")) { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding()

            // ── 消息提示 ──────────────────────────────────────
            if let msg = errorMsg {
                feedbackBar(text: msg, isError: true) { errorMsg = nil }
            }
            if let msg = successMsg {
                feedbackBar(text: msg, isError: false) { successMsg = nil }
            }

            Divider()

            // ── 账户列表 ──────────────────────────────────────
            if modelStore.providers.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("views.apply_credential_sheet.configuration_account", fallback: "尚未配置全局账户"), systemImage: "key")
                } description: {
                    Text(L10n.k("credential.apply.empty.desc", fallback: "在「全局模型池」中添加 Provider 账户并配置凭据，\n即可在此一键同步到虾的 openclaw 配置。"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(modelStore.providers) { account in
                            accountRow(account)
                        }
                    } header: {
                        Text(L10n.k("views.apply_credential_sheet.auth_profiles_json_keyref_secrets", fallback: "同步后虾的 auth-profiles.json 将使用 keyRef 格式引用 secrets"))
                            .font(.caption).foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - 账户行

    @ViewBuilder
    private func accountRow(_ account: ProviderTemplate) -> some View {
        let keyConfig = supportedProviderKeys.first { $0.id == account.providerGroupId }
        let secretKey = "\(account.providerGroupId):\(account.name)"
        let state = credentialState(account: account, keyConfig: keyConfig, secretKey: secretKey)

        HStack(spacing: 10) {
            Image(systemName: iconName(for: state))
                .font(.system(size: 14))
                .foregroundStyle(iconColor(for: state))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.callout).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(account.providerDisplayName)
                        .font(.caption2).foregroundStyle(.secondary)
                    if let kc = keyConfig {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(kc.inputLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    // 显示 secretKey 供用户理解
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(secretKey).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer()

            switch state {
            case .apiKey:
                if syncingId == account.id {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button(L10n.k("views.apply_credential_sheet.text_6a620e3c", fallback: "同步")) {
                        Task { await syncAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .oauth:
                Button(L10n.k("views.apply_credential_sheet.oauth_authorize", fallback: "OAuth 授权")) { }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                    .help(L10n.k("views.apply_credential_sheet.oauth_authorize_a1326d", fallback: "OAuth 授权功能即将推出"))

            case .missing:
                Text(L10n.k("views.apply_credential_sheet.configuration_credential", fallback: "未配置凭据"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 反馈条

    @ViewBuilder
    private func feedbackBar(text: String, isError: Bool, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.caption2)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - 工具方法

    private var canSyncAny: Bool {
        modelStore.providers.contains { account in
            let secretKey = "\(account.providerGroupId):\(account.name)"
            return GlobalSecretsStore.shared.has(secretKey: secretKey)
        }
    }

    private func credentialState(account: ProviderTemplate, keyConfig: ProviderKeyConfig?, secretKey: String) -> CredentialState {
        if GlobalSecretsStore.shared.has(secretKey: secretKey) {
            return .apiKey
        }
        guard let kc = keyConfig else { return .missing }
        return kc.supportsOAuth ? .oauth : .missing
    }

    private func iconName(for state: CredentialState) -> String {
        switch state {
        case .apiKey:   return "key.fill"
        case .oauth:    return "person.badge.key.fill"
        case .missing:  return "key"
        }
    }

    private func iconColor(for state: CredentialState) -> Color {
        switch state {
        case .apiKey:   return Color.accentColor
        case .oauth:    return .orange
        case .missing:  return Color.secondary.opacity(0.4)
        }
    }

    // MARK: - 同步操作

    /// 同步单个账户的凭据到虾（只覆盖该账户对应的条目）
    private func syncAccount(_ account: ProviderTemplate) async {
        let secretKey = "\(account.providerGroupId):\(account.name)"
        guard let value = GlobalSecretsStore.shared.value(for: secretKey) else {
            errorMsg = String(format: L10n.k("views.apply_credential_sheet.account_missing_credentials", fallback: "「%@」未配置凭据，请先在全局模型池中设置"), account.name)
            return
        }
        syncingId = account.id
        errorMsg = nil
        do {
            let secretsPayload = buildSecretsPayload(keys: [secretKey])
            let authProfilesPayload = buildAuthProfiles(keys: [secretKey])
            try await helperClient.syncSecrets(
                username: username,
                secretsPayload: secretsPayload,
                authProfilesPayload: authProfilesPayload
            )
            successMsg = String(format: L10n.k("views.apply_credential_sheet.account_synced_to_user", fallback: "「%@」已同步到 %@"), account.name, username)
            _ = value  // suppress unused warning
        } catch {
            errorMsg = String(format: L10n.k("views.apply_credential_sheet.sync_failed_detail", fallback: "同步失败：%@"), error.localizedDescription)
        }
        syncingId = nil
    }

    /// 同步所有已配置凭据的账户
    private func syncAll() async {
        isSyncingAll = true
        errorMsg = nil
        let allEntries = GlobalSecretsStore.shared.allEntries()
        // 只同步属于当前 providers 的条目
        let providerKeys = modelStore.providers.map { "\($0.providerGroupId):\($0.name)" }
        let relevantKeys = allEntries.map(\.secretKey).filter { providerKeys.contains($0) }
        guard !relevantKeys.isEmpty else {
            errorMsg = L10n.k("views.apply_credential_sheet.configurationaccountsync", fallback: "没有已配置凭据的账户可同步")
            isSyncingAll = false
            return
        }
        do {
            let secretsPayload = buildSecretsPayload(keys: relevantKeys)
            let authProfilesPayload = buildAuthProfiles(keys: relevantKeys)
            try await helperClient.syncSecrets(
                username: username,
                secretsPayload: secretsPayload,
                authProfilesPayload: authProfilesPayload
            )
            successMsg = String(format: L10n.k("views.apply_credential_sheet.synced_account_count_to_user", fallback: "已同步 %d 个账户到 %@"), relevantKeys.count, username)
        } catch {
            errorMsg = String(format: L10n.k("views.apply_credential_sheet.sync_failed_detail", fallback: "同步失败：%@"), error.localizedDescription)
        }
        isSyncingAll = false
    }

    // MARK: - 构建 JSON 载荷

    /// 生成 secrets.json 内容（flat map: { "provider:name": "value" }）
    private func buildSecretsPayload(keys: [String]) -> String {
        GlobalSecretsStore.shared.secretsPayload(for: keys)
    }

    /// 生成 auth-profiles.json 内容（keyRef 格式）
    private func buildAuthProfiles(keys: [String]) -> String {
        var profiles: [String: [String: Any]] = [:]
        for key in keys {
            // key 格式：provider:accountName，按 ":" 分割
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let provider = parts[0]
            profiles[key] = [
                "type": "api_key",
                "provider": provider,
                "keyRef": [
                    "source": "file",
                    "id": key
                ]
            ]
        }
        let root: [String: Any] = ["profiles": profiles]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8)
        else { return "{\"profiles\":{}}" }
        return json
    }
}
