import Foundation

enum LLMWikiPaths {
    static let sharedRoot = "/Users/Shared/ClawdHome"
    static let sharedGroup = "clawdhome-all"
    static let hostBundleIdentifier = "ai.clawdhome.mac"
    static let legacyBundleIdentifier = "com.llmwiki.app"
    static let appStateDirectoryName = "EmbeddedLLMWiki"
    static let notesDirectoryName = "llmwiki-notes"
    static let skillName = "clawdhome-llmwiki"
    static let sharedProjectName = "ClawdHome Wiki"
    static let embeddedResourceDirectoryName = "EmbeddedLLMWiki"
    static let frontendResourceDirectoryName = "wiki"
    static let runtimeExecutableName = "llm-wiki-runtime"

    static let projectRoot = "\(sharedRoot)/llmwiki/project"
    static let runtimeRoot = "\(sharedRoot)/llmwiki/run"
    static let socketPath = "\(runtimeRoot)/knowledge-base-api.sock"
    static let heartbeatSocketPath = "\(runtimeRoot)/knowledge-base-heartbeat.sock"
    static let metadataPath = "\(runtimeRoot)/knowledge-base-api.json"
    static let shrimpsSourcesRoot = "\(projectRoot)/raw/sources/shrimps"

    static func vaultPath(for username: String) -> String {
        "\(sharedRoot)/vaults/\(username)"
    }

    static func notesPath(for username: String) -> String {
        "\(vaultPath(for: username))/\(notesDirectoryName)"
    }

    static func notesEntryPath(for username: String) -> String {
        "/Users/\(username)/clawdhome_shared/private/\(notesDirectoryName)"
    }

    static func projectSymlinkPath(for username: String) -> String {
        "\(shrimpsSourcesRoot)/\(username)"
    }

    static func workspaceSkillPath(for username: String) -> String {
        "/Users/\(username)/.openclaw/workspace/skills/\(skillName)"
    }

    static func appStatePath(for adminUsername: String) -> String {
        "/Users/\(adminUsername)/Library/Application Support/\(hostBundleIdentifier)/\(appStateDirectoryName)/app-state.json"
    }

    static func legacyAppStatePath(for adminUsername: String) -> String {
        "/Users/\(adminUsername)/Library/Application Support/\(legacyBundleIdentifier)/app-state.json"
    }
}

struct LLMWikiGlobalAudit: Codable {
    let projectPath: String
    let runtimePath: String
    let socketPath: String
    let heartbeatSocketPath: String
    let metadataPath: String
    let projectExists: Bool
    let projectStructureComplete: Bool
    let wikiExists: Bool
    let rawSourcesExists: Bool
    let shrimpsSourcesExists: Bool
    let runtimeExists: Bool
    let socketExists: Bool
    let heartbeatExists: Bool
    let metadataExists: Bool
    let runtimeOwner: String?
    let runtimeGroup: String?
    let runtimeMode: String?
    let metadataSecurityMode: String?
    let metadataSecurityGroup: String?
}

struct LLMWikiUserAudit: Codable, Identifiable {
    let username: String
    let notesPath: String
    let notesEntryPath: String
    let projectSymlinkPath: String
    let workspaceSkillPath: String
    let notesExists: Bool
    let notesOwner: String?
    let notesGroup: String?
    let notesMode: String?
    let projectSymlinkExists: Bool
    let projectSymlinkValid: Bool
    let workspaceSkillExists: Bool

    var id: String { username }
}

enum LLMWikiWorkspaceGuidance {
    static let sharedFolderMarker = "## 共享文件夹"
    static let llmWikiNotesMarker = "## LLM Wiki 笔记目录"
    static let llmWikiSkillMarker = "## ClawdHome LLM Wiki Skill"

    static let sharedFolderSection = """
    ## 共享文件夹

    你有两个文件共享空间，可通过以下路径访问：

    ### 专属文件夹（私有）
    - 路径：`~/clawdhome_shared/private/`
    - 权限：仅你和管理员可访问，其他虾不可见
    - 用途：所有工作产出物、生成的文件、导出的数据都应优先存放在此目录

    ### 公共文件夹（共享）
    - 路径：`~/clawdhome_shared/public/`
    - 权限：所有虾和管理员共享
    - 用途：读写通用资源、共享文件、公共数据集

    ### 使用规范
    - 当用户要求保存文件、导出结果、生成报告时，写入 `~/clawdhome_shared/private/`
    - 需要引用公共资源时，从 `~/clawdhome_shared/public/` 读取
    - 不要将敏感数据写入公共文件夹
    """

    static let llmWikiNotesSection = """
    ## LLM Wiki 笔记目录

    - 路径：`~/clawdhome_shared/private/llmwiki-notes/`
    - 权限：仅你和管理员可访问，其他虾不可见
    - 用途：如果希望笔记被 ClawdHome 管理的 LLM Wiki 直接看到并可检索，正式笔记优先写入这里
    - 建议：需要沉淀为可搜索知识时，把正式笔记放到这个目录，而不是只放在普通私有目录
    """

    static let llmWikiSkillSection = """
    ## ClawdHome LLM Wiki Skill

    系统已为你注入 `clawdhome-llmwiki` workspace skill。它可以直接查询 ClawdHome 管理的 LLM Wiki 搜索接口。

    ### 可用能力
    - `save_note_to_kb`：把笔记、总结、知识片段、备忘直接写入 `~/clawdhome_shared/private/llmwiki-notes/`
    - `search_knowledge_base`：搜索整个 LLM Wiki 知识库
    - `get_knowledge_document`：按文件拉取正文和相关内容
    - `note_writing_guide`：获取更适合知识库检索和沉淀的笔记写法

    ### 何时使用
    - 当用户提到“写笔记”“写总结”“写知识库”“存文本”“记住这段内容”“帮我保存”“沉淀一下”时，默认先整理成 Markdown，再调用 `save_note_to_kb`
    - 保存完成后，把生成的文件路径明确返回给用户
    - 当用户要求查询历史笔记、知识沉淀、LLM Wiki 知识库时，优先调用 `search_knowledge_base`
    - 当搜索结果里需要查看某篇笔记或知识文件的全文、摘要、相关内容时，调用 `get_knowledge_document`
    - 当用户要求“怎么写一篇好的知识笔记”或希望输出更适合后续知识库检索的笔记时，调用 `note_writing_guide`

    ### 约束
    - 如果希望某篇笔记能被该 skill 检索到，需要先把笔记写入 `~/clawdhome_shared/private/llmwiki-notes/`
    - 不要只在对话中“记住”，需要持久化时必须落盘到这个目录
    """

    static let defaultToolsContent = [
        sharedFolderSection,
        llmWikiNotesSection,
        llmWikiSkillSection,
    ].joined(separator: "\n\n")

    static func mergedToolsContent(existing: String) -> String? {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultToolsContent
        }

        var merged = trimmed
        merged = upsertSection(in: merged, heading: sharedFolderMarker, section: sharedFolderSection)
        merged = upsertSection(in: merged, heading: llmWikiSkillMarker, section: llmWikiSkillSection)
        merged = upsertSection(in: merged, heading: llmWikiNotesMarker, section: llmWikiNotesSection)

        return merged == trimmed ? nil : merged
    }

    private static func upsertSection(in content: String, heading: String, section: String) -> String {
        guard let headingRange = content.range(of: heading) else {
            return content + "\n\n" + section
        }

        let searchStart = headingRange.lowerBound
        let nextHeadingRange = content.range(of: "\n## ", range: headingRange.upperBound..<content.endIndex)
        let replaceRange = searchStart..<(nextHeadingRange?.lowerBound ?? content.endIndex)
        return content.replacingCharacters(in: replaceRange, with: section)
    }
}
