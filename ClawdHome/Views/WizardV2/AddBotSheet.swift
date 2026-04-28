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
    @Environment(GatewayHub.self) private var gatewayHub
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
    @State private var channelFlow: ChannelOnboardingFlow?
    @State private var isCheckingBinding = false
    @State private var channelBindError: String?
    @State private var didDetectPairingCompletion = false
    @State private var baselineBoundAccountIDs: Set<String> = []
    @State private var selectableBoundSnapshots: [ChannelAccountSnapshot] = []
    @State private var pendingChooserFlow: ChannelOnboardingFlow?

    // 飞书多账号检测
    @State private var isDetectingFeishu = false
    @State private var feishuHasDefaultAccount = false
    @State private var selectedFeishuBrand: FeishuBrand = .feishu

    enum Step {
        case selectPlatform
        case configAccount     // 填 accountKey + displayName
        case provisioning      // 自动绑定（二维码流程）
        case manualToken       // 手动填表单
        case channelOnboarding // 飞书/微信走维护终端 npx
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
                case .channelOnboarding:
                    if let flow = channelFlow {
                        FeishuChannelOnboardingSheet(
                            flow: flow,
                            displayName: username,
                            username: username,
                            entryMode: .initialBinding
                        )
                    }
                case .done:
                    doneView
                }
            }
            .navigationTitle(sheetNavigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) {
                        provisioner?.cancel()
                        dismiss()
                    }
                }
                if step == .channelOnboarding {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.k("common.done", fallback: "完成")) {
                            Task { await finishChannelOnboarding() }
                        }
                        .disabled(isCheckingBinding)
                    }
                }
            }
        }
        .frame(minWidth: step == .channelOnboarding ? 900 : 480,
               minHeight: step == .channelOnboarding ? 500 : 360)
        .onReceive(NotificationCenter.default.publisher(for: .channelOnboardingAutoDetected)) { note in
            guard let payloadUsername = note.userInfo?["username"] as? String,
                  let payloadFlow = note.userInfo?["flow"] as? String,
                  payloadUsername == username,
                  payloadFlow == channelFlow?.rawValue else {
                return
            }
            didDetectPairingCompletion = true
        }
        .alert(L10n.k("add_bot.bind_check_failed", fallback: "绑定确认"), isPresented: Binding(
            get: { channelBindError != nil },
            set: { if !$0 { channelBindError = nil } }
        )) {
            Button(L10n.k("common.ok", fallback: "好"), role: .cancel) { }
        } message: {
            Text(channelBindError ?? "")
        }
        .confirmationDialog(
            L10n.k("add_bot.choose_bound_account_title", fallback: "选择要绑定的 Bot 账号"),
            isPresented: Binding(
                get: { !selectableBoundSnapshots.isEmpty },
                set: { shown in
                    if !shown {
                        selectableBoundSnapshots = []
                        pendingChooserFlow = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            ForEach(selectableBoundSnapshots, id: \.accountId) { snapshot in
                Button(boundAccountChoiceLabel(snapshot)) {
                    guard let flow = pendingChooserFlow else { return }
                    finalizeChannelBinding(snapshot: snapshot, flow: flow)
                }
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {
                selectableBoundSnapshots = []
                pendingChooserFlow = nil
            }
        } message: {
            Text(L10n.k("add_bot.choose_bound_account_hint", fallback: "检测到多个已绑定账号，请选择本次要绑定到当前 Agent 的账号。"))
        }
    }

    // MARK: - Step 1: select platform

    private var selectPlatformView: some View {
        VStack(spacing: 0) {
            if isDetectingFeishu {
                ProgressView(L10n.k("add_bot.detecting_feishu", fallback: "正在检测飞书配置…"))
                    .padding()
            }
            List(IMPlatform.allCases, id: \.rawValue) { platform in
                Button(action: {
                    guard !isDetectingFeishu else { return }
                    selectedPlatform = platform
                    didDetectPairingCompletion = false
                    if platform == .feishu {
                        isDetectingFeishu = true
                        Task {
                            let config = await helperClient.getConfigJSON(username: username)
                            let feishu = (config["channels"] as? [String: Any])?["feishu"] as? [String: Any]
                            let hasDefault = (feishu?["appId"] as? String).map { !$0.isEmpty } ?? false
                                         || ((feishu?["accounts"] as? [String: Any]).map { !$0.isEmpty } ?? false)
                            await MainActor.run {
                                isDetectingFeishu = false
                                feishuHasDefaultAccount = hasDefault
                                if hasDefault {
                                    // 命名账号：需要用户给出有意义的 accountKey
                                    step = .configAccount
                                } else {
                                    channelFlow = .feishu
                                    step = .channelOnboarding
                                    Task { await snapshotExistingBoundAccounts(for: .feishu) }
                                }
                            }
                        }
                    } else if let flow = channelOnboardingFlow(for: platform) {
                        channelFlow = flow
                        step = .channelOnboarding
                        Task { await snapshotExistingBoundAccounts(for: flow) }
                    } else {
                        // 其他平台（Discord / Slack / ...）：单账号，自动用 "default"，直接进凭证填写
                        accountKey = "default"
                        displayName = ""
                        startProvisioning()
                    }
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
                    TextField(selectedPlatform.displayNamePlaceholder, text: $displayName)
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
            if selectedPlatform == .feishu && feishuHasDefaultAccount {
                feishuNamedAccountGuidanceSection
            }
            Section {
                HStack {
                    Text("App ID")
                    TextField("", text: $manualAppId)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("App Secret")
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

    @ViewBuilder
    private var feishuNamedAccountGuidanceSection: some View {
        Section {
            Picker(L10n.k("add_bot.feishu_domain", fallback: "域名"), selection: $selectedFeishuBrand) {
                Text(L10n.k("add_bot.feishu_label", fallback: "飞书 (feishu.cn)")).tag(FeishuBrand.feishu)
                Text("Lark (larksuite.com)").tag(FeishuBrand.lark)
            }
            Button(action: { openFeishuCreatePage() }) {
                Label(
                    selectedFeishuBrand == .feishu
                        ? L10n.k("add_bot.open_feishu_platform", fallback: "打开飞书开放平台创建应用")
                        : L10n.k("add_bot.open_lark_platform", fallback: "打开 Lark 开放平台创建应用"),
                    systemImage: "arrow.up.right.circle"
                )
            }
        } header: {
            Text(L10n.k("add_bot.feishu_named_account_title", fallback: "创建新飞书应用"))
        } footer: {
            Text(L10n.k("add_bot.feishu_named_account_hint",
                        fallback: "此账号将作为命名账号加入多账号配置。点击上方按钮在飞书开放平台创建自建应用，创建完成后将 App ID 和 App Secret 填入下方。"))
        }
    }

    private func openFeishuCreatePage() {
        let urlStr = selectedFeishuBrand == .feishu
            ? "https://open.feishu.cn/page/openclaw?form=multiAgent"
            : "https://open.larksuite.com/page/openclaw?form=multiAgent"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
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

        // 飞书命名账号（已有默认账号）：走手动填写，不启动 npx
        if selectedPlatform == .feishu && feishuHasDefaultAccount {
            step = .manualToken
            return
        }

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

        // 飞书命名账号：appSecret 直接附在 IMAccount 上，由 applyV2Config 写入 JSON
        if selectedPlatform == .feishu && feishuHasDefaultAccount {
            let key = accountKey.trimmingCharacters(in: .whitespaces)
            let name = displayName.isEmpty ? selectedPlatform.displayName : displayName
            guard !key.isEmpty, !manualAppId.isEmpty, !manualAppSecret.isEmpty else { return }
            let account = IMAccount(
                id: key,
                platform: .feishu,
                displayName: name,
                appId: manualAppId,
                appSecret: manualAppSecret,
                brand: selectedFeishuBrand,
                domain: selectedFeishuBrand == .lark ? "lark" : nil,
                createdAt: Date()
            )
            onAdded?(account)
            dismiss()
            return
        }

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

    private func finishChannelOnboarding() async {
        guard let flow = channelFlow else { return }
        isCheckingBinding = true
        defer { isCheckingBinding = false }

        let store = gatewayHub.channelStore(for: username)
        let snapshots = await waitForBoundSnapshots(store: store, flow: flow, allowDelayedSync: didDetectPairingCompletion)
        guard !snapshots.isEmpty else {
            channelBindError = L10n.k("add_bot.no_binding_detected", fallback: "未检测到已绑定的账号，请先完成扫码配对")
            return
        }
        let newlyBound = snapshots.filter { !baselineBoundAccountIDs.contains($0.accountId) }
        if newlyBound.count == 1, let snapshot = newlyBound.first {
            finalizeChannelBinding(snapshot: snapshot, flow: flow)
            return
        }
        if newlyBound.count > 1 {
            pendingChooserFlow = flow
            selectableBoundSnapshots = newlyBound
            return
        }
        if snapshots.count == 1, let snapshot = snapshots.first {
            finalizeChannelBinding(snapshot: snapshot, flow: flow)
            return
        }
        pendingChooserFlow = flow
        selectableBoundSnapshots = snapshots
    }

    private func waitForBoundSnapshots(
        store: GatewayChannelStore,
        flow: ChannelOnboardingFlow,
        allowDelayedSync: Bool
    ) async -> [ChannelAccountSnapshot] {
        let maxAttempts = allowDelayedSync ? 12 : 2
        for attempt in 0..<maxAttempts {
            await store.refresh()
            let snapshots = await detectBoundSnapshots(store: store, flow: flow)
            if !snapshots.isEmpty { return snapshots }
            guard allowDelayedSync, attempt < (maxAttempts - 1) else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        return []
    }

    private func detectBoundSnapshots(
        store: GatewayChannelStore,
        flow: ChannelOnboardingFlow
    ) async -> [ChannelAccountSnapshot] {
        let runtimeSnapshots = collectBoundSnapshotsFromRuntime(store: store, flow: flow)
        let configSnapshots = await collectBoundSnapshotsFromConfigFile(flow: flow)
        return mergeSnapshots(runtimeSnapshots, configSnapshots)
    }

    private func collectBoundSnapshotsFromRuntime(store: GatewayChannelStore, flow: ChannelOnboardingFlow) -> [ChannelAccountSnapshot] {
        var seen = Set<String>()
        var snapshots: [ChannelAccountSnapshot] = []
        for channelId in flow.candidateChannelIds {
            for account in store.boundAccounts(channelId) where seen.insert(account.accountId).inserted {
                snapshots.append(account)
            }
        }
        return snapshots
    }

    private func collectBoundSnapshotsFromConfigFile(flow: ChannelOnboardingFlow) async -> [ChannelAccountSnapshot] {
        let config = await helperClient.getConfigJSON(username: username)
        guard let channels = config["channels"] as? [String: Any] else { return [] }

        var snapshots: [ChannelAccountSnapshot] = []
        for channelId in flow.candidateChannelIds {
            guard let section = channels[channelId] as? [String: Any] else { continue }

            if let accounts = section["accounts"] as? [String: Any] {
                // v2 格式：accounts 字典
                for (accountId, accountValue) in accounts {
                    guard let account = accountValue as? [String: Any] else { continue }
                    if accountId == "default", account.isEmpty { continue }

                    let appId = (account["appId"] as? String) ?? (section["appId"] as? String)
                    let name = (account["botName"] as? String) ?? (account["name"] as? String)
                    let allowFrom = (account["allowFrom"] as? [String]) ?? (section["allowFrom"] as? [String])
                    let domain = (account["domain"] as? String) ?? (section["domain"] as? String)

                    snapshots.append(ChannelAccountSnapshot(
                        accountId: accountId,
                        name: name,
                        enabled: true,
                        configured: true,
                        linked: true,
                        running: nil,
                        connected: nil,
                        lastConnectedAt: nil,
                        lastError: nil,
                        healthState: nil,
                        lastInboundAt: nil,
                        lastOutboundAt: nil,
                        allowFrom: allowFrom,
                        appId: appId,
                        domain: domain
                    ))
                }
            }
            // v1 兜底：accounts 字典为空或所有 entry 都被跳过时，读顶层 appId；
            // 用 snapshots.isEmpty 判断（而非 else if）避免 accounts: {} 空字典导致 appId 被忽略。
            if snapshots.isEmpty, let appId = section["appId"] as? String, !appId.isEmpty {
                // v1 格式：appId 在 channel 顶层（npx 工具直接写入时的格式）
                snapshots.append(ChannelAccountSnapshot(
                    accountId: "default",
                    name: section["botName"] as? String,
                    enabled: true,
                    configured: true,
                    linked: true,
                    running: nil,
                    connected: nil,
                    lastConnectedAt: nil,
                    lastError: nil,
                    healthState: nil,
                    lastInboundAt: nil,
                    lastOutboundAt: nil,
                    allowFrom: section["allowFrom"] as? [String],
                    appId: appId,
                    domain: section["domain"] as? String
                ))
            }
            // v3 兜底：微信等使用顶层 token 字段（非 appId / accounts）的插件通道。
            // openclaw-weixin 绑定成功后写入 token，无 appId / accounts，v1/v2 均无法命中。
            if snapshots.isEmpty, let token = section["token"] as? String, !token.isEmpty {
                snapshots.append(ChannelAccountSnapshot(
                    accountId: "default",
                    name: section["botName"] as? String ?? section["name"] as? String,
                    enabled: true,
                    configured: true,
                    linked: true,
                    running: nil,
                    connected: nil,
                    lastConnectedAt: nil,
                    lastError: nil,
                    healthState: nil,
                    lastInboundAt: nil,
                    lastOutboundAt: nil,
                    allowFrom: section["allowFrom"] as? [String],
                    appId: nil,
                    domain: section["domain"] as? String
                ))
            }
        }
        return snapshots
    }

    private func mergeSnapshots(_ lhs: [ChannelAccountSnapshot], _ rhs: [ChannelAccountSnapshot]) -> [ChannelAccountSnapshot] {
        var merged: [String: ChannelAccountSnapshot] = [:]
        for snapshot in lhs + rhs {
            if let existing = merged[snapshot.accountId] {
                merged[snapshot.accountId] = preferSnapshot(existing, snapshot)
            } else {
                merged[snapshot.accountId] = snapshot
            }
        }
        return merged.values.sorted { $0.accountId < $1.accountId }
    }

    private func preferSnapshot(_ a: ChannelAccountSnapshot, _ b: ChannelAccountSnapshot) -> ChannelAccountSnapshot {
        func score(_ s: ChannelAccountSnapshot) -> Int {
            var value = 0
            if s.name?.isEmpty == false { value += 2 }
            if s.appId?.isEmpty == false { value += 2 }
            if !(s.allowFrom ?? []).isEmpty { value += 1 }
            if s.domain?.isEmpty == false { value += 1 }
            if s.configured == true || s.linked == true { value += 1 }
            return value
        }
        return score(b) >= score(a) ? b : a
    }

    private func snapshotExistingBoundAccounts(for flow: ChannelOnboardingFlow) async {
        let store = gatewayHub.channelStore(for: username)
        await store.refresh()
        let existing = await detectBoundSnapshots(store: store, flow: flow)
        await MainActor.run {
            baselineBoundAccountIDs = Set(existing.map(\.accountId))
        }
    }

    private func boundAccountChoiceLabel(_ snapshot: ChannelAccountSnapshot) -> String {
        let name = (snapshot.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? snapshot.accountId : "\(name) (\(snapshot.accountId))"
        guard let appId = snapshot.appId, !appId.isEmpty else { return title }
        return "\(title) · \(appId)"
    }

    private func finalizeChannelBinding(snapshot: ChannelAccountSnapshot, flow: ChannelOnboardingFlow) {
        selectableBoundSnapshots = []
        pendingChooserFlow = nil
        let account = IMAccount(
            id: snapshot.accountId,
            platform: selectedPlatform,
            displayName: snapshot.name ?? flow.title,
            appId: snapshot.appId,
            allowFrom: snapshot.allowFrom ?? [],
            domain: snapshot.domain,
            createdAt: Date()
        )
        onAdded?(account)
        dismiss()
    }

    private var sheetNavigationTitle: String {
        switch step {
        case .selectPlatform, .done:
            return L10n.k("add_bot.title", fallback: "添加 Bot")
        default:
            return L10n.f("add_bot.title_with_platform", fallback: "添加 %@ Bot", selectedPlatform.displayName)
        }
    }

    private func channelOnboardingFlow(for platform: IMPlatform) -> ChannelOnboardingFlow? {
        switch platform {
        case .feishu: return .feishu
        case .wechat: return .weixin
        default: return nil
        }
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
