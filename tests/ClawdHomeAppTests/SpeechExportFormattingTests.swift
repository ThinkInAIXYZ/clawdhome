import Foundation

@main
struct SpeechExportFormattingTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechExportFormattingTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let service = await MainActor.run {
            SpeechTranscriptionService(historyStore: SpeechHistoryStore(fileURL: tempURL))
        }

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

        let txt = await MainActor.run {
            service.exportedText(for: record, format: .txt)
        }
        expect(txt == "hello world", "txt export should equal transcript text")

        let markdown = await MainActor.run {
            service.exportedText(for: record, format: .markdown)
        }
        expect(markdown.contains("# demo.wav"), "markdown export should include title")
        expect(markdown.contains("- Source: /tmp/demo.wav"), "markdown export should include source path")
        expect(markdown.contains("- Model: Qwen3-ASR 1.7B 8-bit"), "markdown export should include model")
        expect(markdown.contains("- Elapsed: 3.50s"), "markdown export should include elapsed seconds")
        expect(markdown.contains("hello world"), "markdown export should include transcript text")

        print("Speech export formatting tests passed.")
    }
}
