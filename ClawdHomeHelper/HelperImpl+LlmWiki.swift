import Foundation

extension ClawdHomeHelperImpl {
    func setupLlmWikiNotes(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("LLM Wiki notes 初始化 @\(username)")
        do {
            try LlmWikiManager.setupLlmWikiNotes(username: username)
            reply(true, nil)
        } catch {
            helperLog("LLM Wiki notes 初始化失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func repairLlmWikiProject(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("LLM Wiki project 修复")
        do {
            try LlmWikiManager.repairProject()
            reply(true, nil)
        } catch {
            helperLog("LLM Wiki project 修复失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func repairLlmWikiMapping(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("LLM Wiki mapping 修复 @\(username)")
        do {
            try LlmWikiManager.repairMapping(username: username)
            reply(true, nil)
        } catch {
            helperLog("LLM Wiki mapping 修复失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func repairLlmWikiRuntimePermissions(withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("LLM Wiki runtime 权限修复")
        do {
            try LlmWikiManager.repairRuntimePermissions()
            reply(true, nil)
        } catch {
            helperLog("LLM Wiki runtime 权限修复失败: \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func repairBundledLlmWikiSkill(username: String, withReply reply: @escaping (Bool, String?) -> Void) {
        helperLog("LLM Wiki skill 修复 @\(username)")
        do {
            try LlmWikiManager.installBundledSkill(username: username)
            reply(true, nil)
        } catch {
            helperLog("LLM Wiki skill 修复失败 @\(username): \(error.localizedDescription)", level: .error)
            reply(false, error.localizedDescription)
        }
    }

    func auditLlmWikiState(withReply reply: @escaping (String) -> Void) {
        let audit = LlmWikiManager.auditGlobalState()
        let data = (try? JSONEncoder().encode(audit)) ?? Data("{}".utf8)
        reply(String(data: data, encoding: .utf8) ?? "{}")
    }

    func auditLlmWikiUserState(username: String, withReply reply: @escaping (String) -> Void) {
        let audit = LlmWikiManager.auditUserState(username: username)
        let data = (try? JSONEncoder().encode(audit)) ?? Data("{}".utf8)
        reply(String(data: data, encoding: .utf8) ?? "{}")
    }
}
