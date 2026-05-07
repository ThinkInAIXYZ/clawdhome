// ClawdHome/Services/ProviderKeychainStore.swift
import Foundation
import Security
import Observation

enum KnownProvider: String, CaseIterable {
    case anthropic
    case openai
    case google
    case openrouter

    var displayName: String {
        switch self {
        case .anthropic:  return "Anthropic"
        case .openai:     return "OpenAI"
        case .google:     return "Google AI"
        case .openrouter: return "OpenRouter"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic:  return "sk-ant-…"
        case .openai:     return "sk-…"
        case .google:     return "AIza…"
        case .openrouter: return "sk-or-…"
        }
    }

    static func from(modelId: String) -> KnownProvider? {
        let prefix = modelId.components(separatedBy: "/").first ?? ""
        return KnownProvider(rawValue: prefix)
    }
}

@Observable
final class ProviderKeychainStore {
    private let service = "io.github.deepjerry.clawdhome.mac"
    // Incrementing this counter inside save/delete causes @Observable to
    // invalidate any computed property (providerStatuses) that reads it.
    private var _keychainVersion: Int = 0

    private func account(for provider: KnownProvider) -> String {
        "provider.\(provider.rawValue)"
    }

    func save(apiKey: String, for provider: KnownProvider) {
        // Delete first to avoid errSecDuplicateItem on subsequent saves.
        delete(for: provider)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecValueData as String:   Data(apiKey.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
        _keychainVersion += 1
    }

    func read(for provider: KnownProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    func delete(for provider: KnownProvider) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider)
        ]
        SecItemDelete(query as CFDictionary)
        _keychainVersion += 1
    }

    func hasKey(for provider: KnownProvider) -> Bool {
        read(for: provider) != nil
    }

    /// Returns all providers with a flag indicating whether an API key is stored.
    /// Reading `_keychainVersion` establishes an @Observable dependency so
    /// SwiftUI views re-evaluate this property after every save/delete.
    var providerStatuses: [(provider: KnownProvider, hasKey: Bool)] {
        _ = _keychainVersion
        return KnownProvider.allCases.map { ($0, hasKey(for: $0)) }
    }
}
