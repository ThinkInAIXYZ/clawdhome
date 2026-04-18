// ClawdHome/Models/ModelsStatus.swift
// 解析 `openclaw models status --json` 输出 + 统一模型目录定义

import Foundation

struct ModelsStatus: Decodable {
    let defaultModel: String?
    let resolvedDefault: String?
    let fallbacks: [String]
    let imageModel: String?
    let imageFallbacks: [String]
    /// 从 meta.lastTouchedVersion 读取的 openclaw 已安装版本
    let installedVersion: String?

    enum CodingKeys: String, CodingKey {
        case defaultModel, resolvedDefault, fallbacks, imageModel, imageFallbacks
    }

    init(defaultModel: String?, resolvedDefault: String?, fallbacks: [String], imageModel: String?, imageFallbacks: [String], installedVersion: String? = nil) {
        self.defaultModel = defaultModel
        self.resolvedDefault = resolvedDefault
        self.fallbacks = fallbacks
        self.imageModel = imageModel
        self.imageFallbacks = imageFallbacks
        self.installedVersion = installedVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel   = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        resolvedDefault = try c.decodeIfPresent(String.self, forKey: .resolvedDefault)
        fallbacks      = (try? c.decode([String].self, forKey: .fallbacks)) ?? []
        imageModel     = try c.decodeIfPresent(String.self, forKey: .imageModel)
        imageFallbacks = (try? c.decode([String].self, forKey: .imageFallbacks)) ?? []
        installedVersion = nil
    }
}

// MARK: - 模型元数据

struct ModelCost {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

struct ModelCompat {
    let supportsStore: Bool
    let supportsDeveloperRole: Bool
    let supportsReasoningEffort: Bool
}

// MARK: - 统一模型定义

/// ⚠️ 这是模型定义的唯一源，所有 UI 和配置逻辑应引用此类型而非重复定义。
struct ModelEntry: Identifiable {
    let id: String              // provider/model-id（写入配置的值）
    let label: String           // 用户友好名称
    var reasoning: Bool = true
    var inputTypes: [String] = ["text"]
    var contextWindow: Int = 128_000
    var maxTokens: Int = 8192
    var cost: ModelCost? = nil
    var compat: ModelCompat? = nil

    /// 去除 provider 前缀的模型 ID（用于 openclaw provider.models[] 配置）
    var providerModelID: String {
        guard let idx = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: idx)...])
    }

    /// 生成 openclaw provider.models[] 配置字典
    var providerModelConfig: [String: Any] {
        var config: [String: Any] = [
            "id": providerModelID,
            "name": label,
            "reasoning": reasoning,
            "input": inputTypes,
            "contextWindow": contextWindow,
            "maxTokens": maxTokens,
        ]
        if let cost {
            config["cost"] = [
                "input": cost.input,
                "output": cost.output,
                "cacheRead": cost.cacheRead,
                "cacheWrite": cost.cacheWrite,
            ]
        }
        if let compat {
            config["compat"] = [
                "supportsStore": compat.supportsStore,
                "supportsDeveloperRole": compat.supportsDeveloperRole,
                "supportsReasoningEffort": compat.supportsReasoningEffort,
            ]
        }
        return config
    }
}

struct ModelGroup: Identifiable {
    let id: String
    let provider: String
    let models: [ModelEntry]
}

// MARK: - 内置精选模型清单

/// 内置精选模型清单（所有已集成 Provider 的可选模型）
/// 与 openclaw src/agents/defaults.ts 及 models-config.providers.ts 保持同步
/// 格式：provider/model-id，与 openclaw config 写入格式一致
/// ⚠️ 这是模型 (id, label, config) 的唯一源，其他文件应引用此数组而非重复定义
let builtInModelGroups: [ModelGroup] = [
    ModelGroup(id: "kimi-coding", provider: "Kimi Code", models: [
        ModelEntry(id: "kimi-coding/k2p5", label: "Kimi K2.5",
                   inputTypes: ["text", "image"],
                   contextWindow: 262_144, maxTokens: 32_768,
                   cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
    ]),
    ModelGroup(id: "minimax", provider: "MiniMax", models: [
        ModelEntry(id: "minimax/MiniMax-M2.7", label: "MiniMax M2.7",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-M2.7-highspeed", label: "MiniMax M2.7 Highspeed",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-M2.5", label: "MiniMax M2.5",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-M2.5-highspeed", label: "MiniMax M2.5 Highspeed",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-VL-01", label: "MiniMax VL-01",
                   reasoning: false, inputTypes: ["text", "image"],
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-M2", label: "MiniMax M2",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
        ModelEntry(id: "minimax/MiniMax-M2.1", label: "MiniMax M2.1",
                   contextWindow: 200_000,
                   cost: ModelCost(input: 0.3, output: 1.2, cacheRead: 0.03, cacheWrite: 0.12)),
    ]),
    ModelGroup(id: "qiniu", provider: "Qiniu AI", models: [
        ModelEntry(id: "qiniu/deepseek-v3.2-251201", label: "DeepSeek V3.2",
                   reasoning: false,
                   compat: ModelCompat(supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: false)),
        ModelEntry(id: "qiniu/z-ai/glm-5", label: "GLM 5",
                   reasoning: false,
                   compat: ModelCompat(supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: false)),
        ModelEntry(id: "qiniu/moonshotai/kimi-k2.5", label: "Kimi K2.5",
                   reasoning: false, contextWindow: 256_000,
                   compat: ModelCompat(supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: false)),
        ModelEntry(id: "qiniu/minimax/minimax-m2.5", label: "Minimax M2.5",
                   reasoning: false,
                   compat: ModelCompat(supportsStore: false, supportsDeveloperRole: false, supportsReasoningEffort: false)),
    ]),
    ModelGroup(id: "zai", provider: "智谱 Z.AI", models: [
        ModelEntry(id: "zai/glm-5.1", label: "GLM-5.1",
                   contextWindow: 204_800, maxTokens: 131_072,
                   cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
        ModelEntry(id: "zai/glm-5", label: "GLM-5",
                   contextWindow: 204_800, maxTokens: 131_072,
                   cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
        ModelEntry(id: "zai/glm-4.7", label: "GLM-4.7",
                   contextWindow: 204_800, maxTokens: 131_072,
                   cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)),
    ]),
]

// MARK: - 便利查询

/// 按 provider id 查找内置模型组的所有模型
func builtInModels(for providerId: String) -> [ModelEntry] {
    builtInModelGroups.first { $0.id == providerId }?.models ?? []
}

/// 按模型 id 查找单个内置模型
func builtInModel(for modelId: String) -> ModelEntry? {
    builtInModelGroups.flatMap(\.models).first { $0.id == modelId }
}
