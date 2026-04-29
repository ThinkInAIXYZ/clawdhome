import SwiftUI
import AppKit

enum ChannelOnboardingEntryMode: String {
    case initialBinding = "initial"
    case configuration = "config"
}

enum ChannelOnboardingFlow: String, Identifiable, CaseIterable {
    case feishu
    case weixin

    var id: String { rawValue }

    /// 配置文件中的真实 channelId（微信插件使用 openclaw-weixin）
    var channelId: String {
        switch self {
        case .feishu: return "feishu"
        case .weixin: return "openclaw-weixin"
        }
    }

    /// 兼容历史别名（旧配置可能仍使用 weixin）
    var legacyChannelIds: [String] {
        switch self {
        case .feishu: return []
        case .weixin: return ["weixin"]
        }
    }

    var candidateChannelIds: [String] {
        [channelId] + legacyChannelIds
    }

    var title: String {
        switch self {
        case .feishu: return L10n.k("channel.flow.feishu.title", fallback: "飞书")
        case .weixin: return L10n.k("channel.flow.weixin.title", fallback: "微信")
        }
    }

    var commandArgs: [String] {
        switch self {
        case .feishu:
            return ["-y", "@larksuite/openclaw-lark-tools", "install"]
        case .weixin:
            return ["-y", "@tencent-weixin/openclaw-weixin-cli@latest", "install"]
        }
    }
}

struct FeishuChannelOnboardingSheet: View {
    let flow: ChannelOnboardingFlow
    let displayName: String
    let username: String
    let entryMode: ChannelOnboardingEntryMode

    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(HelperClient.self) private var helperClient

    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var showTerminal = false
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()

    // 频道配置开关状态
    @State private var cfgStreaming: Bool?
    @State private var cfgTopicSessionMode: Bool?
    @State private var cfgLoading = false

    // 可编辑的绑定信息
    @State private var editAppId: String = ""
    @State private var editAllowFrom: String = ""
    @State private var editGroupAllowFrom: String = ""
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var showRebindConfirm = false
    @State private var outputBuffer = ""
    @State private var didDetectPairingDone = false
    @State private var pairingCompletedInCurrentSession = false

    private let commandExecutable = "npx"
    private let waitingThreshold: TimeInterval = 8
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var commandArgs: [String] { flow.commandArgs }
    private var logPrefix: String { flow.rawValue }

    private var commandSummary: String {
        ([commandExecutable] + commandArgs).joined(separator: " ")
    }

    private var completionMarkers: [String] {
        switch flow {
        case .feishu:
            return [
                "success! bot configured",
                "bot configured",
                "机器人配置成功",
                "openclaw is all set"
            ]
        case .weixin:
            return [
                "与微信连接成功",
                "微信连接成功",
                "config overwrite:",
                "正在重启 openclaw gateway"
            ]
        }
    }

    private var isRunning: Bool {
        showTerminal && exitCode == nil
    }

    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }

    private var stageTitle: String {
        if !showTerminal { return L10n.k("channel.stage.idle", fallback: "待开始") }
        if isRunning {
            return isWaitingInput
                ? L10n.k("channel.stage.running_waiting", fallback: "运行中（等待输入）")
                : L10n.k("channel.stage.running", fallback: "运行中")
        }
        if exitCode == 0 { return L10n.k("channel.stage.done", fallback: "已完成") }
        return L10n.k("channel.stage.exited", fallback: "已退出")
    }

    private enum PairingButtonState {
        case idle
        case running
        case succeeded
        case failed
    }

    private var pairingButtonState: PairingButtonState {
        if isRunning { return .running }
        guard showTerminal else { return .idle }
        if exitCode == 0 { return .succeeded }
        return .failed
    }

    private var pairingButtonTitle: String {
        switch pairingButtonState {
        case .idle: return L10n.k("channel.pairing.button.generate", fallback: "生成配对二维码")
        case .running: return L10n.k("channel.pairing.button.generating", fallback: "生成中…")
        case .succeeded: return L10n.k("channel.pairing.button.regenerate", fallback: "重新生成二维码")
        case .failed: return L10n.k("channel.pairing.button.retry", fallback: "重试生成二维码")
        }
    }

    private var pairingButtonIcon: String {
        switch pairingButtonState {
        case .idle: return "qrcode.viewfinder"
        case .running: return "hourglass"
        case .succeeded: return "arrow.clockwise.circle"
        case .failed: return "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var pairingStatusLabelText: String {
        switch pairingButtonState {
        case .idle: return L10n.k("channel.pairing.status.idle", fallback: "未开始")
        case .running:
            return isWaitingInput
                ? L10n.k("channel.pairing.status.waiting_input", fallback: "等待扫码/输入")
                : L10n.k("channel.pairing.status.running", fallback: "命令执行中")
        case .succeeded: return L10n.k("channel.pairing.status.succeeded", fallback: "已完成，可再次生成")
        case .failed: return L10n.k("channel.pairing.status.failed", fallback: "生成失败，可重试")
        }
    }

    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        let min = elapsed / 60
        let sec = elapsed % 60
        return String(format: "%02d:%02d", min, sec)
    }

    private var shrimpIdentityTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == username {
            return "@\(username)"
        }
        return "\(trimmed) - @\(username)"
    }

    private var windowTitle: String {
        L10n.f("views.channel_onboarding.window_title", fallback: "%@ · %@ 通道配置 · %@", shrimpIdentityTitle, flow.title, stageTitle)
    }

    /// 当前频道的账号快照（取第一个）
    private var channelAccount: ChannelAccountSnapshot? {
        let store = gatewayHub.channelStore(for: username)
        for channelId in flow.candidateChannelIds {
            if let account = store.channelAccounts[channelId]?.first {
                return account
            }
        }
        return nil
    }

    /// 频道配置路径前缀
    private var configPrefix: String { "channels.\(resolvedChannelId)" }

    private var resolvedChannelId: String {
        let store = gatewayHub.channelStore(for: username)
        for channelId in flow.candidateChannelIds where store.channelAccounts[channelId] != nil {
            return channelId
        }
        return flow.channelId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if shouldShowChannelConfigPanel {
                // 已绑定：显示配置面板
                channelBoundPanel
            } else {
                // 未绑定 或 正在重新绑定：显示配对流程
                Text(L10n.k("channel.pairing.hint", fallback: "请点击按钮生成二维码，扫码配对后给龙虾发消息测试，正常即可关闭窗口。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                actionRow
            }
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
            }
            if showTerminal {
                runtimeToolbar
                HelperMaintenanceTerminalPanel(
                    username: username,
                    command: [commandExecutable] + commandArgs,
                    minHeight: 280,
                    onOutput: handleTerminalOutput,
                    control: terminalControl
                ) { code in
                    handleCommandExit(code)
                }
                .id(terminalRunID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .task { await loadAllConfig() }
        .onDisappear {
            terminalControl.terminate()
            appLog("[\(logPrefix)] ui onboarding window disappeared; terminate active terminal session @\(username)")
        }
        .background(ChannelOnboardingWindowTitleBinder(title: windowTitle))
        .background(ChannelOnboardingWindowLevelBinder())
        .frame(minWidth: 900, minHeight: 460)
    }


    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                startInteractiveRun()
            }
            label: {
                Label(pairingButtonTitle, systemImage: pairingButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingButtonState == .running)

            if pairingButtonState == .running {
                Button(L10n.k("channel.pairing.button.interrupt_generation", fallback: "中断生成")) {
                    terminalControl.sendInterrupt()
                    appLog("[\(logPrefix)] ui interactive interrupt from action row @\(username)")
                }
            }

            Text(L10n.f("channel.pairing.status_label", fallback: "状态：%@", pairingStatusLabelText))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    @ViewBuilder
    private var runtimeToolbar: some View {
        HStack(spacing: 10) {
            Label(
                isRunning
                ? (isWaitingInput
                   ? L10n.k("channel.stage.running_waiting", fallback: "运行中（等待输入）")
                   : L10n.k("channel.stage.running", fallback: "运行中"))
                : L10n.k("channel.stage.exited", fallback: "已退出"),
                systemImage: isRunning ? (isWaitingInput ? "hourglass" : "play.circle.fill") : "stop.circle"
            )
            .font(.caption)
            .foregroundStyle(isRunning ? .secondary : .secondary)

            Text(L10n.f("channel.runtime.elapsed", fallback: "耗时 %@", elapsedText))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(L10n.k("common.action.interrupt", fallback: "中断")) {
                terminalControl.sendInterrupt()
                appLog("[\(logPrefix)] ui interactive interrupt @\(username)")
            }
            .disabled(!isRunning)

            Button(L10n.k("common.action.rerun", fallback: "重跑")) {
                startInteractiveRun()
            }

            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) {
                copyTerminalOutput()
            }
            .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func startInteractiveRun() {
        appLog("[\(logPrefix)] ui interactive run start @\(username) cmd=\(commandSummary)")
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        didDetectPairingDone = false
        pairingCompletedInCurrentSession = false
        showTerminal = true
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        outputBuffer += chunk
        // 控制内存占用：仅保留最近 300KB 文本
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
        evaluatePairingCompletion(from: chunk)
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("channel.runtime.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = L10n.k("channel.runtime.output_copied", fallback: "命令输出已复制。")
        appLog("[\(logPrefix)] ui interactive output copied @\(username) bytes=\(text.utf8.count)")
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        evaluatePairingCompletion(from: outputBuffer)
        if normalized == 0 {
            // 注意：不在此处把 pairingCompletedInCurrentSession 置 true。
            // 仅当 evaluatePairingCompletion 命中完成关键词，或后续 reloadConfig
            // 让 channelStore 回报 isBound==true 时，shouldShowChannelConfigPanel 才放行。
            // 仅 exit==0 不构成绑定证据：用户可能 Ctrl+C、扫码未完成就退出，
            // 此时切到"已配置"面板会出现 App ID 为空的占位符。
            showTerminal = false
            statusText = didDetectPairingDone
                ? L10n.k("channel.runtime.exit.success_detected", fallback: "已检测到配对成功，您可以继续配置下方选项。")
                : L10n.k("channel.runtime.exit.success", fallback: "命令执行完成。若已扫码完成配对，可继续配置下方选项。")
            Task { await reloadConfig() }
            appLog("[\(logPrefix)] ui interactive run success @\(username)")
        } else {
            statusText = L10n.f(
                "channel.runtime.exit.failed",
                fallback: L10n.k("views.channel_onboarding.feishu_channel_onboarding_sheet.exit_num_retry", fallback: "命令已退出（exit %d）。请查看上方终端输出并重试。"),
                normalized
            )
            appLog("[\(logPrefix)] ui interactive run failed @\(username) exit=\(normalized)", level: .error)
        }
    }

    private func evaluatePairingCompletion(from text: String) {
        guard !didDetectPairingDone else { return }
        let normalized = normalizedOutput(text)
        let matched = completionMarkers.contains { marker in
            normalized.contains(marker.lowercased())
        }
        guard matched else { return }

        didDetectPairingDone = true
        pairingCompletedInCurrentSession = true
        statusText = L10n.k("channel.runtime.pairing.detected_ready_config", fallback: "已检测到\u{201C}配置成功/完成\u{201D}提示，可继续配置下方选项。")
        NotificationCenter.default.post(
            name: .channelOnboardingAutoDetected,
            object: nil,
            userInfo: [
                "username": username,
                "flow": flow.rawValue
            ]
        )
        appLog("[\(logPrefix)] completion marker detected; ready for config @\(username)")
    }

    private func normalizedOutput(_ text: String) -> String {
        // 终端输出可能带 ANSI 控制符，先清理再做关键词匹配，避免漏判。
        let ansiPattern = #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#
        let stripped = text.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
        return stripped.lowercased()
    }

    // MARK: - 已绑定配置面板

    @ViewBuilder
    private var channelBoundPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 绑定信息（可编辑）
                channelBindingSection
                // 开关配置
                if !configItems.isEmpty {
                    channelConfigToggles
                }
            }
        }
    }

    // MARK: 绑定信息编辑区

    @ViewBuilder
    private var channelBindingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：已配置 + 操作按钮
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.subheadline)
                Text(L10n.k("views.channel_onboarding.configured", fallback: "已配置"))
                    .font(.headline)
                if let account = channelAccount, let name = account.name, !name.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    Task { await reloadConfig() }
                } label: {
                    Label(L10n.k("views.channel_onboarding.reload", fallback: "重新加载"), systemImage: "arrow.clockwise")
                }
                .disabled(cfgLoading)

                Button {
                    showRebindConfirm = true
                } label: {
                    Label(L10n.k("views.channel_onboarding.rebind", fallback: "重新绑定"), systemImage: "arrow.triangle.2.circlepath")
                }
                .alert(L10n.k("views.channel_onboarding.rebind_confirm_title", fallback: "确认重新绑定？"), isPresented: $showRebindConfirm) {
                    Button(L10n.k("views.channel_onboarding.rebind", fallback: "重新绑定"), role: .destructive) { startInteractiveRun() }
                    Button(L10n.k("views.channel_onboarding.cancel", fallback: "取消"), role: .cancel) { }
                } message: {
                    Text(L10n.k("views.channel_onboarding.rebind_confirm_message", fallback: "将重新执行配对流程，生成新的二维码进行扫码绑定。"))
                }
            }

            if cfgLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.k("views.channel_onboarding.loading", fallback: "加载中…")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if flow == .feishu {
                    // App ID
                    channelEditableField(label: "App ID", text: $editAppId, placeholder: "cli_xxxxxxxx")
                    // Allow From
                    channelEditableField(label: "Allow From", text: $editAllowFrom, placeholder: L10n.k("views.channel_onboarding.allow_from_placeholder", fallback: "每行一个用户 ID，如 ou_xxxx"))
                    // Group Allow From
                    channelEditableField(label: "Group Allow From", text: $editGroupAllowFrom, placeholder: L10n.k("views.channel_onboarding.group_allow_from_placeholder", fallback: "每行一个群组 ID"))
                } else {
                    Text(L10n.k("views.channel_onboarding.weixin_no_config_needed", fallback: "微信通道无需填写 App ID 或 Allowlist，扫码绑定成功后即可使用。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
            }

            // 保存按钮 + 状态
            if flow == .feishu {
                HStack(spacing: 8) {
                    Button {
                        Task { await saveBindingConfig() }
                    } label: {
                        Label(isSaving ? L10n.k("views.channel_onboarding.saving", fallback: "保存中…") : L10n.k("views.channel_onboarding.save", fallback: "保存"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cfgLoading || isSaving)

                    if let msg = saveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle((msg.contains("失败") || msg.contains("fail")) ? Color.red : Color.secondary)
                    }
                    Spacer()
                }
            }

            if let account = channelAccount, let err = account.lastError, !err.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.04))
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func channelEditableField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if text.wrappedValue.contains("\n") || label.contains("Allow") {
                // 多行编辑
                TextEditor(text: text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 40, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.06))
                    )
            } else {
                TextField(placeholder, text: text)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: 开关配置区

    private struct ChannelConfigItem {
        let key: String
        let label: String
        let detail: String
    }

    private static let feishuConfigItems: [ChannelConfigItem] = [
        .init(key: "streaming", label: L10n.k("views.channel_onboarding.config_streaming", fallback: "流式输出"), detail: L10n.k("views.channel_onboarding.config_streaming_detail", fallback: "消息以流式卡片实时更新，而非等待完成后一次性发送")),
        .init(key: "topicSessionMode", label: L10n.k("views.channel_onboarding.config_topic_session", fallback: "话题独立上下文"), detail: L10n.k("views.channel_onboarding.config_topic_session_detail", fallback: "开启后话题群中的每个话题拥有独立上下文，支持多任务并行")),
    ]

    private static let weixinConfigItems: [ChannelConfigItem] = []

    private var configItems: [ChannelConfigItem] {
        switch flow {
        case .feishu: return Self.feishuConfigItems
        case .weixin: return Self.weixinConfigItems
        }
    }

    @ViewBuilder
    private var channelConfigToggles: some View {
        let items = configItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                    if index > 0 { Divider().padding(.leading, 8) }
                    channelConfigToggleRow(item: item)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.04))
                    .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func channelConfigToggleRow(item: ChannelConfigItem) -> some View {
        let binding = configBinding(for: item.key)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.callout)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if cfgLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: binding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    /// 开关仅修改本地状态，统一通过保存按钮提交
    private func configBinding(for key: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { configValue(for: key) ?? false },
            set: { newValue in
                setConfigValue(for: key, value: newValue)
            }
        )
    }

    private func configValue(for key: String) -> Bool? {
        switch key {
        case "streaming": return cfgStreaming
        case "topicSessionMode": return cfgTopicSessionMode
        default: return nil
        }
    }

    private func setConfigValue(for key: String, value: Bool) {
        switch key {
        case "streaming": cfgStreaming = value
        case "topicSessionMode": cfgTopicSessionMode = value
        default: break
        }
    }

    /// 统一解析布尔/开关枚举：兼容 true|false 与 enabled|disabled
    private func parseToggleBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "on", "yes", "enabled":
            return true
        case "0", "false", "off", "no", "disabled":
            return false
        default:
            return nil
        }
    }

    // MARK: - 配置加载/保存

    /// 加载所有配置（开关 + 可编辑字段）
    private func loadAllConfig() async {
        guard channelAccount?.isBound == true else { return }
        cfgLoading = true
        defer { cfgLoading = false }

        // 加载开关配置
        for item in configItems {
            let path = "\(configPrefix).\(item.key)"
            let val = await gatewayHub.configGet(username: username, path: path)
            let boolVal = parseToggleBool(val)
            setConfigValue(for: item.key, value: boolVal ?? false)
        }

        // 加载可编辑字段
        if flow != .feishu {
            editAppId = ""
            editAllowFrom = ""
            editGroupAllowFrom = ""
            return
        }

        // appId 优先从 snapshot 取，fallback 到 config
        if let appId = channelAccount?.appId, !appId.isEmpty {
            editAppId = appId
        } else {
            editAppId = await gatewayHub.configGet(username: username, path: "\(configPrefix).appId") ?? ""
        }

        // allowFrom：优先从 snapshot 取，fallback 到 config（数组类型）
        if let allowFrom = channelAccount?.allowFrom, !allowFrom.isEmpty {
            editAllowFrom = allowFrom.joined(separator: "\n")
        } else if let arr = await gatewayHub.configGetArray(username: username, path: "\(configPrefix).allowFrom") {
            editAllowFrom = arr.joined(separator: "\n")
        }

        // groupAllowFrom（仅在 config 中，snapshot 不含）
        if let arr = await gatewayHub.configGetArray(username: username, path: "\(configPrefix).groupAllowFrom") {
            editGroupAllowFrom = arr.joined(separator: "\n")
        }
    }

    /// 重新加载配置
    private func reloadConfig() async {
        saveMessage = nil
        // 先刷新 channel store，让 loadAllConfig 能读到最新的 isBound 状态
        await gatewayHub.channelStore(for: username).refresh()
        await loadAllConfig()
    }

    /// 保存所有配置（绑定信息 + 开关，一次 config.patch）
    private func saveBindingConfig() async {
        guard flow == .feishu else { return }
        isSaving = true
        saveMessage = nil
        defer { isSaving = false }

        // 兜底：向导首次安装路径下，runEnvInstall 的 10 秒 token 轮询可能错过；
        // 这里在保存前再尝试一次连接，避免 configSetBatch 直接抛 notConnected。
        if !gatewayHub.connectedUsernames.contains(username) {
            let url = await helperClient.getGatewayURL(username: username)
            if !url.isEmpty, url.contains("#token=") {
                await gatewayHub.connect(username: username, gatewayURL: url)
            }
        }

        let appId = editAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowFrom = editAllowFrom
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let groupAllowFrom = editGroupAllowFrom
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var entries: [(path: String, value: Any)] = []
        if !appId.isEmpty {
            entries.append(("\(configPrefix).appId", appId))
        }
        entries.append(("\(configPrefix).allowFrom", allowFrom))
        entries.append(("\(configPrefix).groupAllowFrom", groupAllowFrom))

        // 开关配置
        for item in configItems {
            if let val = configValue(for: item.key) {
                switch item.key {
                case "topicSessionMode":
                    entries.append(("\(configPrefix).\(item.key)", val ? "enabled" : "disabled"))
                default:
                    entries.append(("\(configPrefix).\(item.key)", val))
                }
            }
        }

        do {
            try await gatewayHub.configSetBatch(username: username, entries: entries)
            saveMessage = L10n.k("views.channel_onboarding.saved", fallback: "已保存")
            await gatewayHub.channelStore(for: username).refresh()
        } catch {
            saveMessage = L10n.f("views.channel_onboarding.save_failed", fallback: "保存失败：%@", error.localizedDescription)
        }
    }

    private var shouldShowChannelConfigPanel: Bool {
        guard !showTerminal else { return false }
        switch entryMode {
        case .configuration:
            return channelAccount?.isBound == true || pairingCompletedInCurrentSession
        case .initialBinding:
            // pairingCompletedInCurrentSession 现在仅由 completionMarker 命中触发，
            // 与 channelAccount?.isBound 互为冗余证据，任一成立即可放行。
            return channelAccount?.isBound == true || pairingCompletedInCurrentSession
        }
    }

}

private struct ChannelOnboardingWindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

private struct ChannelOnboardingWindowLevelBinder: NSViewRepresentable {
    final class Coordinator {
        var didActivate = false
        var didScheduleUnpin = false
        var didUnpin = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window, context: context)
        }
    }

    private func apply(window: NSWindow?, context: Context) {
        guard let window else { return }
        if context.coordinator.didUnpin {
            if window.level != .normal {
                window.level = .normal
            }
        } else if window.level != .floating {
            window.level = .floating
        }
        if !context.coordinator.didScheduleUnpin {
            context.coordinator.didScheduleUnpin = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
                guard let window else { return }
                context.coordinator.didUnpin = true
                if window.level == .floating {
                    window.level = .normal
                }
            }
        }
        guard !context.coordinator.didActivate else { return }
        context.coordinator.didActivate = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
