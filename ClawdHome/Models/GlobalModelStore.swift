// ClawdHome/Models/GlobalModelStore.swift
import Foundation
import Observation

/// 全局模型池条目：一个命名的账户配置
/// 同一 Provider 可以添加多个账户（如「Anthropic 主账号」「Anthropic 备用」）
struct ProviderTemplate: Codable, Identifiable {
    var id: UUID = UUID()          // 唯一标识（非 provider 类型）
    var name: String               // 用户自定义名称，如「Anthropic 主账号」
    var providerGroupId: String    // provider 类型，如 "anthropic"
    var providerDisplayName: String// 对应的内置显示名，如 "Anthropic"
    var modelIds: [String]         // 该账户下已选的模型 ID
    /// 自定义 provider 扩展信息（providerGroupId == "custom" 时使用）
    var customProviderId: String? = nil
    var customBaseURL: String? = nil
    var customAPIType: String? = nil

    var displayNameWithAlias: String {
        "\(providerDisplayName)-\(name)"
    }
}

private struct PersistedState: Codable {
    var providers: [ProviderTemplate] = []
    var revision: Int = 0

    init(providers: [ProviderTemplate] = [], revision: Int = 0) {
        self.providers = providers
        self.revision = revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ProviderTemplate].self, forKey: .providers) ?? []
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}

/// 全局模型池
@Observable
final class GlobalModelStore {
    private(set) var providers: [ProviderTemplate] = []
    private(set) var revision: Int = 0

    var hasTemplate: Bool { providers.contains { !$0.modelIds.isEmpty } }
    var firstTemplate: ProviderTemplate? { providers.first { !$0.modelIds.isEmpty } }

    func templates(for providerGroupId: String) -> [ProviderTemplate] {
        providers.filter { $0.providerGroupId == providerGroupId && !$0.modelIds.isEmpty }
    }

    func firstTemplate(for providerGroupId: String) -> ProviderTemplate? {
        templates(for: providerGroupId).first
    }

    func isAliasAvailable(_ alias: String, excluding id: UUID? = nil) -> Bool {
        let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return !providers.contains { item in
            if let id, item.id == id { return false }
            return item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    /// 所有账户下已选模型的平铺列表
    var allTemplateModels: [ModelEntry] {
        let builtIn = builtInModelGroups.flatMap(\.models)
        return providers.flatMap { p in
            p.modelIds.map { id in
                builtIn.first { $0.id == id } ?? ModelEntry(id: id, label: id)
            }
        }
    }

    // MARK: - 编辑

    func addProvider(_ entry: ProviderTemplate) {
        providers.append(entry)
        bumpRevisionAndSave()
    }

    func updateProvider(_ entry: ProviderTemplate) {
        guard let idx = providers.firstIndex(where: { $0.id == entry.id }) else { return }
        providers[idx] = entry
        bumpRevisionAndSave()
    }

    func removeProvider(id: UUID) {
        if let provider = providers.first(where: { $0.id == id }) {
            // 删除账户时同步清理对应的 secrets 条目
            let secretKey = "\(provider.providerGroupId):\(provider.name)"
            GlobalSecretsStore.shared.delete(secretKey: secretKey)
        }
        providers.removeAll { $0.id == id }
        bumpRevisionAndSave()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        bumpRevisionAndSave()
    }

    func providerTemplate(id: UUID?) -> ProviderTemplate? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - 兼容（UserDetailView 应用模版）

    var templateDefault: String? { allTemplateModels.first?.id }
    var templateFallbacks: [String] { allTemplateModels.dropFirst().map(\.id) }

    // MARK: - 持久化

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClawdHome")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("global-models.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        providers = state.providers
        revision = max(0, state.revision)
    }

    func save() {
        let state = PersistedState(providers: providers, revision: revision)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.storeURL)
        }
    }

    private func bumpRevisionAndSave() {
        revision &+= 1
        save()
    }
}

enum ShrimpModelConfigSource: String, Codable {
    case existing
    case new
}

struct ShrimpModelConfigSelection: Codable {
    var source: ShrimpModelConfigSource
    var templateID: UUID?
    var updatedAt: Date
}

final class ShrimpModelConfigSourceStore {
    static let shared = ShrimpModelConfigSourceStore()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "shrimp.model.config.selection."

    private init() {}

    func load(username: String) -> ShrimpModelConfigSelection? {
        let key = storageKey(username: username)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShrimpModelConfigSelection.self, from: data)
    }

    func saveExisting(username: String, templateID: UUID?) {
        save(
            username: username,
            selection: ShrimpModelConfigSelection(
                source: .existing,
                templateID: templateID,
                updatedAt: Date()
            )
        )
    }

    func saveNew(username: String) {
        save(
            username: username,
            selection: ShrimpModelConfigSelection(
                source: .new,
                templateID: nil,
                updatedAt: Date()
            )
        )
    }

    private func save(username: String, selection: ShrimpModelConfigSelection) {
        let key = storageKey(username: username)
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: key)
    }

    private func storageKey(username: String) -> String {
        "\(keyPrefix)\(username)"
    }
}
