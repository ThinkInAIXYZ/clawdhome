import Foundation

@main
struct SpeechToolOutputParserTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let progressLine = #"{"command":"prepare-model","fractionCompleted":0.42,"kind":"progress","message":"Downloading weights..."}"#
        let progress = SpeechToolOutputParser.progressEvent(from: progressLine)
        expect(progress?.command == "prepare-model", "progress event should decode command")
        expect(progress?.fractionCompleted == 0.42, "progress event should decode fraction")
        expect(progress?.message == "Downloading weights...", "progress event should decode message")

        let stdoutJSON = #"{"command":"prepare-model","error":"No safetensors files found","modelID":"","ok":false}"#
        let extracted = SpeechToolOutputParser.errorMessage(stdout: Data(stdoutJSON.utf8), stderr: Data())
        expect(extracted == "No safetensors files found", "error parser should extract JSON error field from stdout")

        let stderrText = "plain stderr failure"
        let fallback = SpeechToolOutputParser.errorMessage(stdout: Data(), stderr: Data(stderrText.utf8))
        expect(fallback == stderrText, "error parser should fall back to plain stderr text")

        print("Speech tool output parser tests passed.")
    }
}
