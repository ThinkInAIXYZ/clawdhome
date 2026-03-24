// ClawdHome/Services/AppLockStore.swift
// App 管理密码：锁定 App 保护隐私
// 密码以 SHA-256 哈希存入 Keychain；支持 Touch ID 解锁
//
// 设计原则：
// - 启动时只读 UserDefaults，不触发 Keychain 弹窗
// - Keychain 仅在用户主动解锁时访问（语义正确）
// - Keychain 被拒绝时显示明确提示，而非静默失败

import Foundation
import Security
import CryptoKit
import LocalAuthentication
import Observation

/// 解锁结果
enum UnlockResult {
    case success
    case wrongPassword
    case keychainDenied   // Keychain 被用户拒绝访问
}

@Observable
@MainActor
final class AppLockStore {

    // MARK: - 状态

    /// 是否已启用 App 锁定
    private(set) var isEnabled: Bool = false

    /// 当前是否处于锁定状态
    private(set) var isLocked: Bool = false

    /// Touch ID 是否可用（硬件支持 + 已注册指纹/面容）
    private(set) var isBiometricAvailable: Bool = false

    /// Touch ID 解锁是否启用
    private(set) var isBiometricEnabled: Bool = false

    // MARK: - 持久化 Key

    private static let service           = "ai.clawdhome.mac.applock"
    private static let hashAccount       = "password-hash"
    private static let bioAccount        = "biometric-enabled"
    /// UserDefaults key — 启动时判断 enabled，不触发 Keychain 弹窗
    private static let enabledDefaultsKey = "ai.clawdhome.mac.applock.enabled"

    // MARK: - Init

    init() {
        let context = LAContext()
        var error: NSError?
        isBiometricAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &error)

        // 启动时只读 UserDefaults，不触发 Keychain 弹窗
        // Keychain 仅在用户实际输入密码时访问
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        isEnabled   = enabled
        isLocked    = enabled

        // biometric 设置存在 UserDefaults（也不触发弹窗）
        isBiometricEnabled = UserDefaults.standard.bool(
            forKey: Self.enabledDefaultsKey + ".biometric")
    }

    // MARK: - 密码管理

    /// 设置新密码（同时启用锁定）
    func setPassword(_ password: String) {
        saveHash(sha256(password))
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        isEnabled = true
        isLocked  = false
    }

    /// 更改密码（需先验证旧密码）
    func changePassword(old: String, new: String) -> UnlockResult {
        let result = verifyFull(old)
        guard result == .success else { return result }
        setPassword(new)
        return .success
    }

    /// 验证密码并解锁，返回详细结果
    func unlockWithPassword(_ password: String) -> UnlockResult {
        let result = verifyFull(password)
        if result == .success { isLocked = false }
        return result
    }

    /// 移除密码，禁用锁定
    func disableLock(password: String) -> UnlockResult {
        let result = verifyFull(password)
        guard result == .success else { return result }
        deleteHash()
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey + ".biometric")
        isEnabled          = false
        isLocked           = false
        isBiometricEnabled = false
        return .success
    }

    // MARK: - Touch ID

    func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey + ".biometric")
    }

    /// 尝试 Touch ID 解锁，成功后自动解锁 App
    func unlockWithBiometrics() async {
        guard isBiometricEnabled, isBiometricAvailable else { return }
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: L10n.k("services.app_lock_store.unlock_clawdhome", fallback: "解锁 ClawdHome")
            )
            if success { isLocked = false }
        } catch {
            // 用户取消或失败，保持锁定
        }
    }

    // MARK: - 锁定

    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    // MARK: - 私有：验证

    private func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 区分L10n.k("services.app_lock_store.password_incorrect", fallback: "密码错误")和L10n.k("services.app_lock_store.keychain", fallback: "Keychain 被拒绝")
    private func verifyFull(_ password: String) -> UnlockResult {
        guard let stored = loadHash() else {
            // loadHash 返回 nil：可能是 Keychain 被拒绝，也可能条目不存在
            // 通过尝试一次空查询区分（被拒绝时 errSecAuthFailed / errSecInteractionNotAllowed）
            return keychainIsDenied() ? .keychainDenied : .wrongPassword
        }
        return stored == sha256(password) ? .success : .wrongPassword
    }

    /// 检查 Keychain 访问是否被系统拒绝（区别于条目不存在）
    private func keychainIsDenied() -> Bool {
        // kSecUseAuthenticationUIFail 已在 macOS 11 废弃，改用 LAContext.interactionNotAllowed
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String:                    kSecClassGenericPassword,
            kSecAttrService as String:              Self.service,
            kSecAttrAccount as String:              Self.hashAccount,
            kSecReturnData as String:               false,
            kSecMatchLimit as String:               kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    // MARK: - 私有：Keychain

    private func saveHash(_ hash: String) {
        keychainSave(hash, account: Self.hashAccount)
    }

    private func loadHash() -> String? {
        keychainLoad(account: Self.hashAccount)
    }

    private func deleteHash() {
        keychainDelete(account: Self.hashAccount)
    }

    private func keychainSave(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
