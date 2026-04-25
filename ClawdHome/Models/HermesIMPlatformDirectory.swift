// ClawdHome/Models/HermesIMPlatformDirectory.swift
// App 侧 IM 平台目录（App target 不能引用 ClawdHomeHelper target，故在此镜像一份）
//
// 注：与 ClawdHomeHelper/Operations/HermesIMPlatforms.swift 保持同步
// 数据来源：hermes-agent .env.example 以及 hermes_cli/gateway.py 各平台 "vars" 定义

import Foundation

// MARK: - 数据结构

struct HermesIMPlatformInfo: Identifiable {
    var id: String { key }
    /// 平台唯一标识（与 helper 端 HermesIMPlatforms.swift key 完全一致）
    let key: String
    /// 用户可见显示名
    let displayName: String
    /// 必填 env key 列表（缺少任何一个拒绝绑定）
    let requiredEnvKeys: [String]
    /// 可选 env key 列表（可留空）
    let optionalEnvKeys: [String]
    /// 是否需要扫码 QR 配对（PR-5 接入；PR-4 阶段使用 placeholder）
    let needsTerminalQR: Bool
}

// MARK: - 平台注册表

enum HermesIMPlatformDirectory {
    static let all: [HermesIMPlatformInfo] = [
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
            key: "dingtalk",
            displayName: "钉钉",
            requiredEnvKeys: [
                "DINGTALK_CLIENT_ID",
                "DINGTALK_CLIENT_SECRET",
            ],
            optionalEnvKeys: [],
            needsTerminalQR: false
        ),
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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
        HermesIMPlatformInfo(
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

    static func find(key: String) -> HermesIMPlatformInfo? {
        all.first { $0.key == key }
    }
}
