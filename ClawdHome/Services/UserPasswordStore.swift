// ClawdHome/Services/UserPasswordStore.swift
// 为受管用户安全存储随机生成的 macOS 账户密码
// 使用 macOS Keychain（kSecClassGenericPassword）
// 用途：创建用户时自动生成并存储，远程桌面时免密连接

import Foundation
import Security

enum UserPasswordStoreError: LocalizedError {
    case invalidPasswordEncoding
    case keychainDenied(operation: String, status: OSStatus)
    case keychainFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPasswordEncoding:
            return L10n.k("services.user_password_store.passwordfailed_retry", fallback: "密码编码失败，请重试。")
        case .keychainDenied(let operation, _):
            return String(format: L10n.k("services.user_password_store.keychain_denied_operation", fallback: "Keychain 访问被拒绝（%@），请在系统弹窗中允许后重试。"), operation)
        case .keychainFailure(let operation, let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return String(format: L10n.k("services.user_password_store.operation_failed_detail", fallback: "%@失败：%@"), operation, message)
        }
    }
}

enum UserPasswordStore {
    private static let service = "ai.clawdhome.mac.user-pw"

    struct TestHooks {
        var randomPassword: () -> String
        var secItemDelete: (CFDictionary) -> OSStatus
        var secItemAdd: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        var secItemCopyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    }

    private static var testHooks: TestHooks?

    /// 为指定用户名生成并存储随机密码，返回生成的密码
    @discardableResult
    static func generateAndSave(for username: String) throws -> String {
        let password = randomPasswordValue()
        try save(password, for: username)
        return password
    }

    /// 存储密码（覆盖已有）
    static func save(_ password: String, for username: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw UserPasswordStoreError.invalidPasswordEncoding
        }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username
        ]
        _ = secItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = secItemAdd(addQuery as CFDictionary, nil)
        try throwIfKeychainFailure(status, operation: L10n.k("services.user_password_store.saveuserpassword", fallback: "保存用户密码"))
    }

    /// 读取已存储的密码（未存储时返回 nil）
    static func load(for username: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = secItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try throwIfKeychainFailure(status, operation: L10n.k("services.user_password_store.userpassword", fallback: "读取用户密码"))
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除指定用户的密码（删除用户时调用）
    static func delete(for username: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username
        ]
        _ = secItemDelete(query as CFDictionary)
    }

    static func _setTestHooks(_ hooks: TestHooks) {
        testHooks = hooks
    }

    static func _resetTestHooks() {
        testHooks = nil
    }

    // MARK: - 私有

    private static func throwIfKeychainFailure(_ status: OSStatus, operation: String) throws {
        guard status != errSecSuccess else { return }
        if isAccessDeniedStatus(status) {
            throw UserPasswordStoreError.keychainDenied(operation: operation, status: status)
        }
        throw UserPasswordStoreError.keychainFailure(operation: operation, status: status)
    }

    private static func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    private static func randomPasswordValue() -> String {
        testHooks?.randomPassword() ?? randomPassword()
    }

    private static func secItemDelete(_ query: CFDictionary) -> OSStatus {
        testHooks?.secItemDelete(query) ?? SecItemDelete(query)
    }

    private static func secItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        testHooks?.secItemAdd(query, result) ?? SecItemAdd(query, result)
    }

    private static func secItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        testHooks?.secItemCopyMatching(query, result) ?? SecItemCopyMatching(query, result)
    }

    /// 生成 20 位随机密码（大小写字母 + 数字，不含易混淆字符）
    private static func randomPassword() -> String {
        let chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"
        return String((0..<20).map { _ in chars.randomElement()! })
    }
}
