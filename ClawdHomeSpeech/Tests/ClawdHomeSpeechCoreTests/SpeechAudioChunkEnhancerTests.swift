import XCTest
@testable import ClawdHomeSpeechCore

final class SpeechAudioChunkEnhancerTests: XCTestCase {
    func testEnhancePreservesChunkLengthAndChangesSamples() throws {
        let sampleRate = 16_000
        let samples = (0..<(sampleRate * 2)).map { frame -> Float in
            let t = Double(frame) / Double(sampleRate)
            let low = sin(2.0 * Double.pi * 60.0 * t) * 0.2
            let voice = sin(2.0 * Double.pi * 2_500.0 * t) * 0.1
            return Float(low + voice)
        }

        let enhanced = try SpeechAudioChunkEnhancer.enhance(samples, sampleRate: sampleRate)

        XCTAssertEqual(enhanced.count, samples.count)
        XCTAssertNotEqual(enhanced.prefix(1024).map { String(format: "%.6f", $0) }, samples.prefix(1024).map { String(format: "%.6f", $0) })
    }
}
