import Foundation

@main
struct SpeechModelAdvisorTests {
    private static let gibibyte: UInt64 = 1024 * 1024 * 1024

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let supportedOS = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let oldOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)

        let unsupportedCPU = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: false,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 32 * gibibyte,
                availableMemoryBytes: 20 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        expect(!unsupportedCPU.availability.isAvailable, "Intel should be unsupported")
        expect(unsupportedCPU.availability.reason == .unsupportedCPU, "Intel reason should be unsupportedCPU")

        let unsupportedOS = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: oldOS,
                physicalMemoryBytes: 32 * gibibyte,
                availableMemoryBytes: 20 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        expect(!unsupportedOS.availability.isAvailable, "macOS 14 should be unsupported")
        expect(unsupportedOS.availability.reason == .unsupportedOS, "OS reason should be unsupportedOS")

        let preferred = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 36 * gibibyte,
                availableMemoryBytes: 18 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        expect(preferred.availability.isAvailable, "supported path should be available")
        expect(preferred.recommendedModel == .qwen3ASR17B8Bit, "ample resources should recommend 1.7B")
        expect(preferred.fallbackModel == .qwen3ASR06B, "1.7B recommendation should expose 0.6B fallback")
        expect(preferred.warnings.isEmpty, "healthy machine should not emit warnings")

        let lowMemory = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 16 * gibibyte,
                availableMemoryBytes: 8 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        expect(lowMemory.recommendedModel == .qwen3ASR17B8Bit, "low memory should keep 1.7B as the default")
        expect(lowMemory.fallbackModel == .qwen3ASR06B, "low memory should expose 0.6B fallback")
        expect(lowMemory.warnings.contains { $0.kind == .lowMemory }, "low memory warning should be present")

        let lowDisk = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 36 * gibibyte,
                availableMemoryBytes: 18 * gibibyte,
                availableDiskBytes: 6 * gibibyte,
                localAIServiceRunning: false
            )
        )
        expect(lowDisk.recommendedModel == .qwen3ASR17B8Bit, "low disk should keep 1.7B as the default")
        expect(lowDisk.fallbackModel == .qwen3ASR06B, "low disk should expose 0.6B fallback")
        expect(lowDisk.warnings.contains { $0.kind == .lowDiskSpace }, "low disk warning should be present")

        let localAIRunning = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 36 * gibibyte,
                availableMemoryBytes: 18 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: true
            )
        )
        expect(localAIRunning.warnings.contains { $0.kind == .localAIServiceRunning }, "local AI warning should be present")

        print("Speech model advisor tests passed.")
    }
}
