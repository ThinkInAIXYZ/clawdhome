// ClawdHome/Services/SpeechHistoryStore.swift
// 语音转写历史存储（JSON，应用侧）

import Foundation

private struct SpeechHistoryFile: Codable {
    var version: Int = 1
    var items: [SpeechHistoryRecord] = []
}

final class SpeechHistoryStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = SpeechHistoryStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("speech-history.json")
    }

    func load() -> [SpeechHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(SpeechHistoryFile.self, from: data)
        else {
            return []
        }
        return Self.sortedNewestFirst(file.items)
    }

    func save(_ item: SpeechHistoryRecord) {
        var items = load()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        write(items: items)
    }

    func delete(id: UUID) {
        let items = load().filter { $0.id != id }
        write(items: items)
    }

    private func write(items: [SpeechHistoryRecord]) {
        let payload = SpeechHistoryFile(items: Self.sortedNewestFirst(items))
        guard let data = try? encoder.encode(payload) else { return }

        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func sortedNewestFirst(_ items: [SpeechHistoryRecord]) -> [SpeechHistoryRecord] {
        items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
