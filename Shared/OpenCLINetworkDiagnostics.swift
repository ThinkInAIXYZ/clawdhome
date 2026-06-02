import Foundation

struct OpenCLINetworkDiagnostics {
    private static let proxyKeys = [
        "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY",
        "https_proxy", "http_proxy", "all_proxy",
        "NO_PROXY", "no_proxy",
    ]

    static func curlEnvironmentAssignments(from proxyEnv: [String: String]) -> [String] {
        proxyKeys.compactMap { key in
            guard let raw = proxyEnv[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return "\(key)=\(raw)"
        }
    }

    static func proxySummary(from proxyEnv: [String: String]) -> String {
        let entries = curlEnvironmentAssignments(from: proxyEnv)
        if entries.isEmpty {
            return "未配置代理"
        }
        return entries.joined(separator: ", ")
    }

    static func failureMessage(
        action: String,
        url: URL,
        statusCode: Int?,
        body: Data?,
        underlying: String?,
        proxyEnv: [String: String]
    ) -> String {
        var parts = ["\(action)：\(url.absoluteString)"]
        if let statusCode {
            parts.append("HTTP \(statusCode)")
        }
        if let underlying, !underlying.isEmpty {
            parts.append("原始错误：\(underlying)")
        }
        let snippet = responseSnippet(from: body)
        if !snippet.isEmpty {
            parts.append("响应片段：\(snippet)")
        }
        parts.append("代理环境：\(proxySummary(from: proxyEnv))")
        return parts.joined(separator: " | ")
    }

    private static func responseSnippet(from body: Data?, limit: Int = 240) -> String {
        guard let body, !body.isEmpty else { return "" }
        let text = String(decoding: body.prefix(limit), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "<\(body.count) bytes binary>"
        }
        if body.count > limit {
            return "\(text)…"
        }
        return text
    }
}
