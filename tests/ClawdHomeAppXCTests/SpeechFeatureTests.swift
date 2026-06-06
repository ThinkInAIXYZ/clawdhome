import XCTest
@testable import ClawdHome

final class SpeechFeatureTests: XCTestCase {
    private let gibibyte: UInt64 = 1024 * 1024 * 1024

    func testRefineOutputDropsInstructionAnalysisBeforeMarkdownTitle() {
        let leakedOutput = """
        1. **Analyze the Input and Instructions**:
           * **Role**: Extremely professional ASR text refinement and proper noun correction expert.
           * **Task**: Apply the selected mode: [原稿智能净化] (Raw Draft Intelligent Purification).

        # 安利生反馈

        今天我们刚刚沟通了一下。
        """

        XCTAssertEqual(
            SpeechTranscriptionService.refinementDisplayText(from: leakedOutput),
            "# 安利生反馈\n\n今天我们刚刚沟通了一下。"
        )
    }

    func testRefineOutputSuppressesOnlyInstructionAnalysisWhileStreaming() {
        let leakedOutput = """
        1. **Analyze the Input and Instructions**:
           * **Role**: Extremely professional ASR text refinement and proper noun correction expert.
           * **Rules for [原稿智能净化]**:
        """

        XCTAssertEqual(
            SpeechTranscriptionService.refinementDisplayText(from: leakedOutput, isFinal: false),
            ""
        )
    }

    func testBailianQwenRefineRequestDisablesThinking() {
        let options = SpeechTranscriptionService.refinementOpenAIRequestOptions(
            providerPrefix: "bailian",
            modelId: "bailian/qwen3.6-plus"
        )

        XCTAssertEqual(options["enable_thinking"] as? Bool, false)
    }

    func testOpenRouterRefineRequestExcludesReasoningTokens() {
        let options = SpeechTranscriptionService.refinementOpenAIRequestOptions(
            providerPrefix: "openrouter",
            modelId: "openrouter/deepseek/deepseek-r1"
        )
        let reasoning = options["reasoning"] as? [String: Any]

        XCTAssertEqual(reasoning?["exclude"] as? Bool, true)
        XCTAssertEqual(reasoning?["effort"] as? String, "none")
    }

    func testCustomRefineRequestDoesNotAddOmlxThinkingOptions() {
        let options = SpeechTranscriptionService.refinementOpenAIRequestOptions(
            providerPrefix: "custom",
            modelId: "custom/Qwopus3.6-35B-A3B-v1-oQ4"
        )

        XCTAssertFalse(options.keys.contains("thinking_budget"))
    }

    func testGeminiFlashRefineRequestDisablesThinkingBudget() {
        let generationConfig = SpeechTranscriptionService.refinementGeminiGenerationConfig(
            modelId: "gemini-2.5-flash"
        )
        let thinkingConfig = generationConfig["thinkingConfig"] as? [String: Any]

        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 4096)
        XCTAssertEqual(thinkingConfig?["thinkingBudget"] as? Int, 0)
    }

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
        XCTAssertEqual(lowMemory.recommendedModel, .qwen3ASR17B8Bit)
        XCTAssertEqual(lowMemory.fallbackModel, .qwen3ASR06B)
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
        defer { service.stopObsidianWatcher() }
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
    func testObsidianSyncNamesAutoCapturedAudioNotesLikeFlashNotes() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "SpeechObsidianNamingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let vaultURL = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        let attachmentsURL = vaultURL.appendingPathComponent("Inbox/attachments", isDirectory: true)
        let sourceAudioURL = attachmentsURL.appendingPathComponent("2026-06-01 00-34-03 Audio.m4a")
        let storeURL = tempRoot.appendingPathComponent("speech-history.json")
        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: sourceAudioURL, options: .atomic)

        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: "obsidian_enabled")
        let oldVault = defaults.string(forKey: "obsidian_vault_path")
        let oldInbox = defaults.string(forKey: "obsidian_inbox")
        let oldAttachments = defaults.string(forKey: "obsidian_attachments")
        defer {
            if let oldEnabled {
                defaults.set(oldEnabled, forKey: "obsidian_enabled")
            } else {
                defaults.removeObject(forKey: "obsidian_enabled")
            }
            defaults.set(oldVault, forKey: "obsidian_vault_path")
            defaults.set(oldInbox, forKey: "obsidian_inbox")
            defaults.set(oldAttachments, forKey: "obsidian_attachments")
        }
        defaults.set(false, forKey: "obsidian_enabled")
        defaults.set(vaultURL.path, forKey: "obsidian_vault_path")
        defaults.set("Inbox", forKey: "obsidian_inbox")
        defaults.set("Inbox/attachments", forKey: "obsidian_attachments")

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: storeURL))
        defer { service.stopObsidianWatcher() }
        let record = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000555")!,
            createdAt: Date(timeIntervalSince1970: 1_801_388_052),
            sourceFilePath: sourceAudioURL.path,
            sourceFileName: sourceAudioURL.lastPathComponent,
            sourceFileSizeBytes: 5,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "闪念内容",
            elapsedSeconds: 1,
            status: .completed,
            errorSummary: nil
        )

        XCTAssertTrue(try service.manualSyncToObsidian(record: record))

        let expectedNote = vaultURL
            .appendingPathComponent("Inbox", isDirectory: true)
            .appendingPathComponent("2026-06-01 00-34-03 Flash clawdhome_asr.md")
        XCTAssertTrue(fm.fileExists(atPath: expectedNote.path))

        let attachmentNames = try fm.contentsOfDirectory(atPath: attachmentsURL.path)
        XCTAssertFalse(
            attachmentNames.contains { name in
                name != sourceAudioURL.lastPathComponent && name.hasSuffix(sourceAudioURL.lastPathComponent)
            }
        )
    }

    @MainActor
    func testCancelAllQueueTranscriptionsCancelsWaitingItems() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechCancelQueueTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        defer { service.stopObsidianWatcher() }
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

    func testGeneratedSRTMergesShortCommaFragments() {
        let srt = SpeechHistoryStore.generateSRT(
            from: "上次那个，上次配合，上次配合南剑波，让王果在群里给他支持一点，这样的怎么样，反正不太行吧，嗯，他是跟每单绑定的。",
            duration: 20
        )

        XCTAssertFalse(srt.contains("\n嗯\n"))
        XCTAssertFalse(srt.contains("\n上次那个\n"))
    }

    func testSaveButtonIsHiddenWhileTranscribing() {
        XCTAssertFalse(
            SpeechTranscriptionSaveButtonPolicy.shouldShow(
                isTranscribing: true,
                isContentModified: true,
                didSaved: false
            )
        )
        XCTAssertFalse(
            SpeechTranscriptionSaveButtonPolicy.shouldShow(
                isTranscribing: true,
                isContentModified: false,
                didSaved: true
            )
        )
        XCTAssertTrue(
            SpeechTranscriptionSaveButtonPolicy.shouldShow(
                isTranscribing: false,
                isContentModified: true,
                didSaved: false
            )
        )
    }

    @MainActor
    func testTranscriptionProgressDoesNotUseStatusMessageAsTranscript() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechProgressTranscriptTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        defer { service.stopObsidianWatcher() }
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

    @MainActor
    func testRunningTranscriptionProgressDoesNotRenderAsCompletedAtOneHundredPercent() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRunningProgressTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        defer { service.stopObsidianWatcher() }
        service.enqueueFiles([URL(fileURLWithPath: "/tmp/live.m4a")])
        let item = service.queue[0]
        item.status = .transcribing
        service.selectedQueueItem = item

        service.applyTranscriptionProgress(
            SpeechToolProgressEvent(
                kind: "progress",
                command: "transcribe",
                fractionCompleted: 1.0,
                message: "已转写 100%",
                transcript: "最终分块文本"
            )
        )

        XCTAssertEqual(item.status, .transcribing)
        XCTAssertLessThan(item.stageProgress, 1.0)
        XCTAssertLessThan(item.progressFraction, 1.0)
        XCTAssertEqual(item.transcriptText, "最终分块文本")
    }

    @MainActor
    func testApplyingRefinedTextKeepsOriginalTranscriptSeparate() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechApplyRefinedTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = SpeechHistoryStore(fileURL: tempURL)
        let record = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000444")!,
            createdAt: Date(timeIntervalSince1970: 5678),
            sourceFilePath: "/tmp/refine.wav",
            sourceFileName: "refine.wav",
            sourceFileSizeBytes: 88,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "原稿内容",
            elapsedSeconds: 2,
            status: .completed,
            errorSummary: nil
        )
        store.save(record)

        let service = SpeechTranscriptionService(historyStore: store)
        defer { service.stopObsidianWatcher() }
        service.currentTranscript = "原稿内容"

        XCTAssertTrue(service.applyRefinedTextToCurrentRecord("AI 总结内容"))

        XCTAssertEqual(service.currentTranscript, "原稿内容")
        XCTAssertEqual(service.currentHistoryRecord?.transcriptText, "原稿内容")
        XCTAssertEqual(service.currentHistoryRecord?.refinedText, "AI 总结内容")
    }

    @MainActor
    func testApplyingRefinedTextExtractsFirstLineTitle() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechApplyRefinedTitleTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = SpeechHistoryStore(fileURL: tempURL)
        let record = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000445")!,
            createdAt: Date(timeIntervalSince1970: 5678),
            sourceFilePath: "/tmp/refine-title.wav",
            sourceFileName: "refine-title.wav",
            sourceFileSizeBytes: 88,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "原稿内容",
            elapsedSeconds: 2,
            status: .completed,
            errorSummary: nil
        )
        store.save(record)

        let service = SpeechTranscriptionService(historyStore: store)
        defer { service.stopObsidianWatcher() }
        service.currentTranscript = "原稿内容"

        let refined = """
        # 产品路线复盘

        AI 总结正文内容。
        """
        XCTAssertTrue(service.applyRefinedTextToCurrentRecord(refined))

        XCTAssertEqual(service.currentHistoryRecord?.refinedTitle, "产品路线复盘")
        XCTAssertEqual(service.currentHistoryRecord?.refinedText, refined)
        XCTAssertEqual(service.currentHistoryRecord?.transcriptText, "原稿内容")
    }

    func testObsidianNoteFileNameUsesRefinedTitleWhenAvailable() {
        let record = SpeechHistoryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000446")!,
            createdAt: Date(timeIntervalSince1970: 1_801_388_052),
            sourceFilePath: "/tmp/raw-audio.wav",
            sourceFileName: "raw-audio.wav",
            sourceFileSizeBytes: 88,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "原稿内容",
            refinedText: "# 产品路线复盘\n\nAI 总结正文内容。",
            refinedTitle: "产品路线复盘",
            elapsedSeconds: 2,
            status: .completed,
            errorSummary: nil
        )

        XCTAssertEqual(
            SpeechTranscriptionService.obsidianASRNoteFileName(for: record),
            "2027-01-31 17-34-12 产品路线复盘 clawdhome_asr.md"
        )
    }
}
