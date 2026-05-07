// Copyright (c) 2026 ClawdHome
// SPDX-License-Identifier: MIT
//
// 多 Agent / 多 IM Bot 配置数据模型 (v2)
//
// 对齐 OpenClaw `openclaw.json` 真实字段结构。详见
// docs/plans/2026-04-18-init-redesign-design.md 附录 B。
//
// 序列化约定：
// - 所有敏感字段（appSecret/token 等）以 Keychain item 名引用，不在 JSON 明文存
// - channels.<platform>.accounts 是 record，key 即 accountId，值是 Account 配置
// - bindings 是顶层数组，连接 agent ↔ account ↔ peer (peer 可选)
// - session.dmScope 在多账号时强制为 "per-account-channel-peer"

import Foundation

// MARK: - Platform / Cardinality

/// IM 平台标识。值与 OpenClaw channel id 完全一致。
public enum IMPlatform: String, Codable, CaseIterable, Sendable {
    case feishu      // openclaw-lark plugin（lark 品牌也用这个 id，brand 字段区分）
    case wechat      // openclaw-weixin plugin
    case slack
    case discord
    case telegram
    case whatsapp
    case tlon

    /// OpenClaw 实际使用的 channel id。多数等于 rawValue，少数 plugin 改名了。
    public var openclawChannelId: String {
        switch self {
        case .wechat: return "openclaw-weixin"
        default:      return rawValue
        }
    }

    /// 是否支持 OpenClaw 标准 `channels login` 命令。
    /// 决定 ProvisionerFactory 选哪个实现。
    public var supportsStandardChannelLogin: Bool {
        switch self {
        case .wechat, .whatsapp, .tlon: return true
        case .feishu:                   return false  // 飞书 plugin 暂未接，走 fallback
        case .slack, .discord, .telegram: return false  // 走表单贴 token
        }
    }

    public var cardinality: Cardinality {
        switch self {
        case .wechat: return .single
        default:      return .multi
        }
    }

    public var displayName: String {
        switch self {
        case .feishu:    return "飞书 / Lark"
        case .wechat:    return "微信"
        case .slack:     return "Slack"
        case .discord:   return "Discord"
        case .telegram:  return "Telegram"
        case .whatsapp:  return "WhatsApp"
        case .tlon:      return "Tlon"
        }
    }
}

/// 账号 cardinality：1 个 IM 账号最多绑定多少个 agent / bot。
public enum Cardinality: String, Codable, Sendable {
    case single  // 微信个人号：1 账号 = 1 bot
    case multi   // 飞书 / Slack / Discord：1 账号可绑多个 agent / 多个群
}

// MARK: - IMAccount

/// 一个 IM 平台账号（飞书 App / Slack workspace / 微信号 / ...）。
/// 序列化到 `channels.<platform>.accounts.<id>`。
public struct IMAccount: Codable, Identifiable, Hashable, Sendable {
    /// accountKey，作为 record key（如 "work" / "personal" / agent 自身的 id）。
    public var id: String

    public var platform: IMPlatform

    /// 用户可见的标签，对应 openclaw 的 `botName` 字段（或类似）。
    public var displayName: String

    /// 平台返回的 bot/app id（飞书 client_id；微信 ilink_bot_id；Slack workspace id 等）。
    /// 非敏感，可明文存。
    public var appId: String?

    /// Keychain 中存放敏感凭证的 item 名。
    /// 取出时拿到 JSON：{"appSecret":"...","encryptKey":"...","botToken":"..."}（按平台不同）。
    public var credsKeychainRef: String?

    // 飞书特有
    public var brand: FeishuBrand?         // .feishu / .lark
    public var dmPolicy: DmPolicy?         // 私聊策略
    public var allowFrom: [String]         // open_id / chat_id 列表
    public var domain: String?             // 自建域名

    /// 创建时间
    public var createdAt: Date

    public init(
        id: String,
        platform: IMPlatform,
        displayName: String,
        appId: String? = nil,
        credsKeychainRef: String? = nil,
        brand: FeishuBrand? = nil,
        dmPolicy: DmPolicy? = nil,
        allowFrom: [String] = [],
        domain: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.displayName = displayName
        self.appId = appId
        self.credsKeychainRef = credsKeychainRef
        self.brand = brand
        self.dmPolicy = dmPolicy
        self.allowFrom = allowFrom
        self.domain = domain
        self.createdAt = createdAt
    }
}

public enum FeishuBrand: String, Codable, Sendable {
    case feishu, lark
}

public enum DmPolicy: String, Codable, CaseIterable, Sendable {
    case pairing      // 默认。陌生人收到配对码，需 owner 批准
    case allowlist    // 只有 allowFrom 中的用户可以聊天
    case open         // 全部允许
    case disabled     // 禁用私聊
}

// MARK: - AgentDef

/// 一个 OpenClaw agent 定义。序列化到 `agents.list[]`。
public struct AgentDef: Codable, Identifiable, Hashable, Sendable {
    public var id: String                   // openclaw agent id
    public var displayName: String          // 对应 openclaw `name`
    public var isDefault: Bool              // 对应 openclaw `default`
    public var workspace: String?           // 对应 openclaw `workspace`，默认 ~/.openclaw/workspace-<id>
    public var modelPrimary: String?        // 对应 openclaw `model.primary`
    public var modelFallbacks: [String]     // 对应 openclaw `model.fallbacks`
    public var roleTemplateId: String?      // ClawdHome 侧概念，不写入 openclaw.json

    public init(
        id: String,
        displayName: String,
        isDefault: Bool = false,
        workspace: String? = nil,
        modelPrimary: String? = nil,
        modelFallbacks: [String] = [],
        roleTemplateId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.workspace = workspace
        self.modelPrimary = modelPrimary
        self.modelFallbacks = modelFallbacks
        self.roleTemplateId = roleTemplateId
    }
}

// MARK: - IMBinding

/// agent ↔ IM 账号 / peer 路由绑定。序列化到顶层 `bindings[]`。
public struct IMBinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var agentId: String              // 引用 AgentDef.id
    public var channel: String              // 引用 IMPlatform.openclawChannelId
    public var accountId: String?           // 引用 IMAccount.id；nil 表示通配
    public var peer: Peer?                  // nil 表示"整个账号"

    public init(
        id: UUID = UUID(),
        agentId: String,
        channel: String,
        accountId: String? = nil,
        peer: Peer? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.channel = channel
        self.accountId = accountId
        self.peer = peer
    }
}

public struct Peer: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case direct    // 单聊
        case group     // 群聊
        case channel   // 频道
    }
    public var kind: Kind
    public var id: String                   // 平台原生 id（飞书 oc_xxx / ou_xxx，Slack C12345 等）

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

// MARK: - Top-level extras

/// 飞书 channel 顶层非 accounts 字段。序列化到 `channels.feishu`（不含 accounts）。
public struct FeishuTopLevel: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var threadSession: Bool
    public var replyMode: String?           // "auto" / "thread" / ...
    public var groupPolicy: String?         // "allowlist" / "open" / ...
    public var groupAllowFrom: [String]
    public var groups: [String: GroupConfig]   // chat_id → 群配置

    public init(
        enabled: Bool = true,
        threadSession: Bool = true,
        replyMode: String? = "auto",
        groupPolicy: String? = nil,
        groupAllowFrom: [String] = [],
        groups: [String: GroupConfig] = [:]
    ) {
        self.enabled = enabled
        self.threadSession = threadSession
        self.replyMode = replyMode
        self.groupPolicy = groupPolicy
        self.groupAllowFrom = groupAllowFrom
        self.groups = groups
    }
}

public struct GroupConfig: Codable, Hashable, Sendable {
    public var requireMention: Bool?
    public var groupPolicy: String?
    public var allowFrom: [String]?

    public init(requireMention: Bool? = nil, groupPolicy: String? = nil, allowFrom: [String]? = nil) {
        self.requireMention = requireMention
        self.groupPolicy = groupPolicy
        self.allowFrom = allowFrom
    }
}

// MARK: - Session

/// `session.dmScope` 取值。
public enum DmScope: String, Codable, Sendable {
    case main
    case perPeer = "per-peer"
    case perChannelPeer = "per-channel-peer"
    case perAccountChannelPeer = "per-account-channel-peer"
}

// MARK: - Provider (model) — 占位，复用现有 ProviderKeyConfig 即可

/// 简化的 provider 引用，详细配置仍在 ClawdHome/Models/ProviderKeyConfig.swift。
public struct ModelProviderRef: Codable, Hashable, Sendable {
    public var id: String                   // openclaw provider id
    public var name: String
    public var modelIds: [String]
    public init(id: String, name: String, modelIds: [String]) {
        self.id = id; self.name = name; self.modelIds = modelIds
    }
}

// MARK: - Aggregate

/// ClawdHome 侧的 Shrimp 配置聚合。序列化时拼成 OpenClaw 的 openclaw.json。
public struct ShrimpConfigV2: Codable, Hashable, Sendable {
    public var agents: [AgentDef]
    public var imAccounts: [IMAccount]
    public var bindings: [IMBinding]
    public var providers: [ModelProviderRef]
    public var feishuTopLevel: FeishuTopLevel?
    public var sessionDmScope: DmScope?

    public init(
        agents: [AgentDef] = [],
        imAccounts: [IMAccount] = [],
        bindings: [IMBinding] = [],
        providers: [ModelProviderRef] = [],
        feishuTopLevel: FeishuTopLevel? = nil,
        sessionDmScope: DmScope? = nil
    ) {
        self.agents = agents
        self.imAccounts = imAccounts
        self.bindings = bindings
        self.providers = providers
        self.feishuTopLevel = feishuTopLevel
        self.sessionDmScope = sessionDmScope
    }

    /// 自动判断是否需要开启账号级会话隔离（多账号时必须）。
    public var needsAccountScopedDmSession: Bool {
        // 同平台 >= 2 个账号即触发
        let byPlatform = Dictionary(grouping: imAccounts, by: { $0.platform })
        return byPlatform.values.contains { $0.count >= 2 }
    }
}
