// ClawdHome/Services/DeviceIdentity.swift
// Ed25519 设备标识管理：生成、持久化、签名
// 用于 Gateway Control UI WebSocket 认证（device identity）

import CryptoKit
import Foundation

/// 管理 ClawdHome 的设备标识（Ed25519 密钥对）
/// - deviceId = SHA-256(publicKey raw bytes)，hex 编码
/// - 密钥对持久化到 Application Support 目录
/// - 签名格式遵循 openclaw gateway 的 v2 payload 规范
struct DeviceIdentity {

    let deviceId: String           // SHA-256(publicKey) hex
    let publicKeyBase64url: String // raw public key, base64url
    private let privateKey: Curve25519.Signing.PrivateKey

    // MARK: - 加载/创建

    /// 从磁盘加载已有密钥对，不存在则创建新的
    static func loadOrCreate() -> DeviceIdentity {
        let storePath = Self.storagePath()
        if let data = try? Data(contentsOf: storePath),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           stored.version == 1,
           let rawKey = Data(base64Encoded: stored.privateKeyBase64) {
            if let privKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey) {
                return DeviceIdentity(privateKey: privKey)
            }
        }
        // 创建新密钥对
        let identity = DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
        identity.save()
        return identity
    }

    // MARK: - 签名

    /// 构建 device auth payload 并签名
    /// - Parameters:
    ///   - clientId: 客户端 ID（如 "openclaw-control-ui"）
    ///   - clientMode: 客户端模式（如 "ui"）
    ///   - role: 角色（如 "operator"）
    ///   - scopes: 权限列表
    ///   - token: 认证令牌
    ///   - nonce: 服务端 challenge 中的 nonce
    /// - Returns: (signature: base64url, signedAt: ms timestamp)
    func sign(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String,
        nonce: String
    ) -> (signature: String, signedAt: Int64) {
        let signedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let scopeStr = scopes.joined(separator: ",")
        // v2 payload 格式：v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
        let payload = "v2|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopeStr)|\(signedAt)|\(token)|\(nonce)"
        let payloadData = Data(payload.utf8)
        // Ed25519 签名不会抛出异常（CryptoKit 实现）
        let sig = try! privateKey.signature(for: payloadData)
        return (base64urlEncode(Data(sig)), signedAt)
    }

    /// 构建 connect 帧的 device 字段
    func connectDevice(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String,
        nonce: String
    ) -> [String: Any] {
        let (signature, signedAt) = sign(
            clientId: clientId, clientMode: clientMode,
            role: role, scopes: scopes, token: token, nonce: nonce
        )
        return [
            "id": deviceId,
            "publicKey": publicKeyBase64url,
            "signature": signature,
            "signedAt": signedAt,
            "nonce": nonce,
        ]
    }

    // MARK: - 内部

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        let pubRaw = privateKey.publicKey.rawRepresentation
        // deviceId = SHA-256(raw public key), hex
        let hash = SHA256.hash(data: pubRaw)
        self.deviceId = hash.map { String(format: "%02x", $0) }.joined()
        self.publicKeyBase64url = base64urlEncode(pubRaw)
    }

    private func save() {
        let stored = StoredIdentity(
            version: 1,
            privateKeyBase64: privateKey.rawRepresentation.base64EncodedString(),
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let path = Self.storagePath()
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: path, options: .atomic)
    }

    private static func storagePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("device-identity-v1.json")
    }

    private struct StoredIdentity: Codable {
        let version: Int
        let privateKeyBase64: String
        let createdAtMs: Int64
    }
}

// MARK: - base64url 编码

private func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
