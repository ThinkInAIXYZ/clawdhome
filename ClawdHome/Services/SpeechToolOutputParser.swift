import Foundation

struct SpeechToolProgressEvent: Codable, Equatable {
    let kind: String
    let command: String
    let fractionCompleted: Double
    let message: String
    let transcript: String?
    let transcriptDelta: String?
    let mlxActiveMemoryBytes: Int?
    let mlxCacheMemoryBytes: Int?
    let mlxPeakMemoryBytes: Int?
    let mlxCacheLimitBytes: Int?

    init(
        kind: String,
        command: String,
        fractionCompleted: Double,
        message: String,
        transcript: String? = nil,
        transcriptDelta: String? = nil,
        mlxActiveMemoryBytes: Int? = nil,
        mlxCacheMemoryBytes: Int? = nil,
        mlxPeakMemoryBytes: Int? = nil,
        mlxCacheLimitBytes: Int? = nil
    ) {
        self.kind = kind
        self.command = command
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.transcript = transcript
        self.transcriptDelta = transcriptDelta
        self.mlxActiveMemoryBytes = mlxActiveMemoryBytes
        self.mlxCacheMemoryBytes = mlxCacheMemoryBytes
        self.mlxPeakMemoryBytes = mlxPeakMemoryBytes
        self.mlxCacheLimitBytes = mlxCacheLimitBytes
    }
}

enum SpeechToolOutputParser {
    private struct ToolErrorEnvelope: Decodable {
        let error: String?
    }

    static func progressEvent(from line: String) -> SpeechToolProgressEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpeechToolProgressEvent.self, from: data)
    }

    static func errorMessage(stdout: Data, stderr: Data) -> String {
        if let extracted = decodedErrorMessage(from: stdout) {
            return extracted
        }
        if let extracted = decodedErrorMessage(from: stderr) {
            return extracted
        }
        let stderrText = normalizedText(stderr)
        if !stderrText.isEmpty {
            return stderrText
        }
        let stdoutText = normalizedText(stdout)
        if !stdoutText.isEmpty {
            return stdoutText
        }
        return "Speech tool failed."
    }

    private static func decodedErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let envelope = try? JSONDecoder().decode(ToolErrorEnvelope.self, from: data),
           let error = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        let text = normalizedText(data)
        guard !text.isEmpty else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            if let envelope = try? JSONDecoder().decode(ToolErrorEnvelope.self, from: lineData),
               let error = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
               !error.isEmpty {
                return error
            }
        }
        return nil
    }

    private static func normalizedText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
