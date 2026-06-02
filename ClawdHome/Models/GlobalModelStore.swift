// ClawdHome/Models/GlobalModelStore.swift
import Foundation
import Observation

/// 平铺的已启用模型完整配置实体，支持全局唯一标识与自定义排序
struct ActiveModelEntry: Identifiable, Equatable, Hashable {
    var id: String { "\(modelId)_\(provider.id.uuidString)" }
    let modelId: String
    let provider: ProviderTemplate
    var isDefault: Bool
    
    var displayName: String {
        let curatedName = builtInModelGroups.flatMap(\.models).first { $0.id == modelId }?.label 
            ?? modelId.components(separatedBy: "/").last 
            ?? modelId
        return "\(curatedName) (\(provider.displayNameWithAlias))"
    }
}

/// 全局模型池条目：一个命名的账户配置
/// 同一 Provider 可以添加多个账户（如「Anthropic 主账号」「Anthropic 备用」）
struct ProviderTemplate: Codable, Identifiable, Hashable, Equatable {
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
    var orderedModelKeys: [String]? = []
    var defaultModelKey: String? = nil

    init(providers: [ProviderTemplate] = [], revision: Int = 0, orderedModelKeys: [String] = [], defaultModelKey: String? = nil) {
        self.providers = providers
        self.revision = revision
        self.orderedModelKeys = orderedModelKeys
        self.defaultModelKey = defaultModelKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ProviderTemplate].self, forKey: .providers) ?? []
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        orderedModelKeys = try container.decodeIfPresent([String].self, forKey: .orderedModelKeys) ?? []
        defaultModelKey = try container.decodeIfPresent(String.self, forKey: .defaultModelKey)
    }
}

/// 全局模型池
@Observable
final class GlobalModelStore {
    private(set) var providers: [ProviderTemplate] = []
    private(set) var revision: Int = 0
    
    // 自定义排序与默认模型字段
    private(set) var orderedModelKeys: [String] = []
    private(set) var defaultModelKey: String? = nil

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

    // MARK: - 排序与默认

    /// 获取排好序的平铺已启用模型配置项
    var sortedActiveModels: [ActiveModelEntry] {
        return orderedModelKeys.compactMap { key in
            // 由于 UUID 固定 36 位，我们从末尾截取以保证模型 ID 带下划线时依然解析准确
            guard key.count > 37 else { return nil }
            let uuidStartIdx = key.index(key.endIndex, offsetBy: -36)
            let providerIdStr = String(key[uuidStartIdx...])
            let separatorIdx = key.index(key.endIndex, offsetBy: -37)
            guard key[separatorIdx] == "_" else { return nil }
            let modelId = String(key[..<separatorIdx])
            
            guard let pUUID = UUID(uuidString: providerIdStr),
                  let provider = providers.first(where: { $0.id == pUUID })
            else { return nil }
            
            let isDefault = (key == defaultModelKey)
            return ActiveModelEntry(modelId: modelId, provider: provider, isDefault: isDefault)
        }
    }

    /// 设置某个模型为系统默认模型
    func setDefaultModel(key: String) {
        guard orderedModelKeys.contains(key) else { return }
        defaultModelKey = key
        bumpRevisionAndSave()
    }

    /// 拖拽排序已启用模型
    func moveActiveModel(from source: IndexSet, to destination: Int) {
        orderedModelKeys.move(fromOffsets: source, toOffset: destination)
        bumpRevisionAndSave()
    }

    /// 同步在账户管理中增删模型的操作到 orderedModelKeys 列表中
    private func syncActiveModelKeys(saveAfterSync: Bool = true) {
        // 1. 搜集当前在 providers 中实际被勾选启用的模型 key 集合与平铺顺序列表
        var actualKeys: Set<String> = []
        var actualKeysOrderedList: [String] = []
        for p in providers {
            for mid in p.modelIds {
                let key = "\(mid)_\(p.id.uuidString)"
                actualKeys.insert(key)
                actualKeysOrderedList.append(key)
            }
        }
        
        // 2. 移出已不存在的 key
        var newOrdered = orderedModelKeys.filter { actualKeys.contains($0) }
        
        // 3. 追加新增勾选的 key
        for key in actualKeysOrderedList {
            if !newOrdered.contains(key) {
                newOrdered.append(key)
            }
        }
        
        self.orderedModelKeys = newOrdered
        
        // 4. 校准默认模型
        if let def = defaultModelKey, actualKeys.contains(def) {
            // 保留原有默认模型
        } else {
            defaultModelKey = newOrdered.first
        }
        
        if saveAfterSync {
            bumpRevisionAndSave()
        }
    }

    // MARK: - 编辑

    func addProvider(_ entry: ProviderTemplate) {
        providers.append(entry)
        syncActiveModelKeys()
    }

    func updateProvider(_ entry: ProviderTemplate) {
        guard let idx = providers.firstIndex(where: { $0.id == entry.id }) else { return }
        providers[idx] = entry
        syncActiveModelKeys()
    }

    func removeProvider(id: UUID) {
        if let provider = providers.first(where: { $0.id == id }) {
            // 删除账户时同步清理对应的 secrets 条目
            let secretKey = "\(provider.providerGroupId):\(provider.name)"
            GlobalSecretsStore.shared.delete(secretKey: secretKey)
        }
        providers.removeAll { $0.id == id }
        syncActiveModelKeys()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        bumpRevisionAndSave()
    }

    func providerTemplate(id: UUID?) -> ProviderTemplate? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    // MARK: - 兼容（OpenClawDetailView 应用模版）

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
        
        let loadedKeys = state.orderedModelKeys ?? []
        if loadedKeys.isEmpty && !providers.isEmpty {
            // 旧版老用户自动静默迁移
            var derived: [String] = []
            for p in providers {
                for mid in p.modelIds {
                    derived.append("\(mid)_\(p.id.uuidString)")
                }
            }
            self.orderedModelKeys = derived
            self.defaultModelKey = derived.first
        } else {
            self.orderedModelKeys = loadedKeys
            self.defaultModelKey = state.defaultModelKey
        }
        
        // 加载后同步过滤一次，防止某些异常情况导致的数据不匹配
        syncActiveModelKeys(saveAfterSync: false)
    }

    func save() {
        let state = PersistedState(
            providers: providers,
            revision: revision,
            orderedModelKeys: orderedModelKeys,
            defaultModelKey: defaultModelKey
        )
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
