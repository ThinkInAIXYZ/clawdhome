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

private struct WizardPanelCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )
    }
}

private struct WizardWindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window)
        }
    }

    private func apply(window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
    }
}

private extension View {
    func wizardInputSurface() -> some View {
        modifier(WizardInputSurfaceModifier())
    }

    func wizardPanelCard() -> some View {
        modifier(WizardPanelCardModifier())
    }
}

struct GatewayActivationCard: View {
    let progress: Double
    let isAnimating: Bool
    let isShrimpLifted: Bool

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(isAnimating ? 0.22 : 0.12),
                                Color.accentColor.opacity(0.03),
                                .clear
                            ],
                            center: .center,
                            startRadius: 18,
                            endRadius: 96
                        )
                    )
                    .frame(width: 196, height: 196)
                    .blur(radius: 4)
                    .opacity(isAnimating ? 1 : 0.7)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                Color.accentColor.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    )
                    .shadow(color: Color.accentColor.opacity(0.14), radius: 28, x: 0, y: 14)
                    .frame(width: 160, height: 160)

                Text("🦞")
                    .font(.system(size: 68))
                    .offset(y: isShrimpLifted ? -5 : 5)
                    .scaleEffect(isShrimpLifted ? 1.03 : 0.98)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Text(L10n.k("views.user_init_wizard_view.initialization_completed", fallback: "配置完成"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Text(L10n.k("views.user_init_wizard_view.done_overview", fallback: "正在启动 OpenClaw Gateway…"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                    Text(L10n.k("views.user_init_wizard_view.gateway_activation_hint", fallback: "首次启动可能需要一点时间，请保持窗口开启。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct EnvironmentSetupWaitingCard: View {
    let title: String
    let subtitle: String
    let rotatingStatus: String
    let isSceneLifted: Bool
    let isToolRaised: Bool
    let isGlowActive: Bool

    var body: some View {
        let cardWidth: CGFloat = 420
        let cardHeight: CGFloat = 220

        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(isGlowActive ? 0.16 : 0.10),
                                Color.blue.opacity(0.05),
                                Color.white.opacity(0.94)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.75), lineWidth: 1)
                    )
                    .shadow(color: Color.accentColor.opacity(0.10), radius: 28, x: 0, y: 18)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(isGlowActive ? 0.22 : 0.14),
                                Color.accentColor.opacity(0.04),
                                .clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 110
                        )
                    )
                    .frame(width: 220, height: 220)
                    .blur(radius: 12)
                    .offset(y: -18)

                VStack(spacing: 12) {
                    HStack(spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                                .frame(width: 112, height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
                                )

                            VStack(spacing: 8) {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Color.accentColor.opacity(0.90))
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.14))
                                    .frame(width: 54, height: 8)
                            }
                        }

                        ZStack {
                            Text("🦞")
                                .font(.system(size: 48))
                                .offset(x: -2, y: isSceneLifted ? -6 : 6)
                                .scaleEffect(isSceneLifted ? 1.03 : 0.98)

                            Image(systemName: "hammer.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.orange.opacity(0.95))
                                .rotationEffect(.degrees(isToolRaised ? -28 : 14))
                                .offset(x: 30, y: isToolRaised ? -28 : -8)
                        }
                        .frame(width: 98, height: 98)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                        Text(rotatingStatus)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
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
        case .configureChannel: return L10n.k("wizard.step.configure_channel", fallback: "IM 频道配置")
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

private enum BaseEnvProgressPhase: Int, CaseIterable {
    case xcodeCheck = 1
    case homebrewRepair
    case installNode
    case setupNpmEnv
    case setNpmRegistry
    case installOpenclaw

    static var totalCount: Int { allCases.count }

    var title: String {
        switch self {
        case .xcodeCheck: return "检查 Xcode 开发环境"
        case .homebrewRepair: return "修复 Homebrew 权限"
        case .installNode: return "安装 Node.js"
        case .setupNpmEnv: return "配置 npm 目录"
        case .setNpmRegistry: return "设置 npm 安装源"
        case .installOpenclaw: return "安装 openclaw"
        }
    }

    var runningText: String {
        "(\(rawValue)/\(Self.totalCount)) \(title)…"
    }
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
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kimiCoding: return "Kimi Code"
        case .minimax:    return "MiniMax"
        case .qiniu:      return "Qiniu AI"
        case .zai:        return "智谱 Z.AI"
        case .custom:     return "Custom Provider"
        }
    }

    var subtitle: String {
        switch self {
        case .kimiCoding: return "Kimi for Coding"
        case .minimax:    return L10n.k("wizard.provider.minimax.subtitle", fallback: "MiniMax M2.5 系列")
        case .qiniu:      return "DeepSeek / GLM / Kimi / Minimax"
        case .zai:        return "GLM系列模型"
        case .custom:     return "OpenAI / Anthropic compatible"
        }
    }

    var icon: String {
        switch self {
        case .kimiCoding: return "k.circle"
        case .minimax:    return "m.circle"
        case .qiniu:      return "q.circle"
        case .zai:        return "sparkles"
        case .custom:     return "slider.horizontal.3"
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .kimiCoding: return "Kimi Code API Key"
        case .minimax:    return "MiniMax API Key"
        case .qiniu:      return "Qiniu API Key"
        case .zai:        return "智谱 API Key"
        case .custom:     return "Custom API Key"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax:    return L10n.k("wizard.provider.minimax.api_key.placeholder", fallback: "粘贴 MiniMax API Key")
        case .qiniu:      return "sk-..."
        case .zai:        return "sk-..."
        case .custom:     return "留空则使用 CUSTOM_API_KEY"
        }
    }

    var consoleURL: String {
        switch self {
        case .kimiCoding: return "https://www.kimi.com/code/console"
        case .minimax:    return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .qiniu:      return "https://portal.qiniu.com/ai-inference/api-key?ref=clawdhome.app"
        case .zai:        return "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"
        case .custom:     return "https://platform.openai.com/api-keys"
        }
    }

    var consoleLinkTitle: String {
        switch self {
        case .kimiCoding: return L10n.k("wizard.provider.kimi.console", fallback: "Kimi Code 控制台")
        case .minimax:    return L10n.k("wizard.provider.minimax.console", fallback: "MiniMax 控制台")
        case .qiniu:      return "七牛 API Key"
        case .zai:        return "获取 API Key"
        case .custom:     return "API Key 参考"
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

private enum WizardAuthMethod: String, CaseIterable, Identifiable {
    case apiKey
    case secretReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiKey: return "API Key"
        case .secretReference: return "Secret Reference"
        }
    }
}

private enum CustomCompatibility: String, CaseIterable, Identifiable {
    case openai
    case anthropic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        }
    }

    var apiType: String {
        switch self {
        case .openai: return "openai-completions"
        case .anthropic: return "anthropic-messages"
        }
    }
}

private enum ModelValidationState: Equatable {
    case idle
    case validating
    case success(String)
    case failure(String)
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
    @Environment(\.dismiss) private var dismiss
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
    @State private var selectedWizardAuthMethod: WizardAuthMethod = .apiKey
    @State private var wizardApiKey = ""
    @State private var customSecretReference = ""
    @State private var customProviderId = ""
    @State private var customModelId = ""
    @State private var customModelAlias = ""
    @State private var customBaseURL = ""
    @State private var customCompatibility: CustomCompatibility = .openai
    @State private var isShowingApiKey = false
    @State private var minimaxApiKey = ""  // 保留用于持久化反序列化兼容
    @State private var selectedMinimaxModel: MinimaxModel = .m27
    @State private var selectedQiniuModel: QiniuModel = .deepseekV32
    @State private var selectedZAIModel: ZAIModel = .glm5
    @State private var isApplyingModel = false
    @State private var modelConfigError = ""
    @State private var modelValidationState: ModelValidationState = .idle
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
    @State private var finishAutoStartTriggered = false
    @State private var activationProgress: Double = 0.08
    @State private var activationShrimpLifted = false
    @State private var waitingSceneLifted = false
    @State private var waitingToolRaised = false
    @State private var waitingGlowActive = false
    @State private var baseEnvProgressPhase: BaseEnvProgressPhase = .xcodeCheck

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

    private var wizardTitle: String {
        L10n.f(
            "wizard.title",
            fallback: "初始化 · %@",
            formatManagedUserDisplayName(fullName: user.fullName, username: user.username)
        )
    }

    private var customProviderIdTrimmed: String {
        customProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customModelIdTrimmed: String {
        customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customBaseURLTrimmed: String {
        customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveCustomProviderId: String {
        customProviderIdTrimmed.isEmpty ? "custom" : customProviderIdTrimmed
    }

    private var availableWizardAuthMethods: [WizardAuthMethod] {
        selectedWizardProvider == .custom ? [.apiKey, .secretReference] : [.apiKey]
    }

    private var wizardSectionTitleFont: Font {
        .system(size: 21, weight: .semibold)
    }

    @ViewBuilder
    private var activeContentPanel: some View {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftRail
                    .frame(width: 246)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        activeContentPanel
                            .wizardPanelCard()

                        if !initiated || currentStep == .basicEnvironment {
                            advancedOptionsPanel
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
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
        .background(WizardWindowTitleBinder(title: wizardTitle))
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
        .onChange(of: selectedWizardProvider) { _, _ in
            if selectedWizardProvider != .custom {
                selectedWizardAuthMethod = .apiKey
            } else if customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                customBaseURL = "https://api.example.com/v1"
            }
            resetModelValidationState(clearCredential: true)
        }
        .onChange(of: selectedWizardAuthMethod) { _, _ in
            resetModelValidationState(clearCredential: false)
        }
        .onChange(of: wizardApiKey) { _, _ in
            if case .idle = modelValidationState { return }
            modelValidationState = .idle
            modelConfigError = ""
        }
    }

    // MARK: - Left Rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(InitStep.allCases, id: \.rawValue) { step in
                    leftRailRow(step: step)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.7),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func leftRailRow(step: InitStep) -> some View {
        let status = statuses[step.rawValue] ?? .pending
        let isActive = currentStep == step || (!initiated && step == .basicEnvironment)

        HStack(spacing: 10) {
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
            .font(.subheadline)
            .frame(width: 18)

            Text(step.title)
                .font(.body)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .primary : (status == .done ? .secondary : .tertiary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
        )
    }

    // MARK: - Panels

    private var preStartPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("wizard.base_env.title", fallback: "基础环境初始化"))
                        .font(wizardSectionTitleFont)
                    Text(L10n.k("wizard.base_env.subtitle", fallback: "安装 Node.js / npm 环境与 openclaw 核心组件。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.96),
                                    Color.accentColor.opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.92), lineWidth: 1)
                        )
                        .frame(width: 56, height: 56)
                        .shadow(color: Color.accentColor.opacity(0.12), radius: 12, x: 0, y: 6)

                    Text("🦞")
                        .font(.system(size: 28))
                }
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
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            EnvironmentSetupWaitingCard(
                title: L10n.k("wizard.base_env.running.title", fallback: "基础环境初始化"),
                subtitle: L10n.k("wizard.base_env.running.subtitle", fallback: "正在准备生存空间并安装依赖，请稍候。此阶段通常需要 1 到 2 分钟，网络较慢时会更久。"),
                rotatingStatus: waitingStatusMessage,
                isSceneLifted: waitingSceneLifted,
                isToolRaised: waitingToolRaised,
                isGlowActive: waitingGlowActive
            )

            VStack(spacing: 10) {
                Button(isCancelling
                       ? L10n.k("wizard.action.terminating", fallback: "正在终止…")
                       : L10n.k("wizard.action.terminate", fallback: "终止初始化")) {
                    isCancelling = true
                    Task {
                        await markRunningStepsAsCancelledAndPersist()
                        await requestCancelInit()
                        isCancelling = false
                    }
                }
                .buttonStyle(.bordered).foregroundStyle(.red)
                .disabled(isCancelling)

                Text(L10n.k("wizard.base_env.running.keep_open", fallback: "保持窗口开启即可，完成后会自动进入下一步。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: statuses[InitStep.basicEnvironment.rawValue] == .running) {
            let isRunning = statuses[InitStep.basicEnvironment.rawValue] == .running
            guard isRunning else {
                waitingSceneLifted = false
                waitingToolRaised = false
                waitingGlowActive = false
                baseEnvProgressPhase = .xcodeCheck
                return
            }

            baseEnvProgressPhase = .xcodeCheck
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                waitingSceneLifted = true
                waitingGlowActive = true
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                waitingToolRaised = true
            }

            while statuses[InitStep.basicEnvironment.rawValue] == .running {
                try? await Task.sleep(for: .seconds(2.4))
                guard statuses[InitStep.basicEnvironment.rawValue] == .running else { break }
                updateBaseEnvProgressFromLog()
            }
        }
    }

    private var injectRolePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("wizard.inject_role.title", fallback: "注入角色"))
                    .font(wizardSectionTitleFont)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("views.user_init_wizard_view.select_ai_provider", fallback: "选择 AI Provider"))
                    .font(wizardSectionTitleFont)
                Text(L10n.k("wizard.model_config.validation.subtitle", fallback: "选择模型提供商并填写认证信息。验证成功后才会进入下一步。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("wizard.provider.label", fallback: "模型提供商"))
                        .font(.subheadline).fontWeight(.medium)
                    Picker(L10n.k("wizard.provider.label", fallback: "模型提供商"), selection: $selectedWizardProvider) {
                        ForEach(WizardProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .wizardInputSurface()
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("wizard.auth_method.label", fallback: "认证方式"))
                        .font(.subheadline).fontWeight(.medium)
                    Picker(L10n.k("wizard.auth_method.label", fallback: "认证方式"), selection: $selectedWizardAuthMethod) {
                        ForEach(availableWizardAuthMethods) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .wizardInputSurface()
                }
                .frame(maxWidth: .infinity)

                providerMoreModelsRow()
            }
            .padding(.bottom, 2)

            Divider()

            providerDetailForm
                .padding(.top, 2)

            modelValidationStatusView

            if !modelConfigError.isEmpty, !isValidationFailureState {
                Label(modelConfigError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button(isApplyingModel ? L10n.k("wizard.model_config.validating", fallback: "验证中…") : L10n.k("wizard.model_config.validate_continue", fallback: "验证并继续")) {
                    Task { await applyModelConfig() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelApplyDisabled)
                Button(L10n.k("wizard.model_config.skip", fallback: "稍后配置")) {
                    Task { await skipModelStep() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func providerMoreModelsRow() -> some View {
        Button {
            openModelConfigTerminal()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                .font(.caption)
                Text(L10n.k("wizard.provider.more_models_openclaw_native", fallback: "更多模型（openclaw原生配置）"))
                    .font(.caption)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isModelConfigTerminalOpen)
    }

    @ViewBuilder
    private var providerDetailForm: some View {
        let provider = selectedWizardProvider
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: provider.icon)
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                Text(provider.displayName)
                    .font(wizardSectionTitleFont)
                Text(provider.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
                        .buttonStyle(.borderless).foregroundStyle(Color.red)
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

                if provider == .custom {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.k("wizard.custom.api_compatibility", fallback: "API 兼容（默认 OpenAI）"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("custom-compatibility", selection: $customCompatibility) {
                                ForEach(CustomCompatibility.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Base URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("https://api.example.com/v1", text: $customBaseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.k("wizard.custom.model_id", fallback: "模型ID"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(L10n.k("wizard.custom.model_id_placeholder", fallback: "例如 gpt-4.1 / claude-3-7-sonnet"), text: $customModelId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.k("wizard.custom.model_alias", fallback: "模型ID别名"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(L10n.k("wizard.custom.model_alias_placeholder", fallback: "例如：自定义 GPT-4.1"), text: $customModelAlias)
                                .textFieldStyle(.roundedBorder)
                                .font(.body)
                        }
                    }
                }

                if selectedWizardAuthMethod == .apiKey {
                    VStack(spacing: 6) {
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
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                } else if provider == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("secret reference")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("env:VAR / ${VAR} / provider:account", text: $customSecretReference)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if provider == .minimax {
                HStack(spacing: 10) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedMinimaxModel) {
                        ForEach(MinimaxModel.allCases, id: \.self) { model in
                            Text(model.providerName).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text(selectedMinimaxModel.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if provider == .qiniu {
                HStack(spacing: 10) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedQiniuModel) {
                        ForEach(QiniuModel.allCases, id: \.self) { model in
                            Text(model.alias).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text(selectedQiniuModel.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if provider == .zai {
                HStack(spacing: 10) {
                    Text(L10n.k("views.user_init_wizard_view.models", fallback: "模型"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker(L10n.k("views.user_init_wizard_view.models", fallback: "模型"), selection: $selectedZAIModel) {
                        ForEach(ZAIModel.allCases, id: \.self) { model in
                            Text(model.alias).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text(selectedZAIModel.rawValue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var modelValidationStatusView: some View {
        switch modelValidationState {
        case .idle:
            Label(L10n.k("wizard.model_config.validation.idle", fallback: "未验证。点击“验证并继续”后会执行实时连通性检查。"), systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .validating:
            Label(L10n.k("wizard.model_config.validation.running", fallback: "正在验证 Provider 配置…"), systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
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
        case .custom:
            guard !customModelIdTrimmed.isEmpty else { return "" }
            return "\(effectiveCustomProviderId)/\(customModelIdTrimmed)"
        }
    }

    private var channelConfigPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("views.user_init_wizard_view.channel", fallback: "IM 绑定"))
                    .font(wizardSectionTitleFont)
                Text(L10n.k("views.user_init_wizard_view.select_done", fallback: "选择要接入的 IM 频道，完成配对后虾即可收发消息。"))
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
                title: L10n.k("views.user_init_wizard_view.feishu", fallback: "飞书 IM 扫码绑定"),
                subtitle: L10n.k("views.user_init_wizard_view.done", fallback: "在独立窗口生成二维码，扫码完成 IM 频道配对。")
            ) {
                selectedChannel = .feishu
                openWindow(
                    id: "channel-onboarding",
                    value: "\(ChannelOnboardingFlow.feishu.rawValue):\(user.username)"
                )
            }
            channelBindingRow(
                channel: .weixin,
                title: L10n.k("views.user_init_wizard_view.wechat", fallback: "微信 IM 扫码绑定"),
                subtitle: L10n.k("views.user_init_wizard_view.donewechat", fallback: "在独立窗口生成二维码，扫码完成微信 IM 频道配对。")
            ) {
                selectedChannel = .weixin
                openWindow(
                    id: "channel-onboarding",
                    value: "\(ChannelOnboardingFlow.weixin.rawValue):\(user.username)"
                )
            }
            channelNativeConfigRow(
                title: L10n.k("wizard.channel.more_im_bindings", fallback: "更多 IM 频道绑定"),
                subtitle: L10n.k("wizard.channel.more_im_bindings_hint", fallback: "通过 openclaw 原生配置界面进行操作。")
            ) {
                openIMChannelNativeConfig()
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

    private func channelNativeConfigRow(
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
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
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var finishPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            GatewayActivationCard(
                progress: activationProgress,
                isAnimating: isStartingOpenclaw,
                isShrimpLifted: activationShrimpLifted
            )

            if !isStartingOpenclaw {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text(L10n.k("views.user_init_wizard_view.initialization_completed", fallback: "配置完成")).font(wizardSectionTitleFont)
                    }
                    Text(L10n.k("views.user_init_wizard_view.models_channelconfigurationdone", fallback: "正在启动 OpenClaw Gateway…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard !finishAutoStartTriggered, !isStartingOpenclaw else { return }
            finishAutoStartTriggered = true
            await finishAndStartOpenclaw()
        }
        .task(id: isStartingOpenclaw) {
            guard isStartingOpenclaw else {
                activationShrimpLifted = false
                return
            }

            activationProgress = max(activationProgress, 0.12)
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                activationShrimpLifted = true
            }

            while isStartingOpenclaw && activationProgress < 0.9 {
                try? await Task.sleep(for: .milliseconds(220))
                if !isStartingOpenclaw { break }
                activationProgress = min(0.9, activationProgress + 0.035)
            }
        }
    }

    private var failurePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(L10n.k("views.user_init_wizard_view.step_failed", fallback: "步骤失败")).font(wizardSectionTitleFont)
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
                    .disabled(isCancelling || isRunningInitFlow)
                Button(L10n.k("views.user_init_wizard_view.restart", fallback: "重新开始")) { resetWizard() }
                    .buttonStyle(.bordered).foregroundStyle(.secondary)
                    .disabled(isCancelling || isRunningInitFlow)
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
                    Text(L10n.k("views.user_init_wizard_view.initialization_paused", fallback: "初始化已暂停")).font(wizardSectionTitleFont)
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
                        await requestCancelInit()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if showAdvancedOptions {
                Divider()
                    .padding(.horizontal, 12)

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
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
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
        customSecretReference = ""
        selectedWizardAuthMethod = .apiKey
        isShowingApiKey = false
        minimaxApiKey = ""
        selectedWizardProvider = .kimiCoding
        customProviderId = ""
        customModelId = ""
        customModelAlias = ""
        customBaseURL = ""
        customCompatibility = .openai
        selectedMinimaxModel = .m27
        selectedQiniuModel = .deepseekV32
        selectedZAIModel = .glm5
        roleSoul = ""
        roleIdentity = ""
        roleUser = ""
        modelConfigError = ""
        modelValidationState = .idle
        activeModelConfigTerminalToken = nil
        isModelConfigTerminalOpen = false
        pendingModelConfigTerminalClose = nil
        selectedChannel = .feishu
        isStartingOpenclaw = false
        finishProgressMessages = []
        waitingSceneLifted = false
        waitingToolRaised = false
        waitingGlowActive = false
        baseEnvProgressPhase = .xcodeCheck
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
        baseEnvProgressPhase = .xcodeCheck
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

        baseEnvProgressPhase = .homebrewRepair
        appendLog("\n▶ \(String(localized: "wizard.homebrew.repair.start", defaultValue: "修复 Homebrew 权限（可选）"))\n")
        do {
            try await conn.repairHomebrewPermission(username: user.username)
            appendLog("✓ \(String(localized: "wizard.homebrew.repair.done", defaultValue: "Homebrew 权限修复已完成"))\n")
        } catch {
            // best-effort：失败不阻断初始化
            appendLog("⚠️ \(String(localized: "wizard.homebrew.repair.failed", defaultValue: "Homebrew 权限修复失败（已跳过，不影响初始化）"))：\(error.localizedDescription)\n")
        }

        let autoSteps: [(phase: BaseEnvProgressPhase, title: String, run: () async throws -> Void)] = [
            (.installNode, L10n.k("views.user_init_wizard_view.node_js", fallback: "安装 Node.js"), { try await conn.installNode(username: user.username, nodeDistURL: nodeDistURL) }),
            (.setupNpmEnv, L10n.k("views.user_init_wizard_view.configuration_npm_directory", fallback: "配置 npm 目录"), { try await conn.setupNpmEnv(username: user.username) }),
            (.setNpmRegistry, L10n.k("views.user_init_wizard_view.settings_npm", fallback: "设置 npm 安装源"), {
                try await conn.setNpmRegistry(username: user.username, registry: selectedNpmRegistry.rawValue)
            }),
            (.installOpenclaw, L10n.k("views.user_init_wizard_view.openclaw_openclawversionlabelforui", fallback: "安装 openclaw (\(openclawVersionLabelForUI))"), {
                try await conn.installOpenclaw(
                    username: user.username,
                    version: selectedOpenclawVersionForInstall
                )
            }),
        ].compactMap { $0 }

        for item in autoSteps {
            baseEnvProgressPhase = item.phase
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
        // 终止后的失败属于“可恢复状态”，重试时先清理，避免被 hasFailure 持续拦截。
        let cancelledMessage = L10n.k("views.user_init_wizard_view.terminated", fallback: "已终止")
        for step in InitStep.allCases {
            if case .failed(let message) = statuses[step.rawValue], message == cancelledMessage {
                statuses[step.rawValue] = .pending
            }
        }

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
        if let validationError = await validateModelConfigInput() {
            modelValidationState = .failure(validationError)
            modelConfigError = validationError
            return
        }

        isApplyingModel = true
        modelConfigError = ""
        modelValidationState = .validating
        defer { isApplyingModel = false }

        do {
            try await writeSelectedModelConfig()
            try await probeSelectedProvider()
            modelValidationState = .success(
                L10n.f(
                    "wizard.model_config.validation.success_provider",
                    fallback: "%@ 验证成功，正在进入下一步。",
                    selectedWizardProvider.displayName
                )
            )
            await markModelStepDone()
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = message.isEmpty
                ? L10n.k("wizard.model_config.validation.failed", fallback: "Provider 验证失败，请检查配置后重试。")
                : message
            modelValidationState = .failure(resolved)
            modelConfigError = resolved
        }
    }

    private var modelApplyDisabled: Bool {
        if isApplyingModel { return true }
        if selectedWizardProvider == .custom {
            let hasModel = !customModelIdTrimmed.isEmpty
            let hasBaseURL = !customBaseURLTrimmed.isEmpty
            if !hasModel || !hasBaseURL { return true }
            switch selectedWizardAuthMethod {
            case .apiKey:
                return false
            case .secretReference:
                return customSecretReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func writeSelectedModelConfig() async throws {
        switch selectedWizardProvider {
        case .kimiCoding:
            let apiKey = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await applyKimiCodingConfig(apiKey: apiKey)
        case .minimax:
            let apiKey = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await applyMinimaxConfig(apiKey: apiKey)
        case .qiniu:
            let apiKey = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await applyQiniuConfig(apiKey: apiKey)
        case .zai:
            let apiKey = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try await applyZAIConfig(apiKey: apiKey)
        case .custom:
            try await applyCustomProviderConfig()
        }
    }

    private func probeSelectedProvider() async throws {
        let providerToProbe: String = {
            if selectedWizardProvider == .custom { return effectiveCustomProviderId }
            return selectedWizardProvider.rawValue
        }()
        let args = ["models", "status", "--probe-provider", providerToProbe, "--probe-timeout", "10000"]
        let (ok, output) = await helperClient.runOpenclawCommand(username: user.username, args: args)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ok else {
            if trimmed.isEmpty {
                throw HelperError.operationFailed(L10n.k("wizard.model_config.validation.failed_generic", fallback: "验证失败，未收到 Provider 返回信息。"))
            }
            throw HelperError.operationFailed(trimmed)
        }
    }

    private func validateModelConfigInput() async -> String? {
        if selectedWizardProvider != .custom {
            let key = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                return L10n.k("wizard.model_config.validation.empty_key", fallback: "请先输入 API Key，再执行验证。")
            }
            return nil
        }

        if customModelIdTrimmed.isEmpty {
            return "请先填写 custom-model-id。"
        }
        if customBaseURLTrimmed.isEmpty {
            return "请先填写 custom-base-url。"
        }

        switch selectedWizardAuthMethod {
        case .apiKey:
            let key = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                let existing = await helperClient.getConfig(username: user.username, key: "env.CUSTOM_API_KEY")
                if existing == nil || existing?.isEmpty == true {
                    return "未输入 custom API Key，且 env.CUSTOM_API_KEY 未配置。"
                }
            }
            return nil
        case .secretReference:
            return await validateCustomSecretReference()
        }
    }

    private func validateCustomSecretReference() async -> String? {
        let raw = customSecretReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return "Secret Reference 不能为空。"
        }
        if raw.hasPrefix("${"), raw.hasSuffix("}") {
            let envName = String(raw.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if envName.isEmpty { return "环境变量引用格式错误。示例：${CUSTOM_API_KEY}" }
            let existing = await helperClient.getConfig(username: user.username, key: "env.\(envName)")
            if existing == nil || existing?.isEmpty == true {
                return "环境变量 \(envName) 未配置（预检失败）。"
            }
            return nil
        }
        if raw.hasPrefix("env:") {
            let envName = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if envName.isEmpty { return "env 引用格式错误。示例：env:CUSTOM_API_KEY" }
            let existing = await helperClient.getConfig(username: user.username, key: "env.\(envName)")
            if existing == nil || existing?.isEmpty == true {
                return "环境变量 \(envName) 未配置（预检失败）。"
            }
            return nil
        }
        if raw.contains(":") {
            if !GlobalSecretsStore.shared.has(secretKey: raw) {
                return "provider ref \(raw) 不存在于全局 secrets（预检失败）。"
            }
            return nil
        }
        return "Secret Reference 格式不支持。请使用 env:VAR / ${VAR} / provider:account。"
    }

    private func resolvedCustomAPIKeyValue() -> String {
        switch selectedWizardAuthMethod {
        case .apiKey:
            let direct = wizardApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if direct.isEmpty {
                return "${CUSTOM_API_KEY}"
            }
            return direct
        case .secretReference:
            let raw = customSecretReference.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("env:") {
                let envName = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                return "${\(envName)}"
            }
            return raw
        }
    }

    private func applyCustomProviderConfig() async throws {
        let providerId = effectiveCustomProviderId
        let modelId = customModelIdTrimmed
        let modelPrimary = "\(providerId)/\(modelId)"
        let alias = customModelAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = await helperClient.getConfigJSON(username: user.username)
        let existingModel = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any]) ?? [:]
        var modelAliasMap = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["models"] as? [String: Any]) ?? [:]
        var normalizedModelConfig: [String: Any] = ["primary": modelPrimary]
        if let arr = existingModel["fallback"] as? [String], !arr.isEmpty {
            normalizedModelConfig["fallback"] = arr
        } else if let single = existingModel["fallback"] as? String, !single.isEmpty {
            normalizedModelConfig["fallback"] = [single]
        }
        if !alias.isEmpty {
            modelAliasMap[modelPrimary] = ["alias": alias]
        }

        let providerPayload: [String: Any] = [
            "baseUrl": customBaseURLTrimmed,
            "apiKey": resolvedCustomAPIKeyValue(),
            "api": customCompatibility.apiType,
            "models": [[
                "id": modelId,
                "name": alias.isEmpty ? modelId : alias,
                "reasoning": true,
                "input": ["text", "image"],
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                "contextWindow": 262144,
                "maxTokens": 32768,
            ]],
        ]

        try await helperClient.setConfigDirect(username: user.username, path: "models.mode", value: "merge")
        try await helperClient.setConfigDirect(username: user.username, path: "models.providers.\(providerId)", value: providerPayload)
        try await helperClient.setConfigDirect(username: user.username, path: "auth.profiles.\(providerId):default", value: ["provider": providerId, "mode": "api_key"])
        try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.model", value: normalizedModelConfig)
        if !alias.isEmpty {
            try await helperClient.setConfigDirect(username: user.username, path: "agents.defaults.models", value: modelAliasMap)
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
        finishAutoStartTriggered = false
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
        modelValidationState = .idle
        await persistState()
    }

    private func moveBackToModelStep() async {
        currentStep = .configureModel
        statuses[InitStep.configureModel.rawValue] = .running
        statuses[InitStep.configureChannel.rawValue] = .pending
        statuses[InitStep.finish.rawValue] = .pending
        user.initStep = InitStep.configureModel.title
        finishAutoStartTriggered = false
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
        activationProgress = 0.12
        appendFinishProgress(L10n.k("views.user_init_wizard_view.done_overview", fallback: "正在启动 OpenClaw Gateway…"))

        gatewayHub.markPendingStart(username: user.username)
        appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_starting_gateway", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] 正在启动 Gateway…\n"))

        do {
            try await helperClient.startGateway(username: user.username)
            user.isRunning = true
            user.pid = nil
            user.startedAt = nil
            activationProgress = 1
            appendLog(L10n.k("views.user_init_wizard_view.finish_self_finishprogresstimeformatter_string_date_gateway_started_successfully", fallback: "[finish] [\(Self.finishProgressTimeFormatter.string(from: Date()))] Gateway 启动成功。\n"))
            await syncGatewayStateAfterStart()
            try? await Task.sleep(for: .milliseconds(280))
            await completeWizardOnly()
            openWindow(id: "claw-detail", value: user.username)
            try? await Task.sleep(for: .milliseconds(360))
            dismiss()
        } catch {
            user.isRunning = false
            user.pid = nil
            user.startedAt = nil
            gatewayHub.markPendingStopped(username: user.username)
            activationProgress = 0.12
            statuses[InitStep.finish.rawValue] = .failed(error.localizedDescription)
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

    private var waitingStatusMessage: String {
        baseEnvProgressPhase.runningText
    }

    private func updateBaseEnvProgressFromLog() {
        let path = "/tmp/clawdhome-init-\(user.username).log"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else { return }

        let markers: [(marker: String, phase: BaseEnvProgressPhase)] = [
            ("▶ 检查 Xcode 开发环境", .xcodeCheck),
            ("▶ 修复 Homebrew 权限", .homebrewRepair),
            ("▶ 安装 Node.js", .installNode),
            ("▶ 配置 npm 目录", .setupNpmEnv),
            ("▶ 设置 npm 安装源", .setNpmRegistry),
            ("▶ 安装 openclaw", .installOpenclaw)
        ]

        var best: (loc: Int, phase: BaseEnvProgressPhase)? = nil
        for item in markers {
            let range = (text as NSString).range(of: item.marker, options: .backwards)
            guard range.location != NSNotFound else { continue }
            if let current = best {
                if range.location > current.loc {
                    best = (range.location, item.phase)
                }
            } else {
                best = (range.location, item.phase)
            }
        }

        guard let detected = best?.phase else { return }
        if detected.rawValue > baseEnvProgressPhase.rawValue {
            baseEnvProgressPhase = detected
        }
    }

    private var isValidationFailureState: Bool {
        if case .failure = modelValidationState { return true }
        return false
    }

    private func resetModelValidationState(clearCredential: Bool) {
        if clearCredential {
            wizardApiKey = ""
            customSecretReference = ""
            customModelAlias = ""
            isShowingApiKey = false
        }
        modelConfigError = ""
        modelValidationState = .idle
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
            } else if saved.modelName.contains("/") {
                let parts = saved.modelName.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    selectedWizardProvider = .custom
                    customProviderId = parts[0]
                    customModelId = parts[1]
                }
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

    /// 请求 Helper 终止初始化流程；等待取消完成，避免“重试”与“终止”发生竞态。
    private func requestCancelInit() async {
        let username = user.username
        let conn = wizardConn
        await conn?.cancelInit(username: username)
        await helperClient.cancelInit(username: username)
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

    private func openIMChannelNativeConfig() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: L10n.k("wizard.channel.native_config.window_title", fallback: "IM 频道原生配置"),
            command: ["openclaw", "channels", "add"]
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

    private static let finishProgressTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
