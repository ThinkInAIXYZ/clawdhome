import Foundation

struct LLMWikiProjectReference: Codable, Equatable {
    var name: String
    var path: String
}

struct LLMWikiStoredLLMConfig: Codable, Equatable {
    var provider: String
    var apiKey: String
    var model: String
    var ollamaUrl: String
    var customEndpoint: String
    var maxContextSize: Int
}

struct LLMWikiStoredEmbeddingConfig: Codable, Equatable {
    var enabled: Bool
    var endpoint: String
    var apiKey: String
    var model: String
}

struct LLMWikiStoreSnapshot {
    let path: String
    let exists: Bool
    let lastProject: String?
    let recentProjects: [String]
    let llmConfig: LLMWikiStoredLLMConfig?
    let embeddingConfig: LLMWikiStoredEmbeddingConfig?
}

enum LLMWikiLLMConfigSource: String, Codable, CaseIterable, Identifiable {
    case global
    case manual

    var id: String { rawValue }
}

struct LLMWikiLLMConfigSelection: Codable {
    var source: LLMWikiLLMConfigSource
    var optionID: String?
    var observedGlobalRevision: Int
    var updatedAt: Date
}

struct LLMWikiGlobalLLMConfigOption: Identifiable, Equatable {
    let id: String
    let providerDisplayName: String
    let accountName: String
    let modelId: String
    let config: LLMWikiStoredLLMConfig

    var title: String {
        "\(providerDisplayName) · \(accountName) · \(modelId)"
    }
}

final class LLMWikiLLMConfigSelectionStore {
    static let shared = LLMWikiLLMConfigSelectionStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "llmwiki.notes.llm.config.selection"

    private init() {}

    func load() -> LLMWikiLLMConfigSelection? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LLMWikiLLMConfigSelection.self, from: data)
    }

    func save(source: LLMWikiLLMConfigSource, optionID: String?, observedGlobalRevision: Int) {
        let payload = LLMWikiLLMConfigSelection(
            source: source,
            optionID: optionID,
            observedGlobalRevision: max(0, observedGlobalRevision),
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

final class LLMWikiStoreService {
    private let storeURL: URL
    private let backupURL: URL

    init(adminUsername: String = NSUserName()) {
        self.storeURL = URL(fileURLWithPath: LLMWikiPaths.appStatePath(for: adminUsername))
        self.backupURL = self.storeURL.appendingPathExtension("clawdhome-backup")
    }

    func load() -> LLMWikiStoreSnapshot {
        guard let state = readState() else {
            return LLMWikiStoreSnapshot(
                path: storeURL.path,
                exists: false,
                lastProject: nil,
                recentProjects: [],
                llmConfig: nil,
                embeddingConfig: nil
            )
        }
        return LLMWikiStoreSnapshot(
            path: storeURL.path,
            exists: true,
            lastProject: decodeProjectReference(from: state["lastProject"])?.path,
            recentProjects: decodeProjectReferences(from: state["recentProjects"]).map(\.path),
            llmConfig: decodeValue(LLMWikiStoredLLMConfig.self, from: state["llmConfig"]).map(normalizedLLMConfig),
            embeddingConfig: decodeValue(LLMWikiStoredEmbeddingConfig.self, from: state["embeddingConfig"])
        )
    }

    func ensureProjectBinding(projectPath: String) throws {
        try mutateState { state in
            let projectRef = projectReference(for: projectPath)
            state["lastProject"] = encodeValue(projectRef)
            let current = decodeProjectReferences(from: state["recentProjects"])
            let merged = [projectRef] + current.filter { $0.path != projectRef.path }
            state["recentProjects"] = encodeValue(Array(merged.prefix(8)))
        }
    }

    func saveLLMConfig(_ config: LLMWikiStoredLLMConfig) throws {
        let normalized = normalizedLLMConfig(config)
        try mutateState { state in
            state["llmConfig"] = encodeValue(normalized)
        }
    }

    func saveEmbeddingConfig(_ config: LLMWikiStoredEmbeddingConfig) throws {
        try mutateState { state in
            state["embeddingConfig"] = encodeValue(config)
        }
    }

    func suggestedLLMConfig(from modelStore: GlobalModelStore) -> LLMWikiStoredLLMConfig? {
        globalLLMConfigOptions(from: modelStore).first?.config
    }

    func globalLLMConfigOptions(from modelStore: GlobalModelStore) -> [LLMWikiGlobalLLMConfigOption] {
        modelStore.providers.flatMap { template in
            template.modelIds.compactMap { rawModelId in
                let modelId = rawModelId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelId.isEmpty,
                      let mapped = mapTemplateToLLMConfig(template: template, modelId: modelId)
                else {
                    return nil
                }
                return LLMWikiGlobalLLMConfigOption(
                    id: "\(template.id.uuidString)|\(modelId)",
                    providerDisplayName: template.providerDisplayName,
                    accountName: template.name,
                    modelId: modelId,
                    config: normalizedLLMConfig(mapped)
                )
            }
        }
    }

    func normalizedLLMConfig(_ config: LLMWikiStoredLLMConfig) -> LLMWikiStoredLLMConfig {
        let provider = config.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let customEndpoint = config.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOllamaURL = config.ollamaUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let ollamaURL = trimmedOllamaURL.isEmpty ? "http://localhost:11434" : trimmedOllamaURL
        let context = max(4096, config.maxContextSize)

        return LLMWikiStoredLLMConfig(
            provider: provider,
            apiKey: apiKey,
            model: model,
            ollamaUrl: ollamaURL,
            customEndpoint: customEndpoint,
            maxContextSize: context
        )
    }

    private func mapTemplateToLLMConfig(template: ProviderTemplate, modelId: String) -> LLMWikiStoredLLMConfig? {
        let provider = template.providerGroupId
        let secretKey = "\(provider):\(template.name)"
        let apiKey = GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: provider) ?? ""

        switch provider {
        case "openai", "anthropic", "google", "minimax":
            return LLMWikiStoredLLMConfig(
                provider: provider,
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                ollamaUrl: "http://localhost:11434",
                customEndpoint: "",
                maxContextSize: 204800
            )
        case "moonshot":
            return openAICompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: "https://api.moonshot.cn/v1"
            )
        case "openrouter":
            return openAICompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: "https://openrouter.ai/api/v1"
            )
        case "qiniu":
            return openAICompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: "https://api.qnaigc.com/v1"
            )
        case "zai":
            return openAICompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: "https://open.bigmodel.cn/api/paas/v4"
            )
        case "kimi-coding":
            return anthropicCompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: "https://api.kimi.com/coding"
            )
        case "custom":
            guard let baseURL = template.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty else {
                return nil
            }
            if (template.customAPIType ?? "").localizedCaseInsensitiveContains("anthropic") {
                return anthropicCompatibleConfig(
                    apiKey: apiKey,
                    model: strippedModelID(modelId, providerPrefix: provider),
                    endpoint: baseURL
                )
            }
            return openAICompatibleConfig(
                apiKey: apiKey,
                model: strippedModelID(modelId, providerPrefix: provider),
                endpoint: baseURL
            )
        case "ollama":
            return LLMWikiStoredLLMConfig(
                provider: "ollama",
                apiKey: "",
                model: strippedModelID(modelId, providerPrefix: provider),
                ollamaUrl: "http://localhost:11434",
                customEndpoint: "",
                maxContextSize: 204800
            )
        default:
            return nil
        }
    }

    private func strippedModelID(_ modelId: String, providerPrefix: String) -> String {
        let prefix = "\(providerPrefix)/"
        guard modelId.hasPrefix(prefix) else { return modelId }
        return String(modelId.dropFirst(prefix.count))
    }

    private func openAICompatibleConfig(apiKey: String, model: String, endpoint: String) -> LLMWikiStoredLLMConfig {
        LLMWikiStoredLLMConfig(
            provider: "custom",
            apiKey: apiKey,
            model: model,
            ollamaUrl: "http://localhost:11434",
            customEndpoint: endpoint,
            maxContextSize: 204800
        )
    }

    private func anthropicCompatibleConfig(apiKey: String, model: String, endpoint: String) -> LLMWikiStoredLLMConfig {
        LLMWikiStoredLLMConfig(
            provider: "anthropic",
            apiKey: apiKey,
            model: model,
            ollamaUrl: "http://localhost:11434",
            customEndpoint: endpoint,
            maxContextSize: 204800
        )
    }

    private func readState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private func projectReference(for path: String) -> LLMWikiProjectReference {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return LLMWikiProjectReference(
            name: name.isEmpty ? "project" : name,
            path: trimmed
        )
    }

    private func mutateState(_ transform: (inout [String: Any]) throws -> Void) throws {
        var state = readState() ?? [:]
        try transform(&state)
        try writeState(state)
    }

    private func writeState(_ state: [String: Any]) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: storeURL.path) {
            try? FileManager.default.copyItem(at: storeURL, to: backupURL)
        }

        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        let tempURL = storeURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            _ = try FileManager.default.replaceItemAt(storeURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: storeURL)
        }
    }

    private func decodeValue<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encodeValue<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return object
    }

    private func decodeProjectReference(from value: Any?) -> LLMWikiProjectReference? {
        if let ref = decodeValue(LLMWikiProjectReference.self, from: value) {
            return ref
        }
        if let path = value as? String {
            return projectReference(for: path)
        }
        return nil
    }

    private func decodeProjectReferences(from value: Any?) -> [LLMWikiProjectReference] {
        if let refs = decodeValue([LLMWikiProjectReference].self, from: value) {
            return refs
        }
        if let paths = value as? [String] {
            return paths.map(projectReference(for:))
        }
        return []
    }
}
