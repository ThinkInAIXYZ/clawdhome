import Foundation
import Observation

struct PromptLibrarySettings: Codable, Equatable {
    enum FloatingBubbleEdge: String, Codable, Equatable {
        case leading
        case trailing
    }

    var defaultInsertionMode: PromptInsertionMode = .append
    var proactiveSuggestionsEnabled = true
    var suggestionThreshold = PromptMemorySearch.suggestionThreshold
    var floatingBubbleEnabled = true
    var floatingBubbleEdge: FloatingBubbleEdge = .trailing
    var floatingBubbleYRatio = 0.52
    var floatingPanelPinned = false
    var defaultPromptsSeeded = false
    var exportPublicPromptsEnabled = false

    private enum CodingKeys: String, CodingKey {
        case defaultInsertionMode
        case proactiveSuggestionsEnabled
        case suggestionThreshold
        case floatingBubbleEnabled
        case floatingBubbleEdge
        case floatingBubbleYRatio
        case floatingPanelPinned
        case defaultPromptsSeeded
        case exportPublicPromptsEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultInsertionMode = try container.decodeIfPresent(PromptInsertionMode.self, forKey: .defaultInsertionMode) ?? .append
        proactiveSuggestionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .proactiveSuggestionsEnabled) ?? true
        suggestionThreshold = try container.decodeIfPresent(Double.self, forKey: .suggestionThreshold) ?? PromptMemorySearch.suggestionThreshold
        floatingBubbleEnabled = try container.decodeIfPresent(Bool.self, forKey: .floatingBubbleEnabled) ?? true
        floatingBubbleEdge = try container.decodeIfPresent(FloatingBubbleEdge.self, forKey: .floatingBubbleEdge) ?? .trailing
        floatingBubbleYRatio = try container.decodeIfPresent(Double.self, forKey: .floatingBubbleYRatio) ?? 0.52
        floatingPanelPinned = try container.decodeIfPresent(Bool.self, forKey: .floatingPanelPinned) ?? false
        defaultPromptsSeeded = try container.decodeIfPresent(Bool.self, forKey: .defaultPromptsSeeded) ?? false
        exportPublicPromptsEnabled = try container.decodeIfPresent(Bool.self, forKey: .exportPublicPromptsEnabled) ?? false
    }
}

private struct PromptLibrarySnapshot: Codable {
    var prompts: [PromptItem]
    var groups: [PromptGroup]
    var usage: [PromptUsageEvent]
    var settings: PromptLibrarySettings
    var quickNoteText: String

    private enum CodingKeys: String, CodingKey {
        case prompts
        case groups
        case usage
        case settings
        case quickNoteText
    }

    init(prompts: [PromptItem], groups: [PromptGroup], usage: [PromptUsageEvent], settings: PromptLibrarySettings, quickNoteText: String) {
        self.prompts = prompts
        self.groups = groups
        self.usage = usage
        self.settings = settings
        self.quickNoteText = quickNoteText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try container.decodeIfPresent([PromptItem].self, forKey: .prompts) ?? []
        groups = try container.decodeIfPresent([PromptGroup].self, forKey: .groups) ?? []
        usage = try container.decodeIfPresent([PromptUsageEvent].self, forKey: .usage) ?? []
        settings = try container.decodeIfPresent(PromptLibrarySettings.self, forKey: .settings) ?? PromptLibrarySettings()
        quickNoteText = try container.decodeIfPresent(String.self, forKey: .quickNoteText) ?? ""
    }
}

private struct PromptIgnoredSuggestion: Codable {
    var key: String
    var count: Int
    var mutedUntil: Date?
    var updatedAt: Date
}

private struct PromptPublicExport: Codable {
    var exportedAt: Date
    var prompts: [PromptItem]
}

@MainActor
@Observable
final class PromptLibraryStore {
    private(set) var prompts: [PromptItem] = []
    private(set) var groups: [PromptGroup] = []
    private(set) var usage: [PromptUsageEvent] = []
    private(set) var error: String?
    private(set) var isLoaded = false
    var settings = PromptLibrarySettings()
    var searchText = ""
    var quickNoteText = ""

    private var indexes: [UUID: PromptSearchIndex] = [:]
    private var ignoredSuggestions: [String: PromptIgnoredSuggestion] = [:]
    private let fileManager: FileManager
    private let libraryDirectoryOverride: URL?

    init(fileManager: FileManager = .default, libraryDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.libraryDirectoryOverride = libraryDirectory
    }

    var filteredPrompts: [PromptSearchResult] {
        PromptMemorySearch.search(
            query: searchText,
            items: prompts,
            indexes: indexes,
            minimumScore: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 0.01,
            limit: 200
        )
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        load()
    }

    func load() {
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let snapshotURL = promptsURL
            if fileManager.fileExists(atPath: snapshotURL.path) {
                let data = try Data(contentsOf: snapshotURL)
                let snapshot = try decoder.decode(PromptLibrarySnapshot.self, from: data)
                prompts = snapshot.prompts
                groups = snapshot.groups
                usage = snapshot.usage
                settings = snapshot.settings
                quickNoteText = snapshot.quickNoteText
            }
            if fileManager.fileExists(atPath: ignoredURL.path) {
                let data = try Data(contentsOf: ignoredURL)
                ignoredSuggestions = try decoder.decode([String: PromptIgnoredSuggestion].self, from: data)
            }
            seedDefaultPromptsIfNeeded()
            rebuildIndex()
            error = nil
            isLoaded = true
        } catch {
            backupCorruptFileIfNeeded(promptsURL)
            self.error = error.localizedDescription
            prompts = []
            groups = []
            usage = []
            indexes = [:]
            isLoaded = true
        }
    }

    func savePrompt(_ prompt: PromptItem) {
        loadIfNeeded()
        var next = prompt
        next.updatedAt = Date()
        if let index = prompts.firstIndex(where: { $0.id == next.id }) {
            prompts[index] = next
        } else {
            prompts.append(next)
        }
        rebuildIndex()
        save()
    }

    func createPromptFromInput(title: String, body: String, tagsText: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedBody.isEmpty else { return }
        savePrompt(PromptItem(
            title: trimmedTitle,
            body: trimmedBody,
            summary: String(trimmedBody.prefix(160)),
            tags: parseList(tagsText),
            triggerKeywords: parseList(tagsText),
            insertionModeDefault: settings.defaultInsertionMode,
            source: .savedFromInput
        ))
    }

    func deletePrompt(id: UUID) {
        loadIfNeeded()
        prompts.removeAll { $0.id == id }
        indexes.removeValue(forKey: id)
        save()
    }

    func search(query: String, limit: Int = 20) -> [PromptSearchResult] {
        loadIfNeeded()
        return PromptMemorySearch.search(query: query, items: prompts, indexes: indexes, limit: limit)
    }

    func suggestion(for query: String) -> PromptSearchResult? {
        loadIfNeeded()
        guard settings.proactiveSuggestionsEnabled else { return nil }
        let ignored = Set(ignoredSuggestions.values.compactMap { item -> String? in
            if let mutedUntil = item.mutedUntil, mutedUntil > Date() { return item.key }
            return nil
        })
        return PromptMemorySearch.search(
            query: query,
            items: prompts,
            indexes: indexes,
            minimumScore: settings.suggestionThreshold,
            limit: 5
        )
        .first { !ignored.contains(PromptMemorySearch.ignoreKey(promptId: $0.item.id, query: query)) }
    }

    func suggestions(for query: String, limit: Int = 3) -> [PromptSearchResult] {
        loadIfNeeded()
        guard settings.proactiveSuggestionsEnabled else { return [] }
        let ignored = Set(ignoredSuggestions.values.compactMap { item -> String? in
            if let mutedUntil = item.mutedUntil, mutedUntil > Date() { return item.key }
            return nil
        })
        let minimumScore = max(PromptMemorySearch.panelThreshold, min(settings.suggestionThreshold, 0.55))
        return PromptMemorySearch.search(
            query: query,
            items: prompts,
            indexes: indexes,
            minimumScore: minimumScore,
            limit: max(limit * 2, limit)
        )
        .filter { !ignored.contains(PromptMemorySearch.ignoreKey(promptId: $0.item.id, query: query)) }
        .prefix(limit)
        .map { $0 }
    }

    func renderedBody(for prompt: PromptItem, values: [String: String]) -> String {
        var text = prompt.body
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return text
    }

    func variables(in prompt: PromptItem) -> [String] {
        let pattern = #"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = prompt.body as NSString
        let matches = regex.matches(in: prompt.body, range: NSRange(location: 0, length: nsText.length))
        var seen = Set<String>()
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let key = nsText.substring(with: match.range(at: 1))
            return seen.insert(key).inserted ? key : nil
        }
    }

    func recordUse(prompt: PromptItem, action: PromptUsageAction, query: String, shrimpUsername: String?) {
        loadIfNeeded()
        usage.insert(PromptUsageEvent(
            id: UUID(),
            promptId: prompt.id,
            action: action,
            queryHash: PromptMemorySearch.queryHash(query),
            shrimpUsername: shrimpUsername,
            createdAt: Date()
        ), at: 0)
        usage = Array(usage.prefix(1_000))
        if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[index].useCount += 1
            prompts[index].lastUsedAt = Date()
        }
        rebuildIndex()
        save()
    }

    func dismissSuggestion(prompt: PromptItem, query: String) {
        loadIfNeeded()
        let key = PromptMemorySearch.ignoreKey(promptId: prompt.id, query: query)
        var item = ignoredSuggestions[key] ?? PromptIgnoredSuggestion(key: key, count: 0, mutedUntil: nil, updatedAt: Date())
        item.count += 1
        item.updatedAt = Date()
        if item.count >= 3 {
            item.mutedUntil = Calendar.current.date(byAdding: .day, value: 30, to: Date())
        }
        ignoredSuggestions[key] = item
        saveIgnored()
        recordUse(prompt: prompt, action: .dismissed, query: query, shrimpUsername: nil)
    }

    func updateSettings(_ transform: (inout PromptLibrarySettings) -> Void) {
        loadIfNeeded()
        transform(&settings)
        save()
    }

    func updateQuickNote(_ text: String) {
        loadIfNeeded()
        guard quickNoteText != text else { return }
        quickNoteText = text
        save()
    }

    func exportPublicPrompts() {
        loadIfNeeded()
        let exportable = prompts.filter { !$0.sensitive && $0.enabled }
        do {
            try fileManager.createDirectory(at: publicExportDirectory, withIntermediateDirectories: true)
            let export = PromptPublicExport(exportedAt: Date(), prompts: exportable)
            let data = try encoder.encode(export)
            try data.write(to: publicExportDirectory.appendingPathComponent("prompts.json"), options: [.atomic])

            let markdown = exportable.map { prompt in
                let tags = prompt.tags.isEmpty ? "" : "\nTags: \(prompt.tags.joined(separator: ", "))"
                return "# \(prompt.title)\(tags)\n\n\(prompt.body)\n"
            }.joined(separator: "\n---\n\n")
            try markdown.data(using: .utf8)?.write(
                to: publicExportDirectory.appendingPathComponent("prompts.md"),
                options: [.atomic]
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rebuildIndex() {
        indexes = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, PromptMemorySearch.makeIndex(for: $0)) })
    }

    private func seedDefaultPromptsIfNeeded() {
        let existingTitles = Set(prompts.map { PromptMemorySearch.normalize($0.title) })
        let missingDefaults = Self.defaultPromptSeed.filter { !existingTitles.contains(PromptMemorySearch.normalize($0.title)) }

        guard !missingDefaults.isEmpty || !settings.defaultPromptsSeeded else { return }

        if prompts.isEmpty {
            prompts = Self.defaultPromptSeed
        } else if !missingDefaults.isEmpty {
            prompts.append(contentsOf: missingDefaults)
        }

        settings.defaultPromptsSeeded = true
        rebuildIndex()
        save()
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let snapshot = PromptLibrarySnapshot(
                prompts: prompts,
                groups: groups,
                usage: usage,
                settings: settings,
                quickNoteText: quickNoteText
            )
            try encoder.encode(snapshot).write(to: promptsURL, options: [.atomic])
            try encoder.encode(Array(indexes.values)).write(to: indexURL, options: [.atomic])
            saveIgnored()
            if settings.exportPublicPromptsEnabled {
                exportPublicPrompts()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveIgnored() {
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            try encoder.encode(ignoredSuggestions).write(to: ignoredURL, options: [.atomic])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parseList(_ text: String) -> [String] {
        text
            .split { $0 == "," || $0 == "，" || $0 == "#" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func backupCorruptFileIfNeeded(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("prompts.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? fileManager.moveItem(at: url, to: backup)
    }

    private var libraryDirectory: URL {
        if let libraryDirectoryOverride { return libraryDirectoryOverride }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ClawdHome/PromptLibrary", isDirectory: true)
    }

    private var promptsURL: URL { libraryDirectory.appendingPathComponent("prompts.json") }
    private var indexURL: URL { libraryDirectory.appendingPathComponent("index.json") }
    private var ignoredURL: URL { libraryDirectory.appendingPathComponent("ignored-suggestions.json") }
    private var publicExportDirectory: URL { URL(fileURLWithPath: "/Users/Shared/ClawdHome/public/prompts", isDirectory: true) }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var defaultPromptSeed: [PromptItem] {
        [
            PromptItem(
                title: "总结归纳",
                body: """
                请将以下内容提炼为结构化摘要。

                要求：
                1. 先给一句话结论
                2. 再列出 3-5 个关键点
                3. 最后列出待跟进事项
                4. 表达简洁，不重复原文
                """,
                summary: "将内容提炼为结构化摘要，输出结论、关键点和待跟进事项。",
                tags: ["总结", "摘要", "提炼"],
                triggerKeywords: ["总结", "摘要", "提炼"],
                source: .imported
            ),
            PromptItem(
                title: "改写润色",
                body: """
                请在不改变原意的前提下，重写下面内容。

                要求：
                1. 表达更清晰
                2. 语言更自然
                3. 去掉重复和空话
                4. 保持信息完整
                """,
                summary: "重写内容，使表达更清晰、自然、完整。",
                tags: ["改写", "润色", "表达优化"],
                triggerKeywords: ["改写", "润色", "表达优化"],
                source: .imported
            ),
            PromptItem(
                title: "中文翻译",
                body: """
                请将以下内容翻译成自然、流畅、地道的中文。

                要求：
                1. 不要直译腔
                2. 保留原文信息和语气
                3. 专业术语优先使用常见中文表达
                """,
                summary: "将内容翻译成自然、流畅、地道的中文。",
                tags: ["翻译", "中文", "本地化"],
                triggerKeywords: ["翻译", "中文", "本地化"],
                source: .imported
            ),
            PromptItem(
                title: "英文润色",
                body: """
                请检查并修正下面内容中的英文语法、用词和表达问题。

                要求：
                1. 给出润色后的版本
                2. 保持原意
                3. 表达自然、专业、简洁
                """,
                summary: "修正英文语法和表达问题，给出更自然专业的版本。",
                tags: ["英文", "润色", "语法纠错"],
                triggerKeywords: ["英文", "润色", "语法纠错"],
                source: .imported
            ),
            PromptItem(
                title: "周报整理",
                body: """
                请将以下工作内容整理为一份周报。

                要求：
                1. 按“本周完成 / 当前进展 / 风险问题 / 下周计划”组织
                2. 突出结果和产出
                3. 使用简洁、可汇报的表达
                4. 输出为 Markdown 列表
                """,
                summary: "将工作内容整理为可直接汇报的周报。",
                tags: ["周报", "汇报", "工作整理"],
                triggerKeywords: ["周报", "汇报", "工作整理"],
                source: .imported
            ),
            PromptItem(
                title: "提纲生成",
                body: """
                请根据以下主题生成一个清晰、可展开的提纲。

                要求：
                1. 结构分层明确
                2. 标题简洁
                3. 逻辑完整
                4. 适合后续继续写成正文
                """,
                summary: "根据主题生成清晰、可展开的提纲。",
                tags: ["提纲", "结构", "写作"],
                triggerKeywords: ["提纲", "结构", "写作"],
                source: .imported
            ),
            PromptItem(
                title: "表格化整理",
                body: """
                请将以下信息整理成表格。

                要求：
                1. 字段清晰
                2. 便于对比
                3. 不遗漏关键信息
                4. 输出为 Markdown 表格
                """,
                summary: "把信息整理成便于对比和复制的表格。",
                tags: ["表格", "结构化", "整理"],
                triggerKeywords: ["表格", "结构化", "整理"],
                source: .imported
            ),
            PromptItem(
                title: "风格模仿写作",
                body: """
                请先分析下面文本的写作风格，再按相同风格重写同主题内容。

                要求：
                1. 保留原意
                2. 模仿语气、节奏和表达特点
                3. 不要生硬复制原句
                """,
                summary: "分析写作风格后，按相同风格重写内容。",
                tags: ["风格模仿", "写作", "改写"],
                triggerKeywords: ["风格模仿", "写作", "改写"],
                source: .imported
            ),
            PromptItem(
                title: "思维梳理",
                body: """
                请把下面这段想法重新整理成清晰结构。

                输出结构：
                1. 目标
                2. 问题
                3. 假设
                4. 可行方案
                5. 下一步

                要求：
                表达清楚，避免发散和重复。
                """,
                summary: "将零散想法整理为目标、问题、方案和下一步。",
                tags: ["思考整理", "结构化", "问题分析"],
                triggerKeywords: ["思考整理", "结构化", "问题分析"],
                source: .imported
            ),
            PromptItem(
                title: "代码解释",
                body: """
                请解释这段代码。

                要求：
                1. 说明整体作用
                2. 说明核心逻辑
                3. 说明输入输出
                4. 说明边界条件和潜在风险
                5. 用清晰、面向工程的语言回答
                """,
                summary: "解释代码作用、核心逻辑、输入输出和风险。",
                tags: ["代码解释", "开发", "程序理解"],
                triggerKeywords: ["代码解释", "开发", "程序理解"],
                source: .imported
            ),
            PromptItem(
                title: "代码审查",
                body: """
                请从以下角度审查这段代码：

                1. 正确性
                2. 边界条件
                3. 可维护性
                4. 性能风险
                5. 测试覆盖

                请按严重程度列出问题，并给出修改建议。
                """,
                summary: "从正确性、边界条件、可维护性、性能和测试覆盖角度审查代码。",
                tags: ["代码审查", "review", "开发"],
                triggerKeywords: ["代码审查", "review", "开发"],
                source: .imported
            ),
            PromptItem(
                title: "头脑风暴",
                body: """
                请围绕这个问题给出多种可行方案。

                要求：
                1. 每个方案说明核心思路
                2. 分析优点和缺点
                3. 说明适用场景
                4. 最后给出推荐顺序
                """,
                summary: "围绕问题给出多种方案，并分析优缺点和适用场景。",
                tags: ["头脑风暴", "方案", "决策"],
                triggerKeywords: ["头脑风暴", "方案", "决策"],
                source: .imported
            ),
            PromptItem(
                title: "调研分析",
                body: """
                请围绕这个主题开展一份调研：
                {{input}}

                输出要求：
                1. 先概述这个主题是什么，以及为什么值得关注
                2. 梳理当前主流做法、代表产品或代表观点
                3. 分析优点、局限和适用场景
                4. 提炼关键结论与建议
                5. 若信息不足，请明确指出还需要补充哪些信息
                """,
                summary: "围绕一个主题做结构化调研分析，仅需一个输入。",
                tags: ["调研", "分析", "研究"],
                triggerKeywords: ["调研", "分析", "研究"],
                source: .imported
            )
        ]
    }
}
