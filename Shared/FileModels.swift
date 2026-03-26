// Shared/FileModels.swift
// 文件浏览器数据模型 — App 与 Helper 共用的文件条目结构
import Foundation

/// 记忆搜索结果中的单个片段（来自 SQLite chunks 表）
struct MemoryChunkResult: Codable, Identifiable {
    var id: String { path + text.prefix(20) }
    let path: String   // 相对文件路径，如 "MEMORY.md"
    let text: String   // 匹配的文本片段
}

struct FileEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    /// 相对于 /Users/<username>/ 的路径（根目录为空字符串 ""）
    let path: String
    let isDirectory: Bool
    let size: Int64    // 目录为 0
    let modifiedAt: Date?
    let isSymlink: Bool
    let ownerUsername: String?
}

/// 统一记忆文件发现策略：优先 workspace 新路径，回退 legacy 路径。
enum MemoryFileLocator {
    static let candidateDirectories: [String] = [
        ".openclaw/workspace/memory",
        ".openclaw/workspace",
        ".openclaw/memory"
    ]

    private static let workspaceRoot = ".openclaw/workspace"

    static func collectVisibleFiles(groupedEntries: [String: [FileEntry]]) -> [FileEntry] {
        var seenPaths = Set<String>()
        var visible: [FileEntry] = []

        for directory in candidateDirectories {
            guard let entries = groupedEntries[directory] else { continue }
            for entry in entries where shouldInclude(entry, in: directory) {
                guard seenPaths.insert(entry.path).inserted else { continue }
                visible.append(entry)
            }
        }

        return visible.sorted {
            let nameCompare = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameCompare == .orderedSame { return $0.path < $1.path }
            return nameCompare == .orderedAscending
        }
    }

    static func shouldInclude(_ entry: FileEntry, in parentRelativePath: String) -> Bool {
        guard !entry.isDirectory else { return false }
        let lowercasedName = entry.name.lowercased()

        if parentRelativePath == workspaceRoot {
            // workspace 根目录只展示 MEMORY.md，避免把 SOUL.md 等杂项混入记忆页。
            return lowercasedName == "memory.md"
        }

        return lowercasedName.hasSuffix(".md") || lowercasedName.hasSuffix(".txt")
    }
}

/// Build candidate transcript paths relative to /Users/<username>/ for HelperClient.readFile.
func resolveSessionTranscriptRelativePaths(
    sessionFile: String?,
    sessionId: String?,
    key: String
) -> [String] {
    var results: [String] = []
    var seen = Set<String>()

    func push(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        if seen.insert(value).inserted {
            results.append(value)
        }
    }

    push(normalizeSessionFileToOpenclawRelative(sessionFile))

    if let sid = normalizeSessionId(sessionId) {
        push(".openclaw/agents/main/sessions/\(sid).jsonl")
    } else if let fallback = fallbackSessionIdFromKey(key) {
        push(".openclaw/agents/main/sessions/\(fallback).jsonl")
    }

    return results
}

private func normalizeSessionFileToOpenclawRelative(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }

    value = value.replacingOccurrences(of: "\\", with: "/")

    if let range = value.range(of: "/.openclaw/") {
        value = ".openclaw/" + value[range.upperBound...]
    } else if value.hasPrefix("~/.openclaw/") {
        value = ".openclaw/" + value.dropFirst("~/.openclaw/".count)
    } else if value.hasPrefix(".openclaw/") {
        // already normalized
    } else if value.hasPrefix("openclaw/") {
        value = "." + value
    } else if value.hasPrefix("/") {
        // absolute path outside ~/.openclaw cannot be read as user-relative path
        return nil
    } else {
        value = ".openclaw/" + value.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
    }

    while value.hasPrefix(".openclaw/.openclaw/") {
        value = ".openclaw/" + value.dropFirst(".openclaw/.openclaw/".count)
    }

    return value
}

private func normalizeSessionId(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

private func fallbackSessionIdFromKey(_ key: String) -> String? {
    let tail = String(key.split(separator: ":").last ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard tail.count >= 8 else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard tail.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    guard tail.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
    return tail
}

// MARK: - 角色定义 Git 历史

/// git commit 记录（角色文件历史追踪）
struct PersonaCommit: Codable, Identifiable {
    let hash: String      // 7 位短哈希，作为唯一 ID
    let message: String   // commit message
    let timestamp: Date   // 提交时间

    var id: String { hash }
}
