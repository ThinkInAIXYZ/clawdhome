import Foundation

enum PromptInsertionMode: String, Codable, CaseIterable, Identifiable {
    case append
    case replace

    var id: String { rawValue }
}

enum VariablePolicy: String, Codable, CaseIterable {
    case manualConfirm
}

enum PromptScope: Codable, Equatable {
    case clawdHome
    case specificShrimp(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case username
    }

    private enum Kind: String, Codable {
        case clawdHome
        case specificShrimp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .clawdHome:
            self = .clawdHome
        case .specificShrimp:
            self = .specificShrimp(try container.decode(String.self, forKey: .username))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clawdHome:
            try container.encode(Kind.clawdHome, forKey: .kind)
        case .specificShrimp(let username):
            try container.encode(Kind.specificShrimp, forKey: .kind)
            try container.encode(username, forKey: .username)
        }
    }
}

enum PromptSource: String, Codable {
    case userCreated
    case imported
    case savedFromInput
}

enum PromptUsageAction: String, Codable {
    case append
    case replace
    case copy
    case dismissed
}

struct PromptItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var summary: String
    var tags: [String]
    var groupId: UUID?
    var triggerKeywords: [String]
    var insertionModeDefault: PromptInsertionMode
    var variablePolicy: VariablePolicy
    var scope: PromptScope
    var enabled: Bool
    var pinned: Bool
    var sensitive: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var source: PromptSource

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        summary: String = "",
        tags: [String] = [],
        groupId: UUID? = nil,
        triggerKeywords: [String] = [],
        insertionModeDefault: PromptInsertionMode = .append,
        variablePolicy: VariablePolicy = .manualConfirm,
        scope: PromptScope = .clawdHome,
        enabled: Bool = true,
        pinned: Bool = false,
        sensitive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        source: PromptSource = .userCreated
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.summary = summary
        self.tags = tags
        self.groupId = groupId
        self.triggerKeywords = triggerKeywords
        self.insertionModeDefault = insertionModeDefault
        self.variablePolicy = variablePolicy
        self.scope = scope
        self.enabled = enabled
        self.pinned = pinned
        self.sensitive = sensitive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.source = source
    }
}

struct PromptGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorName: String?
    var sortOrder: Int
}

struct PromptSearchIndex: Codable, Equatable {
    var promptId: UUID
    var normalizedTitle: String
    var normalizedTags: [String]
    var normalizedKeywords: [String]
    var normalizedSummary: String
    var normalizedBodyPreview: String
    var updatedAt: Date
}

struct PromptUsageEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let promptId: UUID
    let action: PromptUsageAction
    let queryHash: String
    let shrimpUsername: String?
    let createdAt: Date
}

struct PromptSearchResult: Identifiable, Equatable {
    let item: PromptItem
    let score: Double
    let matchedFields: [String]

    var id: UUID { item.id }
}

enum PromptMemorySearch {
    static let suggestionThreshold = 0.78
    static let panelThreshold = 0.45

    static func makeIndex(for item: PromptItem) -> PromptSearchIndex {
        PromptSearchIndex(
            promptId: item.id,
            normalizedTitle: normalize(item.title),
            normalizedTags: item.tags.map(normalize),
            normalizedKeywords: item.triggerKeywords.map(normalize),
            normalizedSummary: normalize(item.summary),
            normalizedBodyPreview: normalize(String(item.body.prefix(2_000))),
            updatedAt: item.updatedAt
        )
    }

    static func search(
        query: String,
        items: [PromptItem],
        indexes: [UUID: PromptSearchIndex],
        minimumScore: Double = panelThreshold,
        limit: Int = 20
    ) -> [PromptSearchResult] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return items
                .filter(\.enabled)
                .sorted(by: defaultSort)
                .prefix(limit)
                .map { PromptSearchResult(item: $0, score: $0.pinned ? 0.2 : 0.1, matchedFields: []) }
        }

        return items.compactMap { item -> PromptSearchResult? in
            guard item.enabled else { return nil }
            let index = indexes[item.id] ?? makeIndex(for: item)
            let scored = score(normalizedQuery: normalizedQuery, index: index)
            guard scored.score >= minimumScore else { return nil }
            return PromptSearchResult(item: item, score: scored.score, matchedFields: scored.fields)
        }
        .sorted { lhs, rhs in
            if lhs.item.pinned != rhs.item.pinned { return lhs.item.pinned && !rhs.item.pinned }
            if abs(lhs.score - rhs.score) > 0.0001 { return lhs.score > rhs.score }
            return defaultSort(lhs.item, rhs.item)
        }
        .prefix(limit)
        .map { $0 }
    }

    static func bestSuggestion(
        query: String,
        items: [PromptItem],
        indexes: [UUID: PromptSearchIndex],
        ignored: Set<String> = []
    ) -> PromptSearchResult? {
        search(query: query, items: items, indexes: indexes, minimumScore: suggestionThreshold, limit: 5)
            .first { !ignored.contains(ignoreKey(promptId: $0.item.id, query: query)) }
    }

    static func queryHash(_ query: String) -> String {
        let normalized = normalize(query)
        let basis: UInt64 = 1_469_598_103_934_665_603
        let prime: UInt64 = 1_099_511_628_211
        let hash = normalized.utf8.reduce(basis) { partial, byte in
            (partial ^ UInt64(byte)).multipliedReportingOverflow(by: prime).partialValue
        }
        return String(hash, radix: 16)
    }

    static func ignoreKey(promptId: UUID, query: String) -> String {
        "\(promptId.uuidString)#\(queryHash(query))"
    }

    static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .map { char in
                char.isLetter || char.isNumber ? char : " "
            }
            .reduce(into: "") { partial, char in
                if char == " ", partial.last == " " { return }
                partial.append(char)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func score(normalizedQuery: String, index: PromptSearchIndex) -> (score: Double, fields: [String]) {
        let fields: [(name: String, weight: Double, values: [String])] = [
            ("标题", 0.34, [index.normalizedTitle]),
            ("关键词", 0.26, index.normalizedKeywords),
            ("标签", 0.16, index.normalizedTags),
            ("摘要", 0.14, [index.normalizedSummary]),
            ("正文", 0.10, [index.normalizedBodyPreview])
        ]

        var total = 0.0
        var matched: [String] = []
        for field in fields {
            let best = field.values.map { fieldScore(query: normalizedQuery, text: $0) }.max() ?? 0
            if best > 0.08 {
                matched.append(field.name)
            }
            total += best * field.weight
        }

        let coreMatchCount = matched.reduce(into: 0) { count, field in
            if field == "标题" || field == "关键词" || field == "标签" {
                count += 1
            }
        }
        if coreMatchCount >= 2 {
            total += 0.06 + (Double(coreMatchCount - 2) * 0.04)
        }
        if matched.contains("标题"), matched.contains("关键词") {
            total += 0.03
        }

        if index.normalizedSummary.contains(normalizedQuery) {
            total = max(total, 0.5)
            if !matched.contains("摘要") {
                matched.append("摘要")
            }
        }
        if index.normalizedBodyPreview.contains(normalizedQuery) {
            total = max(total, 0.5)
            if !matched.contains("正文") {
                matched.append("正文")
            }
        }
        return (min(1, total), matched)
    }

    private static func fieldScore(query: String, text: String) -> Double {
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        if text == query { return 1 }
        if text.contains(query) { return 0.92 }
        if query.contains(text), text.count >= 2 { return 0.9 }

        let queryTokens = Set(query.split(separator: " ").map(String.init).filter { $0.count > 1 })
        let textTokens = Set(text.split(separator: " ").map(String.init).filter { $0.count > 1 })
        guard !queryTokens.isEmpty, !textTokens.isEmpty else {
            return charDice(query, text) * 0.55
        }

        let overlap = queryTokens.intersection(textTokens).count
        let tokenScore = Double(overlap) / Double(max(queryTokens.count, 1))
        return max(tokenScore, charDice(query, text) * 0.7)
    }

    private static func charDice(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.reduce(0) { $0 + min($1.value, right[$1.key] ?? 0) }
        return (2.0 * Double(intersection)) / Double(left.values.reduce(0, +) + right.values.reduce(0, +))
    }

    private static func bigrams(_ text: String) -> [String: Int] {
        let chars = Array(text.filter { !$0.isWhitespace })
        guard chars.count > 1 else { return [:] }
        var result: [String: Int] = [:]
        for index in 0..<(chars.count - 1) {
            result[String(chars[index...index + 1]), default: 0] += 1
        }
        return result
    }

    private static func defaultSort(_ lhs: PromptItem, _ rhs: PromptItem) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        if lhs.lastUsedAt != rhs.lastUsedAt {
            return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
        }
        if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
        return lhs.updatedAt > rhs.updatedAt
    }
}
