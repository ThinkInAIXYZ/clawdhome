@preconcurrency import AVFoundation
import Foundation

public struct SpeechAudioFileInfo: Equatable {
    public let estimatedTotalSamples: Int
    public let durationSeconds: Double
    public let sourceSampleRate: Double
    public let sourceChannelCount: Int
}

public struct SpeechAudioChunk: Equatable {
    public let index: Int
    public let startSample: Int
    public let endSample: Int
    public let samples: [Float]

    public func startTime(sampleRate: Int) -> Double {
        Double(startSample) / Double(sampleRate)
    }

    public func endTime(sampleRate: Int) -> Double {
        Double(endSample) / Double(sampleRate)
    }
}

public enum StreamingAudioFileLoader {
    public static func info(from url: URL, targetSampleRate: Int) throws -> SpeechAudioFileInfo {
        let audioFile = try AVAudioFile(forReading: url)
        return info(for: audioFile, targetSampleRate: targetSampleRate)
    }

    public static func readChunks(
        from url: URL,
        targetSampleRate: Int,
        chunkSamples: Int,
        overlapSamples: Int
    ) throws -> [SpeechAudioChunk] {
        var chunks: [SpeechAudioChunk] = []
        _ = try forEachChunk(
            from: url,
            targetSampleRate: targetSampleRate,
            chunkSamples: chunkSamples,
            overlapSamples: overlapSamples
        ) { chunk in
            chunks.append(chunk)
        }
        return chunks
    }

    @discardableResult
    public static func forEachChunk(
        from url: URL,
        targetSampleRate: Int,
        chunkSamples: Int,
        overlapSamples: Int,
        onChunk: (SpeechAudioChunk) throws -> Void
    ) throws -> SpeechAudioFileInfo {
        precondition(targetSampleRate > 0)
        precondition(chunkSamples > 0)
        precondition(overlapSamples >= 0 && overlapSamples < chunkSamples)

        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let fileInfo = info(for: audioFile, targetSampleRate: targetSampleRate)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
        let converter: AVAudioConverter?
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount {
            converter = nil
        } else {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        let sourceFrameCapacity = AVAudioFrameCount(min(max(Int(sourceFormat.sampleRate), 16_384), 65_536))
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCapacity)!
        let stepSamples = chunkSamples - overlapSamples
        var pending: [Float] = []
        var pendingStartSample = 0
        var chunkIndex = 0
        var lastEmittedEndSample = 0

        func emitReadyChunks() throws {
            while pending.count >= chunkSamples {
                chunkIndex += 1
                let samples = Array(pending.prefix(chunkSamples))
                let chunk = SpeechAudioChunk(
                    index: chunkIndex,
                    startSample: pendingStartSample,
                    endSample: pendingStartSample + samples.count,
                    samples: samples
                )
                try onChunk(chunk)
                lastEmittedEndSample = chunk.endSample
                pending.removeFirst(stepSamples)
                pendingStartSample += stepSamples
            }
        }

        while audioFile.framePosition < audioFile.length {
            try audioFile.read(into: sourceBuffer, frameCount: sourceFrameCapacity)
            guard sourceBuffer.frameLength > 0 else { break }

            let converted = try samples(from: sourceBuffer, converter: converter, targetFormat: targetFormat)
            if !converted.isEmpty {
                pending.append(contentsOf: converted)
                try emitReadyChunks()
            }
        }

        if pendingStartSample + pending.count > lastEmittedEndSample {
            chunkIndex += 1
            let chunk = SpeechAudioChunk(
                index: chunkIndex,
                startSample: pendingStartSample,
                endSample: pendingStartSample + pending.count,
                samples: pending
            )
            try onChunk(chunk)
        }

        return fileInfo
    }

    private static func info(for audioFile: AVAudioFile, targetSampleRate: Int) -> SpeechAudioFileInfo {
        let format = audioFile.processingFormat
        let duration = Double(audioFile.length) / format.sampleRate
        let estimatedTotalSamples = max(Int((duration * Double(targetSampleRate)).rounded(.up)), 0)
        return SpeechAudioFileInfo(
            estimatedTotalSamples: estimatedTotalSamples,
            durationSeconds: duration,
            sourceSampleRate: format.sampleRate,
            sourceChannelCount: Int(format.channelCount)
        )
    }

    private static func samples(
        from inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) throws -> [Float] {
        guard let converter else {
            return firstChannelSamples(from: inputBuffer)
        }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(inputBuffer.frameLength) * ratio)) + 8192))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return []
        }

        let inputState = AudioConverterInputState(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return firstChannelSamples(from: outputBuffer)
        case .error:
            throw NSError(
                domain: "ai.clawdhome.speech.audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
            )
        @unknown default:
            return firstChannelSamples(from: outputBuffer)
        }
    }

    private static func firstChannelSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return []
        }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
