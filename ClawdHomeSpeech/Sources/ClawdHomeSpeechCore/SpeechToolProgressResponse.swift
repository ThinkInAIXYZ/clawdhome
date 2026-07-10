import Foundation

public struct SpeechToolProgressResponse: Codable, Sendable {
    public let kind: String
    public let command: String
    public let fractionCompleted: Double
    public let message: String
    public let transcript: String?
    public let transcriptDelta: String?
    public let mlxActiveMemoryBytes: Int?
    public let mlxCacheMemoryBytes: Int?
    public let mlxPeakMemoryBytes: Int?
    public let mlxCacheLimitBytes: Int?

    public init(
        kind: String,
        command: String,
        fractionCompleted: Double,
        message: String,
        transcript: String? = nil,
        transcriptDelta: String? = nil,
        memorySnapshot: SpeechInferenceMemorySnapshot? = nil
    ) {
        self.kind = kind
        self.command = command
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.transcript = transcript
        self.transcriptDelta = transcriptDelta
        self.mlxActiveMemoryBytes = memorySnapshot?.activeMemoryBytes
        self.mlxCacheMemoryBytes = memorySnapshot?.cacheMemoryBytes
        self.mlxPeakMemoryBytes = memorySnapshot?.peakMemoryBytes
        self.mlxCacheLimitBytes = memorySnapshot?.cacheLimitBytes
    }
}
