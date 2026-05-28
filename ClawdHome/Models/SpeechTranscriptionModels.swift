import Foundation
import Observation

enum SpeechToolAvailabilityReason: String, Codable {
    case supported
    case unsupportedCPU
    case unsupportedOS
    case missingBundledTool
    case toolLaunchFailed
}

struct SpeechToolAvailability: Codable, Equatable {
    var isAvailable: Bool
    var reason: SpeechToolAvailabilityReason
    var detail: String

    static let supported = SpeechToolAvailability(
        isAvailable: true,
        reason: .supported,
        detail: "Speech transcription is available."
    )
}

enum SpeechModelID: String, Codable, CaseIterable, Identifiable {
    case qwen3ASR17B8Bit = "qwen3-asr-1.7b-8bit"
    case qwen3ASR06B = "qwen3-asr-0.6b"

    var id: String { rawValue }

    var repositoryModelID: String {
        switch self {
        case .qwen3ASR17B8Bit:
            return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case .qwen3ASR06B:
            return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        }
    }

    var repositoryCachePathComponents: [String] {
        let parts = repositoryModelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return ["models", repositoryModelID]
        }
        return ["models", parts[0], parts[1]]
    }

    var cacheDirectoryName: String {
        switch self {
        case .qwen3ASR17B8Bit:
            return "qwen3-asr-1.7b-8bit"
        case .qwen3ASR06B:
            return "qwen3-asr-0.6b"
        }
    }
}

struct SpeechModelDescriptor: Codable, Identifiable, Equatable {
    var id: SpeechModelID
    var displayName: String
    var estimatedDiskGB: Double
}

enum SpeechRecommendationWarningKind: String, Codable, Hashable {
    case lowMemory
    case localAIServiceRunning
    case lowDiskSpace
    case unsupportedCPU
    case unsupportedOS
}

struct SpeechRecommendationWarning: Codable, Hashable, Identifiable {
    var id: String { kind.rawValue }
    var kind: SpeechRecommendationWarningKind
    var message: String
}

struct SpeechModelRecommendation: Codable, Equatable {
    var recommendedModel: SpeechModelID?
    var fallbackModel: SpeechModelID?
    var warnings: [SpeechRecommendationWarning]
    var availability: SpeechToolAvailability
}

enum SpeechHistoryStatus: String, Codable {
    case completed
    case failed
    case cancelled
}

struct SpeechHistoryRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var sourceFilePath: String
    var sourceFileName: String
    var sourceFileSizeBytes: Int64
    var durationSeconds: Double?
    var engineID: String
    var modelID: SpeechModelID
    var modelDisplayName: String
    var languageHintOrDetectedLanguage: String?
    var transcriptText: String
    var elapsedSeconds: Double
    var status: SpeechHistoryStatus
    var errorSummary: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceFilePath: String,
        sourceFileName: String,
        sourceFileSizeBytes: Int64,
        durationSeconds: Double? = nil,
        engineID: String,
        modelID: SpeechModelID,
        modelDisplayName: String,
        languageHintOrDetectedLanguage: String? = nil,
        transcriptText: String,
        elapsedSeconds: Double,
        status: SpeechHistoryStatus,
        errorSummary: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceFilePath = sourceFilePath
        self.sourceFileName = sourceFileName
        self.sourceFileSizeBytes = sourceFileSizeBytes
        self.durationSeconds = durationSeconds
        self.engineID = engineID
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.languageHintOrDetectedLanguage = languageHintOrDetectedLanguage
        self.transcriptText = transcriptText
        self.elapsedSeconds = elapsedSeconds
        self.status = status
        self.errorSummary = errorSummary
    }
}

enum SpeechTranscriptExportFormat {
    case txt
    case markdown
}

enum SpeechToolCommand: String {
    case probe
    case transcribe
}

let curatedSpeechModels: [SpeechModelDescriptor] = [
    SpeechModelDescriptor(
        id: .qwen3ASR17B8Bit,
        displayName: "Qwen3-ASR 1.7B 8-bit",
        estimatedDiskGB: 2.6
    ),
    SpeechModelDescriptor(
        id: .qwen3ASR06B,
        displayName: "Qwen3-ASR 0.6B",
        estimatedDiskGB: 1.1
    ),
]

/// 任务在队列中的状态
enum SpeechQueueItemStatus: String, Codable {
    case waiting      = "waiting"      // 等待中
    case transcribing = "transcribing" // 转译中
    case completed    = "completed"    // 已完成
    case failed       = "failed"       // 失败
    case cancelled    = "cancelled"    // 已取消
}

/// 队列中的单个音频任务项
@Observable
final class SpeechQueueItem: Identifiable, Hashable {
    let id: UUID
    let fileURL: URL
    var status: SpeechQueueItemStatus
    var progressFraction: Double
    var statusMessage: String?
    var transcriptText: String
    var elapsedSeconds: Double
    var errorSummary: String?
    
    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
        self.status = .waiting
        self.progressFraction = 0
        self.statusMessage = nil
        self.transcriptText = ""
        self.elapsedSeconds = 0
        self.errorSummary = nil
    }

    
    static func == (lhs: SpeechQueueItem, rhs: SpeechQueueItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

