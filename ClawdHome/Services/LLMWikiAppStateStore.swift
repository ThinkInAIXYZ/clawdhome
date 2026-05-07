import Foundation

final class LLMWikiAppStateStore {
    static let shared = LLMWikiAppStateStore()

    private let fileManager = FileManager.default
    private let supportedStoreName = "app-state.json"

    private init() {}

    var storeURL: URL {
        URL(fileURLWithPath: LLMWikiPaths.appStatePath(for: NSUserName()))
    }

    func loadStore(named name: String) throws {
        guard name == supportedStoreName else {
            throw NSError(
                domain: "LLMWikiAppStateStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported store: \(name)"]
            )
        }
        _ = try readState()
    }

    func getValue(forKey key: String) throws -> Any? {
        try readState()[key]
    }

    func setValue(_ value: Any, forKey key: String) throws {
        var state = try readState()
        state[key] = value
        try writeState(state)
    }

    private func readState() throws -> [String: Any] {
        try migrateLegacyStoreIfNeeded()
        let url = storeURL
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            try writeState([:])
            return [:]
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any] ?? [:]
    }

    private func writeState(_ state: [String: Any]) throws {
        try migrateLegacyStoreIfNeeded()
        let url = storeURL
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func migrateLegacyStoreIfNeeded() throws {
        let username = NSUserName()
        let currentURL = URL(fileURLWithPath: LLMWikiPaths.appStatePath(for: username))
        guard !fileManager.fileExists(atPath: currentURL.path) else { return }

        let legacyURL = URL(fileURLWithPath: LLMWikiPaths.legacyAppStatePath(for: username))
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        try fileManager.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.copyItem(at: legacyURL, to: currentURL)
    }
}
