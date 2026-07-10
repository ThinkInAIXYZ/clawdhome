import XCTest
@testable import ClawdHomeSpeechCore

final class SpeechInferenceMemoryPolicyTests: XCTestCase {
    private let mib: UInt64 = 1024 * 1024
    private let gib: UInt64 = 1024 * 1024 * 1024

    func testCacheLimitUsesMinimumForMissingOrSmallMemory() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 0),
            256 * Int(mib)
        )
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 4 * gib),
            256 * Int(mib)
        )
    }

    func testCacheLimitScalesForSixteenGigabytes() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 16 * gib),
            512 * Int(mib)
        )
    }

    func testCacheLimitCapsAtOneGibibyte() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 32 * gib),
            Int(gib)
        )
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 64 * gib),
            Int(gib)
        )
    }

    func testSnapshotKeepsByteCountsExactly() {
        let snapshot = SpeechInferenceMemorySnapshot(
            activeMemoryBytes: 11,
            cacheMemoryBytes: 22,
            peakMemoryBytes: 33,
            cacheLimitBytes: 44
        )

        XCTAssertEqual(snapshot.activeMemoryBytes, 11)
        XCTAssertEqual(snapshot.cacheMemoryBytes, 22)
        XCTAssertEqual(snapshot.peakMemoryBytes, 33)
        XCTAssertEqual(snapshot.cacheLimitBytes, 44)
    }
}
