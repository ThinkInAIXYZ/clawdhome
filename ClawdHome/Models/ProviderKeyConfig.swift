// ClawdHome/Models/ProviderKeyConfig.swift
// 支持的 AI Provider 及其配置路径

import Foundation

enum ProviderConfigValue {
    case string(String)
    case bool(Bool)
}

struct ProviderKeyConfig: Identifiable {
    let id: String           // provider 标识（如 "anthropic"）
    let displayName: String  // UI 显示名
    let configPath: String   // openclaw config dot-path
    let placeholder: String  // 输入框占位符
    let isUrlConfig: Bool    // true = 填 URL 而非 API Key（Ollama）
    let supportsOAuth: Bool  // true = 支持 OAuth 授权（如 OpenAI Codex）
    /// 设置主配置时必须同步写入的附加键值对（如 moonshot 需要同时设 baseUrl）
    let sideConfigs: [(key: String, value: ProviderConfigValue)]

    init(id: String, displayName: String, configPath: String, placeholder: String,
         isUrlConfig: Bool, supportsOAuth: Bool,
         sideConfigs: [(key: String, value: ProviderConfigValue)] = []) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.placeholder = placeholder
        self.isUrlConfig = isUrlConfig
        self.supportsOAuth = supportsOAuth
        self.sideConfigs = sideConfigs
    }

    var inputLabel: String { isUrlConfig ? L10n.k("models.provider_key_config.service_url", fallback: "服务地址") : "API Key" }
}

/// 所有支持的 Provider（顺序即界面显示顺序）
/// 与 openclaw src/agents/models-config.providers.ts 同步
let supportedProviderKeys: [ProviderKeyConfig] = [
    // ── 直连 Provider ──────────────────────────────────────
    ProviderKeyConfig(
        id: "anthropic",
        displayName: "Anthropic",
        configPath: "models.providers.anthropic.apiKey",
        placeholder: "sk-ant-api...",
        isUrlConfig: false, supportsOAuth: false),
    ProviderKeyConfig(
        id: "openai",
        displayName: "OpenAI",
        configPath: "models.providers.openai.apiKey",
        placeholder: "sk-proj-...",
        isUrlConfig: false, supportsOAuth: true),   // OpenAI Codex (ChatGPT OAuth)
    ProviderKeyConfig(
        id: "google",
        displayName: "Google Gemini",
        configPath: "models.providers.google.apiKey",
        placeholder: "AIzaSy...",
        isUrlConfig: false, supportsOAuth: false),
    ProviderKeyConfig(
        id: "moonshot",
        displayName: "Moonshot（Kimi）",
        configPath: "models.providers.moonshot.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.moonshot.api", .string("openai-completions")),
            ("models.providers.moonshot.baseUrl", .string("https://api.moonshot.cn/v1")),
        ]),
    ProviderKeyConfig(
        id: "kimi-coding",
        displayName: "Kimi Coding",
        configPath: "models.providers.kimi-coding.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.kimi-coding.api", .string("anthropic-messages")),
            ("models.providers.kimi-coding.baseUrl", .string("https://api.kimi.com/coding/")),
        ]),
    ProviderKeyConfig(
        id: "minimax",
        displayName: "MiniMax",
        configPath: "models.providers.minimax.apiKey",
        placeholder: "eyJ...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.minimax.api", .string("anthropic-messages")),
            ("models.providers.minimax.baseUrl", .string("https://api.minimaxi.com/anthropic")),
            ("models.providers.minimax.authHeader", .bool(true)),
        ]),
    ProviderKeyConfig(
        id: "zai",
        displayName: L10n.k("model.provider.zai.name", fallback: "智谱 Z.AI"),
        configPath: "models.providers.zai.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.zai.api", .string("openai-completions")),
            ("models.providers.zai.baseUrl", .string("https://open.bigmodel.cn/api/paas/v4")),
        ]),
    // ── 网关 / 聚合 ────────────────────────────────────────
    ProviderKeyConfig(
        id: "openrouter",
        displayName: "OpenRouter",
        configPath: "models.providers.openrouter.apiKey",
        placeholder: "sk-or-...",
        isUrlConfig: false, supportsOAuth: false),
    // ── 本地 ───────────────────────────────────────────────
    ProviderKeyConfig(
        id: "ollama",
        displayName: "Ollama",
        configPath: "models.providers.ollama.baseUrl",
        placeholder: "http://localhost:11434",
        isUrlConfig: true, supportsOAuth: false),
]
