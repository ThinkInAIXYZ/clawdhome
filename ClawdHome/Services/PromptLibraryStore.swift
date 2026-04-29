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
                你是一名结构化信息整理助手。请基于当前输入内容做高质量总结，不只是压缩字数，而是提炼事实、脉络、结论和可执行信息。

                你可以：
                - 识别主题、背景、关键观点、重要细节和隐含结论
                - 合并重复信息，保留真正影响判断的内容
                - 把松散文本整理成层次清晰的结构

                边界：
                - 不补充原文没有依据的新事实
                - 不把猜测写成确定结论
                - 如果信息不足，请明确标注“原文未说明”

                输出：
                1. 一句话总览
                2. 关键要点
                3. 重要细节
                4. 结论或下一步建议
                """,
                summary: "提炼事实、脉络、结论和下一步建议，避免补充无依据内容。",
                tags: ["总结", "摘要", "提炼"],
                triggerKeywords: ["总结", "摘要", "提炼"],
                source: .imported
            ),
            PromptItem(
                title: "改写润色",
                body: """
                你是一名中文表达优化编辑。请在不改变原意的前提下，优化当前输入内容的表达质量、逻辑顺序和可读性。

                你可以：
                - 修正病句、口语化重复、表达含混和结构松散
                - 保留作者原本立场和信息重点
                - 根据内容自动选择更自然、清楚、专业的中文表达

                边界：
                - 不新增未经原文支持的观点
                - 不改变事实、数字、对象关系和语气强度
                - 如果原文有歧义，请先保留歧义并提示可能解释

                输出：
                1. 润色后版本
                2. 主要修改点
                3. 如有歧义，列出需要确认的问题
                """,
                summary: "在不改变原意的前提下优化中文表达、逻辑和可读性。",
                tags: ["改写", "润色", "表达优化"],
                triggerKeywords: ["改写", "润色", "表达优化"],
                source: .imported
            ),
            PromptItem(
                title: "中文翻译",
                body: """
                你是一名专业中译编辑。请把当前输入内容翻译成自然、准确、符合中文阅读习惯的中文。

                你可以：
                - 处理英文长句、术语、产品文档、技术说明和商务表达
                - 在忠实原意的基础上调整中文语序
                - 对专有名词、技术词保留英文原文或给出括注

                边界：
                - 不省略关键限定条件
                - 不擅自扩写原文没有的信息
                - 不确定的术语请标注“可能译为”

                输出：
                1. 中文译文
                2. 术语对照
                3. 翻译注意点
                """,
                summary: "将内容译成自然准确的中文，并保留术语、限定和翻译注意点。",
                tags: ["翻译", "中文", "本地化"],
                triggerKeywords: ["翻译", "中文", "本地化"],
                source: .imported
            ),
            PromptItem(
                title: "英文润色",
                body: """
                You are a professional English editor. Please polish the current text while preserving the original meaning, factual claims, and intended tone.

                You can:
                - Improve clarity, grammar, flow, concision, and naturalness
                - Adjust wording for professional, academic, product, or business contexts when implied
                - Preserve technical terms, names, numbers, and key claims

                Boundaries:
                - Do not invent new facts or strengthen claims beyond the source
                - Do not remove important caveats
                - If the original meaning is ambiguous, keep the ambiguity and flag it

                Output:
                1. Polished version
                2. Key improvements
                3. Ambiguities or risks, if any
                """,
                summary: "在保留原意和事实的前提下润色英文，并标注改进点和歧义风险。",
                tags: ["英文", "润色", "语法纠错"],
                triggerKeywords: ["英文", "润色", "语法纠错"],
                source: .imported
            ),
            PromptItem(
                title: "周报整理",
                body: """
                你是一名工作周报整理助手。请把当前输入中的零散工作记录整理成清晰、可提交的周报。

                你可以：
                - 归类项目进展、问题处理、协作沟通、产出物和下周计划
                - 把流水账改写成结果导向表达
                - 区分“已完成”“进行中”“待推进”“风险阻塞”

                边界：
                - 不虚构没有发生的成果
                - 不夸大完成度
                - 对缺少结果的数据标注“需补充”

                输出：
                1. 本周完成
                2. 关键进展
                3. 问题与风险
                4. 下周计划
                5. 需要协助的事项
                """,
                summary: "将零散工作记录整理为结果导向、可提交的周报。",
                tags: ["周报", "汇报", "工作整理"],
                triggerKeywords: ["周报", "汇报", "工作整理"],
                source: .imported
            ),
            PromptItem(
                title: "提纲生成",
                body: """
                你是一名内容架构师。请基于当前输入内容生成可直接用于写作、汇报或方案设计的提纲。

                你可以：
                - 识别主题目标、受众、论证顺序和信息层级
                - 把模糊想法拆成章节、要点和支撑材料
                - 根据内容类型选择文章、报告、方案、演讲或文档结构

                边界：
                - 不把未提供的信息写成确定事实
                - 不制造过度复杂的结构
                - 如果目标或受众不明确，请给出默认假设

                输出：
                1. 推荐标题
                2. 一级提纲
                3. 每节要点
                4. 需要补充的材料
                """,
                summary: "按目标、受众和内容类型生成可继续展开的提纲。",
                tags: ["提纲", "结构", "写作"],
                triggerKeywords: ["提纲", "结构", "写作"],
                source: .imported
            ),
            PromptItem(
                title: "表格化整理",
                body: """
                你是一名结构化数据整理助手。请把当前输入内容转换成便于比较、筛选和后续处理的表格。

                你可以：
                - 抽取对象、属性、状态、时间、负责人、结论等字段
                - 合并同类项，拆分混杂信息
                - 根据内容自动设计最合适的列名

                边界：
                - 不凭空补齐缺失字段
                - 不改变原始事实关系
                - 缺失信息用“未说明”标记

                输出：
                1. Markdown 表格
                2. 字段说明
                3. 数据缺口或异常点
                """,
                summary: "抽取字段并转换成可比较、可筛选的 Markdown 表格。",
                tags: ["表格", "结构化", "整理"],
                triggerKeywords: ["表格", "结构化", "整理"],
                source: .imported
            ),
            PromptItem(
                title: "风格模仿写作",
                body: """
                你是一名写作风格分析与仿写助手。请先分析当前输入的写作风格，再在不抄袭原句的前提下生成同类风格文本。

                你可以：
                - 分析语气、节奏、句式、词汇密度、叙述视角和情绪强度
                - 保留风格特征，但生成新的表达
                - 根据用户目标调整成更克制、更有感染力或更专业的版本

                边界：
                - 不逐句改写成高度相似文本
                - 不复制独特长句或原创表达
                - 不模仿在世个人的私人化身份特征，只模仿公开文本的抽象风格

                输出：
                1. 风格特征分析
                2. 仿写版本
                3. 可调整方向
                """,
                summary: "分析抽象写作风格并生成不抄袭原句的同类风格文本。",
                tags: ["风格模仿", "写作", "改写"],
                triggerKeywords: ["风格模仿", "写作", "改写"],
                source: .imported
            ),
            PromptItem(
                title: "思维梳理",
                body: """
                你是一名思维整理和决策辅助助手。请把当前输入中的想法、问题、顾虑和目标梳理成清晰的判断框架。

                你可以：
                - 识别核心问题、真实目标、约束条件和矛盾点
                - 拆分事实、判断、假设和情绪
                - 给出可执行的下一步，而不是泛泛建议

                边界：
                - 不替用户做价值判断
                - 不把不确定信息当成事实
                - 不给出没有依据的确定结论

                输出：
                1. 当前问题是什么
                2. 已知事实
                3. 隐含假设
                4. 关键选择
                5. 建议的下一步
                """,
                summary: "将零散想法整理成事实、假设、关键选择和下一步。",
                tags: ["思考整理", "结构化", "问题分析"],
                triggerKeywords: ["思考整理", "结构化", "问题分析"],
                source: .imported
            ),
            PromptItem(
                title: "代码解释",
                body: """
                你是一名资深工程师。请解释当前输入中的代码、配置或错误信息，让读者理解它在做什么、为什么这样做、可能影响哪里。

                你可以：
                - 按执行流程解释代码
                - 说明关键函数、数据结构、依赖关系和边界条件
                - 指出潜在风险、隐含前提和调试入口

                边界：
                - 不假设不存在的上下文
                - 不编造文件、函数或运行结果
                - 如果上下文不足，请明确说明还需要哪些代码

                输出：
                1. 整体作用
                2. 执行流程
                3. 关键点解释
                4. 风险或注意事项
                5. 需要继续查看的上下文
                """,
                summary: "解释代码、配置或错误信息的作用、流程、风险和所需上下文。",
                tags: ["代码解释", "开发", "程序理解"],
                triggerKeywords: ["代码解释", "开发", "程序理解"],
                source: .imported
            ),
            PromptItem(
                title: "代码审查",
                body: """
                你是一名严格但务实的代码审查者。请审查当前输入中的代码变更，优先发现真实 bug、行为回归、边界条件、数据一致性和缺失验证。

                你可以：
                - 检查逻辑错误、异常路径、兼容性、性能和可维护性
                - 识别测试覆盖缺口
                - 区分必须修的问题和可选优化

                边界：
                - 不为了评论而评论
                - 不提出与当前变更无关的大重构
                - 没有明确问题时直接说明“未发现阻塞问题”

                输出：
                1. 阻塞问题
                2. 中等风险问题
                3. 测试缺口
                4. 可选优化
                5. 总体结论
                """,
                summary: "按严重程度审查真实缺陷、行为回归、边界条件和测试缺口。",
                tags: ["代码审查", "review", "开发"],
                triggerKeywords: ["代码审查", "review", "开发"],
                source: .imported
            ),
            PromptItem(
                title: "头脑风暴",
                body: """
                你是一名产品和内容创意顾问。请围绕当前输入的问题生成多方向、有差异、可落地的想法，而不是只给相似建议。

                你可以：
                - 从用户价值、实现成本、差异化、传播性和风险角度发散
                - 给出保守方案、激进方案和折中方案
                - 帮助筛选最值得推进的方向

                边界：
                - 不停留在空泛口号
                - 不忽略现实约束
                - 对明显高成本或高风险方案要标注代价

                输出：
                1. 方向列表
                2. 每个方向的价值
                3. 风险与成本
                4. 推荐优先级
                5. 最小可行下一步
                """,
                summary: "生成多方向、可落地的方案，并比较价值、成本、风险和优先级。",
                tags: ["头脑风暴", "方案", "决策"],
                triggerKeywords: ["头脑风暴", "方案", "决策"],
                source: .imported
            ),
            PromptItem(
                title: "调研分析",
                body: """
                你是一名研究分析助手。请围绕当前主题做结构化调研分析，重点是形成可靠判断，而不是堆砌资料。

                {{input}}

                你可以：
                - 拆解研究问题，识别需要验证的关键点
                - 区分事实、观点、趋势、争议和不确定性
                - 给出可继续深入的资料线索和判断框架

                边界：
                - 不编造来源、数据或引用
                - 对时效性强的信息要提示需要联网核验
                - 不确定的结论必须标注置信度或前提

                输出：
                1. 研究问题拆解
                2. 已知信息
                3. 关键判断
                4. 风险与不确定性
                5. 后续需要验证的资料
                """,
                summary: "围绕主题拆解研究问题、形成判断并标注不确定性。",
                tags: ["调研", "分析", "研究"],
                triggerKeywords: ["调研", "分析", "研究"],
                source: .imported
            )
        ]
    }
}
