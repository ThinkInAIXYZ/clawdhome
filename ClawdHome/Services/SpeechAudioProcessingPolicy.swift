import Foundation

enum SpeechVocalEnhancementMode: Equatable {
    case fullFile
    case chunked
    case disabled
}

enum SpeechAudioVocalEnhancementSkipReason: Equatable {
    case audioTooLong
    case tempFileTooLarge
    case lowDiskSpace
}

struct SpeechVocalEnhancementDecision: Equatable {
    var mode: SpeechVocalEnhancementMode
    var reason: SpeechAudioVocalEnhancementSkipReason?
    var estimatedTempBytes: UInt64

    var shouldEnhance: Bool {
        mode != .disabled
    }
}

enum SpeechAudioProcessingPolicy {
    static let maxDefaultVocalEnhancementDurationSeconds: Double = 30 * 60
    static let maxDefaultVocalEnhancementTempBytes: UInt64 = 1 * 1024 * 1024 * 1024
    static let minimumTempFileHeadroomBytes: UInt64 = 512 * 1024 * 1024

    static func vocalEnhancementDecision(
        durationSeconds: Double?,
        sampleRate: Double?,
        channelCount: Int?,
        availableDiskBytes: UInt64
    ) -> SpeechVocalEnhancementDecision {
        let duration = max(durationSeconds ?? 0, 0)
        let estimatedTempBytes = estimatedFloat32PCMBytes(
            durationSeconds: duration,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        guard duration <= maxDefaultVocalEnhancementDurationSeconds else {
            return SpeechVocalEnhancementDecision(
                mode: .chunked,
                reason: .audioTooLong,
                estimatedTempBytes: estimatedTempBytes
            )
        }

        guard estimatedTempBytes <= maxDefaultVocalEnhancementTempBytes else {
            return SpeechVocalEnhancementDecision(
                mode: .chunked,
                reason: .tempFileTooLarge,
                estimatedTempBytes: estimatedTempBytes
            )
        }

        if estimatedTempBytes > 0,
           availableDiskBytes > 0,
           availableDiskBytes < estimatedTempBytes + minimumTempFileHeadroomBytes {
            return SpeechVocalEnhancementDecision(
                mode: .chunked,
                reason: .lowDiskSpace,
                estimatedTempBytes: estimatedTempBytes
            )
        }

        return SpeechVocalEnhancementDecision(
            mode: .fullFile,
            reason: nil,
            estimatedTempBytes: estimatedTempBytes
        )
    }

    private static func estimatedFloat32PCMBytes(
        durationSeconds: Double,
        sampleRate: Double?,
        channelCount: Int?
    ) -> UInt64 {
        guard durationSeconds > 0 else { return 0 }

        let framesPerSecond = max(sampleRate ?? 48_000, 1)
        let channels = max(channelCount ?? 1, 1)
        let bytes = durationSeconds * framesPerSecond * Double(channels) * Double(MemoryLayout<Float>.stride)

        guard bytes.isFinite, bytes > 0 else { return 0 }
        return UInt64(bytes.rounded(.up))
    }
}
