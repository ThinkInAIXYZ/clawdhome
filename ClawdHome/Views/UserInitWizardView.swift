// ClawdHome/Views/UserInitWizardView.swift
// 生存空间初始化向导：基础环境初始化 → 模型配置 → 频道配置 → 完成

import SwiftUI

// MARK: - 枚举定义

enum InitStep: Int, CaseIterable {
    case basicEnvironment
    case configureModel
    case configureChannel
    case finish

    var key: String {
        switch self {
        case .basicEnvironment: return "basicEnvironment"
        case .configureModel:   return "configureModel"
        case .configureChannel: return "configureChannel"
        case .finish:           return "finish"
        }
    }

    var title: String {
        switch self {
        case .basicEnvironment: return "基础环境"
        case .configureModel:   return "模型配置"
        case .configureChannel: return "频道配置"
        case .finish:           return "完成"
        }
    }

    var icon: String {
        switch self {
        case .basicEnvironment: return "wrench.and.screwdriver"
        case .configureModel:   return "cpu"
        case .configureChannel: return "qrcode.viewfinder"
        case .finish:           return "checkmark.seal"
        }
    }

    static func from(key: String?) -> InitStep? {
        guard let key else { return nil }
        return allCases.first { $0.key == key || $0.title == key }
    }
}

enum StepStatus: Equatable {
    case pending, running, done
    case failed(String)
}

private enum MinimaxModel: String, CaseIterable {
    case m25 = "minimax/MiniMax-M2.5"
    case m25Highspeed = "minimax/MiniMax-M2.5-highspeed"
    case vl01 = "minimax/MiniMax-VL-01"
    case m2 = "minimax/MiniMax-M2"
    case m21 = "minimax/MiniMax-M2.1"

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "minimax/", with: "")
    }

    var providerName: String {
        switch self {
        case .m25: return "MiniMax M2.5"
        case .m25Highspeed: return "MiniMax M2.5 Highspeed"
        case .vl01: return "MiniMax VL 01"
        case .m2: return "MiniMax M2"
        case .m21: return "MiniMax M2.1"
        }
    }

    var reasoning: Bool {
        switch self {
        case .vl01: return false
        default: return true
        }
    }

    var inputTypes: [String] {
        switch self {
        case .vl01: return ["text", "image"]
        default: return ["text"]
        }
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": providerName,
            "reasoning": reasoning,
            "input": inputTypes,
            "cost": [
                "input": 0.3,
                "output": 1.2,
                "cacheRead": 0.03,
                "cacheWrite": 0.12,
            ],
            "contextWindow": 200000,
            "maxTokens": 8192,
        ]
    }
}

private enum WizardChannelType: String {
    case feishu
}

private enum WizardXcodeHealthState {
    case checking
    case healthy
    case unhealthy
}

private enum WizardProvider: String, CaseIterable, Identifiable {
    case kimiCoding = "kimi-coding"
    case minimax = "minimax"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimiCoding: return "Kimi Code"
        case .minimax:    return "MiniMax"
        }
    }

    var subtitle: String {
        switch self {
        case .kimiCoding: return "Kimi for Coding"
        case .minimax:    return "MiniMax M2.5 系列"
        }
    }

    var icon: String {
        switch self {
        case .kimiCoding: return "k.circle"
        case .minimax:    return "m.circle"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax:    return "MiniMax API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax:    return "粘贴 MiniMax API Key"
        }
    }

    var consoleURL: String {
        switch self {
        case .kimiCoding: return "https://www.kimi.com/code/console"
        case .minimax:    return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        }
    }

    var consoleLinkTitle: String {
        switch self {
        case .kimiCoding: return "Kimi Code 控制台"
        case .minimax:    return "MiniMax 控制台"
        }
    }
}

// MARK: - 进度持久化模型

enum InitWizardMode: String, Codable {
    case onboarding
    case reconfigure
}

struct InitWizardState: Codable {
    var schemaVersion: Int = 2
    var mode: InitWizardMode = .onboarding
    var active: Bool = false
    var currentStep: String?
    var steps: [String: String] = [:]
    var stepErrors: [String: String] = [:]
    var npmRegistry: String?
    var modelName: String = ""
    var channelType: String = ""
    var updatedAt: Date = Date()
    var completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, active, currentStep, steps, stepErrors, npmRegistry, modelName, channelType, updatedAt, completedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        mode = try c.decodeIfPresent(InitWizardMode.self, forKey: .mode) ?? .onboarding
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        currentStep = try c.decodeIfPresent(String.self, forKey: .currentStep)
        steps = try c.decodeIfPresent([String: String].self, forKey: .steps) ?? [:]
        stepErrors = try c.decodeIfPresent([String: String].self, forKey: .stepErrors) ?? [:]
        npmRegistry = try c.decodeIfPresent(String.self, forKey: .npmRegistry)
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        channelType = try c.decodeIfPresent(String.self, forKey: .channelType) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    var isCompleted: Bool {
        completedAt != nil
            || steps["finish"] == "done"
            || steps["configureOpenclaw"] == "done"
    }

    static func from(json: String) -> InitWizardState? {
        guard let data = json.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var state = try? dec.decode(InitWizardState.self, from: data) else { return nil }
        if state.schemaVersion <= 1 {
            // 兼容旧结构：从 running 步骤推断 currentStep
            if state.currentStep == nil {
                state.currentStep = InitStep.allCases.first {
                    state.steps[$0.key] == "running"
                }?.key
            }
            if !state.isCompleted {
                let hasLegacyProgress = InitStep.allCases.contains {
                    (state.steps[$0.key] ?? "pending") != "pending"
                }
                if hasLegacyProgress {
                    state.active = true
                }
            }
            if state.isCompleted {
                state.active = false
                if state.completedAt == nil { state.completedAt = state.updatedAt }
            }
            state.schemaVersion = 2
        }
        return state
    }

    func toJSON() -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - 向导主视图

struct UserInitWizardView: View {
    let user: ManagedUser
    var onSessionActiveChanged: ((Bool) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow

    @State private var statuses: [Int: StepStatus] = [:]
    @State private var initiated = false
    @State private var isCancelling = false
    @State private var isHydratingState = true
    @State private var isRunningInitFlow = false
    @State private var wizardMode: InitWizardMode = .onboarding
    @State private var currentStep: InitStep? = nil
    @State private var selectedNpmRegistry: NpmRegistryOption = .defaultForInitialization
    @State private var showTerminal = false
    @State private var showAdvancedOptions = false
    @State private var wizardConn: WizardConnection? = nil
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue

    // Step 2: 模型配置
    @State private var selectedWizardProvider: WizardProvider = .kimiCoding
    @State private var wizardApiKey = ""
    @State private var isShowingApiKey = false
    @State private var minimaxApiKey = ""  // 保留用于持久化反序列化兼容
    @State private var selectedMinimaxModel: MinimaxModel = .m25
    @State private var isApplyingModel = false
    @State private var modelConfigError = ""

    // Step 3: 频道配置
    @State private var selectedChannel: WizardChannelType = .feishu
    @State private var isFeishuBindingHovered = false

    // Step 4: 完成
    @State private var isStartingOpenclaw = false
    @State private var finishProgressMessages: [String] = []
    @State private var xcodeEnvStatus: XcodeEnvStatus? = nil
    @State private var isInstallingXcodeCLT = false
    @State private var isAcceptingXcodeLicense = false
    @State private var xcodeFixMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── 顶部标题栏 ───────────────────────────────────────
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("初始化 · \(user.username)")
                        .font(.headline)
                    Text("正在配置生存空间")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if (currentStep == .basicEnvironment) || isApplyingModel || isStartingOpenclaw {
                    ProgressView().scaleEffect(0.65)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // ── 主体：左侧导航 + 右侧内容 ────────────────────────
            HStack(spacing: 0) {
                leftRail
                    .frame(width: 160)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            if !initiated {
                                preStartPanel
                            } else if hasFailure {
                                failurePanel
                            } else if currentStep == .basicEnvironment {
                                runningPanel
                            } else if currentStep == .configureModel {
                                modelConfigPanel
                            } else if currentStep == .configureChannel {
                                channelConfigPanel
                            } else if currentStep == .finish {
                                finishPanel
                            } else {
                                recoveryPanel
                            }
                        }
                        .padding(20)

                        advancedOptionsPanel
                            .padding(.horizontal, 20)
                    }
                }
                .frame(minWidth: 300)
            }

            Divider()

            // ── 底部命令输出折叠条 ────────────────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showTerminal.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTerminal ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text("命令输出")
                        .font(.caption).fontWeight(.medium)
                    Spacer()
                    if !showTerminal && ((currentStep == .basicEnvironment) || isApplyingModel || isStartingOpenclaw) {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                            .symbolEffect(.pulse, options: .repeating)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showTerminal {
                TerminalLogPanel(username: user.username)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .task {
            await loadSavedState()
            while !Task.isCancelled {
                if initiated {
                    await reconcileStateFromPersistence()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onChange(of: user.username) { _, _ in
            resetWizardStateOnly()
        }
    }

    // MARK: - Left Rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(InitStep.allCases, id: \.rawValue) { step in
                leftRailRow(step: step)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func leftRailRow(step: InitStep) -> some View {
        let status = statuses[step.rawValue] ?? .pending
        let isActive = currentStep == step || (!initiated && step == .basicEnvironment)

        HStack(spacing: 8) {
            Group {
                switch status {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse, options: .repeating)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .pending:
                    Image(systemName: step.icon)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                }
            }
            .font(.footnote)
            .frame(width: 16)

            Text(step.title)
                .font(.callout)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .primary : (status == .done ? .secondary : .tertiary))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Panels

    private var preStartPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("基础环境初始化")
                    .font(.title3).fontWeight(.semibold)
                Text("安装 Node.js / npm 环境与 openclaw 核心组件。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("关于权限", systemImage: "info.circle")
                        .font(.subheadline).fontWeight(.medium)
                    Text("安装阶段会自动处理 Node.js / npm 环境 / openclaw。\n\n这些细节统一归为「基础环境初始化」。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }

            if isHydratingState {
                Label("正在恢复初始化状态…", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button(hasPartialProgress ? "从当前进度继续" : "开始初始化") {
                initiated = true
                Task {
                    if hasPartialProgress { await resumePendingStep() }
                    else { await runInitSteps() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isHydratingState)
        }
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("基础环境初始化")
                    .font(.title3).fontWeight(.semibold)
                Text("正在安装依赖，请稍候。此阶段无需重复点击继续。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(isCancelling ? "正在终止…" : "终止初始化") {
                    isCancelling = true
                    Task {
                        await helperClient.cancelInit(username: user.username)
                        await markRunningStepsAsCancelledAndPersist()
                        isCancelling = false
                    }
                }
                .buttonStyle(.bordered).foregroundStyle(.red)
                .disabled(isCancelling)
            }
        }
    }

    private var modelConfigPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择 AI Provider")
                    .font(.title3).fontWeight(.semibold)
                Text("选择一个 Provider 并填入 API Key，即可完成模型配置。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(WizardProvider.allCases) { provider in
                    providerSelectRow(provider)
                }
            }

            Divider()

            providerDetailForm

            if !modelConfigError.isEmpty {
                Label(modelConfigError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(isApplyingModel ? "保存中…" : "保存并继续") {
                    Task { await applyModelConfig() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingModel || wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func providerSelectRow(_ provider: WizardProvider) -> some View {
        let selected = selectedWizardProvider == provider
        Button {
            selectedWizardProvider = provider
            wizardApiKey = ""
            modelConfigError = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.body)

                Image(systemName: provider.icon)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.callout).fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    Text(provider.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var providerDetailForm: some View {
        let provider = selectedWizardProvider
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(provider.apiKeyLabel)
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button {
                        if let url = URL(string: provider.consoleURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square").font(.caption)
                            Text(provider.consoleLinkTitle).font(.caption)
                        }
                    }
                    .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                }

                HStack(spacing: 8) {
                    Group {
                        if isShowingApiKey {
                            TextField(provider.apiKeyPlaceholder, text: $wizardApiKey)
                        } else {
                            SecureField(provider.apiKeyPlaceholder, text: $wizardApiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        isShowingApiKey.toggle()
                    } label: {
                        Image(systemName: isShowingApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .help(isShowingApiKey ? "隐藏" : "显示")
                }
            }

            if provider == .minimax {
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型").font(.subheadline).fontWeight(.medium)
                    VStack(spacing: 0) {
                        ForEach(MinimaxModel.allCases, id: \.self) { model in
                            minimaxModelRow(model)
                            if model != MinimaxModel.allCases.last {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func minimaxModelRow(_ model: MinimaxModel) -> some View {
        let selected = selectedMinimaxModel == model
        Button { selectedMinimaxModel = model } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.providerName).font(.callout).foregroundStyle(.primary)
                    Text(model.rawValue)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var channelConfigPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("绑定频道")
                    .font(.title3).fontWeight(.semibold)
                Text("选择要接入的沟通渠道，完成配对后虾即可收发消息。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            channelBindingList

            HStack(spacing: 12) {
                Button("上一步") { Task { await moveBackToModelStep() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary)
                Button("已完成，继续") { Task { await markChannelStepDone() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var channelBindingList: some View {
        VStack(spacing: 0) {
            channelBindingRow(
                title: "飞书扫码绑定",
                subtitle: "在独立窗口生成二维码，扫码完成配对。"
            ) {
                openWindow(
                    id: "channel-onboarding",
                    value: "\(ChannelOnboardingFlow.feishu.rawValue):\(user.username)"
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func channelBindingRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("点击打开")
                        .font(.caption)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(isFeishuBindingHovered ? Color.accentColor : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFeishuBindingHovered ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFeishuBindingHovered
                            ? Color.accentColor.opacity(0.45)
                            : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isFeishuBindingHovered = hovering
            }
        }
    }

    private var finishPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("初始化完成").font(.title3).fontWeight(.semibold)
                }
                Text("基础环境、模型、频道配置步骤已完成。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("上一步") { Task { await moveBackToChannelStep() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary).disabled(isStartingOpenclaw)

                Button(isStartingOpenclaw ? "启动中…" : "立即启动 OpenClaw") {
                    Task { await finishAndStartOpenclaw() }
                }
                .buttonStyle(.borderedProminent).disabled(isStartingOpenclaw)

                Button("稍后启动") { Task { await completeWizardOnly() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary).disabled(isStartingOpenclaw)
            }

            finishProgressPanel
        }
    }

    @ViewBuilder
    private var finishProgressPanel: some View {
        if !finishProgressMessages.isEmpty {
            GroupBox("当前进度") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(finishProgressMessages.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("步骤失败").font(.title3).fontWeight(.semibold)
                }
                Text("请查看命令输出了解详情，然后重试或重新开始。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message = latestFailureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if isBasicEnvironmentFailed {
                xcodeQuickFixPanel
            }
            HStack(spacing: 12) {
                Button("重试失败步骤") { Task { await retryFromFailure() } }
                    .buttonStyle(.borderedProminent)
                Button("重新开始") { resetWizard() }
                    .buttonStyle(.bordered).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var xcodeQuickFixPanel: some View {
        let status = xcodeEnvStatus
        let healthState: WizardXcodeHealthState = {
            guard let status else { return .checking }
            return status.isHealthy ? .healthy : .unhealthy
        }()
        let iconName: String = {
            switch healthState {
            case .checking: return "clock"
            case .healthy: return "checkmark.circle.fill"
            case .unhealthy: return "exclamationmark.triangle.fill"
            }
        }()
        let iconColor: Color = {
            switch healthState {
            case .checking: return .secondary
            case .healthy: return .green
            case .unhealthy: return .orange
            }
        }()
        let bgColor: Color = {
            switch healthState {
            case .checking: return Color.secondary.opacity(0.08)
            case .healthy: return Color.green.opacity(0.08)
            case .unhealthy: return Color.orange.opacity(0.08)
            }
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                Text("开发环境修复")
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
                if isInstallingXcodeCLT || isAcceptingXcodeLicense {
                    ProgressView().scaleEffect(0.6)
                }
                Button("刷新状态") { Task { await refreshXcodeEnvStatus() } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            if let status {
                Label(status.commandLineToolsInstalled ? "CLT 已安装" : "CLT 未安装",
                      systemImage: status.commandLineToolsInstalled ? "checkmark" : "xmark")
                    .font(.caption)
                    .foregroundStyle(status.commandLineToolsInstalled ? Color.secondary : Color.orange)
                Label(status.licenseAccepted ? "Xcode license 已接受" : "Xcode license 未接受",
                      systemImage: status.licenseAccepted ? "checkmark" : "xmark")
                    .font(.caption)
                    .foregroundStyle(status.licenseAccepted ? Color.secondary : Color.orange)
            } else {
                Text("环境状态读取中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(isInstallingXcodeCLT ? "安装中…" : "安装开发工具") {
                    Task { await installXcodeCommandLineToolsFromWizard() }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)

                Button(isAcceptingXcodeLicense ? "处理中…" : "同意 Xcode 许可") {
                    Task { await acceptXcodeLicenseFromWizard() }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)

                Button("打开软件更新") {
                    openSoftwareUpdate()
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense)
            }

            if let msg = xcodeFixMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bgColor)
        )
    }

    private var recoveryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(.orange)
                    Text("初始化已暂停").font(.title3).fontWeight(.semibold)
                }
                Text("检测到步骤未运行但未完成，可继续执行剩余步骤。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("继续剩余步骤") { Task { await resumePendingStep() } }
                    .buttonStyle(.borderedProminent)
                Button("重新初始化") {
                    isCancelling = true
                    Task {
                        await helperClient.cancelInit(username: user.username)
                        isCancelling = false
                        resetWizard()
                    }
                }
                .buttonStyle(.bordered).foregroundStyle(.secondary).disabled(isCancelling)
            }
        }
    }

    private var advancedOptionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 可点击的标题行
            Button {
                showAdvancedOptions.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvancedOptions ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text("高级选项")
                        .font(.caption).fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if showAdvancedOptions {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("npm 安装源").font(.subheadline).fontWeight(.medium)
                        Picker("npm 安装源", selection: $selectedNpmRegistry) {
                            ForEach(NpmRegistryOption.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text("该设置会写入 @\(user.username) 的 npm 用户配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("维护工具").font(.subheadline).fontWeight(.medium)
                        Button("命令行维护（高级）") { openMaintenanceTerminal() }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.secondary)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - 步骤执行

    private var hasFailure: Bool {
        statuses.values.contains { if case .failed = $0 { return true }; return false }
    }

    private var isBasicEnvironmentFailed: Bool {
        if case .failed = statuses[InitStep.basicEnvironment.rawValue] { return true }
        return false
    }

    private var latestFailureMessage: String? {
        for step in InitStep.allCases {
            if case .failed(let message) = statuses[step.rawValue],
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        return nil
    }

    private var hasPartialProgress: Bool {
        InitStep.allCases.contains {
            switch statuses[$0.rawValue] ?? .pending {
            case .pending: return false
            default: return true
            }
        }
    }

    private func resetWizardStateOnly() {
        statuses = [:]
        initiated = false
        isHydratingState = true
        isRunningInitFlow = false
        wizardMode = .onboarding
        currentStep = nil
        selectedNpmRegistry = .defaultForInitialization
        showTerminal = false
        wizardApiKey = ""
        isShowingApiKey = false
        minimaxApiKey = ""
        selectedWizardProvider = .kimiCoding
        selectedMinimaxModel = .m25
        modelConfigError = ""
        selectedChannel = .feishu
        isStartingOpenclaw = false
        finishProgressMessages = []
        user.initStep = nil
    }

    private func resetWizard() {
        resetWizardStateOnly()
        wizardConn = nil
        onSessionActiveChanged?(false)
        Task { try? await helperClient.saveInitState(username: user.username, json: "{}") }
    }

    private func runInitSteps() async {
        guard !isRunningInitFlow else { return }
        guard (statuses[InitStep.basicEnvironment.rawValue] ?? .pending) != .done else { return }

        isRunningInitFlow = true
        defer { isRunningInitFlow = false }

        // 在进入长流程前先做 Xcode 预检，避免失败/运行面板来回闪动。
        appendLog("\n▶ 检查 Xcode 开发环境\n")
        do {
            try await ensureXcodeEnvironmentReady()
            appendLog("✓ Xcode 开发环境已就绪\n")
        } catch {
            let message = error.localizedDescription
            appendLog("❌ \(message)\n")
            wizardMode = .onboarding
            currentStep = .basicEnvironment
            statuses[InitStep.basicEnvironment.rawValue] = .failed(message)
            user.initStep = InitStep.basicEnvironment.title
            onSessionActiveChanged?(true)
            await persistState(activeOverride: true)
            return
        }

        if wizardConn == nil { wizardConn = WizardConnection() }
        guard let conn = wizardConn else { return }

        wizardMode = .onboarding
        currentStep = .basicEnvironment
        statuses[InitStep.basicEnvironment.rawValue] = .running
        user.initStep = InitStep.basicEnvironment.title
        await persistState()
        onSessionActiveChanged?(true)

        let autoSteps: [(title: String, run: () async throws -> Void)] = [
            ("安装 Node.js", { try await conn.installNode(username: user.username, nodeDistURL: nodeDistURL) }),
            ("配置 npm 目录", { try await conn.setupNpmEnv(username: user.username) }),
            ("设置 npm 安装源", {
                try await conn.setNpmRegistry(username: user.username, registry: selectedNpmRegistry.rawValue)
            }),
            ("安装 openclaw", { try await conn.installOpenclaw(username: user.username) }),
        ].compactMap { $0 }

        for item in autoSteps {
            appendLog("\n▶ \(item.title)\n")
            do {
                try await item.run()
            } catch {
                let message = error.localizedDescription
                if message.contains("已有初始化命令正在运行") {
                    return
                }
                appendLog("❌ \(message)\n")
                statuses[InitStep.basicEnvironment.rawValue] = .failed(message)
                // 失败时保持在基础环境步骤，避免 active=false 导致向导被父视图收起。
                user.initStep = InitStep.basicEnvironment.title
                currentStep = .basicEnvironment
                await persistState(activeOverride: true)
                return
            }
        }

        statuses[InitStep.basicEnvironment.rawValue] = .done
        currentStep = .configureModel
        statuses[InitStep.configureModel.rawValue] = .running
        user.initStep = InitStep.configureModel.title
        await persistState()
    }

    private func ensureXcodeEnvironmentReady() async throws {
        guard let status = await helperClient.getXcodeEnvStatus() else {
            xcodeEnvStatus = nil
            throw HelperError.operationFailed("无法读取 Xcode 开发环境状态，请稍后重试。")
        }
        xcodeEnvStatus = status
        xcodeFixMessage = nil
        if !status.commandLineToolsInstalled {
            throw HelperError.operationFailed("检测到缺少 Xcode Command Line Tools。请先在「开发环境修复」中点击“安装开发工具”，完成后再重试初始化。")
        }
        if !status.licenseAccepted {
            throw HelperError.operationFailed("检测到 Xcode license 未接受。请先在「开发环境修复」中点击“同意 Xcode 许可”，完成后再重试初始化。")
        }
        if !status.clangAvailable {
            let details = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                throw HelperError.operationFailed("检测到 Xcode 工具链未就绪。请先在「开发环境修复」中完成修复后再重试初始化。")
            }
            throw HelperError.operationFailed("检测到 Xcode 工具链未就绪：\(details)")
        }
    }

    private func refreshXcodeEnvStatus() async {
        xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
    }

    private func installXcodeCommandLineToolsFromWizard() async {
        isInstallingXcodeCLT = true
        xcodeFixMessage = nil
        do {
            try await helperClient.installXcodeCommandLineTools()
            xcodeFixMessage = "已触发系统安装窗口，请按提示完成安装。"
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        await refreshXcodeEnvStatus()
        isInstallingXcodeCLT = false
    }

    private func acceptXcodeLicenseFromWizard() async {
        isAcceptingXcodeLicense = true
        xcodeFixMessage = nil
        do {
            try await helperClient.acceptXcodeLicense()
            xcodeFixMessage = "已执行 license 接受，正在刷新状态。"
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        await refreshXcodeEnvStatus()
        isAcceptingXcodeLicense = false
    }

    private func openSoftwareUpdate() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") else {
            return
        }
        NSWorkspace.shared.open(url)
        xcodeFixMessage = "已打开“软件更新”。若弹窗未出现，可在系统设置中手动安装 Command Line Tools。"
    }

    private func resumePendingStep() async {
        if (statuses[InitStep.basicEnvironment.rawValue] ?? .pending) != .done {
            await runInitSteps()
            return
        }
        if (statuses[InitStep.configureModel.rawValue] ?? .pending) != .done {
            currentStep = .configureModel
            statuses[InitStep.configureModel.rawValue] = .running
            user.initStep = InitStep.configureModel.title
            await persistState()
            return
        }
        if (statuses[InitStep.configureChannel.rawValue] ?? .pending) != .done {
            currentStep = .configureChannel
            statuses[InitStep.configureChannel.rawValue] = .running
            user.initStep = InitStep.configureChannel.title
            await persistState()
            return
        }
        if (statuses[InitStep.finish.rawValue] ?? .pending) != .done {
            currentStep = .finish
            statuses[InitStep.finish.rawValue] = .running
            user.initStep = InitStep.finish.title
            await persistState()
        }
    }

    private func retryFromFailure() async {
        if case .failed = statuses[InitStep.basicEnvironment.rawValue] {
            statuses[InitStep.basicEnvironment.rawValue] = .pending
            await runInitSteps()
            return
        }
        if case .failed = statuses[InitStep.configureModel.rawValue] {
            statuses[InitStep.configureModel.rawValue] = .running
            currentStep = .configureModel
            user.initStep = InitStep.configureModel.title
            await persistState()
            return
        }
        if case .failed = statuses[InitStep.configureChannel.rawValue] {
            statuses[InitStep.configureChannel.rawValue] = .running
            currentStep = .configureChannel
            user.initStep = InitStep.configureChannel.title
            await persistState()
            return
        }
        if case .failed = statuses[InitStep.finish.rawValue] {
            statuses[InitStep.finish.rawValue] = .running
            currentStep = .finish
            user.initStep = InitStep.finish.title
            await persistState()
            return
        }
        await resumePendingStep()
    }

    private func applyModelConfig() async {
        let key = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isApplyingModel = true
        modelConfigError = ""
        defer { isApplyingModel = false }

        do {
            switch selectedWizardProvider {
            case .kimiCoding:
                try await applyKimiCodingConfig(apiKey: key)
            case .minimax:
                try await applyMinimaxConfig(apiKey: key)
            }

            statuses[InitStep.configureModel.rawValue] = .done
            currentStep = .configureChannel
            statuses[InitStep.configureChannel.rawValue] = .running
            user.initStep = InitStep.configureChannel.title
            await persistState()
        } catch {
            modelConfigError = error.localizedDescription
        }
    }

    private func applyKimiCodingConfig(apiKey: String) async throws {
        let modelId = "kimi-coding/k2p5"
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.kimi-coding",
            value: [
                "api": "anthropic-messages",
                "baseUrl": "https://api.kimi.com/coding/",
                "apiKey": apiKey,
                "models": [[
                    "id": "k2p5",
                    "name": "Kimi for Coding",
                    "reasoning": true,
                    "input": ["text", "image"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 262144,
                    "maxTokens": 32768,
                ]],
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "agents.defaults.model",
            value: ["primary": modelId]
        )

        // auth-profiles.json
        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["kimi-coding:default"] = ["type": "api_key", "provider": "kimi-coding", "key": apiKey]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        // models.json
        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["kimi-coding"] = [
            "baseUrl": "https://api.kimi.com/coding/",
            "api": "anthropic-messages",
            "models": [["id": "k2p5", "name": "Kimi for Coding", "reasoning": true,
                        "input": ["text", "image"],
                        "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                        "contextWindow": 262144, "maxTokens": 32768]],
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func applyMinimaxConfig(apiKey: String) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let providerModels = MinimaxModel.allCases.map(\.providerModelConfig)
        var modelAliasMap = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:]
        var selectedAlias = (modelAliasMap[selectedMinimaxModel.rawValue] as? [String: Any]) ?? [:]
        selectedAlias["alias"] = selectedAlias["alias"] ?? "Minimax"
        modelAliasMap[selectedMinimaxModel.rawValue] = selectedAlias
        let existingModel = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:]
        var normalizedModelConfig: [String: Any] = ["primary": selectedMinimaxModel.rawValue]
        if let arr = existingModel["fallback"] as? [String], !arr.isEmpty {
            normalizedModelConfig["fallback"] = arr
        } else if let single = existingModel["fallback"] as? String, !single.isEmpty {
            normalizedModelConfig["fallback"] = [single]
        }

        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.minimax",
            value: [
                "api": "anthropic-messages",
                "baseUrl": "https://api.minimaxi.com/anthropic",
                "authHeader": true,
                "models": providerModels,
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.minimax:cn",
            value: ["provider": "minimax", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.model", value: normalizedModelConfig)
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.models", value: modelAliasMap)
        try await syncAgentModelFiles(apiKey: apiKey, providerModels: providerModels)
    }

    /// 同步写入新结构下的 agent 配置文件：
    /// - ~/.openclaw/agents/main/agent/auth-profiles.json（API key）
    /// - ~/.openclaw/agents/main/agent/models.json（provider + 模型清单）
    private func syncAgentModelFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        // auth-profiles.json
        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["minimax:cn"] = [
            "type": "api_key",
            "provider": "minimax",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        // models.json
        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["minimax"] = [
            "baseUrl": "https://api.minimaxi.com/anthropic",
            "api": "anthropic-messages",
            "authHeader": true,
            "models": providerModels,
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func readUserJSON(relativePath: String) async -> [String: Any] {
        guard let data = try? await helperClient.readFile(username: user.username, relativePath: relativePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return root
    }

    private func writeUserJSON(_ object: [String: Any], relativePath: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try await helperClient.writeFile(username: user.username, relativePath: relativePath, data: data)
    }

    private func markChannelStepDone() async {
        statuses[InitStep.configureChannel.rawValue] = .done
        currentStep = .finish
        statuses[InitStep.finish.rawValue] = .running
        user.initStep = InitStep.finish.title
        await persistState()
    }

    private func moveBackToModelStep() async {
        currentStep = .configureModel
        statuses[InitStep.configureModel.rawValue] = .running
        statuses[InitStep.configureChannel.rawValue] = .pending
        statuses[InitStep.finish.rawValue] = .pending
        user.initStep = InitStep.configureModel.title
        await persistState()
    }

    private func moveBackToChannelStep() async {
        currentStep = .configureChannel
        statuses[InitStep.configureChannel.rawValue] = .running
        statuses[InitStep.finish.rawValue] = .pending
        user.initStep = InitStep.configureChannel.title
        await persistState()
    }

    private func completeWizardOnly() async {
        statuses[InitStep.finish.rawValue] = .done
        currentStep = nil
        user.initStep = nil
        await persistState()
        onSessionActiveChanged?(false)
        wizardConn = nil
        user.openclawVersion = await helperClient.getOpenclawVersion(username: user.username)
    }

    private func finishAndStartOpenclaw() async {
        guard !isStartingOpenclaw else { return }
        isStartingOpenclaw = true
        defer { isStartingOpenclaw = false }
        finishProgressMessages = []
        appendFinishProgress("初始化已完成，正在进入概览页…")

        // 先退出向导回到概览页，再在后台继续启动流程，避免用户停留在初始化界面。
        gatewayHub.markPendingStart(username: user.username)
        await completeWizardOnly()
        appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 已切换到概览页，继续后台启动 Gateway。\n")

        appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 正在启动 Gateway…\n")

        do {
            try await helperClient.startGateway(username: user.username)
            user.isRunning = true
            appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 启动成功。\n")
        } catch {
            // 启动失败不阻断完成状态，用户可在列表页再次启动
            appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 启动失败：\(error.localizedDescription)\n")
        }

        let tokenReadyURL = await waitForGatewayURLWithToken(emitProgress: false)
        if let tokenReadyURL,
           let url = URL(string: tokenReadyURL),
           !tokenReadyURL.isEmpty {
            NSWorkspace.shared.open(url)
            appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Web UI 已打开。\n")
        }
    }

    private func waitForGatewayURLWithToken(
        maxAttempts: Int = 20,
        retryDelayNanoseconds: UInt64 = 500_000_000,
        emitProgress: Bool = true
    ) async -> String? {
        if emitProgress {
            appendFinishProgress("正在获取 Web UI Token…")
        } else {
            appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 正在获取 Web UI Token…\n")
        }
        for attempt in 1...maxAttempts {
            let urlString = await helperClient.getGatewayURL(username: user.username)
            if gatewayToken(from: urlString) != nil {
                if emitProgress {
                    appendFinishProgress("Token 获取成功。")
                } else {
                    appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 获取成功。\n")
                }
                return urlString
            }
            if attempt < maxAttempts {
                if emitProgress {
                    appendFinishProgress("Token 暂未就绪（\(attempt)/\(maxAttempts)），继续等待…")
                } else {
                    appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 暂未就绪（\(attempt)/\(maxAttempts)），继续等待…\n")
                }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        if emitProgress {
            appendFinishProgress("Token 获取超时，未自动打开 Web UI。")
        } else {
            appendLog("[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 获取超时，未自动打开 Web UI。\n")
        }
        return nil
    }

    private func gatewayToken(from gatewayURL: String) -> String? {
        guard let components = URLComponents(string: gatewayURL),
              let fragment = components.fragment,
              fragment.hasPrefix("token=") else { return nil }
        let token = String(fragment.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func appendFinishProgress(_ text: String) {
        let line = "[\(Self.finishProgressTimeFormatter.string(from: Date()))] \(text)"
        finishProgressMessages.append(line)
        if finishProgressMessages.count > 8 {
            finishProgressMessages.removeFirst(finishProgressMessages.count - 8)
        }
        appendLog("[finish] \(line)\n")
    }

    private func appendLog(_ text: String) {
        let path = "/tmp/clawdhome-init-\(user.username).log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                attributes: [FileAttributeKey.posixPermissions: 0o644])
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(text.utf8))
            fh.closeFile()
        }
    }

    // MARK: - 持久化

    private func persistState(activeOverride: Bool? = nil) async {
        var state = InitWizardState()
        state.schemaVersion = 2
        state.mode = wizardMode
        state.currentStep = currentStep?.key
        for step in InitStep.allCases {
            switch statuses[step.rawValue] ?? .pending {
            case .pending: state.steps[step.key] = "pending"
            case .running: state.steps[step.key] = "running"
            case .done:    state.steps[step.key] = "done"
            case .failed(let message):
                state.steps[step.key] = "failed"
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    state.stepErrors[step.key] = trimmed
                }
            }
        }
        state.npmRegistry = selectedNpmRegistry.rawValue
        state.modelName = selectedMinimaxModel.rawValue
        state.channelType = selectedChannel.rawValue
        state.updatedAt = Date()
        let done = (statuses[InitStep.finish.rawValue] ?? .pending) == .done
        state.active = activeOverride ?? (!done && currentStep != nil)
        state.completedAt = done ? Date() : nil
        try? await helperClient.saveInitState(username: user.username, json: state.toJSON())
    }

    private func loadSavedState() async {
        defer { isHydratingState = false }
        let json = await helperClient.loadInitState(username: user.username)
        guard let saved = InitWizardState.from(json: json) else { return }
        await applySavedState(saved)
    }

    private func reconcileStateFromPersistence() async {
        let json = await helperClient.loadInitState(username: user.username)
        guard let saved = InitWizardState.from(json: json) else { return }
        await applySavedState(saved)
    }

    private func applySavedState(_ saved: InitWizardState) async {
        wizardMode = saved.mode
        hydrateDraftSelectionsIfNeeded(from: saved)
        await applyRuntimeStateFromPersistence(saved)
    }

    /// 仅在首次加载阶段回填“可编辑草稿字段”。
    /// 轮询同步期间不覆盖用户正在界面上的实时选择。
    private func hydrateDraftSelectionsIfNeeded(from saved: InitWizardState) {
        // 仅在首次水合阶段回填 npm 源，避免轮询状态覆盖用户在界面上的实时选择。
        if isHydratingState,
           let raw = saved.npmRegistry,
           let option = NpmRegistryOption.fromRegistryURL(raw) {
            selectedNpmRegistry = option
        }

        // 仅在首次水合阶段回填模型草稿，避免轮询状态覆盖用户在界面上的实时选择。
        if isHydratingState, let model = MinimaxModel(rawValue: saved.modelName) {
            selectedMinimaxModel = model
        }

        // 仅在首次水合阶段回填频道草稿，避免未来多频道场景下出现“选择被弹回”。
        if isHydratingState {
            selectedChannel = WizardChannelType(rawValue: saved.channelType) ?? .feishu
        }
    }

    /// 从持久化状态同步“运行态字段”（步骤状态、当前步骤、会话活跃态）。
    /// 该阶段允许在轮询期间持续更新。
    private func applyRuntimeStateFromPersistence(_ saved: InitWizardState) async {
        var restored: [Int: StepStatus] = [:]
        for step in InitStep.allCases {
            let raw = saved.steps[step.key] ?? saved.steps[step.title]
            switch raw {
            case "running": restored[step.rawValue] = .running
            case "done":    restored[step.rawValue] = .done
            case "failed":
                let message = saved.stepErrors[step.key]
                    ?? saved.stepErrors[step.title]
                    ?? ""
                restored[step.rawValue] = .failed(message)
            default: break
            }
        }

        if let step = InitStep.from(key: saved.currentStep) {
            if restored[step.rawValue] == nil {
                restored[step.rawValue] = .running
            }
            currentStep = step
        } else if let failed = InitStep.allCases.first(where: {
            if case .failed = restored[$0.rawValue] { return true }
            return false
        }) {
            currentStep = failed
        } else if let running = InitStep.allCases.first(where: { restored[$0.rawValue] == .running }) {
            currentStep = running
        } else if !saved.isCompleted {
            currentStep = InitStep.allCases.first(where: { restored[$0.rawValue] != .done })
        } else {
            currentStep = nil
        }
        statuses = restored
        if case .failed = restored[InitStep.basicEnvironment.rawValue] {
            xcodeEnvStatus = await helperClient.getXcodeEnvStatus()
        }

        let hasRecoverableProgress = InitStep.allCases.contains { step in
            switch restored[step.rawValue] ?? .pending {
            case .pending: return false
            default: return true
            }
        }
        let effectiveActive = saved.active || (!saved.isCompleted && hasRecoverableProgress)
        let hasAnyState = effectiveActive || saved.isCompleted
        initiated = hasAnyState
        onSessionActiveChanged?(effectiveActive)

        guard hasAnyState else {
            user.initStep = nil
            currentStep = nil
            return
        }

        if saved.isCompleted {
            user.openclawVersion = await helperClient.getOpenclawVersion(username: user.username)
            user.initStep = nil
            currentStep = nil
            return
        }

        guard effectiveActive else {
            user.initStep = nil
            currentStep = nil
            return
        }

        if let step = currentStep {
            user.initStep = step.title
        } else {
            user.initStep = nil
        }
    }

    private func markRunningStepsAsCancelledAndPersist() async {
        var changed = false
        for step in InitStep.allCases where statuses[step.rawValue] == .running {
            statuses[step.rawValue] = .failed("已终止")
            changed = true
        }
        if changed {
            let failedStep = InitStep.allCases.first {
                if case .failed = statuses[$0.rawValue] { return true }
                return false
            } ?? .basicEnvironment
            currentStep = failedStep
            user.initStep = failedStep.title
            // 终止后保持向导会话活跃，确保稳定停留在失败面板，避免界面闪回 pre-start。
            await persistState(activeOverride: true)
        }
    }

    // MARK: - 完成后操作

    private func openMaintenanceTerminal() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: "初始化向导维护终端",
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    // 保留统一入口：若未来需要在完成页直接打开 Web，可复用此流程。
    private func openWebUI() async {
        finishProgressMessages = []
        if !user.isRunning {
            appendFinishProgress("Gateway 未运行，正在启动…")
            do {
                gatewayHub.markPendingStart(username: user.username)
                try await helperClient.startGateway(username: user.username)
                user.isRunning = true
                appendFinishProgress("Gateway 启动成功。")
            } catch {
                appendFinishProgress("Gateway 启动失败：\(error.localizedDescription)")
            }
        } else {
            appendFinishProgress("Gateway 已运行。")
        }

        let tokenReadyURL = await waitForGatewayURLWithToken()
        if let tokenReadyURL,
           let url = URL(string: tokenReadyURL),
           !tokenReadyURL.isEmpty {
            appendFinishProgress("正在打开 Web UI…")
            NSWorkspace.shared.open(url)
            appendFinishProgress("Web UI 已打开。")
        }
    }

    private static let finishProgressTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
