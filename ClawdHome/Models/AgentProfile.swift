import Foundation

/// 单个 Agent 在 App 内的表示，对应 OpenClaw agents.list[] 中的一个条目
struct AgentProfile: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var emoji: String
    var modelPrimary: String?
    var workspacePath: String?
    var isDefault: Bool

    var displayLabel: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}
