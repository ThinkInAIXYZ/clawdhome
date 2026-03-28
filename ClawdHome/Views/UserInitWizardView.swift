// ClawdHome/Views/UserInitWizardView.swift
// 生存空间初始化向导：基础环境初始化 → 模型配置 → 频道配置 → 完成

import SwiftUI

private let modelConfigMaintenanceContext = "wizard-model-config"

private struct ModelConfigTerminalCloseState: Identifiable {
    let id = UUID()
    let exitCode: Int32?
    let detectedModel: String?
}

private struct WizardInputSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }
}

private extension View {
    func wizardInputSurface() -> some View {
        modifier(WizardInputSurfaceModifier())
    }
}

// MARK: - 枚举定义

enum InitStep: Int, CaseIterable {
    case basicEnvironment
    case injectRole
    case configureModel
    case configureChannel
    case finish

    var key: String {
        switch self {
        case .basicEnvironment: return "basicEnvironment"
        case .injectRole:       return "injectRole"
        case .configureModel:   return "configureModel"
        case .configureChannel: return "configureChannel"
        case .finish:           return "finish"
        }
    }

    var title: String {
        switch self {
        case .basicEnvironment: return L10n.k("wizard.step.basic_environment", fallback: "基础环境")
        case .injectRole:       return L10n.k("wizard.step.inject_role", fallback: "注入角色")
        case .configureModel:   return L10n.k("wizard.step.configure_model", fallback: "模型配置")
        case .configureChannel: return L10n.k("wizard.step.configure_channel", fallback: "频道配置")
        case .finish:           return L10n.k("wizard.step.finish", fallback: "完成")
        }
    }

    var icon: String {
        switch self {
        case .basicEnvironment: return "wrench.and.screwdriver"
        case .injectRole:       return "person.text.rectangle"
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
    case m27 = "minimax/MiniMax-M2.7"
    case m27Highspeed = "minimax/MiniMax-M2.7-highspeed"
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
        case .m27: return "MiniMax M2.7"
        case .m27Highspeed: return "MiniMax M2.7 Highspeed"
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

private enum QiniuModel: String, CaseIterable {
    case deepseekV32 = "qiniu/deepseek-v3.2-251201"
    case glm5 = "qiniu/z-ai/glm-5"
    case kimiK25 = "qiniu/moonshotai/kimi-k2.5"
    case minimaxM25 = "qiniu/minimax/minimax-m2.5"

    var alias: String {
        switch self {
        case .deepseekV32: return "DeepSeek V3.2"
        case .glm5: return "GLM 5"
        case .kimiK25: return "Kimi K2.5"
        case .minimaxM25: return "Minimax M2.5"
        }
    }

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "qiniu/", with: "")
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": alias,
            "reasoning": false,
            "input": ["text"],
            "contextWindow": contextWindow,
            "maxTokens": 8192,
            "compat": [
                "supportsStore": false,
                "supportsDeveloperRole": false,
                "supportsReasoningEffort": false,
            ],
        ]
    }

    private var contextWindow: Int {
        switch self {
        case .kimiK25: return 256000
        default: return 128000
        }
    }
}

private enum ZAIModel: String, CaseIterable {
    case glm5 = "zai/glm-5"
    case glm4_7 = "zai/glm-4.7"
    case glm5_1 = "zai/glm-5.1"

    var alias: String {
        switch self {
        case .glm5: return "GLM-5"
        case .glm4_7: return "GLM-4.7"
        case .glm5_1: return "GLM-5.1"
        }
    }

    var providerModelID: String {
        rawValue.replacingOccurrences(of: "zai/", with: "")
    }

    var providerModelConfig: [String: Any] {
        [
            "id": providerModelID,
            "name": alias,
            "reasoning": true,
            "input": ["text"],
            "cost": ["input": 0.0, "output": 0.0, "cacheRead": 0.0, "cacheWrite": 0.0],
            "contextWindow": 204800,
            "maxTokens": 131072,
        ]
    }
}

private enum WizardChannelType: String {
    case feishu
    case weixin
}

private enum OpenclawVersionPreset: String {
    case latest
    case custom
}

private enum WizardXcodeHealthState {
    case checking
    case healthy
    case unhealthy
}

private enum WizardProvider: String, CaseIterable, Identifiable {
    case kimiCoding = "kimi-coding"
    case minimax = "minimax"
    case qiniu = "qiniu"
    case zai = "zai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimiCoding: return "Kimi Code"
        case .minimax:    return "MiniMax"
        case .qiniu:      return "Qiniu AI"
        case .zai:        return "智谱 Z.AI"
        }
    }

    var subtitle: String {
        switch self {
        case .kimiCoding: return "Kimi for Coding"
        case .minimax:    return L10n.k("wizard.provider.minimax.subtitle", fallback: "MiniMax M2.5 系列")
        case .qiniu:      return "DeepSeek / GLM / Kimi / Minimax"
        case .zai:        return "GLM系列模型"
        }
    }

    var icon: String {
        switch self {
        case .kimiCoding: return "k.circle"
        case .minimax:    return "m.circle"
        case .qiniu:      return "q.circle"
        case .zai:        return "sparkles"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax:    return "MiniMax API Key"
        case .qiniu:      return "Qiniu API Key"
        case .zai:        return "智谱 API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax:    return L10n.k("wizard.provider.minimax.api_key.placeholder", fallback: "粘贴 MiniMax API Key")
        case .qiniu:      return "sk-..."
        case .zai:        return "sk-..."
        }
    }

    var consoleURL: String {
        switch self {
        case .kimiCoding: return "https://www.kimi.com/code/console"
        case .minimax:    return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .qiniu:      return "https://portal.qiniu.com/ai-inference/api-key?ref=clawdhome.app"
        case .zai:        return "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"
        }
    }

    var consoleLinkTitle: String {
        switch self {
        case .kimiCoding: return L10n.k("wizard.provider.kimi.console", fallback: "Kimi Code 控制台")
        case .minimax:    return L10n.k("wizard.provider.minimax.console", fallback: "MiniMax 控制台")
        case .qiniu:      return "七牛 API Key"
        case .zai:        return "获取 API Key"
        }
    }

    var promotionURL: String? {
        switch self {
        case .minimax:
            return "https://platform.minimaxi.com/subscribe/token-plan?code=BvYUzElSu4&source=link"
        case .qiniu:
            return "https://www.qiniu.com/ai/promotion/invited?cps_key=1hdl63udiuyqa"
        case .zai:
            return "https://www.bigmodel.cn/glm-coding?ic=BXQV5BQ8BB"
        default:
            return nil
        }
    }

    var promotionTitle: String? {
        switch self {
        case .minimax:
            return "🎁 领取 9 折专属优惠"
        case .qiniu:
            return "免费领取 1000 万 Token"
        case .zai:
            return "95折优惠订阅"
        default:
            return nil
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
    var openclawVersion: String = "latest"
    var modelName: String = ""
    var channelType: String = ""
    var updatedAt: Date = Date()
    var completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, active, currentStep, steps, stepErrors, npmRegistry, openclawVersion, modelName, channelType, updatedAt, completedAt
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
        openclawVersion = try c.decodeIfPresent(String.self, forKey: .openclawVersion) ?? "latest"
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
    @State private var selectedOpenclawVersionPreset: OpenclawVersionPreset = .latest
    @State private var customOpenclawVersion = ""
    @State private var showTerminal = false
    @State private var showAdvancedOptions = false
    @State private var wizardConn: WizardConnection? = nil
    @AppStorage("nodeDistURL") private var nodeDistURL = NodeDistOption.defaultForInitialization.rawValue

    // Step 2: 注入角色
    @State private var roleSoul = ""
    @State private var roleIdentity = ""
    @State private var roleUser = ""
    @State private var isSavingRole = false

    // Step 3: 模型配置
    @State private var selectedWizardProvider: WizardProvider = .kimiCoding
    @State private var providerSearchText = ""
    @State private var wizardApiKey = ""
    @State private var isShowingApiKey = false
    @State private var minimaxApiKey = ""  // 保留用于持久化反序列化兼容
    @State private var selectedMinimaxModel: MinimaxModel = .m27
    @State private var selectedQiniuModel: QiniuModel = .deepseekV32
    @State private var selectedZAIModel: ZAIModel = .glm5
    @State private var isApplyingModel = false
    @State private var modelConfigError = ""
    @State private var activeModelConfigTerminalToken: String? = nil
    @State private var isModelConfigTerminalOpen = false
    @State private var pendingModelConfigTerminalClose: ModelConfigTerminalCloseState? = nil

    // Step 4: 频道配置
    @State private var selectedChannel: WizardChannelType = .feishu
    @State private var hoveredChannelBinding: WizardChannelType? = nil
    @State private var autoChannelFinishInFlight = false

    // Step 5: 完成
    @State private var isStartingOpenclaw = false
    @State private var finishProgressMessages: [String] = []
    @State private var xcodeEnvStatus: XcodeEnvStatus? = nil
    @State private var isInstallingXcodeCLT = false
    @State private var isAcceptingXcodeLicense = false
    @State private var isRepairingHomebrewPermission = false
    @State private var xcodeFixMessage: String? = nil

    private var selectedOpenclawVersionForInstall: String? {
        switch selectedOpenclawVersionPreset {
        case .latest:
            return nil
        case .custom:
            let value = customOpenclawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private var openclawVersionLabelForUI: String {
        selectedOpenclawVersionForInstall ?? "latest"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── 顶部标题栏 ───────────────────────────────────────
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.f("wizard.title", fallback: "初始化 · %@", user.username))
                        .font(.headline)
                    Text(L10n.k("wizard.subtitle.configuring", fallback: "正在配置生存空间"))
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
                            } else if currentStep == .injectRole {
                                injectRolePanel
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

            // ── 底部日志输出折叠条 ────────────────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showTerminal.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTerminal ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text(L10n.k("wizard.log_output", fallback: "日志输出"))
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
        .onReceive(NotificationCenter.default.publisher(for: .maintenanceTerminalWindowClosed)) { notification in
            guard let userInfo = notification.userInfo,
                  let token = userInfo["token"] as? String,
                  let context = userInfo["context"] as? String,
                  context == modelConfigMaintenanceContext,
                  token == activeModelConfigTerminalToken else { return }
            activeModelConfigTerminalToken = nil
            isModelConfigTerminalOpen = false
            Task { await handleModelConfigTerminalClosed(userInfo: userInfo) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .channelOnboardingAutoDetected)) { notification in
            guard let userInfo = notification.userInfo,
                  let username = userInfo["username"] as? String,
                  username == user.username else { return }
            Task { await handleAutoDetectedChannelPairing() }
        }
        .alert(item: $pendingModelConfigTerminalClose) { state in
            Alert(
                title: Text(modelConfigTerminalAlertTitle(for: state)),
                message: Text(modelConfigTerminalAlertMessage(for: state)),
                primaryButton: .default(Text(L10n.k("wizard.model_config.command.confirm_complete", fallback: "标记已完成并继续"))) {
                    Task { await markModelStepDone() }
                },
                secondaryButton: .cancel(Text(L10n.k("wizard.model_config.command.stay_on_step", fallback: "留在当前步骤")))
            )
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
                Text(L10n.k("wizard.base_env.title", fallback: "基础环境初始化"))
                    .font(.title3).fontWeight(.semibold)
                Text(L10n.k("wizard.base_env.subtitle", fallback: "安装 Node.js / npm 环境与 openclaw 核心组件。"))
                    .font(.callout).foregroundStyle(.secondary)
            }


            GroupBox(L10n.k("wizard.openclaw_version.group", fallback: "OpenClaw 版本")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.k("wizard.openclaw_version.picker", fallback: "OpenClaw 版本"), selection: $selectedOpenclawVersionPreset) {
                        Text(L10n.k("wizard.openclaw_version.latest", fallback: "最新版本")).tag(OpenclawVersionPreset.latest)
                        Text(L10n.k("wizard.openclaw_version.custom", fallback: "指定版本")).tag(OpenclawVersionPreset.custom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if selectedOpenclawVersionPreset == .custom {
                        TextField(L10n.k("wizard.openclaw_version.custom_placeholder", fallback: "例如：2026.3.12"), text: $customOpenclawVersion)
                            .textFieldStyle(.roundedBorder)
                    }

                }
            }

            if isHydratingState {
                Label(L10n.k("wizard.resume_state.loading", fallback: "正在恢复初始化状态…"), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button(hasPartialProgress
                   ? L10n.k("wizard.action.resume_from_progress", fallback: "从当前进度继续")
                   : L10n.k("wizard.action.start", fallback: "开始初始化")) {
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
                Text(L10n.k("wizard.base_env.running.title", fallback: "基础环境初始化"))
                    .font(.title3).fontWeight(.semibold)
                Text(L10n.k("wizard.base_env.running.subtitle", fallback: "正在安装依赖，请稍候。此阶段无需重复点击继续。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(isCancelling
                       ? L10n.k("wizard.action.terminating", fallback: "正在终止…")
                       : L10n.k("wizard.action.terminate", fallback: "终止初始化")) {
                    isCancelling = true
                    Task {
                        await markRunningStepsAsCancelledAndPersist()
                        requestCancelInit()
                        isCancelling = false
                    }
                }
                .buttonStyle(.bordered).foregroundStyle(.red)
                .disabled(isCancelling)
            }
        }
    }

    private var injectRolePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("wizard.inject_role.title", fallback: "注入角色"))
                    .font(.title3).fontWeight(.semibold)
                Text(L10n.k("wizard.inject_role.subtitle", fallback: "定义角色的核心价值观、身份设定和画像。留空则保留默认设定。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                DNAFileEditor(
                    icon: "heart.text.square.fill",
                    iconColor: .pink,
                    title: "核心价值观",
                    subtitle: "SOUL",
                    text: $roleSoul
                )
                DNAFileEditor(
                    icon: "person.text.rectangle.fill",
                    iconColor: .purple,
                    title: "身份设定",
                    subtitle: "IDENTITY",
                    text: $roleIdentity
                )
                DNAFileEditor(
                    icon: "person.crop.circle.fill",
                    iconColor: .orange,
                    title: "我的画像",
                    subtitle: "USER",
                    text: $roleUser
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button(isSavingRole ? "保存中…" : "保存并继续") {
                    Task { await saveRoleAndContinue() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingRole)
            }
        }
        .task {
            if roleSoul.isEmpty && roleIdentity.isEmpty && roleUser.isEmpty {
                await loadRoleFilesIfExist()
            }
        }
    }

    private func loadRoleFilesIfExist() async {
        let workspaceDir = ".openclaw/workspace"
        if let data = try? await helperClient.readFile(username: user.username, relativePath: "\(workspaceDir)/SOUL.md"),
           let text = String(data: data, encoding: .utf8) {
            roleSoul = text
        }
        if let data = try? await helperClient.readFile(username: user.username, relativePath: "\(workspaceDir)/IDENTITY.md"),
           let text = String(data: data, encoding: .utf8) {
            roleIdentity = text
        }
        if let data = try? await helperClient.readFile(username: user.username, relativePath: "\(workspaceDir)/USER.md"),
           let text = String(data: data, encoding: .utf8) {
            roleUser = text
        }
    }

    private var modelConfigPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.k("views.user_init_wizard_view.select_ai_provider", fallback: "选择 AI Provider"))
                .font(.title3).fontWeight(.semibold)

            VStack(spacing: 10) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(L10n.k("wizard.provider.search", fallback: "搜索 Provider..."), text: $providerSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !providerSearchText.isEmpty {
                        Button { providerSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .wizardInputSurface()

                // 供选择的列表，限制高度默认展示3个，支持内滚
                ScrollView {
                    VStack(spacing: 6) {
                        let filteredProviders = WizardProvider.allCases.filter {
                            providerSearchText.isEmpty ||
                            $0.displayName.localizedCaseInsensitiveContains(providerSearchText) ||
                            $0.subtitle.localizedCaseInsensitiveContains(providerSearchText)
                        }
                        if filteredProviders.isEmpty {
                            Text(L10n.k("wizard.provider.no_results", fallback: "未找到匹配项"))
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(filteredProviders) { provider in
                                providerSelectRow(provider)
                            }
                        }
                    }
                    .padding(.trailing, 4) // 给滚动条留出空间
                }
                .frame(height: 160) // 约等于 3 个选项的高度 (每行约46 + 间距)
            }

            Divider()

            providerDetailForm

            if !modelConfigError.isEmpty {
                Label(modelConfigError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(isApplyingModel ? L10n.k("views.user_init_wizard_view.save", fallback: "保存中…") : L10n.k("views.user_init_wizard_view.savecontinue", fallback: "保存并继续")) {
                    Task { await applyModelConfig() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingModel || wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            GroupBox(L10n.k("wizard.model_config.command.group", fallback: "高阶方式")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        isModelConfigTerminalOpen
                        ? L10n.k("wizard.model_config.command.open_hint", fallback: "命令行配置窗口已打开。完成或取消后关闭窗口，这里会提示是否进入下一步。")
                        : L10n.k("wizard.model_config.command.desc", fallback: "也可以直接打开命令行执行 `openclaw configure --section model`。关闭窗口后，向导会确认这一步是否完成。")
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(
                            isModelConfigTerminalOpen
                            ? L10n.k("wizard.model_config.command.reopen", fallback: "命令行窗口已打开")
                            : L10n.k("wizard.model_config.command.open", fallback: "通过命令行配置")
                        ) {
                            openModelConfigTerminal()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isModelConfigTerminalOpen)

                        Button(L10n.k("wizard.model_config.skip", fallback: "跳过此步骤")) {
                            Task { await skipModelStep() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    if let promotionTitle = provider.promotionTitle,
                       let promotionURL = provider.promotionURL {
                        Button {
                            if let url = URL(string: promotionURL) { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "gift").font(.caption)
                                Text(promotionTitle).font(.caption)
                            }
                        }
                        .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                    }
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
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                    Button {
                        isShowingApiKey.toggle()
                    } label: {
                        Image(systemName: isShowingApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isShowingApiKey ? L10n.k("views.user_init_wizard_view.hide", fallback: "隐藏") : L10n.k("views.user_init_wizard_view.show", fallback: "显示"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .wizardInputSurface()
            }

            if provider == .minimax {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型")).font(.subheadline).fontWeight(.medium)
                    HStack(spacing: 12) {
                        Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedMinimaxModel) {
                            ForEach(MinimaxModel.allCases, id: \.self) { model in
                                Text(model.providerName).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 160)

                        Text(selectedMinimaxModel.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if provider == .qiniu {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型")).font(.subheadline).fontWeight(.medium)
                    HStack(spacing: 12) {
                        Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedQiniuModel) {
                            ForEach(QiniuModel.allCases, id: \.self) { model in
                                Text(model.alias).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 160)

                        Text(selectedQiniuModel.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if provider == .zai {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型")).font(.subheadline).fontWeight(.medium)
                    HStack(spacing: 12) {
                        Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedZAIModel) {
                            ForEach(ZAIModel.allCases, id: \.self) { model in
                                Text(model.alias).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 160)

                        Text(selectedZAIModel.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var currentWizardModelName: String {
        switch selectedWizardProvider {
        case .kimiCoding:
            return "kimi-coding/k2p5"
        case .minimax:
            return selectedMinimaxModel.rawValue
        case .qiniu:
            return selectedQiniuModel.rawValue
        case .zai:
            return selectedZAIModel.rawValue
        }
    }

    private var channelConfigPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("views.user_init_wizard_view.channel", fallback: "绑定频道"))
                    .font(.title3).fontWeight(.semibold)
                Text(L10n.k("views.user_init_wizard_view.select_done", fallback: "选择要接入的沟通渠道，完成配对后虾即可收发消息。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            channelBindingList

            HStack(spacing: 12) {
                Button(L10n.k("views.user_init_wizard_view.back", fallback: "上一步")) { Task { await moveBackToModelStep() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary)
                Button(L10n.k("views.user_init_wizard_view.done_continue", fallback: "已完成，继续")) { Task { await markChannelStepDone() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var channelBindingList: some View {
        VStack(spacing: 8) {
            channelBindingRow(
                channel: .feishu,
                title: L10n.k("views.user_init_wizard_view.feishu", fallback: "飞书扫码绑定"),
                subtitle: L10n.k("views.user_init_wizard_view.done", fallback: "在独立窗口生成二维码，扫码完成配对。")
            ) {
                selectedChannel = .feishu
                openWindow(
                    id: "channel-onboarding",
                    value: "\(ChannelOnboardingFlow.feishu.rawValue):\(user.username)"
                )
            }
            channelBindingRow(
                channel: .weixin,
                title: L10n.k("views.user_init_wizard_view.wechat", fallback: "微信扫码绑定"),
                subtitle: L10n.k("views.user_init_wizard_view.donewechat", fallback: "在独立窗口生成二维码，扫码完成微信配对。")
            ) {
                selectedChannel = .weixin
                openWindow(
                    id: "channel-onboarding",
                    value: "\(ChannelOnboardingFlow.weixin.rawValue):\(user.username)"
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func channelBindingRow(
        channel: WizardChannelType,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredChannelBinding == channel
        return Button(action: action) {
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
                    Text(L10n.k("views.user_init_wizard_view.open", fallback: "点击打开"))
                        .font(.caption)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovered
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
                hoveredChannelBinding = hovering ? channel : nil
            }
        }
    }

    private var finishPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(L10n.k("views.user_init_wizard_view.initialization_completed", fallback: "初始化完成")).font(.title3).fontWeight(.semibold)
                }
                Text(L10n.k("views.user_init_wizard_view.models_channelconfigurationdone", fallback: "基础环境、模型、频道配置步骤已完成。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(L10n.k("views.user_init_wizard_view.back", fallback: "上一步")) { Task { await moveBackToChannelStep() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary).disabled(isStartingOpenclaw)

                Button(isStartingOpenclaw ? L10n.k("views.user_detail_view.start", fallback: "启动中…") : L10n.k("views.user_init_wizard_view.start_openclaw", fallback: "立即启动 OpenClaw")) {
                    Task { await finishAndStartOpenclaw() }
                }
                .buttonStyle(.borderedProminent).disabled(isStartingOpenclaw)

                Button(L10n.k("views.user_init_wizard_view.start", fallback: "稍后启动")) { Task { await completeWizardOnly() } }
                    .buttonStyle(.bordered).foregroundStyle(.secondary).disabled(isStartingOpenclaw)
            }

            finishProgressPanel
        }
    }

    @ViewBuilder
    private var finishProgressPanel: some View {
        if !finishProgressMessages.isEmpty {
            GroupBox(L10n.k("views.user_init_wizard_view.current_progress", fallback: "当前进度")) {
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
                    Text(L10n.k("views.user_init_wizard_view.step_failed", fallback: "步骤失败")).font(.title3).fontWeight(.semibold)
                }
                Text(L10n.k("views.user_init_wizard_view.check_log_output_details_then_retry_restart", fallback: "请查看日志输出了解详情，然后重试或重新开始。"))
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
                Button(L10n.k("views.user_init_wizard_view.retry_failed_step", fallback: "重试失败步骤")) { Task { await retryFromFailure() } }
                    .buttonStyle(.borderedProminent)
                Button(L10n.k("views.user_init_wizard_view.restart", fallback: "重新开始")) { resetWizard() }
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
                Text(L10n.k("views.user_init_wizard_view.development_environment_repair", fallback: "开发环境修复"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
                if isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission {
                    ProgressView().scaleEffect(0.6)
                }
                Button(L10n.k("views.user_init_wizard_view.refreshstatus", fallback: "刷新状态")) { Task { await refreshXcodeEnvStatus() } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            if let status {
                Label(status.commandLineToolsInstalled ? L10n.k("views.user_init_wizard_view.clt", fallback: "CLT 已安装") : L10n.k("views.user_init_wizard_view.clt_not_installed", fallback: "CLT 未安装"),
                      systemImage: status.commandLineToolsInstalled ? "checkmark" : "xmark")
                    .font(.caption)
                    .foregroundStyle(status.commandLineToolsInstalled ? Color.secondary : Color.orange)
                Label(status.licenseAccepted ? L10n.k("views.user_init_wizard_view.xcode_license", fallback: "Xcode license 已接受") : L10n.k("views.user_init_wizard_view.xcode_license_not_accepted", fallback: "Xcode license 未接受"),
                      systemImage: status.licenseAccepted ? "checkmark" : "xmark")
                    .font(.caption)
                    .foregroundStyle(status.licenseAccepted ? Color.secondary : Color.orange)
            } else {
                Text(L10n.k("views.user_init_wizard_view.status", fallback: "环境状态读取中…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(isInstallingXcodeCLT ? L10n.k("views.user_init_wizard_view.installing_tools", fallback: "安装中…") : L10n.k("views.user_init_wizard_view.install_developer_tools", fallback: "安装开发工具")) {
                    Task { await installXcodeCommandLineToolsFromWizard() }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                Button(isAcceptingXcodeLicense ? L10n.k("views.user_init_wizard_view.processing", fallback: "处理中…") : L10n.k("views.user_init_wizard_view.xcode", fallback: "同意 Xcode 许可")) {
                    Task { await acceptXcodeLicenseFromWizard() }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                Button(isRepairingHomebrewPermission ? L10n.k("views.user_init_wizard_view.processing", fallback: "处理中…") : L10n.k("wizard.base_env.repair_homebrew_permission", fallback: "修复 Homebrew 权限")) {
                    Task { await repairHomebrewPermissionFromWizard() }
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)

                Button(L10n.k("views.user_init_wizard_view.open_software_update", fallback: "打开软件更新")) {
                    openSoftwareUpdate()
                }
                .buttonStyle(.bordered)
                .disabled(isInstallingXcodeCLT || isAcceptingXcodeLicense || isRepairingHomebrewPermission)
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
                    Text(L10n.k("views.user_init_wizard_view.initialization_paused", fallback: "初始化已暂停")).font(.title3).fontWeight(.semibold)
                }
                Text(L10n.k("views.user_init_wizard_view.resume_detected_pending_steps", fallback: "检测到步骤未运行但未完成，可继续执行剩余步骤。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(L10n.k("views.user_init_wizard_view.continue", fallback: "继续剩余步骤")) { Task { await resumePendingStep() } }
                    .buttonStyle(.borderedProminent)
                Button(L10n.k("views.user_init_wizard_view.re_initialize", fallback: "重新初始化")) {
                    isCancelling = true
                    Task {
                        requestCancelInit()
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
                    Text(L10n.k("views.user_init_wizard_view.advanced_options", fallback: "高级选项"))
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
                        Text(L10n.k("views.user_init_wizard_view.npm", fallback: "npm 安装源")).font(.subheadline).fontWeight(.medium)
                        Picker(L10n.k("views.user_init_wizard_view.npm", fallback: "npm 安装源"), selection: $selectedNpmRegistry) {
                            ForEach(NpmRegistryOption.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.k("views.user_init_wizard_view.maintenance_tools", fallback: "维护工具")).font(.subheadline).fontWeight(.medium)
                        Button(L10n.k("views.user_list_view.cli_maintenance_advanced", fallback: "命令行维护（高级）")) { openMaintenanceTerminal() }
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
        selectedOpenclawVersionPreset = .latest
        customOpenclawVersion = ""
        showTerminal = false
        wizardApiKey = ""
        isShowingApiKey = false
        minimaxApiKey = ""
        selectedWizardProvider = .kimiCoding
        selectedMinimaxModel = .m27
        selectedQiniuModel = .deepseekV32
        selectedZAIModel = .glm5
        roleSoul = ""
        roleIdentity = ""
        roleUser = ""
        modelConfigError = ""
        activeModelConfigTerminalToken = nil
        isModelConfigTerminalOpen = false
        pendingModelConfigTerminalClose = nil
        selectedChannel = .feishu
        isStartingOpenclaw = false
        finishProgressMessages = []
        user.initStep = nil
    }

    private func resetWizard() {
        resetWizardStateOnly()
        wizardConn = nil
        onSessionActiveChanged?(false)
        Task {
            do {
                try await helperClient.saveInitState(username: user.username, json: "{}")
            } catch {
                appendLog(L10n.k("views.user_init_wizard_view.state_resetstatus_error_localizeddescription", fallback: "[state] 重置初始化状态失败：\(error.localizedDescription)\n"))
            }
        }
    }

    private func runInitSteps() async {
        guard !isRunningInitFlow else { return }
        guard (statuses[InitStep.basicEnvironment.rawValue] ?? .pending) != .done else { return }

        isRunningInitFlow = true
        defer { isRunningInitFlow = false }

        // 在进入长流程前先做 Xcode 预检，避免失败/运行面板来回闪动。
        appendLog(L10n.k("views.user_init_wizard_view.checking_xcode_environment_log", fallback: "\n▶ 检查 Xcode 开发环境\n"))
        do {
            try await ensureXcodeEnvironmentReady()
            appendLog(L10n.k("views.user_init_wizard_view.xcode_environment_ready_log", fallback: "✓ Xcode 开发环境已就绪\n"))
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

        appendLog("\n▶ \(String(localized: "wizard.homebrew.repair.start", defaultValue: "修复 Homebrew 权限（可选）"))\n")
        do {
            try await conn.repairHomebrewPermission(username: user.username)
            appendLog("✓ \(String(localized: "wizard.homebrew.repair.done", defaultValue: "Homebrew 权限修复已完成"))\n")
        } catch {
            // best-effort：失败不阻断初始化
            appendLog("⚠️ \(String(localized: "wizard.homebrew.repair.failed", defaultValue: "Homebrew 权限修复失败（已跳过，不影响初始化）"))：\(error.localizedDescription)\n")
        }

        let autoSteps: [(title: String, run: () async throws -> Void)] = [
            (L10n.k("views.user_init_wizard_view.node_js", fallback: "安装 Node.js"), { try await conn.installNode(username: user.username, nodeDistURL: nodeDistURL) }),
            (L10n.k("views.user_init_wizard_view.configuration_npm_directory", fallback: "配置 npm 目录"), { try await conn.setupNpmEnv(username: user.username) }),
            (L10n.k("views.user_init_wizard_view.settings_npm", fallback: "设置 npm 安装源"), {
                try await conn.setNpmRegistry(username: user.username, registry: selectedNpmRegistry.rawValue)
            }),
            (L10n.k("views.user_init_wizard_view.openclaw_openclawversionlabelforui", fallback: "安装 openclaw (\(openclawVersionLabelForUI))"), {
                try await conn.installOpenclaw(
                    username: user.username,
                    version: selectedOpenclawVersionForInstall
                )
            }),
        ].compactMap { $0 }

        for item in autoSteps {
            appendLog("\n▶ \(item.title)\n")
            do {
                try await item.run()
            } catch {
                let message = error.localizedDescription
                if message.contains(L10n.k("views.user_init_wizard_view.run", fallback: "已有初始化命令正在运行")) {
                    let reason = L10n.k("views.user_init_wizard_view.syncstatus", fallback: "检测到已有初始化任务在运行，正在同步当前状态。")
                    appendLog("[info] \(reason)\n")
                    statuses[InitStep.basicEnvironment.rawValue] = .running
                    user.initStep = InitStep.basicEnvironment.title
                    currentStep = .basicEnvironment
                    await persistState(activeOverride: true)
                    onSessionActiveChanged?(true)
                    await reconcileStateFromPersistence()
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
        currentStep = .injectRole
        statuses[InitStep.injectRole.rawValue] = .running
        user.initStep = InitStep.injectRole.title
        await persistState()
    }

    private func saveRoleAndContinue() async {
        isSavingRole = true
        defer { isSavingRole = false }

        do {
            let workspaceDir = ".openclaw/workspace"
            try await helperClient.createDirectory(username: user.username, relativePath: workspaceDir)
            if !roleSoul.isEmpty {
                try await helperClient.writeFile(username: user.username, relativePath: "\(workspaceDir)/SOUL.md", data: roleSoul.data(using: .utf8) ?? Data())
            }
            if !roleIdentity.isEmpty {
                try await helperClient.writeFile(username: user.username, relativePath: "\(workspaceDir)/IDENTITY.md", data: roleIdentity.data(using: .utf8) ?? Data())
            }
            if !roleUser.isEmpty {
                try await helperClient.writeFile(username: user.username, relativePath: "\(workspaceDir)/USER.md", data: roleUser.data(using: .utf8) ?? Data())
            }

            // Try init git repo silently, won't block if fails
            try? await helperClient.initPersonaGitRepo(username: user.username)
            if !roleSoul.isEmpty { try? await helperClient.commitPersonaFile(username: user.username, filename: "SOUL.md", message: "Initial commit") }
            if !roleIdentity.isEmpty { try? await helperClient.commitPersonaFile(username: user.username, filename: "IDENTITY.md", message: "Initial commit") }
            if !roleUser.isEmpty { try? await helperClient.commitPersonaFile(username: user.username, filename: "USER.md", message: "Initial commit") }

            statuses[InitStep.injectRole.rawValue] = .done
            currentStep = .configureModel
            statuses[InitStep.configureModel.rawValue] = .running
            user.initStep = InitStep.configureModel.title
            await persistState()
        } catch {
            appendLog("❌ [injectRole] 写入角色文件失败：\(error.localizedDescription)\n")
        }
    }

    private func ensureXcodeEnvironmentReady() async throws {
        guard let status = await helperClient.getXcodeEnvStatus() else {
            xcodeEnvStatus = nil
            throw HelperError.operationFailed(L10n.k("views.user_init_wizard_view.xcode_status_retry", fallback: "无法读取 Xcode 开发环境状态，请稍后重试。"))
        }
        xcodeEnvStatus = status
        xcodeFixMessage = nil
        if !status.commandLineToolsInstalled {
            throw HelperError.operationFailed(L10n.k("views.user_init_wizard_view.xcode_command_line_tools_done", fallback: "检测到缺少 Xcode Command Line Tools。请先在「开发环境修复」中点击“安装开发工具”，完成后再重试初始化。"))
        }
        if !status.licenseAccepted {
            throw HelperError.operationFailed(L10n.k("views.user_init_wizard_view.xcode_license_not_accepted_open_development_environment_repair", fallback: "检测到 Xcode license 未接受。请先在「开发环境修复」中点击“同意 Xcode 许可”，完成后再重试初始化。"))
        }
        if !status.clangAvailable {
            let details = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                throw HelperError.operationFailed(L10n.k("views.user_init_wizard_view.xcode_toolsready_doneretry", fallback: "检测到 Xcode 工具链未就绪。请先在「开发环境修复」中完成修复后再重试初始化。"))
            }
            throw HelperError.operationFailed(L10n.k("views.user_init_wizard_view.xcode_details", fallback: "检测到 Xcode 工具链未就绪：\(details)"))
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
            xcodeFixMessage = L10n.k("views.user_init_wizard_view.hintdone", fallback: "已触发系统安装窗口，请按提示完成安装。")
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
            xcodeFixMessage = L10n.k("views.user_init_wizard_view.license_refreshstatus", fallback: "已执行 license 接受，正在刷新状态。")
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        await refreshXcodeEnvStatus()
        isAcceptingXcodeLicense = false
    }

    private func repairHomebrewPermissionFromWizard() async {
        isRepairingHomebrewPermission = true
        xcodeFixMessage = nil
        do {
            try await helperClient.repairHomebrewPermission(username: user.username)
            xcodeFixMessage = L10n.k("wizard.base_env.repair_homebrew_permission_done", fallback: "Homebrew 权限修复完成：已安装/更新 ~/.brew，并写入 ~/.zprofile 环境变量。")
        } catch {
            xcodeFixMessage = error.localizedDescription
        }
        await refreshXcodeEnvStatus()
        isRepairingHomebrewPermission = false
    }

    private func openSoftwareUpdate() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.softwareupdate") else {
            return
        }
        NSWorkspace.shared.open(url)
        xcodeFixMessage = L10n.k("views.user_init_wizard_view.open_settings_command_line_tools", fallback: "已打开“软件更新”。若弹窗未出现，可在系统设置中手动安装 Command Line Tools。")
    }

    private func resumePendingStep() async {
        if (statuses[InitStep.basicEnvironment.rawValue] ?? .pending) != .done {
            await runInitSteps()
            return
        }
        if (statuses[InitStep.injectRole.rawValue] ?? .pending) != .done {
            currentStep = .injectRole
            statuses[InitStep.injectRole.rawValue] = .running
            user.initStep = InitStep.injectRole.title
            await persistState()
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
        if case .failed = statuses[InitStep.injectRole.rawValue] {
            statuses[InitStep.injectRole.rawValue] = .running
            currentStep = .injectRole
            user.initStep = InitStep.injectRole.title
            await persistState()
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
            case .qiniu:
                try await applyQiniuConfig(apiKey: key)
            case .zai:
                try await applyZAIConfig(apiKey: key)
            }

            await markModelStepDone()
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

    private func applyQiniuConfig(apiKey: String) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let providerModels = QiniuModel.allCases.map(\.providerModelConfig)
        var modelAliasMap = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:]
        for model in QiniuModel.allCases {
            var aliasConfig = (modelAliasMap[model.rawValue] as? [String: Any]) ?? [:]
            aliasConfig["alias"] = model.alias
            modelAliasMap[model.rawValue] = aliasConfig
        }
        let existingModel = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:]
        var normalizedModelConfig: [String: Any] = ["primary": selectedQiniuModel.rawValue]
        if let arr = existingModel["fallback"] as? [String], !arr.isEmpty {
            normalizedModelConfig["fallback"] = arr
        } else if let single = existingModel["fallback"] as? String, !single.isEmpty {
            normalizedModelConfig["fallback"] = [single]
        }

        try await helperClient.setConfigDirect(username: user.username, path: "env.QINIU_API_KEY", value: apiKey)
        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.qiniu",
            value: [
                "baseUrl": "https://api.qnaigc.com/v1",
                "apiKey": "${QINIU_API_KEY}",
                "api": "openai-completions",
                "models": providerModels,
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.qiniu:default",
            value: ["provider": "qiniu", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.model", value: normalizedModelConfig)
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.models", value: modelAliasMap)
        try await syncQiniuAgentFiles(apiKey: apiKey, providerModels: providerModels)
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

    private func syncQiniuAgentFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["qiniu:default"] = [
            "type": "api_key",
            "provider": "qiniu",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["qiniu"] = [
            "baseUrl": "https://api.qnaigc.com/v1",
            "api": "openai-completions",
            "models": providerModels,
        ]
        modelsRoot["providers"] = providers
        try await writeUserJSON(modelsRoot, relativePath: "\(agentDir)/models.json")
    }

    private func applyZAIConfig(apiKey: String) async throws {
        let config = await helperClient.getConfigJSON(username: user.username)
        let providerModels = ZAIModel.allCases.map(\.providerModelConfig)
        var modelAliasMap = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:]
        for model in ZAIModel.allCases {
            var aliasConfig = (modelAliasMap[model.rawValue] as? [String: Any]) ?? [:]
            aliasConfig["alias"] = model.alias
            modelAliasMap[model.rawValue] = aliasConfig
        }
        let existingModel = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:]
        var normalizedModelConfig: [String: Any] = ["primary": selectedZAIModel.rawValue]
        if let arr = existingModel["fallback"] as? [String], !arr.isEmpty {
            normalizedModelConfig["fallback"] = arr
        } else if let single = existingModel["fallback"] as? String, !single.isEmpty {
            normalizedModelConfig["fallback"] = [single]
        }

        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "models.providers.zai",
            value: [
                "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
                "apiKey": apiKey,
                "api": "openai-completions",
                "models": providerModels,
            ]
        )
        try await helperClient.setConfigDirect(
            username: user.username,
            path: "auth.profiles.zai:default",
            value: ["provider": "zai", "mode": "api_key"]
        )
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.model", value: normalizedModelConfig)
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.models", value: modelAliasMap)
        try await syncZAIAgentFiles(apiKey: apiKey, providerModels: providerModels)
    }

    private func syncZAIAgentFiles(apiKey: String, providerModels: [[String: Any]]) async throws {
        let agentDir = ".openclaw/agents/main/agent"
        try await helperClient.createDirectory(username: user.username, relativePath: agentDir)

        var authProfilesRoot = await readUserJSON(relativePath: "\(agentDir)/auth-profiles.json")
        var profiles = (authProfilesRoot["profiles"] as? [String: Any]) ?? [:]
        profiles["zai:default"] = [
            "type": "api_key",
            "provider": "zai",
            "key": apiKey,
        ]
        authProfilesRoot["version"] = (authProfilesRoot["version"] as? Int) ?? 1
        authProfilesRoot["profiles"] = profiles
        try await writeUserJSON(authProfilesRoot, relativePath: "\(agentDir)/auth-profiles.json")

        var modelsRoot = await readUserJSON(relativePath: "\(agentDir)/models.json")
        var providers = (modelsRoot["providers"] as? [String: Any]) ?? [:]
        providers["zai"] = [
            "baseUrl": "https://open.bigmodel.cn/api/paas/v4",
            "api": "openai-completions",
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

    private func markModelStepDone() async {
        statuses[InitStep.configureModel.rawValue] = .done
        currentStep = .configureChannel
        statuses[InitStep.configureChannel.rawValue] = .running
        user.initStep = InitStep.configureChannel.title
        modelConfigError = ""
        await persistState()
    }

    private func skipModelStep() async {
        statuses[InitStep.configureModel.rawValue] = .pending
        currentStep = .configureChannel
        statuses[InitStep.configureChannel.rawValue] = .running
        user.initStep = InitStep.configureChannel.title
        modelConfigError = ""
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
        appendFinishProgress(L10n.k("views.user_init_wizard_view.done_overview", fallback: "初始化已完成，正在进入概览页…"))

        // 先退出向导回到概览页，再在后台继续启动流程，避免用户停留在初始化界面。
        gatewayHub.markPendingStart(username: user.username)
        await completeWizardOnly()
        appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_switched_overview_continuing", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 已切换到概览页，继续后台启动 Gateway。\n"))

        appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_starting_gateway", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 正在启动 Gateway…\n"))

        do {
            try await helperClient.startGateway(username: user.username)
            user.isRunning = true
            user.pid = nil
            user.startedAt = nil
            appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_gateway_started_successfully", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 启动成功。\n"))
            await syncGatewayStateAfterStart()
        } catch {
            // 启动失败不阻断完成状态，用户可在列表页再次启动
            user.isRunning = false
            user.pid = nil
            user.startedAt = nil
            gatewayHub.markPendingStopped(username: user.username)
            appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_gateway_start_failed", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 启动失败：\(error.localizedDescription)\n"))
        }
    }

    private func handleAutoDetectedChannelPairing() async {
        guard initiated,
              currentStep == .configureChannel,
              !autoChannelFinishInFlight,
              !isStartingOpenclaw else { return }
        autoChannelFinishInFlight = true
        defer { autoChannelFinishInFlight = false }
        await markChannelStepDone()
        await finishAndStartOpenclaw()
    }

    private func syncGatewayStateAfterStart(
        maxAttempts: Int = 12,
        retryDelayNanoseconds: UInt64 = 500_000_000
    ) async {
        for attempt in 1...maxAttempts {
            if let (running, pid) = try? await helperClient.getGatewayStatus(username: user.username),
               running {
                user.isRunning = true
                user.pid = pid > 0 ? pid : nil
                user.startedAt = pid > 0 ? GatewayHub.processStartTime(pid: pid) : nil
                appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_gateway_running_confirmed", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 运行状态已确认。\n"))
                _ = await helperClient.getGatewayURL(username: user.username)
                return
            }

            if attempt < maxAttempts {
                appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_waiting_gateway_running_state", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 等待 Gateway 进入运行态（\(attempt)/\(maxAttempts)）…\n"))
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_gateway_status_sync_timeout", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 状态同步超时，概览页会在后续轮询中继续刷新。\n"))
    }

    private func waitForGatewayURLWithToken(
        maxAttempts: Int = 20,
        retryDelayNanoseconds: UInt64 = 500_000_000,
        emitProgress: Bool = true
    ) async -> String? {
        if emitProgress {
            appendFinishProgress(L10n.k("views.user_init_wizard_view.web_ui_token", fallback: "正在获取 Web UI Token…"))
        } else {
            appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_fetching_web_ui", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 正在获取 Web UI Token…\n"))
        }
        for attempt in 1...maxAttempts {
            let urlString = await helperClient.getGatewayURL(username: user.username)
            if gatewayToken(from: urlString) != nil {
                if emitProgress {
                    appendFinishProgress(L10n.k("views.user_init_wizard_view.token", fallback: "Token 获取成功。"))
                } else {
                    appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_token_acquired_successfully", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 获取成功。\n"))
                }
                return urlString
            }
            if attempt < maxAttempts {
                if emitProgress {
                    appendFinishProgress(L10n.k("views.user_init_wizard_view.token_attempt_maxattempts_continuewaiting", fallback: "Token 暂未就绪（\(attempt)/\(maxAttempts)），继续等待…"))
                } else {
                    appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_token_not_ready", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 暂未就绪（\(attempt)/\(maxAttempts)），继续等待…\n"))
                }
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        if emitProgress {
            appendFinishProgress(L10n.k("views.user_init_wizard_view.token_open_web_ui", fallback: "Token 获取超时，未自动打开 Web UI。"))
        } else {
            appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_token_request_timed", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Token 获取超时，未自动打开 Web UI。\n"))
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
        state.openclawVersion = openclawVersionLabelForUI
        state.modelName = currentWizardModelName
        state.channelType = selectedChannel.rawValue
        state.updatedAt = Date()
        let done = (statuses[InitStep.finish.rawValue] ?? .pending) == .done
        state.active = activeOverride ?? (!done && currentStep != nil)
        state.completedAt = done ? Date() : nil
        do {
            try await helperClient.saveInitState(username: user.username, json: state.toJSON())
        } catch {
            appendLog(L10n.k("views.user_init_wizard_view.state_savestatus_error_localizeddescription", fallback: "[state] 保存初始化状态失败：\(error.localizedDescription)\n"))
        }
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

        if isHydratingState {
            let v = saved.openclawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || v == "latest" {
                selectedOpenclawVersionPreset = .latest
                customOpenclawVersion = ""
            } else {
                selectedOpenclawVersionPreset = .custom
                customOpenclawVersion = v
            }
        }

        // 仅在首次水合阶段回填模型草稿，避免轮询状态覆盖用户在界面上的实时选择。
        if isHydratingState {
            if let model = MinimaxModel(rawValue: saved.modelName) {
                selectedWizardProvider = .minimax
                selectedMinimaxModel = model
            } else if let model = QiniuModel(rawValue: saved.modelName) {
                selectedWizardProvider = .qiniu
                selectedQiniuModel = model
            } else if let model = ZAIModel(rawValue: saved.modelName) {
                selectedWizardProvider = .zai
                selectedZAIModel = model
            } else if saved.modelName.hasPrefix("kimi-coding/") {
                selectedWizardProvider = .kimiCoding
            }
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

        let hasRecoverableProgress = InitStep.allCases.contains { step in
            switch restored[step.rawValue] ?? .pending {
            case .pending: return false
            default: return true
            }
        }

        // 迁移旧脏状态：active=true 但所有步骤 pending，会导致 UI 误判为“正在初始化”。
        if saved.active && !saved.isCompleted && !hasRecoverableProgress {
            var repaired = saved
            repaired.active = false
            repaired.currentStep = nil
            repaired.updatedAt = Date()
            do {
                try await helperClient.saveInitState(username: user.username, json: repaired.toJSON())
            } catch {
                appendLog(L10n.k("views.user_init_wizard_view.state_status_error_localizeddescription", fallback: "[state] 迁移旧初始化状态失败：\(error.localizedDescription)\n"))
            }
        }

        let isPrestartSession = !saved.isCompleted && !hasRecoverableProgress
        if isPrestartSession {
            currentStep = nil
        } else if let step = InitStep.from(key: saved.currentStep) {
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

        let effectiveActive = !saved.isCompleted && (saved.active || hasRecoverableProgress) && !isPrestartSession
        let hasAnyState = saved.isCompleted || effectiveActive || isPrestartSession
        let sessionVisible = !saved.isCompleted && (effectiveActive || isPrestartSession)
        initiated = effectiveActive
        onSessionActiveChanged?(sessionVisible)

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
            statuses[step.rawValue] = .failed(L10n.k("views.user_init_wizard_view.terminated", fallback: "已终止"))
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

    /// 非阻塞地请求 Helper 终止初始化流程，避免 UI 因回调延迟而卡住。
    private func requestCancelInit() {
        let username = user.username
        let conn = wizardConn
        Task {
            await conn?.cancelInit(username: username)
            await helperClient.cancelInit(username: username)
        }
    }

    // MARK: - 完成后操作

    private func openModelConfigTerminal() {
        let completionToken = UUID().uuidString
        activeModelConfigTerminalToken = completionToken
        isModelConfigTerminalOpen = true
        modelConfigError = ""
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("wizard.model_config.command.window_title", fallback: "模型配置命令行"),
            command: ["openclaw", "configure", "--section", "model"],
            completionToken: completionToken,
            completionContext: modelConfigMaintenanceContext
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    private func handleModelConfigTerminalClosed(userInfo: [AnyHashable: Any]) async {
        let exitCode = (userInfo["exitCode"] as? NSNumber)?.int32Value
        let status = await helperClient.getModelsStatus(username: user.username)
        let detectedModel = status?.resolvedDefault ?? status?.defaultModel
        pendingModelConfigTerminalClose = ModelConfigTerminalCloseState(
            exitCode: exitCode,
            detectedModel: detectedModel
        )
    }

    private func modelConfigTerminalAlertTitle(for state: ModelConfigTerminalCloseState) -> String {
        if state.detectedModel != nil {
            return L10n.k("wizard.model_config.command.alert.detected_title", fallback: "检测到模型配置")
        }
        if state.exitCode == 0 {
            return L10n.k("wizard.model_config.command.alert.success_title", fallback: "命令已执行完成")
        }
        return L10n.k("wizard.model_config.command.alert.incomplete_title", fallback: "模型步骤可能未完成")
    }

    private func modelConfigTerminalAlertMessage(for state: ModelConfigTerminalCloseState) -> String {
        if let detectedModel = state.detectedModel, !detectedModel.isEmpty {
            return L10n.f(
                "wizard.model_config.command.alert.detected_message",
                fallback: "已检测到当前默认模型：%@。如果命令行配置已经完成，可以直接进入下一步。",
                detectedModel
            )
        }
        if state.exitCode == 0 {
            return L10n.k("wizard.model_config.command.alert.success_message", fallback: "命令行窗口已正常退出，但当前还没检测到默认模型。若你已经在命令行里完成了需要的配置，可以继续下一步。")
        }
        if let exitCode = state.exitCode {
            return L10n.f(
                "wizard.model_config.command.alert.failed_message",
                fallback: "命令行窗口已关闭，进程退出码为 %@。这一步可能尚未完成。若确认配置已经完成，仍可继续下一步。",
                String(exitCode)
            )
        }
        return L10n.k("wizard.model_config.command.alert.closed_message", fallback: "命令行窗口已关闭，这一步可能尚未完成。若确认配置已经完成，仍可继续下一步。")
    }

    private func openMaintenanceTerminal() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("views.user_init_wizard_view.setup_wizard_maintenance_terminal", fallback: "初始化向导维护终端"),
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    // 保留统一入口：若未来需要在完成页直接打开 Web，可复用此流程。
    private func openWebUI() async {
        finishProgressMessages = []
        if !user.isRunning {
            appendFinishProgress(L10n.k("views.user_init_wizard_view.gateway_start", fallback: "Gateway 未运行，正在启动…"))
            do {
                gatewayHub.markPendingStart(username: user.username)
                try await helperClient.startGateway(username: user.username)
                user.isRunning = true
                appendFinishProgress(L10n.k("views.user_init_wizard_view.gateway_start_success", fallback: "Gateway 启动成功。"))
            } catch {
                appendFinishProgress(L10n.k("views.user_init_wizard_view.gateway_start_error_localizeddescription", fallback: "Gateway 启动失败：\(error.localizedDescription)"))
            }
        } else {
            appendFinishProgress(L10n.k("views.user_init_wizard_view.gateway", fallback: "Gateway 已运行。"))
        }

        let tokenReadyURL = await waitForGatewayURLWithToken()
        if let tokenReadyURL,
           let url = URL(string: tokenReadyURL),
           !tokenReadyURL.isEmpty {
            appendFinishProgress(L10n.k("views.user_init_wizard_view.open_web_ui", fallback: "正在打开 Web UI…"))
            NSWorkspace.shared.open(url)
            appendFinishProgress(L10n.k("views.user_init_wizard_view.web_ui_open", fallback: "Web UI 已打开。"))
        }
    }

    private static let finishProgressTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
