// Shared/NetworkModels.swift
// 网络策略数据模型（Helper 和 App 共用）

import Foundation

// MARK: - 每虾网络策略

public struct ShrimpNetworkPolicy: Codable, Sendable {
    public var mode: PolicyMode
    public var allowedHosts: [String]   // allowlist 模式有效
    public var blockedHosts: [String]   // blocklist 模式有效
    public var proxyEnabled: Bool
    public var proxyAddress: String?    // nil → 使用全局默认

    public init(mode: PolicyMode = .open,
                allowedHosts: [String] = [],
                blockedHosts: [String] = [],
                proxyEnabled: Bool = false,
                proxyAddress: String? = nil) {
        self.mode = mode
        self.allowedHosts = allowedHosts
        self.blockedHosts = blockedHosts
        self.proxyEnabled = proxyEnabled
        self.proxyAddress = proxyAddress
    }

    public enum PolicyMode: String, Codable, CaseIterable, Sendable {
        case open        // 不限制
        case allowlist   // 仅允许列表内
        case blocklist   // 仅屏蔽列表内

        public var label: String {
            switch self {
            case .open:      "开放"
            case .allowlist: "白名单"
            case .blocklist: "黑名单"
            }
        }
    }
}

// MARK: - 全局网络配置

public struct GlobalNetworkConfig: Codable, Sendable {
    public var pfEnabled: Bool
    public var defaultProxyAddress: String?

    public init(pfEnabled: Bool = false, defaultProxyAddress: String? = nil) {
        self.pfEnabled = pfEnabled
        self.defaultProxyAddress = defaultProxyAddress
    }
}
