// ClawdHome/Models/AccountKeychain.swift
// 为全局模型池账户安全存储凭据（API Key / URL）
// 使用 macOS Keychain，service 独立，key = accountId.uuidString

import Foundation
import Security

enum AccountKeychain {
    private static let service = "io.github.deepjerry.clawdhome.mac.accounts"

    static func save(_ value: String, for accountId: UUID) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for accountId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasCredential(for accountId: UUID) -> Bool {
        load(for: accountId) != nil
    }

    static func delete(for accountId: UUID) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
