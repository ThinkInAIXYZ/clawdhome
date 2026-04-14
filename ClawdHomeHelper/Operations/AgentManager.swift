// ClawdHomeHelper/Operations/AgentManager.swift
// Agent 管理：读取 / 创建 / 删除 openclaw.json 中的 agents 配置
// 所有操作直接操作 JSON 文件（毫秒级，不启动 CLI）

import Foundation

enum AgentManagerError: LocalizedError {
    case configReadFailed(String)
    case agentAlreadyExists(String)
    case cannotRemoveDefaultAgent
    case agentNotFound(String)
    case invalidConfigJSON

    var errorDescription: String? {
        switch self {
        case .configReadFailed(let path):
            return "无法读取配置文件：\(path)"
        case .agentAlreadyExists(let id):
            return "Agent ID 已存在：\(id)"
        case .cannotRemoveDefaultAgent:
            return "不能删除默认 Agent"
        case .agentNotFound(let id):
            return "未找到 Agent：\(id)"
        case .invalidConfigJSON:
            return "configJSON 解析失败"
        }
    }
}

struct AgentManager {

    // MARK: - listAgents

    /// 读取 ~/.openclaw/openclaw.json，返回 JSON 编码的 [AgentProfile]
    static func listAgents(username: String) throws -> String {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default

        // 读取并解析 JSON
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: configPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = dict
        }

        let agents = root["agents"] as? [String: Any]
        let list = agents?["list"] as? [[String: Any]]
        let defaultId = agents?["defaultId"] as? String ?? "main"

        // 如果 agents.list 不存在或为空，返回默认 agent
        guard let agentList = list, !agentList.isEmpty else {
            let defaultAgent = AgentProfileDTO(
                id: "main",
                name: "默认角色",
                emoji: "",
                modelPrimary: nil,
                workspacePath: nil,
                isDefault: true
            )
            let data = try JSONEncoder().encode([defaultAgent])
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        // 解析每个 agent 条目
        var profiles: [AgentProfileDTO] = []
        for entry in agentList {
            let id = entry["id"] as? String ?? ""
            // name: 优先顶层 name，回退到 identity.name
            let identity = entry["identity"] as? [String: Any]
            let name = entry["name"] as? String
                ?? identity?["name"] as? String
                ?? id
            let emoji = identity?["emoji"] as? String ?? ""
            // model.primary
            let model = entry["model"] as? [String: Any]
            let modelPrimary = model?["primary"] as? String
            // workspace
            let workspace = entry["workspace"] as? String
            let isDefault = (id == defaultId)

            profiles.append(AgentProfileDTO(
                id: id,
                name: name,
                emoji: emoji,
                modelPrimary: modelPrimary,
                workspacePath: workspace,
                isDefault: isDefault
            ))
        }

        let data = try JSONEncoder().encode(profiles)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - createAgent

    /// 创建新 agent，追加到 agents.list，创建 workspace 目录
    static func createAgent(username: String, configJSON: String) throws {
        // 解析传入的 AgentProfile
        guard let profileData = configJSON.data(using: .utf8),
              let profile = try? JSONDecoder().decode(AgentProfileDTO.self, from: profileData)
        else {
            throw AgentManagerError.invalidConfigJSON
        }

        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default

        // 读取现有 JSON
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: configPath),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = dict
        }

        var agents = root["agents"] as? [String: Any] ?? [:]
        var list = agents["list"] as? [[String: Any]] ?? []

        // 检查 id 是否已存在
        if list.contains(where: { ($0["id"] as? String) == profile.id }) {
            throw AgentManagerError.agentAlreadyExists(profile.id)
        }

        // 构造新的 agent 条目
        var entry: [String: Any] = [
            "id": profile.id,
            "name": profile.name,
        ]
        // identity
        var identity: [String: Any] = ["name": profile.name]
        if !profile.emoji.isEmpty {
            identity["emoji"] = profile.emoji
        }
        entry["identity"] = identity

        // model
        if let modelPrimary = profile.modelPrimary, !modelPrimary.isEmpty {
            entry["model"] = ["primary": modelPrimary]
        }

        // workspace — 默认路径
        let workspacePath = profile.workspacePath
            ?? "/Users/\(username)/.openclaw/workspace-\(profile.id)"
        entry["workspace"] = workspacePath

        list.append(entry)
        agents["list"] = list

        // 如果没有 defaultId，设置第一个为默认
        if agents["defaultId"] == nil {
            agents["defaultId"] = list.first.flatMap { $0["id"] as? String } ?? profile.id
        }
        root["agents"] = agents

        // 写回 JSON
        try writeConfig(root, toPath: configPath, username: username)

        // 创建 workspace 目录
        let workspaceDir = workspacePath
        if !fm.fileExists(atPath: workspaceDir) {
            try fm.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)
        }

        // 修正目录权限（owner = 该用户）
        chownRecursive(path: "/Users/\(username)/.openclaw", username: username)
    }

    // MARK: - removeAgent

    /// 删除 agent：从 list 移除、清理 bindings、删除 workspace 和 sessions 目录
    static func removeAgent(username: String, agentId: String) throws {
        let configPath = "/Users/\(username)/.openclaw/openclaw.json"
        let fm = FileManager.default

        // 读取现有 JSON
        guard let data = fm.contents(atPath: configPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AgentManagerError.configReadFailed(configPath)
        }

        var agents = root["agents"] as? [String: Any] ?? [:]
        var list = agents["list"] as? [[String: Any]] ?? []
        let defaultId = agents["defaultId"] as? String ?? "main"

        // 不允许删除默认 agent
        if agentId == defaultId {
            throw AgentManagerError.cannotRemoveDefaultAgent
        }

        // 查找并移除
        let originalCount = list.count
        list.removeAll { ($0["id"] as? String) == agentId }
        if list.count == originalCount {
            throw AgentManagerError.agentNotFound(agentId)
        }

        agents["list"] = list

        // 从 bindings 数组中移除 agentId 匹配的条目
        if var bindings = agents["bindings"] as? [[String: Any]] {
            bindings.removeAll { ($0["agentId"] as? String) == agentId }
            agents["bindings"] = bindings
        }

        root["agents"] = agents

        // 写回 JSON
        try writeConfig(root, toPath: configPath, username: username)

        // 删除 workspace 目录
        let workspaceDir = "/Users/\(username)/.openclaw/workspace-\(agentId)"
        if fm.fileExists(atPath: workspaceDir) {
            try? fm.removeItem(atPath: workspaceDir)
            helperLog("[agent] 已删除 workspace 目录：\(workspaceDir)")
        }

        // 删除 sessions 目录
        let sessionsDir = "/Users/\(username)/.openclaw/agents/\(agentId)"
        if fm.fileExists(atPath: sessionsDir) {
            try? fm.removeItem(atPath: sessionsDir)
            helperLog("[agent] 已删除 sessions 目录：\(sessionsDir)")
        }
    }

    // MARK: - 内部工具

    /// 将 JSON 字典写回配置文件，修正所有权
    private static func writeConfig(_ root: [String: Any], toPath configPath: String, username: String) throws {
        let fm = FileManager.default
        let dir = (configPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let outData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try outData.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        // 修正所有权
        chownRecursive(path: dir, username: username)
    }

    /// 递归 chown 目录给指定用户
    private static func chownRecursive(path: String, username: String) {
        if (try? run("/usr/sbin/chown", args: ["-R", username, path])) == nil {
            helperLog("chown -R \(username) \(path) failed in AgentManager", level: .warn)
        }
    }
}

// MARK: - DTO（与 App 端 AgentProfile 结构一致，用于 JSON 编解码）

private struct AgentProfileDTO: Codable {
    let id: String
    var name: String
    var emoji: String
    var modelPrimary: String?
    var workspacePath: String?
    var isDefault: Bool
}
