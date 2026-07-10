import ClawdHomeSpeechCore
import Foundation
import MLX

public protocol SpeechMLXMemoryBackend: AnyObject {
    var activeMemoryBytes: Int { get }
    var cacheMemoryBytes: Int { get }
    var peakMemoryBytes: Int { get }
    var cacheLimitBytes: Int { get set }
    func clearCache()
}

public final class LiveSpeechMLXMemoryBackend: SpeechMLXMemoryBackend {
    public init() {}

    public var activeMemoryBytes: Int { Memory.activeMemory }
    public var cacheMemoryBytes: Int { Memory.cacheMemory }
    public var peakMemoryBytes: Int { Memory.peakMemory }

    public var cacheLimitBytes: Int {
        get { Memory.cacheLimit }
        set { Memory.cacheLimit = newValue }
    }

    public func clearCache() {
        Memory.clearCache()
    }
}

public final class SpeechMLXMemoryController {
    private let backend: any SpeechMLXMemoryBackend
    public let configuredCacheLimitBytes: Int

    public convenience init(physicalMemoryBytes: UInt64) {
        self.init(
            physicalMemoryBytes: physicalMemoryBytes,
            backend: LiveSpeechMLXMemoryBackend()
        )
    }

    public init(
        physicalMemoryBytes: UInt64,
        backend: any SpeechMLXMemoryBackend
    ) {
        self.backend = backend
        self.configuredCacheLimitBytes = SpeechInferenceMemoryPolicy.cacheLimitBytes(
            forPhysicalMemoryBytes: physicalMemoryBytes
        )
    }

    @discardableResult
    public func configure() -> SpeechInferenceMemorySnapshot {
        backend.cacheLimitBytes = configuredCacheLimitBytes
        backend.clearCache()
        return snapshot()
    }

    @discardableResult
    public func reclaim() -> SpeechInferenceMemorySnapshot {
        backend.clearCache()
        return snapshot()
    }

    public func runReclaiming<T>(
        _ operation: () throws -> T
    ) rethrows -> (value: T, snapshot: SpeechInferenceMemorySnapshot) {
        do {
            let value = try operation()
            return (value, reclaim())
        } catch {
            reclaim()
            throw error
        }
    }

    private func snapshot() -> SpeechInferenceMemorySnapshot {
        SpeechInferenceMemorySnapshot(
            activeMemoryBytes: backend.activeMemoryBytes,
            cacheMemoryBytes: backend.cacheMemoryBytes,
            peakMemoryBytes: backend.peakMemoryBytes,
            cacheLimitBytes: configuredCacheLimitBytes
        )
    }
}
