// ClawdHome/Models/GlobalSecretsStore.swift
// 全局 secrets 存储（替代 Keychain，存为 JSON 文件）
// 存储路径：~/Library/Application Support/ClawdHome/secrets.json
// 权限说明：secrets.json 只有管理员用户可读；虾的 secrets 由 Helper 以 root 权限写入

import Foundation

/// 单条 secret 的存储结构
struct SecretEntry: Codable {
    var provider: String     // e.g. "anthropic"
    var accountName: String  // e.g. L10n.k("models.global_secrets_store.text_0010795e", fallback: "主账号")
    var value: String        // 明文 API Key 或 URL

    /// 在 secrets 文件中的 key（也用作 openclaw keyRef.id）
    var secretKey: String { "\(provider):\(accountName)" }
}

/// 全局 secrets 文件结构（管理员侧）
private struct SecretsFile: Codable {
    var version: Int = 1
    var secrets: [String: SecretEntry] = [:]  // key = secretKey
}

/// 管理员侧的全局 secrets 存储
/// 只在 ClawdHome.app 进程内访问（不需要 XPC），文件系统权限保护
final class GlobalSecretsStore {
    static let shared = GlobalSecretsStore()
    private init() {}

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClawdHome")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("secrets.json")
    }

    // MARK: - 读写

    /// 保存指定账户的 secret（provider:accountName → value）
    func save(entry: SecretEntry) {
        var file = load()
        file.secrets[entry.secretKey] = entry
        write(file)
    }

    /// 删除指定 secretKey 的条目
    func delete(secretKey: String) {
        var file = load()
        file.secrets.removeValue(forKey: secretKey)
        write(file)
    }

    /// 重命名：旧 secretKey → 新 SecretEntry（账户名变化时使用）
    func rename(oldKey: String, newEntry: SecretEntry) {
        var file = load()
        file.secrets.removeValue(forKey: oldKey)
        file.secrets[newEntry.secretKey] = newEntry
        write(file)
    }

    /// 读取指定 secretKey 的值（未存储时返回 nil）
    func value(for secretKey: String) -> String? {
        load().secrets[secretKey]?.value
    }

    /// 是否已存储指定 secretKey 的凭据
    func has(secretKey: String) -> Bool {
        load().secrets[secretKey] != nil
    }

    /// 所有已存储的条目（供L10n.k("models.global_secrets_store.text_1ff177a5", fallback: "同步到虾")功能使用）
    func allEntries() -> [SecretEntry] {
        Array(load().secrets.values)
    }

    /// 生成同步到虾的 secrets JSON 字符串
    /// 格式：{ "provider:accountName": "api-key-value", ... }
    func secretsPayload(for keys: [String]? = nil) -> String {
        let file = load()
        var dict: [String: String] = [:]
        let entries = keys == nil
            ? Array(file.secrets.values)
            : keys!.compactMap { file.secrets[$0] }
        for entry in entries {
            dict[entry.secretKey] = entry.value
        }
        guard let data = try? JSONEncoder().encode(dict),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    // MARK: - 私有

    private func load() -> SecretsFile {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let file = try? JSONDecoder().decode(SecretsFile.self, from: data)
        else { return SecretsFile() }
        return file
    }

    private func write(_ file: SecretsFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        // 先写临时文件再替换，防止写入中途崩溃导致数据丢失
        let tmpURL = Self.storeURL.appendingPathExtension("tmp")
        _ = try? data.write(to: tmpURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tmpURL.path
        )

        if FileManager.default.fileExists(atPath: Self.storeURL.path) {
            _ = try? FileManager.default.replaceItemAt(Self.storeURL, withItemAt: tmpURL)
        } else {
            try? FileManager.default.moveItem(at: tmpURL, to: Self.storeURL)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.storeURL.path
        )
    }
}
