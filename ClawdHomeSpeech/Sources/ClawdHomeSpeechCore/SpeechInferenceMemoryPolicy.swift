import Foundation

public enum SpeechInferenceMemoryPolicy {
    public static let minimumCacheLimitBytes = 256 * 1024 * 1024
    public static let maximumCacheLimitBytes = 1024 * 1024 * 1024

    public static func cacheLimitBytes(forPhysicalMemoryBytes physicalMemoryBytes: UInt64) -> Int {
        let scaled = physicalMemoryBytes / 32
        let minimum = UInt64(minimumCacheLimitBytes)
        let maximum = UInt64(maximumCacheLimitBytes)
        return Int(min(max(scaled, minimum), maximum))
    }
}

public struct SpeechInferenceMemorySnapshot: Equatable, Sendable {
    public let activeMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let peakMemoryBytes: Int
    public let cacheLimitBytes: Int

    public init(
        activeMemoryBytes: Int,
        cacheMemoryBytes: Int,
        peakMemoryBytes: Int,
        cacheLimitBytes: Int
    ) {
        self.activeMemoryBytes = activeMemoryBytes
        self.cacheMemoryBytes = cacheMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.cacheLimitBytes = cacheLimitBytes
    }
}
