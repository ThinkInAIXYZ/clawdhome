import Foundation
import Darwin

enum ASRPlatformDetector {
    enum Result: Equatable {
        case appleSilicon
        case intel
        case unknown
    }

    static func current() -> Result {
        let override = ProcessInfo.processInfo.environment["CLAWDHOME_CPU_ARCH_OVERRIDE"]
        if let override, !override.isEmpty {
            return detect(
                override: override,
                hardwareARM64: nil,
                processArchitecture: nil
            )
        }

        if let hardwareARM64 = hardwareARM64() {
            return detect(
                override: nil,
                hardwareARM64: hardwareARM64,
                processArchitecture: nil
            )
        }

        return detect(
            override: nil,
            hardwareARM64: nil,
            processArchitecture: processArchitecture()
        )
    }

    static func detect(
        override: String?,
        hardwareARM64: Int32?,
        processArchitecture: String?
    ) -> Result {
        if let override, !override.isEmpty {
            return override == "arm64" ? .appleSilicon : .intel
        }
        if let hardwareARM64 {
            return hardwareARM64 == 1 ? .appleSilicon : .intel
        }
        switch processArchitecture?.lowercased() {
        case "arm64", "arm64e":
            return .appleSilicon
        case "x86_64", "i386":
            return .intel
        default:
            return .unknown
        }
    }

    private static func hardwareARM64() -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func processArchitecture() -> String? {
        var uts = utsname()
        guard uname(&uts) == 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: uts.machine)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}
