// ClawdHome/Utils/FormatUtils.swift
import Foundation

enum FormatUtils {
    /// 将 bytes/sec 速率格式化为带单位字符串，如 "1.2 KB/s"
    static func formatBps(_ bps: Double) -> String {
        switch bps {
        case ..<1_000:       return String(format: "%.0f B/s", bps)
        case ..<1_000_000:   return String(format: "%.1f KB/s", bps / 1_000)
        default:             return String(format: "%.1f MB/s", bps / 1_000_000)
        }
    }

    /// 将字节数格式化为存储大小，如 "342.1 MB"
    static func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1_024:           return "\(bytes) B"
        case ..<1_048_576:       return String(format: "%.0f KB", Double(bytes) / 1_024)
        case ..<1_073_741_824:   return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        default:                 return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
    }

    /// 将累计 UInt64 字节格式化为简短显示
    static func formatTotalBytes(_ bytes: UInt64) -> String {
        formatBytes(Int64(min(bytes, UInt64(Int64.max))))
    }
}

enum CustomModelConfigUtils {
    struct CustomModelConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func resolvedAPIKey(_ raw: String, fallbackEnvName: String = "CUSTOM_API_KEY") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "${\(fallbackEnvName)}" : trimmed
    }

    static func modelsListURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(normalized)/models")
    }

    static func parseModelIDs(from payload: Any) -> [String] {
        if let dict = payload as? [String: Any] {
            if let data = dict["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
                if !ids.isEmpty { return dedupePreservingOrder(ids) }
            }
            if let models = dict["models"] as? [[String: Any]] {
                let ids = models.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
                if !ids.isEmpty { return dedupePreservingOrder(ids) }
            }
        }

        var ids: [String] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let id = dict["id"] as? String, !id.isEmpty {
                    ids.append(id)
                }
                for (_, child) in dict {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }
        walk(payload)
        return dedupePreservingOrder(ids)
    }

    static func fetchModelIDs(baseURL: String, apiKey: String?) async throws -> [String] {
        guard let endpoint = modelsListURL(from: baseURL) else {
            throw CustomModelConfigError(message: L10n.k("utils.custom_model.invalid_base_url", fallback: "Base URL 无效，无法拉取模型列表"))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomModelConfigError(message: L10n.k("utils.custom_model.no_response", fallback: "模型列表请求失败：无响应状态"))
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw CustomModelConfigError(message: L10n.f("utils.custom_model.http_error", fallback: "模型列表请求失败：HTTP %d", http.statusCode))
        }

        let payload = try JSONSerialization.jsonObject(with: data, options: [])
        return parseModelIDs(from: payload)
    }

    private static func dedupePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }
}
