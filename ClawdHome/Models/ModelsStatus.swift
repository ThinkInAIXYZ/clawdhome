// ClawdHome/Models/ModelsStatus.swift
// 解析 `openclaw models status --json` 输出

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

// MARK: - 内置精选模型清单

struct ModelEntry: Identifiable {
    let id: String      // provider/model-id（写入配置的值）
    let label: String   // 用户友好名称
}

struct ModelGroup: Identifiable {
    let id: String
    let provider: String
    let models: [ModelEntry]
}

/// 内置精选模型清单（重构阶段仅保留 MiniMax）
/// 与 openclaw src/agents/defaults.ts 及 models-config.providers.ts 保持同步
/// 格式：provider/model-id，与 openclaw config 写入格式一致
let builtInModelGroups: [ModelGroup] = [
    ModelGroup(id: "minimax", provider: "MiniMax", models: [
        ModelEntry(id: "minimax/MiniMax-M2.7",           label: "MiniMax M2.7"),
        ModelEntry(id: "minimax/MiniMax-M2.7-highspeed", label: "MiniMax M2.7 Highspeed"),
        ModelEntry(id: "minimax/MiniMax-M2.5",           label: "MiniMax M2.5"),
        ModelEntry(id: "minimax/MiniMax-M2.5-highspeed", label: "MiniMax M2.5 Highspeed"),
        ModelEntry(id: "minimax/MiniMax-VL-01",          label: "MiniMax VL-01"),
        ModelEntry(id: "minimax/MiniMax-M2",             label: "MiniMax M2"),
        ModelEntry(id: "minimax/MiniMax-M2.1",           label: "MiniMax M2.1"),
    ]),
]
