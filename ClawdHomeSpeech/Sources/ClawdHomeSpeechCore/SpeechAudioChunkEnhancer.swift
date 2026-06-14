@preconcurrency import AVFoundation
import Foundation

public enum SpeechAudioChunkEnhancer {
    public static func enhance(_ samples: [Float], sampleRate: Int) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            inputBuffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 2)

        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.outputNode, format: format)

        let highPassBand = eq.bands[0]
        highPassBand.filterType = .highPass
        highPassBand.frequency = 100.0
        highPassBand.bypass = false

        let vocalBand = eq.bands[1]
        vocalBand.filterType = .parametric
        vocalBand.frequency = 2_500.0
        vocalBand.bandwidth = 1.0
        vocalBand.gain = 4.0
        vocalBand.bypass = false

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()
        player.scheduleBuffer(inputBuffer, at: nil, options: [])
        player.play()

        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maxFrames
        )!
        var enhanced: [Float] = []
        enhanced.reserveCapacity(samples.count)
        var retryCount = 0

        while enhanced.count < samples.count {
            let remaining = samples.count - enhanced.count
            let framesToRender = min(maxFrames, AVAudioFrameCount(remaining))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)

            switch status {
            case .success:
                retryCount = 0
                enhanced.append(contentsOf: firstChannelSamples(from: renderBuffer))
            case .insufficientDataFromInputNode:
                enhanced.append(contentsOf: samples[enhanced.count...])
            case .cannotDoInCurrentContext:
                retryCount += 1
                if retryCount > 8 {
                    enhanced.append(contentsOf: samples[enhanced.count...])
                }
            case .error:
                throw NSError(
                    domain: "ai.clawdhome.speech.enhance",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Chunk vocal enhancement failed."]
                )
            @unknown default:
                enhanced.append(contentsOf: samples[enhanced.count...])
            }
        }

        player.stop()
        engine.stop()

        if enhanced.count > samples.count {
            return Array(enhanced.prefix(samples.count))
        }
        return enhanced
    }

    private static func firstChannelSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
    }
}
