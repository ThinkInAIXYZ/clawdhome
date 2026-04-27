// ClawdHome/Views/WizardModels.swift
// 初始化向导相关的模型、枚举定义

import SwiftUI

let modelConfigMaintenanceContext = "wizard-model-config"

// MARK: - 团队 Agent 激活状态

enum TeamAgentActivationStatus: Equatable {
    case waiting          // 尚未开始
    case activating       // 正在写入
    case done             // 已就位
    case failed(String)   // 失败，附带错误
}

enum WizardL10nKeys {
    static var pairingDetectedHint: String {
        L10n.k("wizard.channel.pairing_detected_continue_hint", fallback: "%@ pairing detected. Review channel settings, then click Done to continue.")
    }
    static var currentChannelName: String {
        L10n.k("views.wizard.channel_name.current", fallback: "Current Channel")
    }
}

struct ModelConfigTerminalCloseState: Identifiable {
    let id = UUID()
    let exitCode: Int32?
    let detectedModel: String?
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

enum BaseEnvProgressPhase: Int, CaseIterable {
    case xcodeCheck = 1
    case homebrewRepair
    case installNode
    case setupNpmEnv
    case setNpmRegistry
    case installOpenclaw

    static var totalCount: Int { allCases.count }

    var title: String {
        switch self {
        case .xcodeCheck: return L10n.k("wizard.base_env.xcode_check", fallback: "检查 Xcode 开发环境")
        case .homebrewRepair: return L10n.k("wizard.base_env.homebrew_repair", fallback: "修复 Homebrew 权限")
        case .installNode: return L10n.k("wizard.base_env.install_node", fallback: "安装 Node.js")
        case .setupNpmEnv: return L10n.k("wizard.base_env.setup_npm_env", fallback: "配置 npm 目录")
        case .setNpmRegistry: return L10n.k("wizard.base_env.set_npm_registry", fallback: "设置 npm 安装源")
        case .installOpenclaw: return L10n.k("wizard.base_env.install_openclaw", fallback: "安装 openclaw")
        }
    }

    var runningText: String {
        "(\(rawValue)/\(Self.totalCount)) \(title)…"
    }
}

// MinimaxModel / QiniuModel / ZAIModel 已统一到 ModelsStatus.swift 的 builtInModelGroups
// 使用 builtInModels(for: "minimax") / builtInModels(for: "qiniu") / builtInModels(for: "zai") 查询

enum WizardChannelType: String {
    case feishu
    case weixin

    var localizedName: String {
        switch self {
        case .feishu: return L10n.k("views.wizard.channel_name.feishu", fallback: "Feishu")
        case .weixin: return L10n.k("views.wizard.channel_name.weixin", fallback: "WeChat")
        }
    }
}

enum OpenclawVersionPreset: String {
    case latest
    case custom
}

enum WizardXcodeHealthState {
    case checking
    case healthy
    case unhealthy
}

enum WizardProvider: String, CaseIterable, Identifiable {
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
        case .zai:        return L10n.k("wizard.provider.zai.name", fallback: "智谱 Z.AI")
        case .custom:     return L10n.k("wizard.provider.custom.name", fallback: "自定义")
        }
    }

    var subtitle: String {
        switch self {
        case .kimiCoding: return "Kimi for Coding"
        case .minimax:    return L10n.k("wizard.provider.minimax.subtitle", fallback: "MiniMax M2.5 系列")
        case .qiniu:      return "DeepSeek / GLM / Kimi / Minimax"
        case .zai:        return L10n.k("wizard.provider.zai.subtitle", fallback: "GLM系列模型")
        case .custom:     return L10n.k("wizard.provider.custom.subtitle", fallback: "OpenAI / Anthropic 兼容")
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
        case .zai:        return L10n.k("wizard.provider.zai.api_key_label", fallback: "智谱 API Key")
        case .custom:     return L10n.k("wizard.provider.custom.api_key_label", fallback: "自定义 API Key")
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .kimiCoding: return "sk-..."
        case .minimax:    return L10n.k("wizard.provider.minimax.api_key.placeholder", fallback: "粘贴 MiniMax API Key")
        case .qiniu:      return "sk-..."
        case .zai:        return "sk-..."
        case .custom:     return L10n.k("wizard.provider.custom.api_key_placeholder", fallback: "留空则使用 CUSTOM_API_KEY")
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
        case .qiniu:      return L10n.k("wizard.provider.qiniu.console", fallback: "七牛 API Key")
        case .zai:        return L10n.k("wizard.provider.zai.console", fallback: "获取 API Key")
        case .custom:     return L10n.k("wizard.provider.custom.console", fallback: "API Key 参考")
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
            return L10n.k("wizard.provider.minimax.promotion", fallback: "🎁 领取 9 折专属优惠")
        case .qiniu:
            return L10n.k("wizard.provider.qiniu.promotion", fallback: "免费领取 1000 万 Token")
        case .zai:
            return L10n.k("wizard.provider.zai.promotion", fallback: "95折优惠订阅")
        default:
            return nil
        }
    }
}

enum WizardAuthMethod: String, CaseIterable, Identifiable {
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

enum CustomCompatibility: String, CaseIterable, Identifiable {
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

enum ModelValidationState: Equatable {
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
