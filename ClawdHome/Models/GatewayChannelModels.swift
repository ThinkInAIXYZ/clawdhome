// Gateway channels.status 响应模型
// 参考 openclaw/src/gateway/protocol/schema/channels.ts

import Foundation

struct ChannelAccountSnapshot: Codable, Identifiable {
    let accountId: String
    let name: String?
    let enabled: Bool?
    let configured: Bool?
    let linked: Bool?
    let running: Bool?
    let connected: Bool?
    let lastConnectedAt: Int?
    let lastError: String?
    let healthState: String?
    let lastInboundAt: Int?
    let lastOutboundAt: Int?
    let allowFrom: [String]?
    /// 频道绑定的应用 ID（如飞书 cli_xxx），从 extra 展平到顶层
    let appId: String?
    let domain: String?

    var id: String { accountId }

    /// 是否已配置（configured 或 linked 为 true）
    var isBound: Bool {
        (configured ?? false) || (linked ?? false)
    }
}

struct ChannelUiMeta: Codable, Identifiable {
    let id: String
    let label: String
    let detailLabel: String
    let systemImage: String?
}

struct ChannelsStatusResult: Codable {
    let ts: Int
    let channelOrder: [String]
    let channelLabels: [String: String]
    let channelDetailLabels: [String: String]?
    let channelSystemImages: [String: String]?
    let channelMeta: [ChannelUiMeta]?
    let channelAccounts: [String: [ChannelAccountSnapshot]]
    let channelDefaultAccountId: [String: String]?
}
