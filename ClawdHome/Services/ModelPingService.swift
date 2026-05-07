// ClawdHome/Services/ModelPingService.swift
import Foundation

struct PingResult {
    let latencyMs: Double
    let success: Bool
    let errorMessage: String?
    let responseText: String?
}

actor ModelPingService {
    static let shared = ModelPingService()

    func ping(
        modelId: String,
        apiKey: String,
        message: String? = nil,
        baseURL: String? = nil,
        apiType: String? = nil,
        authHeader: Bool = false
    ) async -> PingResult {
        let start = Date()
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalMessage = normalizedMessage.isEmpty
            ? L10n.k("services.model_ping_service.hello_prompt", fallback: "请发送你好")
            : normalizedMessage
        do {
            let response = try await sendChat(
                modelId: modelId,
                apiKey: apiKey,
                message: finalMessage,
                baseURL: baseURL,
                apiType: apiType,
                authHeader: authHeader
            )
            let redactedResponse = redact(response, secret: apiKey)
            return PingResult(
                latencyMs: Date().timeIntervalSince(start) * 1000,
                success: true,
                errorMessage: nil,
                responseText: redactedResponse
            )
        } catch {
            // Redact API key from error message before surfacing to UI
            let msg = redact(error.localizedDescription, secret: apiKey)
            return PingResult(
                latencyMs: Date().timeIntervalSince(start) * 1000,
                success: false,
                errorMessage: msg,
                responseText: nil
            )
        }
    }

    /// Replace any occurrence of the secret in a string with [REDACTED].
    private func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    func chat(
        modelId: String,
        apiKey: String,
        message: String,
        baseURL: String? = nil,
        apiType: String? = nil,
        authHeader: Bool = false
    ) async throws -> String {
        return try await sendChat(
            modelId: modelId,
            apiKey: apiKey,
            message: message,
            baseURL: baseURL,
            apiType: apiType,
            authHeader: authHeader
        )
    }

    private func sendChat(
        modelId: String,
        apiKey: String,
        message: String,
        baseURL: String? = nil,
        apiType: String? = nil,
        authHeader: Bool = false
    ) async throws -> String {
        if let baseURL,
           !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mode = apiType ?? "openai-completions"
            let normalizedBase = normalizedBaseURL(baseURL)
            let effectiveModel = modelId.dropProviderPrefix()
            if mode.contains("anthropic") {
                return try await callAnthropic(
                    base: normalizedBase,
                    modelId: effectiveModel,
                    apiKey: apiKey,
                    message: message,
                    authHeader: authHeader
                )
            }
            return try await callOpenAI(
                base: normalizedBase,
                modelId: effectiveModel,
                apiKey: apiKey,
                message: message
            )
        }

        let prefix = modelId.components(separatedBy: "/").first ?? ""
        switch prefix {
        case "anthropic":
            return try await callAnthropic(
                base: "https://api.anthropic.com",
                modelId: modelId.dropPrefix("anthropic/"),
                apiKey: apiKey,
                message: message
            )
        case "openai":
            return try await callOpenAI(base: "https://api.openai.com", modelId: modelId.dropPrefix("openai/"), apiKey: apiKey, message: message)
        case "openrouter":
            return try await callOpenAI(base: "https://openrouter.ai", modelId: modelId.dropPrefix("openrouter/"), apiKey: apiKey, message: message)
        case "google":
            return try await callGoogle(modelId: modelId, apiKey: apiKey, message: message)
        case "qiniu":
            return try await callOpenAI(
                base: "https://api.qnaigc.com/v1",
                modelId: modelId.dropPrefix("qiniu/"),
                apiKey: apiKey,
                message: message
            )
        case "zai":
            return try await callOpenAI(
                base: "https://open.bigmodel.cn/api/paas/v4",
                modelId: modelId.dropPrefix("zai/"),
                apiKey: apiKey,
                message: message
            )
        case "minimax":
            return try await callAnthropic(
                base: "https://api.minimaxi.com/anthropic",
                modelId: modelId.dropPrefix("minimax/"),
                apiKey: apiKey,
                message: message,
                authHeader: true
            )
        case "kimi-coding":
            return try await callAnthropic(
                base: "https://api.kimi.com/coding",
                modelId: modelId.dropPrefix("kimi-coding/"),
                apiKey: apiKey,
                message: message
            )
        default:
            // Local model (e.g. ollama) — use OpenAI-compatible endpoint on localhost
            return try await callOpenAI(base: "http://localhost:18800", modelId: modelId, apiKey: "local", message: message)
        }
    }

    private func callAnthropic(
        base: String,
        modelId: String,
        apiKey: String,
        message: String,
        authHeader: Bool = false
    ) async throws -> String {
        let endpoint = anthropicEndpoint(base: base)
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        if authHeader {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelId,
            "max_tokens": 64,
            "messages": [["role": "user", "content": message]]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Ping", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP error"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    private func callOpenAI(base: String, modelId: String, apiKey: String, message: String) async throws -> String {
        let endpoint = openAIEndpoint(base: base)
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelId,
            "max_tokens": 64,
            "messages": [["role": "user", "content": message]]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Ping", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP error"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private func callGoogle(modelId: String, apiKey: String, message: String) async throws -> String {
        let rawModel = modelId.dropPrefix("google/")
        // Use x-goog-api-key header instead of URL query param to prevent key exposure in error messages
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(rawModel):generateContent"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": message]]]],
            "generationConfig": ["maxOutputTokens": 64]
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Ping", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP error"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    private func normalizedBaseURL(_ base: String) -> String {
        var value = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func anthropicEndpoint(base: String) -> String {
        let normalized = normalizedBaseURL(base)
        if normalized.hasSuffix("/v1/messages") { return normalized }
        if normalized.hasSuffix("/v1") { return "\(normalized)/messages" }
        return "\(normalized)/v1/messages"
    }

    private func openAIEndpoint(base: String) -> String {
        let normalized = normalizedBaseURL(base)
        if normalized.hasSuffix("/chat/completions") { return normalized }
        if normalized.hasSuffix("/v1") { return "\(normalized)/chat/completions" }
        if normalized.range(of: "/v\\d+$", options: .regularExpression) != nil {
            return "\(normalized)/chat/completions"
        }
        return "\(normalized)/v1/chat/completions"
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func dropProviderPrefix() -> String {
        let parts = split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return self }
        return parts[1]
    }
}
