// ClawdHome/Services/ModelPingService.swift
import Foundation

struct PingResult {
    let latencyMs: Double
    let success: Bool
    let errorMessage: String?
}

actor ModelPingService {
    static let shared = ModelPingService()

    func ping(modelId: String, apiKey: String) async -> PingResult {
        let start = Date()
        do {
            let _ = try await sendChat(modelId: modelId, apiKey: apiKey, message: L10n.k("services.model_ping_service.you", fallback: "你好"))
            return PingResult(latencyMs: Date().timeIntervalSince(start) * 1000, success: true, errorMessage: nil)
        } catch {
            // Redact API key from error message before surfacing to UI
            let msg = redact(error.localizedDescription, secret: apiKey)
            return PingResult(latencyMs: Date().timeIntervalSince(start) * 1000, success: false, errorMessage: msg)
        }
    }

    /// Replace any occurrence of the secret in a string with [REDACTED].
    private func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[REDACTED]")
    }

    func chat(modelId: String, apiKey: String, message: String) async throws -> String {
        return try await sendChat(modelId: modelId, apiKey: apiKey, message: message)
    }

    private func sendChat(modelId: String, apiKey: String, message: String) async throws -> String {
        let prefix = modelId.components(separatedBy: "/").first ?? ""
        switch prefix {
        case "anthropic":
            return try await callAnthropic(modelId: modelId, apiKey: apiKey, message: message)
        case "openai":
            return try await callOpenAI(base: "https://api.openai.com", modelId: modelId.dropPrefix("openai/"), apiKey: apiKey, message: message)
        case "openrouter":
            return try await callOpenAI(base: "https://openrouter.ai", modelId: modelId.dropPrefix("openrouter/"), apiKey: apiKey, message: message)
        case "google":
            return try await callGoogle(modelId: modelId, apiKey: apiKey, message: message)
        default:
            // Local model (e.g. ollama) — use OpenAI-compatible endpoint on localhost
            return try await callOpenAI(base: "http://localhost:18800", modelId: modelId, apiKey: "local", message: message)
        }
    }

    private func callAnthropic(modelId: String, apiKey: String, message: String) async throws -> String {
        let rawModel = modelId.dropPrefix("anthropic/")
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": rawModel,
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
        var req = URLRequest(url: URL(string: "\(base)/v1/chat/completions")!)
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
}

private extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
