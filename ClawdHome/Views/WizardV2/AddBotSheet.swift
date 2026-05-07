// ClawdHome/Views/WizardV2/AddBotSheet.swift
// 为指定 agent 添加 IM bot 绑定的弹窗（v2）
//
// 流程：
// 1. 选择平台
// 2. 根据平台选择 provisioner 类型（auto / manual-token）
// 3. 自动：显示二维码 / 链接，等待扫码
//    手动：粘贴 appId / token 表单
// 4. 完成，回调 onAdded

import SwiftUI

struct AddBotSheet: View {
    let username: String
    let agentId: String
    var onAdded: ((IMAccount) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .selectPlatform
    @State private var selectedPlatform: IMPlatform = .feishu
    @State private var accountKey = ""
    @State private var displayName = ""
    @State private var manualAppId = ""
    @State private var manualAppSecret = ""

    @State private var isProvisioning = false
    @State private var provisionProgress = ""
    @State private var provisionError: String?
    @State private var provisioner: (any IMBotProvisioner)?

    enum Step {
        case selectPlatform
        case configAccount     // 填 accountKey + displayName
        case provisioning      // 自动绑定（二维码流程）
        case manualToken       // 手动填表单
        case done
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .selectPlatform:
                    selectPlatformView
                case .configAccount:
                    configAccountView
                case .provisioning:
                    provisioningView
                case .manualToken:
                    manualTokenView
                case .done:
                    doneView
                }
            }
            .navigationTitle(L10n.k("add_bot.title", fallback: "添加 Bot"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) {
                        provisioner?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Step 1: select platform

    private var selectPlatformView: some View {
        VStack(spacing: 0) {
            List(IMPlatform.allCases, id: \.rawValue) { platform in
                Button(action: {
                    selectedPlatform = platform
                    step = .configAccount
                }) {
                    HStack {
                        Text(platform.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(platform.supportsStandardChannelLogin || platform == .feishu
                             ? L10n.k("add_bot.auto_bind", fallback: "扫码绑定")
                             : L10n.k("add_bot.manual_token", fallback: "手动填 token"))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 2: config account

    private var configAccountView: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.k("add_bot.account_key", fallback: "账号标识"))
                    TextField(L10n.k("add_bot.account_key_placeholder", fallback: "如 work / personal"), text: $accountKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text(L10n.k("add_bot.display_name", fallback: "显示名称"))
                    TextField(L10n.k("add_bot.display_name_placeholder", fallback: "飞书工作账号"), text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("\(selectedPlatform.displayName) - \(L10n.k("add_bot.account_config", fallback: "账号配置"))")
            }

            Section {
                HStack {
                    Spacer()
                    Button(L10n.k("common.next", fallback: "下一步")) {
                        startProvisioning()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accountKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Step 3a: provisioning (auto)

    private var provisioningView: some View {
        VStack(spacing: 20) {
            if isProvisioning {
                ProgressView()
                    .scaleEffect(1.4)
                Text(L10n.k("add_bot.provisioning", fallback: "正在绑定…"))
                    .foregroundStyle(.secondary)
            }

            if !provisionProgress.isEmpty {
                ScrollView {
                    Text(provisionProgress)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }

            if let err = provisionError {
                Text(err)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                Button(L10n.k("common.retry", fallback: "重试")) {
                    startProvisioning()
                }
            }
        }
        .padding()
    }

    // MARK: - Step 3b: manual token

    private var manualTokenView: some View {
        Form {
            Section {
                HStack {
                    Text("App ID")
                    TextField("", text: $manualAppId)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("App Secret / Token")
                    SecureField("", text: $manualAppSecret)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("\(selectedPlatform.displayName) - \(L10n.k("add_bot.credentials", fallback: "凭证"))")
            }
            Section {
                HStack {
                    Spacer()
                    Button(L10n.k("common.confirm", fallback: "确认")) {
                        finishManual()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualAppId.isEmpty || manualAppSecret.isEmpty || isProvisioning)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Step 4: done

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(L10n.k("add_bot.done_title", fallback: "绑定成功"))
                .font(.headline)
            Text(L10n.k("add_bot.done_detail", fallback: "Bot 已添加，可在设置中查看"))
                .foregroundStyle(.secondary)
            Button(L10n.k("common.done", fallback: "完成")) {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func startProvisioning() {
        let key = accountKey.trimmingCharacters(in: .whitespaces)
        let name = displayName.isEmpty ? selectedPlatform.displayName : displayName
        provisionError = nil
        provisionProgress = ""

        // 不支持自动绑定的平台直接跳到手动 token
        guard selectedPlatform.supportsStandardChannelLogin || selectedPlatform == .feishu else {
            step = .manualToken
            return
        }

        let p = ProvisionerFactory.make(
            platform: selectedPlatform,
            helperClient: helperClient
        )
        provisioner = p
        step = .provisioning
        isProvisioning = true

        Task {
            defer { isProvisioning = false }
            do {
                let credential = try await p.provision(
                    username: username,
                    accountKey: key
                ) { [key] msg in
                    Task { @MainActor in
                        provisionProgress += msg + "\n"
                    }
                }
                let account = try await buildIMAccountWithSecretsSync(
                    key: key,
                    displayName: name,
                    credential: credential
                )
                await MainActor.run {
                    step = .done
                    onAdded?(account)
                }
            } catch {
                await MainActor.run {
                    provisionError = error.localizedDescription
                }
            }
        }
    }

    private func finishManual() {
        guard !isProvisioning else { return }
        isProvisioning = true
        provisionError = nil
        let key = accountKey.trimmingCharacters(in: .whitespaces)
        let name = displayName.isEmpty ? selectedPlatform.displayName : displayName
        let secretPayload = (try? String(data: JSONEncoder().encode(["appSecret": manualAppSecret]), encoding: .utf8)) ?? "{}"

        Task {
            defer { isProvisioning = false }
            do {
                let credential = IMBotCredential(
                    appId: manualAppId,
                    secretsPayload: secretPayload,
                    platform: selectedPlatform,
                    botName: name
                )
                let account = try await buildIMAccountWithSecretsSync(
                    key: key,
                    displayName: name,
                    credential: credential
                )
                await MainActor.run {
                    step = .done
                    onAdded?(account)
                }
            } catch {
                await MainActor.run {
                    provisionError = error.localizedDescription
                }
            }
        }
    }

    private func buildIMAccount(key: String, displayName: String, credential: IMBotCredential) -> IMAccount {
        let secretRef = trySaveSecretIfNeeded(
            platform: credential.platform,
            accountKey: key,
            secretsPayload: credential.secretsPayload
        )

        return IMAccount(
            id: key,
            platform: credential.platform,
            displayName: displayName,
            appId: credential.appId.isEmpty ? nil : credential.appId,
            credsKeychainRef: secretRef,
            createdAt: Date()
        )
    }

    private func buildIMAccountWithSecretsSync(
        key: String,
        displayName: String,
        credential: IMBotCredential
    ) async throws -> IMAccount {
        let account = buildIMAccount(key: key, displayName: displayName, credential: credential)
        if account.credsKeychainRef != nil {
            try await helperClient.syncSecrets(
                username: username,
                secretsPayload: GlobalSecretsStore.shared.secretsPayload(),
                authProfilesPayload: buildAuthProfilesPayload()
            )
        }
        return account
    }

    private func trySaveSecretIfNeeded(platform: IMPlatform, accountKey: String, secretsPayload: String) -> String? {
        guard let appSecret = extractAppSecret(from: secretsPayload) else { return nil }
        let provider = "im.\(platform.rawValue)"
        let ref = "\(provider):\(accountKey)"
        GlobalSecretsStore.shared.save(entry: SecretEntry(
            provider: provider,
            accountName: accountKey,
            value: appSecret
        ))
        return ref
    }

    private func extractAppSecret(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = obj["appSecret"] as? String
        else { return nil }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildAuthProfilesPayload() -> String {
        let entries = GlobalSecretsStore.shared.allEntries()
        var profiles: [String: [String: Any]] = [:]
        for entry in entries {
            let parts = entry.secretKey.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            profiles[entry.secretKey] = [
                "type": "api_key",
                "provider": parts[0],
                "keyRef": [
                    "source": "file",
                    "id": entry.secretKey
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
