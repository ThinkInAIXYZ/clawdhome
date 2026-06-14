import Foundation

@main
struct SpeechHistoryStoreTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "SpeechHistoryStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let storeURL = tempRoot.appendingPathComponent("speech-history.json")
        let missingSource = tempRoot.appendingPathComponent("missing-audio.wav").path
        let existingSource = tempRoot.appendingPathComponent("audio.wav")
        let existingSourcePath = existingSource.path
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try Data("dummy".utf8).write(to: existingSource, options: .atomic)
        } catch {
            fputs("FAIL: setup failed: \(error)\n", stderr)
            exit(1)
        }

        defer { try? fm.removeItem(at: tempRoot) }

        let store = SpeechHistoryStore(fileURL: storeURL)

        expect(store.load().isEmpty, "load should return empty when file does not exist")

        let older = SpeechHistoryRecord(
            id: olderID,
            createdAt: oldDate,
            sourceFilePath: existingSourcePath,
            sourceFileName: existingSource.lastPathComponent,
            sourceFileSizeBytes: 5,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR06B,
            modelDisplayName: "Qwen3-ASR 0.6B",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "older transcript",
            elapsedSeconds: 1,
            status: .completed,
            errorSummary: nil,
            vocalEnhanceEnabled: true
        )
        let newer = SpeechHistoryRecord(
            id: newerID,
            createdAt: newDate,
            sourceFilePath: missingSource,
            sourceFileName: "missing-audio.wav",
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

        store.save(older)
        store.save(newer)

        let loaded = store.load()
        expect(loaded.count == 2, "save should persist items")
        expect(loaded.map(\.id) == [newerID, olderID], "items should be sorted newest-first")
        expect(loaded.first?.sourceFilePath == missingSource, "missing source path should not break load")
        expect(loaded.last?.vocalEnhanceEnabled == true, "vocal enhance flag should survive save and load")

        let updatedOlder = SpeechHistoryRecord(
            id: olderID,
            createdAt: Date(timeIntervalSince1970: 300),
            sourceFilePath: existingSourcePath,
            sourceFileName: existingSource.lastPathComponent,
            sourceFileSizeBytes: 5,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR06B,
            modelDisplayName: "Qwen3-ASR 0.6B",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "older updated",
            elapsedSeconds: 3,
            status: .completed,
            errorSummary: nil
        )
        store.save(updatedOlder)

        let afterUpdate = store.load()
        expect(afterUpdate.count == 2, "save with existing id should update instead of duplicating")
        expect(afterUpdate.first?.id == olderID, "updated item should be re-ordered by timestamp")
        expect(afterUpdate.first?.transcriptText == "older updated", "updated item should replace previous payload")

        store.delete(id: newerID)
        let afterDelete = store.load()
        expect(afterDelete.count == 1, "delete should remove one item")
        expect(afterDelete.first?.id == olderID, "delete should keep remaining item intact")

        store.delete(id: UUID())
        expect(store.load().count == 1, "delete of unknown id should be a no-op")

        let refinedID = UUID(uuidString: "00000000-0000-0000-0000-000000000333")!
        let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000444")!
        let longAudioPath = tempRoot.appendingPathComponent("2026-06-14 16-12-14 Audio.m4a").path
        let refinedRecord = SpeechHistoryRecord(
            id: refinedID,
            createdAt: Date(timeIntervalSince1970: 400),
            sourceFilePath: longAudioPath,
            sourceFileName: "2026-06-14 16-12-14 Audio.m4a",
            sourceFileSizeBytes: 45_500_000,
            durationSeconds: 5_924,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "第一版原稿",
            refinedText: "# TGO-16-AI转型与教育焦虑\n\n精装版",
            refinedTitle: "TGO-16-AI转型与教育焦虑",
            elapsedSeconds: 6_700,
            status: .completed,
            errorSummary: nil,
            vocalEnhanceEnabled: true
        )
        let duplicateRecord = SpeechHistoryRecord(
            id: duplicateID,
            createdAt: Date(timeIntervalSince1970: 500),
            sourceFilePath: longAudioPath,
            sourceFileName: "2026-06-14 16-12-14 Audio.m4a",
            sourceFileSizeBytes: 45_500_000,
            durationSeconds: 5_924,
            engineID: "qwen3-asr",
            modelID: .qwen3ASR17B8Bit,
            modelDisplayName: "Qwen3-ASR 1.7B 8-bit",
            languageHintOrDetectedLanguage: nil,
            transcriptText: "第二版原稿",
            elapsedSeconds: 6_755,
            status: .completed,
            errorSummary: nil,
            vocalEnhanceEnabled: true
        )
        store.save(refinedRecord)
        let persistedDuplicate = store.save(duplicateRecord)

        let mergedRecords = store.load()
        let matching = mergedRecords.filter { $0.sourceFilePath == longAudioPath }
        expect(persistedDuplicate.id == refinedID, "save should return the merged existing record id")
        expect(persistedDuplicate.refinedTitle == "TGO-16-AI转型与教育焦虑", "save should return preserved refined title")
        expect(persistedDuplicate.refinedText == "# TGO-16-AI转型与教育焦虑\n\n精装版", "save should return preserved refined text")
        expect(matching.count == 1, "same source audio should merge instead of duplicating")
        expect(matching.first?.id == refinedID, "merged source audio should keep the existing record id")
        expect(matching.first?.transcriptText == "第二版原稿", "merged source audio should update the transcript")
        expect(matching.first?.refinedTitle == "TGO-16-AI转型与教育焦虑", "merged source audio should keep refined title")
        expect(matching.first?.refinedText == "# TGO-16-AI转型与教育焦虑\n\n精装版", "merged source audio should keep refined text")

        let replacedPath = tempRoot.appendingPathComponent("replaced-audio.m4a").path
        var replacedFirst = duplicateRecord
        replacedFirst.id = UUID(uuidString: "00000000-0000-0000-0000-000000000555")!
        replacedFirst.sourceFilePath = replacedPath
        replacedFirst.sourceFileName = "replaced-audio.m4a"
        replacedFirst.sourceFileSizeBytes = 1_000
        replacedFirst.transcriptText = "旧音频"

        var replacedSecond = replacedFirst
        replacedSecond.id = UUID(uuidString: "00000000-0000-0000-0000-000000000556")!
        replacedSecond.sourceFileSizeBytes = 2_000
        replacedSecond.transcriptText = "新音频"

        store.save(replacedFirst)
        store.save(replacedSecond)
        let replacedMatches = store.load().filter { $0.sourceFilePath == replacedPath }
        expect(replacedMatches.count == 2, "same path with different file sizes should not merge")

        print("SpeechHistoryStore tests passed.")
    }
}
