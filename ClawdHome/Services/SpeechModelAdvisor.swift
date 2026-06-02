import Foundation

struct SpeechModelAdvisor {
    struct Input {
        let isAppleSilicon: Bool
        let operatingSystemVersion: OperatingSystemVersion
        let physicalMemoryBytes: UInt64
        let availableMemoryBytes: UInt64
        let availableDiskBytes: UInt64
        let localAIServiceRunning: Bool

        init(
            isAppleSilicon: Bool,
            operatingSystemVersion: OperatingSystemVersion,
            physicalMemoryBytes: UInt64,
            availableMemoryBytes: UInt64,
            availableDiskBytes: UInt64,
            localAIServiceRunning: Bool
        ) {
            self.isAppleSilicon = isAppleSilicon
            self.operatingSystemVersion = operatingSystemVersion
            self.physicalMemoryBytes = physicalMemoryBytes
            self.availableMemoryBytes = availableMemoryBytes
            self.availableDiskBytes = availableDiskBytes
            self.localAIServiceRunning = localAIServiceRunning
        }
    }

    private static let minimumSupportedOSMajorVersion = 15
    private static let preferredModelMinimumAvailableMemoryBytes: UInt64 = 12 * 1024 * 1024 * 1024
    private static let lowMemoryWarningThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024
    private static let lowDiskSpaceThresholdBytes: UInt64 = 8 * 1024 * 1024 * 1024

    static func recommend(for input: Input) -> SpeechModelRecommendation {
        if !input.isAppleSilicon {
            return SpeechModelRecommendation(
                recommendedModel: nil,
                fallbackModel: nil,
                warnings: [
                    SpeechRecommendationWarning(
                        kind: .unsupportedCPU,
                        message: "Speech transcription requires Apple Silicon."
                    )
                ],
                availability: SpeechToolAvailability(
                    isAvailable: false,
                    reason: .unsupportedCPU,
                    detail: "Speech transcription requires Apple Silicon."
                )
            )
        }
        if input.operatingSystemVersion.majorVersion < minimumSupportedOSMajorVersion {
            return SpeechModelRecommendation(
                recommendedModel: nil,
                fallbackModel: nil,
                warnings: [
                    SpeechRecommendationWarning(
                        kind: .unsupportedOS,
                        message: "Speech transcription requires macOS 15 or later."
                    )
                ],
                availability: SpeechToolAvailability(
                    isAvailable: false,
                    reason: .unsupportedOS,
                    detail: "Speech transcription requires macOS 15 or later."
                )
            )
        }

        var warnings: [SpeechRecommendationWarning] = []
        if input.physicalMemoryBytes < lowMemoryWarningThresholdBytes
            || input.availableMemoryBytes < preferredModelMinimumAvailableMemoryBytes {
            warnings.append(
                SpeechRecommendationWarning(
                    kind: .lowMemory,
                    message: "Available memory is currently low for the larger ASR model."
                )
            )
        }
        if input.localAIServiceRunning {
            warnings.append(
                SpeechRecommendationWarning(
                    kind: .localAIServiceRunning,
                    message: "Another local AI service is running and may reduce transcription stability."
                )
            )
        }
        if input.availableDiskBytes < lowDiskSpaceThresholdBytes {
            warnings.append(
                SpeechRecommendationWarning(
                    kind: .lowDiskSpace,
                    message: "Available disk space is low for model download and cache growth."
                )
            )
        }

        return SpeechModelRecommendation(
            recommendedModel: .qwen3ASR17B8Bit,
            fallbackModel: .qwen3ASR06B,
            warnings: warnings,
            availability: .supported
        )
    }
}
