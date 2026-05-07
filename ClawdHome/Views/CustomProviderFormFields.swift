// ClawdHome/Views/CustomProviderFormFields.swift
// 自定义提供商表单字段 — 共享组件，供 ModelPrioritySheet / UserDetailView 复用

import SwiftUI

/// 自定义模型提供商的表单字段组件
/// 字段顺序：兼容类型 → Base URL → API Key（带 show/hide）→ 模型（带拉取列表）→ Provider ID
struct CustomProviderFormFields: View {
    @Binding var compatibility: String          // "openai-completions" | "anthropic-messages"
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var modelId: String
    @Binding var providerId: String

    /// API Key 占位文字
    var apiKeyPlaceholder: String = L10n.k("views.custom_provider.api_key_placeholder", fallback: "留空则尝试使用 CUSTOM_API_KEY")
    /// 模型 ID 占位文字
    var modelIdPlaceholder: String = L10n.k("views.custom_provider.model_id_placeholder", fallback: "输入模型 ID（例如 gpt-4.1 / claude-3-7-sonnet）")

    /// 是否显示兼容类型选择器（ModelPrioritySheet 需要，UserDetailView 已有独立的）
    var showCompatibilityPicker: Bool = true

    // 内部状态
    @State private var isShowingApiKey = false
    @State private var isFetchingModels = false
    @State private var modelSuggestions: [String] = []
    @State private var fetchMessage: String? = nil
    @State private var fetchError: String? = nil

    var body: some View {
        if showCompatibilityPicker {
            Picker(L10n.k("model_priority.compatibility", fallback: "兼容类型"), selection: $compatibility) {
                Text("OpenAI").tag("openai-completions")
                Text("Anthropic").tag("anthropic-messages")
            }
            .pickerStyle(.segmented)
        }

        // Base URL
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("views.user_detail_view.base_url", fallback: "Base URL"))
                .font(.caption)
                .foregroundStyle(.primary)
            TextField("https://api.example.com/v1", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        // API Key（带眼睛切换）
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("model_priority.custom_api_key_label", fallback: "自定义 API Key"))
                .font(.caption)
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                Group {
                    if isShowingApiKey {
                        TextField(apiKeyPlaceholder, text: $apiKey)
                    } else {
                        SecureField(apiKeyPlaceholder, text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Button {
                    isShowingApiKey.toggle()
                } label: {
                    Image(systemName: isShowingApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(isShowingApiKey
                      ? L10n.k("user.detail.auto.hide", fallback: "隐藏")
                      : L10n.k("user.detail.auto.show", fallback: "显示"))
            }
        }

        // 模型（带"从 API 拉取列表"按钮）
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("model_priority.model_label", fallback: "模型"))
                .font(.caption)
                .foregroundStyle(.primary)
            TextField(modelIdPlaceholder, text: $modelId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 8) {
                Button(isFetchingModels ? L10n.k("views.custom_provider.fetching", fallback: "拉取中…") : L10n.k("views.custom_provider.fetch_from_api", fallback: "从 API 拉取列表")) {
                    Task { await fetchModels() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetchingModels || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !modelSuggestions.isEmpty {
                    Picker(L10n.k("views.user_detail_view.suggested_models", fallback: "可选模型"), selection: $modelId) {
                        ForEach(modelSuggestions, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }

            if let fetchMessage {
                Text(fetchMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let fetchError {
                Text(fetchError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }

        // Provider ID
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.k("model_priority.provider_id_label", fallback: "Provider ID（可选，默认 custom）"))
                .font(.caption)
                .foregroundStyle(.primary)
            TextField("custom", text: $providerId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if !providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(providerId.trimmingCharacters(in: .whitespacesAndNewlines))/")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 从 API 拉取模型列表

    private func fetchModels() async {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            fetchError = L10n.k("views.custom_provider.invalid_base_url", fallback: "请先填写有效的 Base URL")
            fetchMessage = nil
            return
        }

        isFetchingModels = true
        fetchError = nil
        fetchMessage = nil
        defer { isFetchingModels = false }

        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = try await CustomModelConfigUtils.fetchModelIDs(
                baseURL: trimmedURL,
                apiKey: key.isEmpty ? nil : key
            )
            if ids.isEmpty {
                modelSuggestions = []
                fetchMessage = L10n.k("views.custom_provider.no_models_found", fallback: "已请求成功，但未解析到可用模型 ID（该接口可能不支持标准 list）")
                return
            }
            modelSuggestions = ids
            if modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = ids.first {
                modelId = first
            }
            fetchMessage = L10n.f("views.custom_provider.models_fetched", fallback: "已拉取 %d 个模型", ids.count)
        } catch {
            fetchError = error.localizedDescription
        }
    }
}
