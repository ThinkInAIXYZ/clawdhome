// ClawdHomeHelper/HelperImpl+Agent.swift
// Agent 管理 XPC 处理：listAgents / createAgent / removeAgent

import Foundation

extension ClawdHomeHelperImpl {

    func listAgents(username: String,
                    withReply reply: @escaping (String?, String?) -> Void) {
        helperLog("[agent] listAgents @\(username)")
        do {
            let json = try AgentManager.listAgents(username: username)
            reply(json, nil)
        } catch {
            helperLog("[agent] listAgents 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(nil, error.localizedDescription)
        }
    }

    func createAgent(username: String, configJSON: String,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[agent] createAgent @\(username)")
        do {
            try AgentManager.createAgent(username: username, configJSON: configJSON)
            helperLog("[agent] createAgent 成功 @\(username)")
            reply(true, nil)
        } catch {
            helperLog("[agent] createAgent 失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func removeAgent(username: String, agentId: String,
                     withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("[agent] removeAgent @\(username) agentId=\(agentId)")
        do {
            try AgentManager.removeAgent(username: username, agentId: agentId)
            helperLog("[agent] removeAgent 成功 @\(username) agentId=\(agentId)")
            reply(true, nil)
        } catch {
            helperLog("[agent] removeAgent 失败 @\(username) agentId=\(agentId): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }
}
