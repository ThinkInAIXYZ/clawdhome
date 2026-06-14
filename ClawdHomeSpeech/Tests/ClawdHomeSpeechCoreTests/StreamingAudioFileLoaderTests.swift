import AVFoundation
import XCTest
@testable import ClawdHomeSpeechCore

final class StreamingAudioFileLoaderTests: XCTestCase {
    func testReadsLongAudioAsOverlappedChunks() throws {
        let sourceURL = try Self.writeSineWaveWAV(durationSeconds: 65, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let chunkSamples = 30 * 16_000
        let overlapSamples = 2 * 16_000
        let chunks = try StreamingAudioFileLoader.readChunks(
            from: sourceURL,
            targetSampleRate: 16_000,
            chunkSamples: chunkSamples,
            overlapSamples: overlapSamples
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].index, 1)
        XCTAssertEqual(chunks[0].startSample, 0)
        XCTAssertEqual(chunks[0].samples.count, chunkSamples)
        XCTAssertEqual(chunks[1].startSample, 28 * 16_000)
        XCTAssertEqual(chunks[1].samples.count, chunkSamples)
        XCTAssertEqual(chunks[2].startSample, 56 * 16_000)
        XCTAssertEqual(chunks[2].samples.count, 9 * 16_000)
    }

    private static func writeSineWaveWAV(durationSeconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingAudioFileLoaderTests-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            samples[frame] = Float(sin(2.0 * Double.pi * 440.0 * t) * 0.2)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
