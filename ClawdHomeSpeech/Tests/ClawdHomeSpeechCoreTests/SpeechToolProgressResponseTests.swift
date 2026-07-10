import Foundation
import XCTest
@testable import ClawdHomeSpeechCore

final class SpeechToolProgressResponseTests: XCTestCase {
    func testEncodesFlatMLXMemoryFields() throws {
        let response = SpeechToolProgressResponse(
            kind: "progress",
            command: "transcribe",
            fractionCompleted: 0.5,
            message: "half",
            transcriptDelta: "text",
            memorySnapshot: SpeechInferenceMemorySnapshot(
                activeMemoryBytes: 11,
                cacheMemoryBytes: 22,
                peakMemoryBytes: 33,
                cacheLimitBytes: 44
            )
        )

        let data = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["mlxActiveMemoryBytes"] as? Int, 11)
        XCTAssertEqual(json["mlxCacheMemoryBytes"] as? Int, 22)
        XCTAssertEqual(json["mlxPeakMemoryBytes"] as? Int, 33)
        XCTAssertEqual(json["mlxCacheLimitBytes"] as? Int, 44)
        XCTAssertEqual(json["transcriptDelta"] as? String, "text")
    }
}
