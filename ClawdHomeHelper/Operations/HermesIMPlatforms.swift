// ClawdHomeHelper/Operations/HermesIMPlatforms.swift
// IM 平台 schema 定义：每个平台的必填/可选 env key 清单
//
// 权威来源：hermes-agent 源码 .env.example
// 以及 hermes_cli/gateway.py 中各平台的 "vars" 定义
//
// 所有 requiredEnvKeys 均可在 hermes-agent 源码中找到对应字段

import Foundation

// MARK: - 数据结构

struct HermesIMPlatform: Codable {
    /// 平台唯一标识（与 hermes gateway.py key 字段一致）
    let key: String
    /// 用户可见显示名
    let displayName: String
    /// 必填 env key 列表（缺少任何一个应拒绝绑定）
    let requiredEnvKeys: [String]
    /// 可选 env key 列表（可留空）
    let optionalEnvKeys: [String]
    /// 是否需要扫码 QR 配对（需要弹终端）
    let needsTerminalQR: Bool
}

struct HermesIMPlatforms {

    // MARK: - 平台注册表
    //
    // 来源对照（hermes-agent）：
    //
    // telegram     .env.example §TELEGRAM INTEGRATION
    //              TELEGRAM_BOT_TOKEN=                    (必填)
    //              TELEGRAM_ALLOWED_USERS=                (可选)
    //              TELEGRAM_HOME_CHANNEL=                 (可选)
    //              TELEGRAM_HOME_CHANNEL_NAME=            (可选)
    //              TELEGRAM_WEBHOOK_URL=                  (可选，webhook 模式)
    //
    // slack        .env.example §SLACK INTEGRATION
    //              SLACK_BOT_TOKEN=xoxb-...               (必填)
    //              SLACK_APP_TOKEN=xapp-...               (必填，Socket Mode)
    //              SLACK_ALLOWED_USERS=                   (可选)
    //
    // discord      gateway.py "key": "discord"
    //              DISCORD_BOT_TOKEN=                     (必填)
    //              DISCORD_ALLOWED_USERS=                 (可选)
    //              DISCORD_HOME_CHANNEL=                  (可选)
    //
    // feishu       gateway.py "key": "feishu"
    //              FEISHU_APP_ID=                         (必填)
    //              FEISHU_APP_SECRET=                     (必填)
    //              FEISHU_DOMAIN=                         (可选，feishu/lark)
    //              FEISHU_CONNECTION_MODE=                (可选，websocket/webhook)
    //              FEISHU_ALLOWED_USERS=                  (可选)
    //              FEISHU_HOME_CHANNEL=                   (可选)
    //
    // wecom        gateway.py "key": "wecom"
    //              WECOM_BOT_ID=                          (必填)
    //              WECOM_SECRET=                          (必填)
    //              WECOM_ALLOWED_USERS=                   (可选)
    //              WECOM_HOME_CHANNEL=                    (可选)
    //
    // dingtalk     gateway.py "key": "dingtalk"
    //              DINGTALK_CLIENT_ID=                    (必填)
    //              DINGTALK_CLIENT_SECRET=                (必填)
    //
    // email        .env.example §EMAIL + gateway.py "key": "email"
    //              EMAIL_ADDRESS=                         (必填)
    //              EMAIL_PASSWORD=                        (必填)
    //              EMAIL_IMAP_HOST=                       (必填)
    //              EMAIL_SMTP_HOST=                       (必填)
    //              EMAIL_ALLOWED_USERS=                   (可选)
    //              EMAIL_IMAP_PORT=                       (可选)
    //              EMAIL_SMTP_PORT=                       (可选)
    //              EMAIL_HOME_ADDRESS=                    (可选)
    //              EMAIL_POLL_INTERVAL=                   (可选)
    //
    // signal       gateway.py "key": "signal"
    //              SIGNAL_HTTP_URL=                       (必填，signal-cli REST API URL)
    //              SIGNAL_ACCOUNT=                        (必填)
    //              SIGNAL_ALLOWED_USERS=                  (可选)
    //
    // matrix       gateway.py "key": "matrix"
    //              MATRIX_HOMESERVER=                     (必填)
    //              MATRIX_ACCESS_TOKEN=                   (必填)
    //              MATRIX_USER_ID=                        (可选，password login 时必填)
    //              MATRIX_ALLOWED_USERS=                  (可选)
    //              MATRIX_HOME_ROOM=                      (可选)
    //
    // mattermost   gateway.py "key": "mattermost"
    //              MATTERMOST_URL=                        (必填)
    //              MATTERMOST_TOKEN=                      (必填)
    //              MATTERMOST_ALLOWED_USERS=              (可选)
    //              MATTERMOST_HOME_CHANNEL=               (可选)
    //              MATTERMOST_REPLY_MODE=                 (可选)
    //
    // whatsapp     .env.example WHATSAPP_ENABLED + gateway.py "key": "whatsapp"
    //              WHATSAPP_ENABLED=true                  (必填，需设为 true 激活)
    //              WHATSAPP_ALLOWED_USERS=                (可选)
    //              needsTerminalQR=true（Baileys QR 配对）
    //
    // weixin       gateway.py "key": "weixin"
    //              WEIXIN_ACCOUNT_ID=                     (必填，iLink 账号 ID)
    //              WEIXIN_TOKEN=                          (必填，iLink token)
    //              WEIXIN_BASE_URL=                       (可选)
    //              WEIXIN_CDN_BASE_URL=                   (可选)
    //              WEIXIN_ALLOWED_USERS=                  (可选)
    //              needsTerminalQR=true（iLink QR 扫码配对）

    static let all: [HermesIMPlatform] = [
        HermesIMPlatform(
            key: "telegram",
            displayName: "Telegram",
            requiredEnvKeys: [
                "TELEGRAM_BOT_TOKEN",
            ],
            optionalEnvKeys: [
                "TELEGRAM_ALLOWED_USERS",
                "TELEGRAM_HOME_CHANNEL",
                "TELEGRAM_HOME_CHANNEL_NAME",
                "TELEGRAM_WEBHOOK_URL",
                "TELEGRAM_WEBHOOK_PORT",
                "TELEGRAM_WEBHOOK_SECRET",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "slack",
            displayName: "Slack",
            requiredEnvKeys: [
                "SLACK_BOT_TOKEN",
                "SLACK_APP_TOKEN",
            ],
            optionalEnvKeys: [
                "SLACK_ALLOWED_USERS",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "discord",
            displayName: "Discord",
            requiredEnvKeys: [
                "DISCORD_BOT_TOKEN",
            ],
            optionalEnvKeys: [
                "DISCORD_ALLOWED_USERS",
                "DISCORD_HOME_CHANNEL",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "feishu",
            displayName: "飞书 / Lark",
            requiredEnvKeys: [
                "FEISHU_APP_ID",
                "FEISHU_APP_SECRET",
            ],
            optionalEnvKeys: [
                "FEISHU_DOMAIN",
                "FEISHU_CONNECTION_MODE",
                "FEISHU_ALLOWED_USERS",
                "FEISHU_HOME_CHANNEL",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "wecom",
            displayName: "企业微信",
            requiredEnvKeys: [
                "WECOM_BOT_ID",
                "WECOM_SECRET",
            ],
            optionalEnvKeys: [
                "WECOM_ALLOWED_USERS",
                "WECOM_HOME_CHANNEL",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "dingtalk",
            displayName: "钉钉",
            requiredEnvKeys: [
                "DINGTALK_CLIENT_ID",
                "DINGTALK_CLIENT_SECRET",
            ],
            optionalEnvKeys: [],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "email",
            displayName: "Email",
            requiredEnvKeys: [
                "EMAIL_ADDRESS",
                "EMAIL_PASSWORD",
                "EMAIL_IMAP_HOST",
                "EMAIL_SMTP_HOST",
            ],
            optionalEnvKeys: [
                "EMAIL_IMAP_PORT",
                "EMAIL_SMTP_PORT",
                "EMAIL_POLL_INTERVAL",
                "EMAIL_ALLOWED_USERS",
                "EMAIL_HOME_ADDRESS",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "signal",
            displayName: "Signal",
            requiredEnvKeys: [
                "SIGNAL_HTTP_URL",
                "SIGNAL_ACCOUNT",
            ],
            optionalEnvKeys: [
                "SIGNAL_ALLOWED_USERS",
                "SIGNAL_GROUP_ALLOWED_USERS",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "matrix",
            displayName: "Matrix",
            requiredEnvKeys: [
                "MATRIX_HOMESERVER",
                "MATRIX_ACCESS_TOKEN",
            ],
            optionalEnvKeys: [
                "MATRIX_USER_ID",
                "MATRIX_ALLOWED_USERS",
                "MATRIX_HOME_ROOM",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "mattermost",
            displayName: "Mattermost",
            requiredEnvKeys: [
                "MATTERMOST_URL",
                "MATTERMOST_TOKEN",
            ],
            optionalEnvKeys: [
                "MATTERMOST_ALLOWED_USERS",
                "MATTERMOST_HOME_CHANNEL",
                "MATTERMOST_REPLY_MODE",
            ],
            needsTerminalQR: false
        ),
        HermesIMPlatform(
            key: "whatsapp",
            displayName: "WhatsApp",
            requiredEnvKeys: [
                "WHATSAPP_ENABLED",
            ],
            optionalEnvKeys: [
                "WHATSAPP_ALLOWED_USERS",
            ],
            needsTerminalQR: true
        ),
        HermesIMPlatform(
            key: "weixin",
            displayName: "微信",
            requiredEnvKeys: [
                "WEIXIN_ACCOUNT_ID",
                "WEIXIN_TOKEN",
            ],
            optionalEnvKeys: [
                "WEIXIN_BASE_URL",
                "WEIXIN_CDN_BASE_URL",
                "WEIXIN_ALLOWED_USERS",
                "WEIXIN_DM_POLICY",
                "WEIXIN_ALLOW_ALL_USERS",
            ],
            needsTerminalQR: true
        ),
    ]

    // MARK: - 查询

    static func find(key: String) -> HermesIMPlatform? {
        all.first { $0.key == key }
    }
}
