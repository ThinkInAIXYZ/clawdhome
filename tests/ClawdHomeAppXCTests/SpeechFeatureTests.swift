import XCTest
@testable import ClawdHome

final class SpeechFeatureTests: XCTestCase {
    private let gibibyte: UInt64 = 1024 * 1024 * 1024

    func testSpeechModelAdvisorRecommendations() {
        let supportedOS = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let oldOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)

        let unsupportedCPU = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: false,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 32 * gibibyte,
                availableMemoryBytes: 20 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        XCTAssertFalse(unsupportedCPU.availability.isAvailable)
        XCTAssertEqual(unsupportedCPU.availability.reason, .unsupportedCPU)

        let unsupportedOS = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: oldOS,
                physicalMemoryBytes: 32 * gibibyte,
                availableMemoryBytes: 20 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        XCTAssertFalse(unsupportedOS.availability.isAvailable)
        XCTAssertEqual(unsupportedOS.availability.reason, .unsupportedOS)

        let preferred = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 36 * gibibyte,
                availableMemoryBytes: 18 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        XCTAssertTrue(preferred.availability.isAvailable)
        XCTAssertEqual(preferred.recommendedModel, .qwen3ASR17B8Bit)
        XCTAssertEqual(preferred.fallbackModel, .qwen3ASR06B)
        XCTAssertTrue(preferred.warnings.isEmpty)

        let lowMemory = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: true,
                operatingSystemVersion: supportedOS,
                physicalMemoryBytes: 16 * gibibyte,
                availableMemoryBytes: 8 * gibibyte,
                availableDiskBytes: 100 * gibibyte,
                localAIServiceRunning: false
            )
        )
        XCTAssertEqual(lowMemory.recommendedModel, .qwen3ASR06B)
        XCTAssertTrue(lowMemory.warnings.contains { $0.kind == .lowMemory })
    }

    func testSpeechHistoryStorePersistence() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "SpeechHistoryStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let storeURL = tempRoot.appendingPathComponent("speech-history.json")
        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let store = SpeechHistoryStore(fileURL: storeURL)
        XCTAssertTrue(store.load().isEmpty)

        let first = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            createdAt: Date(timeIntervalSince1970: 100),
            sourceFilePath: "/tmp/first.wav",
            sourceFileName: "first.wav",
            sourceFileSizeBytes: 5,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR06B,
            modelDisplayName: "Qwen3-ASR 0.6B",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "older transcript",
            elapsedSeconds: 1,
            status: .completed,
            errorSummary: nil
        )
        let second = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            createdAt: Date(timeIntervalSince1970: 200),
            sourceFilePath: "/tmp/second.wav",
            sourceFileName: "second.wav",
            sourceFileSizeBytes: 7,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "newer transcript",
            elapsedSeconds: 2,
            status: .completed,
            errorSummary: nil
        )

        store.save(first)
        store.save(second)

        XCTAssertEqual(store.load().map(\.id), [second.id, first.id])

        store.delete(id: second.id)
        XCTAssertEqual(store.load().map(\.id), [first.id])
    }

    @MainActor
    func testSpeechExportFormatting() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechExportFormattingTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        let record = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000333")!,
            createdAt: Date(timeIntervalSince1970: 1234),
            sourceFilePath: "/tmp/demo.wav",
            sourceFileName: "demo.wav",
            sourceFileSizeBytes: 42,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "hello world",
            elapsedSeconds: 3.5,
            status: .completed,
            errorSummary: nil
        )

        XCTAssertEqual(service.exportedText(for: record, format: .txt), "hello world")

        let markdown = service.exportedText(for: record, format: .markdown)
        XCTAssertTrue(markdown.contains("# demo.wav"))
        XCTAssertTrue(markdown.contains("- Source: /tmp/demo.wav"))
        XCTAssertTrue(markdown.contains("- Model: Qwen3-ASR 1.7B 8-bit"))
        XCTAssertTrue(markdown.contains("- Elapsed: 3.50s"))
        XCTAssertTrue(markdown.contains("hello world"))
    }

    @MainActor
    func testCancelAllQueueTranscriptionsCancelsWaitingItems() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechCancelQueueTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        service.enqueueFiles([
            URL(fileURLWithPath: "/tmp/first.wav"),
            URL(fileURLWithPath: "/tmp/second.wav")
        ])

        service.cancelAllQueueTranscriptions()

        XCTAssertEqual(service.queue.map(\.status), [.cancelled, .cancelled])
    }

    func testTranscriptionProgressEventDecodesPartialTranscript() {
        let progressLine = #"{"command":"transcribe","fractionCompleted":0.5,"kind":"progress","message":"已转写 50%","transcript":"这是实时识别文本"}"#

        let progress = SpeechToolOutputParser.progressEvent(from: progressLine)

        XCTAssertEqual(progress?.message, "已转写 50%")
        XCTAssertEqual(progress?.transcript, "这是实时识别文本")
    }

    @MainActor
    func testTranscriptionProgressDoesNotUseStatusMessageAsTranscript() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechProgressTranscriptTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        service.enqueueFiles([URL(fileURLWithPath: "/tmp/live.m4a")])
        let item = service.queue[0]
        item.status = .transcribing
        service.selectedQueueItem = item

        service.applyTranscriptionProgress(
            SpeechToolProgressEvent(
                kind: "progress",
                command: "transcribe",
                fractionCompleted: 0.05,
                message: "已转写 5% (速率 24.4x, 剩余 90s)",
                transcript: nil
            )
        )

        XCTAssertEqual(service.currentTranscript, "")
        XCTAssertEqual(item.transcriptText, "")
        XCTAssertEqual(item.statusMessage, "已转写 5% (速率 24.4x, 剩余 90s)")

        service.applyTranscriptionProgress(
            SpeechToolProgressEvent(
                kind: "progress",
                command: "transcribe",
                fractionCompleted: 0.12,
                message: "已转写 12%",
                transcript: "真正的 ASR 文本"
            )
        )

        XCTAssertEqual(service.currentTranscript, "真正的 ASR 文本")
        XCTAssertEqual(item.transcriptText, "真正的 ASR 文本")
        XCTAssertEqual(item.statusMessage, "已转写 12%")
    }
}
