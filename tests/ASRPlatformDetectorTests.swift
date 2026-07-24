import Foundation

@main
struct ASRPlatformDetectorTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(
            ASRPlatformDetector.detect(
                override: "arm64",
                hardwareARM64: 0,
                processArchitecture: "x86_64"
            ) == .appleSilicon,
            "arm64 override must take priority for tests"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: 1,
                processArchitecture: "x86_64"
            ) == .appleSilicon,
            "hardware sysctl must identify Apple Silicon under Rosetta"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: 0,
                processArchitecture: "arm64"
            ) == .intel,
            "successful hardware sysctl reporting 0 must remain Intel"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: "arm64"
            ) == .appleSilicon,
            "native arm64 must be accepted when sysctl is denied"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: "arm64e"
            ) == .appleSilicon,
            "arm64e fallback must be accepted when sysctl is denied"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: "x86_64"
            ) == .intel,
            "x86_64 fallback must remain unsupported"
        )
        expect(
            ASRPlatformDetector.detect(
                override: nil,
                hardwareARM64: nil,
                processArchitecture: nil
            ) == .unknown,
            "unavailable hardware and process probes must be unknown"
        )
        print("ASR platform detector tests passed.")
    }
}
