// ClawdHomeHelper/Operations/OpenclawConfigSerializerV2.swift
// 直接读写 ~/.openclaw/openclaw.json 的批量序列化器（v2）。
// 与现有 ConfigWriter（基于 `openclaw config set` 单键操作）互补：
// - ConfigWriter：单字段 update，CLI 校验，适合简单标量
// - OpenclawConfigSerializerV2：批量改 accounts[]/bindings[]，直接操作 JSON，
//   原子写入，避免 N 次 CLI 调用且支持嵌套结构
//
// 写入策略：
// 1. 读取现有 JSON（缺失则起空对象）
// 2. 把 ShrimpConfigV2 的 imAccounts/agents/bindings 合并到对应字段
// 3. 验证 JSON 合法性
// 4. 原子写入（先 .tmp 后 rename），保证 chown 到目标用户

import Foundation

public enum OpenclawConfigSerializerV2 {

    /// openclaw.json 路径
    public static func configPath(username: String) -> String {
        "/Users/\(username)/.openclaw/openclaw.json"
    }

    // MARK: - Read

    /// 读取整个配置 JSON，返回根字典；不存在或损坏返回空字典。
    public static func readRaw(username: String) -> [String: Any] {
        let path = configPath(username: username)
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    /// 读出 ShrimpConfigV2（部分字段——不包含 providers，那部分在别处管理）。
    public static func readShrimpConfig(username: String) -> ShrimpConfigV2 {
        let root = readRaw(username: username)

        let agents = parseAgents(root)
        let imAccounts = parseImAccounts(root)
        let bindings = parseBindings(root)
        let feishuTop = parseFeishuTopLevel(root)
        let dmScope = parseDmScope(root)

        return ShrimpConfigV2(
            agents: agents,
            imAccounts: imAccounts,
            bindings: bindings,
            providers: [],
            feishuTopLevel: feishuTop,
            sessionDmScope: dmScope
        )
    }

    // MARK: - Write

    /// 把 ShrimpConfigV2 合并写入 openclaw.json（原子）。
    /// 仅覆盖 v2 管理的字段（agents/channels.<platform>.accounts/bindings/session.dmScope/feishu top）；
    /// 其他字段（plugins/secrets/env/...）保持不变。
    public static func writeShrimpConfig(_ config: ShrimpConfigV2, username: String) throws {
        var root = readRaw(username: username)

        applyAgents(config.agents, into: &root)
        applyImAccounts(config.imAccounts, into: &root)
        applyBindings(config.bindings, into: &root)
        applyFeishuTopLevel(config.feishuTopLevel, into: &root)

        // 自动账号级会话隔离
        let needsScope = config.needsAccountScopedDmSession
        let scope = needsScope ? .perAccountChannelPeer : (config.sessionDmScope ?? .perAccountChannelPeer)
        applyDmScope(needsScope ? scope : config.sessionDmScope, into: &root)

        try writeAtomic(root, username: username)
    }

    // MARK: - Targeted helpers (for incremental UI operations)

    /// 增 / 改一个 IMAccount。
    public static func upsertIMAccount(_ account: IMAccount, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        if let i = cfg.imAccounts.firstIndex(where: { $0.id == account.id && $0.platform == account.platform }) {
            cfg.imAccounts[i] = account
        } else {
            cfg.imAccounts.append(account)
        }
        try writeShrimpConfig(cfg, username: username)
    }

    /// 删除一个 IMAccount，并同时删除引用它的 bindings。
    public static func removeIMAccount(id: String, platform: IMPlatform, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        cfg.imAccounts.removeAll { $0.id == id && $0.platform == platform }
        cfg.bindings.removeAll { $0.channel == platform.openclawChannelId && $0.accountId == id }
        try writeShrimpConfig(cfg, username: username)
    }

    /// 增 / 改一条 Binding。
    public static func upsertBinding(_ binding: IMBinding, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        if let i = cfg.bindings.firstIndex(where: { $0.id == binding.id }) {
            cfg.bindings[i] = binding
        } else {
            cfg.bindings.append(binding)
        }
        try writeShrimpConfig(cfg, username: username)
    }

    public static func removeBinding(id: UUID, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        cfg.bindings.removeAll { $0.id == id }
        try writeShrimpConfig(cfg, username: username)
    }

    public static func upsertAgent(_ agent: AgentDef, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        if let i = cfg.agents.firstIndex(where: { $0.id == agent.id }) {
            cfg.agents[i] = agent
        } else {
            cfg.agents.append(agent)
        }
        // 保证至多一个 default
        if agent.isDefault {
            for j in cfg.agents.indices where cfg.agents[j].id != agent.id {
                cfg.agents[j].isDefault = false
            }
        }
        try writeShrimpConfig(cfg, username: username)
    }

    public static func removeAgent(id: String, username: String) throws {
        var cfg = readShrimpConfig(username: username)
        cfg.agents.removeAll { $0.id == id }
        cfg.bindings.removeAll { $0.agentId == id }
        try writeShrimpConfig(cfg, username: username)
    }

    // MARK: - Migration (v1 → v2)

    /// 检测 v1 形态：channels.feishu.appId / appSecret 在顶层，但没有 accounts。
    public static func isV1FeishuShape(_ root: [String: Any]) -> Bool {
        guard let channels = root["channels"] as? [String: Any],
              let feishu = channels["feishu"] as? [String: Any] else { return false }
        let hasTopAppId = (feishu["appId"] as? String).map { !$0.isEmpty } ?? false
        let hasAccounts = (feishu["accounts"] as? [String: Any])?.isEmpty == false
        return hasTopAppId && !hasAccounts
    }

    /// 把 v1 形态的飞书顶层凭证迁移到 accounts.<accountKey>。
    /// 调用方需要提供 accountKey（通常是新 agent 的 id 或 "default"）。
    /// 不修改 secrets / Keychain；appSecret 字段会带过去。
    public static func migrateV1FeishuToAccounts(accountKey: String, username: String) throws {
        var root = readRaw(username: username)
        guard isV1FeishuShape(root) else { return }
        var channels = root["channels"] as? [String: Any] ?? [:]
        var feishu = channels["feishu"] as? [String: Any] ?? [:]

        // 抽出顶层凭证
        let appId = feishu["appId"] as? String ?? ""
        let appSecret = feishu["appSecret"] as? String ?? ""
        let domain = feishu["domain"] as? String
        let dmPolicy = feishu["dmPolicy"] as? String
        let allowFrom = feishu["allowFrom"] as? [String] ?? []
        let botName = feishu["botName"] as? String

        var account: [String: Any] = [
            "appId": appId,
            "appSecret": appSecret,
        ]
        if let d = domain { account["domain"] = d }
        if let p = dmPolicy { account["dmPolicy"] = p }
        if !allowFrom.isEmpty { account["allowFrom"] = allowFrom }
        if let n = botName { account["botName"] = n }

        var accounts = feishu["accounts"] as? [String: Any] ?? [:]
        accounts[accountKey] = account
        // 同时保留顶层 default 引用（accounts.default = {} 引用顶层）
        if accounts["default"] == nil {
            accounts["default"] = [String: Any]()
        }
        feishu["accounts"] = accounts

        channels["feishu"] = feishu
        root["channels"] = channels

        try writeAtomic(root, username: username)
    }

    // MARK: - Internal: parsers

    private static func parseAgents(_ root: [String: Any]) -> [AgentDef] {
        guard let agentsRoot = root["agents"] as? [String: Any],
              let list = agentsRoot["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> AgentDef? in
            guard let id = item["id"] as? String else { return nil }
            let name = item["name"] as? String ?? id
            let isDefault = item["default"] as? Bool ?? false
            let workspace = item["workspace"] as? String
            var primary: String?
            var fallbacks: [String] = []
            if let model = item["model"] as? [String: Any] {
                primary = model["primary"] as? String
                fallbacks = model["fallbacks"] as? [String] ?? []
            } else if let modelStr = item["model"] as? String {
                primary = modelStr
            }
            return AgentDef(id: id, displayName: name, isDefault: isDefault,
                           workspace: workspace, modelPrimary: primary, modelFallbacks: fallbacks)
        }
    }

    private static func parseImAccounts(_ root: [String: Any]) -> [IMAccount] {
        guard let channels = root["channels"] as? [String: Any] else { return [] }
        var result: [IMAccount] = []

        for (channelId, value) in channels {
            guard let platform = IMPlatform.allCases.first(where: { $0.openclawChannelId == channelId }) else { continue }
            guard let section = value as? [String: Any] else { continue }
            guard let accounts = section["accounts"] as? [String: Any] else { continue }

            for (accountKey, accVal) in accounts {
                guard let acc = accVal as? [String: Any] else { continue }
                // 跳过空 default（仅引用顶层）
                if accountKey == "default" && acc.isEmpty { continue }

                let displayName = (acc["botName"] as? String) ?? (acc["name"] as? String) ?? accountKey
                let appId = acc["appId"] as? String ?? section["appId"] as? String
                let dmPolicyStr = acc["dmPolicy"] as? String
                let dmPolicy = dmPolicyStr.flatMap(DmPolicy.init(rawValue:))
                let allowFrom = acc["allowFrom"] as? [String] ?? []
                let domain = acc["domain"] as? String
                let brand: FeishuBrand? = {
                    guard platform == .feishu else { return nil }
                    if let d = domain, d == "lark" { return .lark }
                    return .feishu
                }()

                result.append(IMAccount(
                    id: accountKey,
                    platform: platform,
                    displayName: displayName,
                    appId: appId,
                    credsKeychainRef: nil,  // Keychain ref 在 ClawdHome 侧由 KeychainStore 维护
                    brand: brand,
                    dmPolicy: dmPolicy,
                    allowFrom: allowFrom,
                    domain: domain
                ))
            }
        }
        return result.sorted(by: { $0.id < $1.id })
    }

    private static func parseBindings(_ root: [String: Any]) -> [IMBinding] {
        guard let arr = root["bindings"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> IMBinding? in
            guard let agentId = item["agentId"] as? String,
                  let match = item["match"] as? [String: Any],
                  let channel = match["channel"] as? String else { return nil }
            let accountId = match["accountId"] as? String
            var peer: Peer?
            if let p = match["peer"] as? [String: Any],
               let kindStr = p["kind"] as? String,
               let kind = Peer.Kind(rawValue: kindStr),
               let pid = p["id"] as? String {
                peer = Peer(kind: kind, id: pid)
            }
            return IMBinding(agentId: agentId, channel: channel, accountId: accountId, peer: peer)
        }
    }

    private static func parseFeishuTopLevel(_ root: [String: Any]) -> FeishuTopLevel? {
        guard let channels = root["channels"] as? [String: Any],
              let feishu = channels["feishu"] as? [String: Any] else { return nil }
        var groups: [String: GroupConfig] = [:]
        if let g = feishu["groups"] as? [String: Any] {
            for (k, v) in g {
                guard let dict = v as? [String: Any] else { continue }
                groups[k] = GroupConfig(
                    requireMention: dict["requireMention"] as? Bool,
                    groupPolicy: dict["groupPolicy"] as? String,
                    allowFrom: dict["allowFrom"] as? [String]
                )
            }
        }
        return FeishuTopLevel(
            enabled: feishu["enabled"] as? Bool ?? true,
            threadSession: feishu["threadSession"] as? Bool ?? true,
            replyMode: feishu["replyMode"] as? String,
            groupPolicy: feishu["groupPolicy"] as? String,
            groupAllowFrom: feishu["groupAllowFrom"] as? [String] ?? [],
            groups: groups
        )
    }

    private static func parseDmScope(_ root: [String: Any]) -> DmScope? {
        guard let s = root["session"] as? [String: Any],
              let raw = s["dmScope"] as? String else { return nil }
        return DmScope(rawValue: raw)
    }

    // MARK: - Internal: appliers

    private static func applyAgents(_ agents: [AgentDef], into root: inout [String: Any]) {
        var section = root["agents"] as? [String: Any] ?? [:]
        section["list"] = agents.map { a -> [String: Any] in
            var dict: [String: Any] = ["id": a.id, "name": a.displayName]
            if a.isDefault { dict["default"] = true }
            if let ws = a.workspace { dict["workspace"] = ws }
            if let p = a.modelPrimary {
                if a.modelFallbacks.isEmpty {
                    dict["model"] = ["primary": p]
                } else {
                    dict["model"] = ["primary": p, "fallbacks": a.modelFallbacks]
                }
            }
            return dict
        }
        root["agents"] = section
    }

    private static func applyImAccounts(_ accounts: [IMAccount], into root: inout [String: Any]) {
        var channels = root["channels"] as? [String: Any] ?? [:]

        // 按 platform 分组
        let byPlatform = Dictionary(grouping: accounts, by: { $0.platform })

        for (platform, platAccounts) in byPlatform {
            let channelId = platform.openclawChannelId
            var section = channels[channelId] as? [String: Any] ?? [:]
            section["enabled"] = true

            var accountsDict: [String: Any] = [:]
            for acc in platAccounts {
                var dict: [String: Any] = [:]
                if let appId = acc.appId { dict["appId"] = appId }
                // appSecret 由 Keychain 管理；此处写入占位 ref（实际值由 OpenClaw 通过 secrets 引用读取）
                if let ref = acc.credsKeychainRef { dict["appSecret"] = "{{secrets.\(ref)}}" }
                dict["botName"] = acc.displayName
                if let p = acc.dmPolicy { dict["dmPolicy"] = p.rawValue }
                if !acc.allowFrom.isEmpty { dict["allowFrom"] = acc.allowFrom }
                if let d = acc.domain { dict["domain"] = d }
                accountsDict[acc.id] = dict
            }
            // 保留 default 空对象引用顶层（如果用户未显式定义 default）
            if accountsDict["default"] == nil, let existing = section["accounts"] as? [String: Any], existing["default"] != nil {
                accountsDict["default"] = existing["default"]
            }
            section["accounts"] = accountsDict

            channels[channelId] = section
        }

        // 删除已不存在 platform 的 accounts 字段（清理掉空 channels.<id>.accounts）
        for channelId in channels.keys {
            if !byPlatform.keys.contains(where: { $0.openclawChannelId == channelId }) {
                if var section = channels[channelId] as? [String: Any] {
                    section.removeValue(forKey: "accounts")
                    channels[channelId] = section
                }
            }
        }

        root["channels"] = channels
    }

    private static func applyBindings(_ bindings: [IMBinding], into root: inout [String: Any]) {
        root["bindings"] = bindings.map { b -> [String: Any] in
            var match: [String: Any] = ["channel": b.channel]
            if let aid = b.accountId { match["accountId"] = aid }
            if let p = b.peer {
                match["peer"] = ["kind": p.kind.rawValue, "id": p.id]
            }
            return ["agentId": b.agentId, "match": match]
        }
    }

    private static func applyFeishuTopLevel(_ top: FeishuTopLevel?, into root: inout [String: Any]) {
        guard let top else { return }
        var channels = root["channels"] as? [String: Any] ?? [:]
        var feishu = channels["feishu"] as? [String: Any] ?? [:]
        feishu["enabled"] = top.enabled
        feishu["threadSession"] = top.threadSession
        if let r = top.replyMode { feishu["replyMode"] = r }
        if let g = top.groupPolicy { feishu["groupPolicy"] = g }
        if !top.groupAllowFrom.isEmpty { feishu["groupAllowFrom"] = top.groupAllowFrom }
        if !top.groups.isEmpty {
            var groupsDict: [String: Any] = [:]
            for (k, v) in top.groups {
                var d: [String: Any] = [:]
                if let r = v.requireMention { d["requireMention"] = r }
                if let p = v.groupPolicy { d["groupPolicy"] = p }
                if let a = v.allowFrom { d["allowFrom"] = a }
                groupsDict[k] = d
            }
            feishu["groups"] = groupsDict
        }
        channels["feishu"] = feishu
        root["channels"] = channels
    }

    private static func applyDmScope(_ scope: DmScope?, into root: inout [String: Any]) {
        guard let scope else { return }
        var session = root["session"] as? [String: Any] ?? [:]
        session["dmScope"] = scope.rawValue
        root["session"] = session
    }

    // MARK: - Internal: atomic write

    private static func writeAtomic(_ json: [String: Any], username: String) throws {
        let path = configPath(username: username)
        let url = URL(fileURLWithPath: path)
        // 确保父目录存在
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = url.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        // 替换原文件
        if FileManager.default.fileExists(atPath: path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
        // chown 给目标用户（root 写入后需要还给 shrimp 用户）
        _ = try? Process.run(URL(fileURLWithPath: "/usr/sbin/chown"),
                             arguments: [username, path])
    }
}
