import Foundation

@MainActor
final class LLMWikiHostCommandDispatcher {
    static let shared = LLMWikiHostCommandDispatcher()

    private let runtimeManager = LLMWikiRuntimeManager.shared
    private let storeService = LLMWikiStoreService()

    private init() {}

    func invoke(command: String, payload: Any) async throws -> Any {
        let dictionary = payload as? [String: Any] ?? [:]
        switch command {
        case "read_file":
            return try LocalWikiHostFS.readFile(path: try Self.stringValue("path", in: dictionary))
        case "write_file":
            try LocalWikiHostFS.writeFile(
                path: try Self.stringValue("path", in: dictionary),
                contents: try Self.stringValue("contents", in: dictionary)
            )
            return NSNull()
        case "list_directory":
            return try LocalWikiHostFS.listDirectory(path: try Self.stringValue("path", in: dictionary))
        case "copy_file":
            try LocalWikiHostFS.copyFile(
                source: try Self.stringValue("source", in: dictionary),
                destination: try Self.stringValue("destination", in: dictionary)
            )
            return NSNull()
        case "copy_directory":
            return try LocalWikiHostFS.copyDirectory(
                source: try Self.stringValue("source", in: dictionary),
                destination: try Self.stringValue("destination", in: dictionary)
            )
        case "preprocess_file":
            return try LocalWikiHostFS.preprocessFile(path: try Self.stringValue("path", in: dictionary))
        case "delete_file":
            try LocalWikiHostFS.deleteFile(path: try Self.stringValue("path", in: dictionary))
            return NSNull()
        case "find_related_wiki_pages":
            return try LocalWikiHostFS.findRelatedWikiPages(
                projectPath: try Self.stringValue("projectPath", in: dictionary),
                sourceName: try Self.stringValue("sourceName", in: dictionary)
            )
        case "create_directory":
            try LocalWikiHostFS.createDirectory(path: try Self.stringValue("path", in: dictionary))
            return NSNull()
        case "list_source_documents":
            return try LocalWikiHostFS.listSourceDocuments(projectPath: try Self.stringValue("projectPath", in: dictionary))
        case "create_project":
            return try LocalWikiHostFS.createProject(
                name: try Self.stringValue("name", in: dictionary),
                path: try Self.stringValue("path", in: dictionary)
            )
        case "open_project":
            return try LocalWikiHostFS.openProject(path: try Self.stringValue("path", in: dictionary))
        case "clip_server_status":
            return await runtimeManager.clipServerStatus()
        case "chat_completion":
            return try await HostLLMBridge.completeChat(payload: dictionary)
        case "list_global_llm_options":
            return GlobalLLMConfigBridge.listOptions(storeService: storeService)
        case "get_global_llm_selection":
            return GlobalLLMConfigBridge.currentSelection(storeService: storeService)
        case "save_global_llm_option":
            let optionID = try Self.stringValue("optionId", in: dictionary)
            let maxContextSize = dictionary["maxContextSize"] as? Int
            return try await GlobalLLMConfigBridge.saveSelection(
                optionID: optionID,
                maxContextSize: maxContextSize,
                storeService: storeService,
                runtimeManager: runtimeManager
            )
        case "take_pending_ingest_requests":
            let projectPath = dictionary["projectPath"] as? String
            return try await runtimeManager.takePendingIngestRequests(projectPath: projectPath)
        default:
            return try await runtimeManager.invoke(command: command, payload: payload)
        }
    }

    private static func stringValue(_ key: String, in dictionary: [String: Any]) throws -> String {
        guard let value = dictionary[key] as? String else {
            throw NSError(
                domain: "LLMWikiHostCommandDispatcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required string field: \(key)"]
            )
        }
        return value
    }
}

private enum HostLLMBridge {
    static func completeChat(payload: [String: Any]) async throws -> [String: Any] {
        let config = try parseConfig(from: payload["config"])
        let messages = try parseMessages(from: payload["messages"])
        let text = try await requestText(config: config, messages: messages)
        return ["text": text]
    }

    private static func parseConfig(from raw: Any?) throws -> LLMWikiStoredLLMConfig {
        guard let dict = raw as? [String: Any] else {
            throw NSError(domain: "HostLLMBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing llm config"])
        }
        let provider = (dict["provider"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = dict["apiKey"] as? String ?? ""
        let model = dict["model"] as? String ?? ""
        let ollamaURL = dict["ollamaUrl"] as? String ?? "http://localhost:11434"
        let customEndpoint = dict["customEndpoint"] as? String ?? ""
        let maxContextSize = dict["maxContextSize"] as? Int ?? 204800
        guard !provider.isEmpty, !model.isEmpty else {
            throw NSError(domain: "HostLLMBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incomplete llm config"])
        }
        return LLMWikiStoredLLMConfig(
            provider: provider,
            apiKey: apiKey,
            model: model,
            ollamaUrl: ollamaURL,
            customEndpoint: customEndpoint,
            maxContextSize: maxContextSize
        )
    }

    private static func parseMessages(from raw: Any?) throws -> [[String: String]] {
        guard let items = raw as? [[String: Any]] else {
            throw NSError(domain: "HostLLMBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing chat messages"])
        }
        let messages = items.compactMap { item -> [String: String]? in
            guard let role = item["role"] as? String, let content = item["content"] as? String else { return nil }
            return ["role": role, "content": content]
        }
        guard !messages.isEmpty else {
            throw NSError(domain: "HostLLMBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "No chat messages"])
        }
        return messages
    }

    private static func requestText(config: LLMWikiStoredLLMConfig, messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: try requestURL(for: config))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch config.provider {
        case "openai", "custom":
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "messages": messages,
                "stream": false,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String
            return content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        case "anthropic", "minimax":
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            if config.provider == "minimax", !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(nil, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            let system = messages.filter { $0["role"] == "system" }.map { $0["content"] ?? "" }.joined(separator: "\n")
            let conversation = messages.filter { $0["role"] != "system" }
            var body: [String: Any] = [
                "model": config.model,
                "messages": conversation,
                "stream": false,
                "max_tokens": 4096,
            ]
            if !system.isEmpty {
                body["system"] = system
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            let text = content?.compactMap { $0["text"] as? String }.joined()
            return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        case "google":
            request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
            let system = messages.filter { $0["role"] == "system" }.map { ["text": $0["content"] ?? ""] }
            let conversation = messages.filter { $0["role"] != "system" }.map { message in
                [
                    "role": (message["role"] == "assistant") ? "model" : "user",
                    "parts": [["text": message["content"] ?? ""]],
                ] as [String: Any]
            }
            var body: [String: Any] = ["contents": conversation]
            if !system.isEmpty {
                body["systemInstruction"] = ["parts": system]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let candidates = json?["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { $0["text"] as? String }.joined()
            return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        case "ollama":
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "messages": messages,
                "stream": false,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["message"] as? [String: Any]
            let content = message?["content"] as? String
            return content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        default:
            throw NSError(domain: "HostLLMBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsupported provider: \(config.provider)"])
        }
    }

    private static func requestURL(for config: LLMWikiStoredLLMConfig) throws -> URL {
        switch config.provider {
        case "openai":
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case "anthropic":
            return try url(from: anthropicEndpoint(base: config.customEndpoint.isEmpty ? "https://api.anthropic.com" : config.customEndpoint))
        case "google":
            return try url(from: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")
        case "ollama":
            return try url(from: openAIEndpoint(base: config.ollamaUrl))
        case "minimax":
            return try url(from: anthropicEndpoint(base: "https://api.minimaxi.com/anthropic"))
        case "custom":
            return try url(from: openAIEndpoint(base: config.customEndpoint))
        default:
            throw NSError(domain: "HostLLMBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unsupported provider: \(config.provider)"])
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "HostLLMBridge", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "HostLLMBridge", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
    }

    private static func normalizedBaseURL(_ base: String) -> String {
        var value = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func anthropicEndpoint(base: String) -> String {
        let normalized = normalizedBaseURL(base)
        if normalized.hasSuffix("/v1/messages") { return normalized }
        if normalized.hasSuffix("/v1") { return "\(normalized)/messages" }
        return "\(normalized)/v1/messages"
    }

    private static func openAIEndpoint(base: String) -> String {
        let normalized = normalizedBaseURL(base)
        if normalized.hasSuffix("/chat/completions") { return normalized }
        if normalized.hasSuffix("/v1") { return "\(normalized)/chat/completions" }
        if normalized.range(of: "/v\\d+$", options: .regularExpression) != nil {
            return "\(normalized)/chat/completions"
        }
        return "\(normalized)/v1/chat/completions"
    }

    private static func url(from string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw NSError(domain: "HostLLMBridge", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(string)"])
        }
        return url
    }
}

private enum GlobalLLMConfigBridge {
    static func listOptions(storeService: LLMWikiStoreService) -> [[String: Any]] {
        let globalStore = storeService.persistedGlobalModelStore()
        return storeService.persistedGlobalLLMConfigOptions().map { option in
            serialize(option: option, revision: globalStore.revision)
        }
    }

    static func currentSelection(storeService: LLMWikiStoreService) -> [String: Any] {
        let globalStore = storeService.persistedGlobalModelStore()
        let selection = storeService.persistedLLMConfigSelection()
        let payload: [String: Any] = [
            "source": selection?.source.rawValue ?? LLMWikiLLMConfigSource.manual.rawValue,
            "optionId": selection?.optionID ?? NSNull(),
            "observedGlobalRevision": selection?.observedGlobalRevision ?? globalStore.revision,
            "currentRevision": globalStore.revision,
        ]
        return payload
    }

    static func saveSelection(
        optionID: String,
        maxContextSize: Int?,
        storeService: LLMWikiStoreService,
        runtimeManager: LLMWikiRuntimeManager
    ) async throws -> [String: Any] {
        let globalStore = storeService.persistedGlobalModelStore()
        let options = storeService.globalLLMConfigOptions(from: globalStore)
        guard let selected = options.first(where: { $0.id == optionID }) else {
            throw NSError(
                domain: "GlobalLLMConfigBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Selected global LLM config no longer exists."]
            )
        }

        let resolvedConfig = LLMWikiStoredLLMConfig(
            provider: selected.config.provider,
            apiKey: selected.config.apiKey,
            model: selected.config.model,
            ollamaUrl: selected.config.ollamaUrl,
            customEndpoint: selected.config.customEndpoint,
            maxContextSize: maxContextSize ?? selected.config.maxContextSize
        )

        try storeService.saveLLMConfig(resolvedConfig)
        storeService.savePersistedLLMConfigSelection(
            source: .global,
            optionID: selected.id,
            observedGlobalRevision: globalStore.revision
        )

        let runtimeStatus = await runtimeManager.clipServerStatus()
        let runtimeIsRunning = await MainActor.run { runtimeManager.isRunning() }
        if runtimeIsRunning || runtimeStatus == "running" {
            try await runtimeManager.restart()
        }
        NotificationCenter.default.post(name: .llmWikiConfigDidChange, object: nil)

        return [
            "option": serialize(option: selected, config: resolvedConfig, revision: globalStore.revision),
            "restarted": true,
        ]
    }

    private static func serialize(
        option: LLMWikiGlobalLLMConfigOption,
        config: LLMWikiStoredLLMConfig? = nil,
        revision: Int
    ) -> [String: Any] {
        let resolvedConfig = config ?? option.config
        let payload: [String: Any] = [
            "id": option.id,
            "title": option.title,
            "providerDisplayName": option.providerDisplayName,
            "accountName": option.accountName,
            "modelId": option.modelId,
            "revision": revision,
            "config": [
                "provider": resolvedConfig.provider,
                "apiKey": resolvedConfig.apiKey,
                "model": resolvedConfig.model,
                "ollamaUrl": resolvedConfig.ollamaUrl,
                "customEndpoint": resolvedConfig.customEndpoint,
                "maxContextSize": resolvedConfig.maxContextSize,
            ],
        ]
        return payload
    }
}

private enum LocalWikiHostFS {
    private static let fileManager = FileManager.default
    private static let autoIngestExtensions: Set<String> = [
        "md", "mdx", "txt", "rtf", "pdf", "html", "htm", "xml", "docx", "xlsx", "xls", "pptx",
        "odt", "ods", "odp", "json", "jsonl", "csv", "tsv", "yaml", "yml", "ndjson", "py", "js",
        "ts", "jsx", "tsx", "rs", "go", "java", "c", "cpp", "h", "rb", "php", "swift", "sql", "sh",
    ]

    static func readFile(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            let sizeKB = Double(data.count) / 1024.0
            return String(format: "[Binary file: %@ (%.1f KB)]", url.lastPathComponent, sizeKB)
        }
    }

    static func writeFile(path: String, contents: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func listDirectory(path: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw NSError(domain: "LocalWikiHostFS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path does not exist: '\(path)'"])
        }
        guard isDirectory.boolValue else {
            throw NSError(domain: "LocalWikiHostFS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Path is not a directory: '\(path)'"])
        }
        return try buildTree(directory: url, depth: 0, maxDepth: 30)
    }

    static func copyFile(source: String, destination: String) throws {
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    static func copyDirectory(source: String, destination: String) throws -> [String] {
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        var copied: [String] = []
        try copyDirectoryRecursive(sourceURL: sourceURL, destinationURL: destinationURL, copied: &copied)
        return copied
    }

    static func preprocessFile(path: String) throws -> String {
        try readFile(path: path)
    }

    static func deleteFile(path: String) throws {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            try fileManager.removeItem(at: url)
        } else {
            try fileManager.removeItem(at: url)
        }
    }

    static func findRelatedWikiPages(projectPath: String, sourceName: String) throws -> [String] {
        let wikiURL = URL(fileURLWithPath: projectPath).appendingPathComponent("wiki", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: wikiURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let fileName = URL(fileURLWithPath: sourceName).lastPathComponent.lowercased()
        let fileStem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent.lowercased()
        var related: [String] = []
        try collectRelatedPages(in: wikiURL, fileName: fileName, fileStem: fileStem, results: &related)
        return related
    }

    static func createDirectory(path: String) throws {
        try fileManager.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    }

    static func listSourceDocuments(projectPath: String) throws -> [[String: Any]] {
        let projectURL = URL(fileURLWithPath: projectPath)
        let sourceRoot = projectURL.appendingPathComponent("raw/sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        var results: [[String: Any]] = []
        try collectSourceDocuments(projectRoot: projectURL, directory: sourceRoot, results: &results)
        return results.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
    }

    static func createProject(name: String, path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: root.appendingPathComponent("wiki"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("raw/sources"), withIntermediateDirectories: true)
        let schemaURL = root.appendingPathComponent("schema.md")
        if !fileManager.fileExists(atPath: schemaURL.path) {
            try "Schema".write(to: schemaURL, atomically: true, encoding: .utf8)
        }
        return ["name": name, "path": root.path]
    }

    static func openProject(path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw NSError(domain: "LocalWikiHostFS", code: 4, userInfo: [NSLocalizedDescriptionKey: "Path does not exist: '\(path)'"])
        }
        guard isDirectory.boolValue else {
            throw NSError(domain: "LocalWikiHostFS", code: 5, userInfo: [NSLocalizedDescriptionKey: "Path is not a directory: '\(path)'"])
        }
        guard fileManager.fileExists(atPath: root.appendingPathComponent("schema.md").path) else {
            throw NSError(domain: "LocalWikiHostFS", code: 6, userInfo: [NSLocalizedDescriptionKey: "Not a valid wiki project (missing schema.md): '\(path)'"])
        }
        var wikiIsDirectory: ObjCBool = false
        let wikiURL = root.appendingPathComponent("wiki", isDirectory: true)
        guard fileManager.fileExists(atPath: wikiURL.path, isDirectory: &wikiIsDirectory), wikiIsDirectory.boolValue else {
            throw NSError(domain: "LocalWikiHostFS", code: 7, userInfo: [NSLocalizedDescriptionKey: "Not a valid wiki project (missing wiki/ directory): '\(path)'"])
        }
        return ["name": root.lastPathComponent.isEmpty ? "Unknown" : root.lastPathComponent, "path": root.path]
    }

    private static func buildTree(directory: URL, depth: Int, maxDepth: Int) throws -> [[String: Any]] {
        if depth >= maxDepth { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        var entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter { !$0.lastPathComponent.hasPrefix(".") }

        entries.sort { lhs, rhs in
            let lhsIsDirectory = (try? lhs.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            let rhsIsDirectory = (try? rhs.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            if lhsIsDirectory != rhsIsDirectory {
                return lhsIsDirectory && !rhsIsDirectory
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        return try entries.map { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            var node: [String: Any] = [
                "name": entry.lastPathComponent,
                "path": entry.path,
                "is_dir": isDirectory,
            ]
            if isDirectory {
                let children = try buildTree(directory: entry, depth: depth + 1, maxDepth: maxDepth)
                if !children.isEmpty {
                    node["children"] = children
                }
            }
            return node
        }
    }

    private static func copyDirectoryRecursive(sourceURL: URL, destinationURL: URL, copied: inout [String]) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for child in try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            let destinationChild = destinationURL.appendingPathComponent(child.lastPathComponent, isDirectory: false)
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try copyDirectoryRecursive(sourceURL: child, destinationURL: destinationChild, copied: &copied)
            } else {
                if fileManager.fileExists(atPath: destinationChild.path) {
                    try fileManager.removeItem(at: destinationChild)
                }
                try fileManager.copyItem(at: child, to: destinationChild)
                copied.append(destinationChild.path)
            }
        }
    }

    private static func collectRelatedPages(in directory: URL, fileName: String, fileStem: String, results: inout [String]) throws {
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if entry.lastPathComponent.hasPrefix(".") { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try collectRelatedPages(in: entry, fileName: fileName, fileStem: fileStem, results: &results)
                continue
            }
            guard entry.pathExtension.lowercased() == "md" else { continue }
            let name = entry.lastPathComponent.lowercased()
            if name == "index.md" || name == "log.md" || name == "overview.md" { continue }
            guard let content = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            let inSourcesDir = entry.pathComponents.contains("sources")
            let isSourceSummary = inSourcesDir && name.hasPrefix(fileStem)
            let sourcesMatch = lower.contains("\"\(fileName)\"") || lower.contains("'\(fileName)'")
            let frontmatterMatch = lower.contains("sources:") && lower.contains(fileName)
            if sourcesMatch || frontmatterMatch || isSourceSummary {
                results.append(entry.path)
            }
        }
    }

    private static func collectSourceDocuments(projectRoot: URL, directory: URL, results: inout [[String: Any]]) throws {
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || name == ".cache" { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try collectSourceDocuments(projectRoot: projectRoot, directory: entry, results: &results)
                continue
            }

            let ext = entry.pathExtension.lowercased()
            if !autoIngestExtensions.contains(ext) { continue }

            let values = try entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedMs = UInt64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            let relativePath = entry.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            results.append([
                "path": entry.path,
                "relativePath": relativePath.replacingOccurrences(of: "\\", with: "/"),
                "modifiedMs": modifiedMs,
                "size": values.fileSize ?? 0,
            ])
        }
    }
}
