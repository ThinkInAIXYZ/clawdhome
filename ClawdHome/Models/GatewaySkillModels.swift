// 简化自 openclaw/apps/macos/Sources/OpenClaw/SkillsModels.swift
// 参考 openclaw commit 505b980f63 (2026-04-07)

import Foundation

struct GatewaySkillsStatusReport: Codable {
    let workspaceDir: String
    let managedSkillsDir: String
    let skills: [GatewaySkillStatus]
}

struct GatewaySkillStatus: Codable, Identifiable {
    let name: String
    let description: String
    let source: String
    let skillKey: String
    let primaryEnv: String?
    let emoji: String?
    let homepage: String?
    let always: Bool
    let disabled: Bool
    let eligible: Bool
    let missing: GatewaySkillMissing
    let configChecks: [GatewaySkillConfigCheck]
    let install: [GatewaySkillInstallOption]

    var id: String {
        self.name
    }

    /// source 为 "openclaw-bundled" 时视为内置
    var isBundled: Bool {
        source == "openclaw-bundled"
    }

    /// 来源标签
    var sourceLabel: String {
        switch source {
        case "openclaw-bundled": return L10n.k("model.skill.source.bundled", fallback: "内置")
        case "openclaw-managed": return L10n.k("model.skill.source.managed", fallback: "已安装")
        case "openclaw-workspace": return L10n.k("model.skill.source.workspace", fallback: "工作区")
        case "openclaw-extra": return L10n.k("model.skill.source.extra", fallback: "扩展")
        case "openclaw-plugin": return L10n.k("model.skill.source.plugin", fallback: "插件")
        default: return source
        }
    }

    // 向后兼容：configChecks / install 可能不存在于旧版 gateway
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        source = try c.decode(String.self, forKey: .source)
        skillKey = try c.decode(String.self, forKey: .skillKey)
        primaryEnv = try c.decodeIfPresent(String.self, forKey: .primaryEnv)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        always = try c.decode(Bool.self, forKey: .always)
        disabled = try c.decode(Bool.self, forKey: .disabled)
        eligible = try c.decode(Bool.self, forKey: .eligible)
        missing = try c.decode(GatewaySkillMissing.self, forKey: .missing)
        configChecks = try c.decodeIfPresent([GatewaySkillConfigCheck].self, forKey: .configChecks) ?? []
        install = try c.decodeIfPresent([GatewaySkillInstallOption].self, forKey: .install) ?? []
    }
}

struct GatewaySkillMissing: Codable {
    let bins: [String]
    let env: [String]
    let config: [String]

    var isEmpty: Bool {
        bins.isEmpty && env.isEmpty && config.isEmpty
    }
}

struct GatewaySkillConfigCheck: Codable, Identifiable {
    let path: String
    let satisfied: Bool

    var id: String { path }
}

struct GatewaySkillInstallOption: Codable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let bins: [String]
}

struct GatewaySkillInstallResult: Codable {
    let ok: Bool
    let message: String
    let stdout: String?
    let stderr: String?
}

struct GatewaySkillUpdateResult: Codable {
    let ok: Bool
    let skillKey: String
}
