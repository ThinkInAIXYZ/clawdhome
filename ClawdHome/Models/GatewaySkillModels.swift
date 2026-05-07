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
    let emoji: String?
    let homepage: String?
    let always: Bool
    let disabled: Bool
    let eligible: Bool
    let missing: GatewaySkillMissing

    var id: String {
        self.name
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
