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
}

private struct PersistedState: Codable {
    var providers: [ProviderTemplate] = []
}

/// 全局模型池
@Observable
final class GlobalModelStore {
    private(set) var providers: [ProviderTemplate] = []

    var hasTemplate: Bool { providers.contains { !$0.modelIds.isEmpty } }

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
        save()
    }

    func updateProvider(_ entry: ProviderTemplate) {
        guard let idx = providers.firstIndex(where: { $0.id == entry.id }) else { return }
        providers[idx] = entry
        save()
    }

    func removeProvider(id: UUID) {
        if let provider = providers.first(where: { $0.id == id }) {
            // 删除账户时同步清理对应的 secrets 条目
            let secretKey = "\(provider.providerGroupId):\(provider.name)"
            GlobalSecretsStore.shared.delete(secretKey: secretKey)
        }
        providers.removeAll { $0.id == id }
        save()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        save()
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
    }

    func save() {
        let state = PersistedState(providers: providers)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.storeURL)
        }
    }
}
