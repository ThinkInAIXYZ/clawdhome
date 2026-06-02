import Foundation

@main
struct SpeechModelCachePathTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(
            SpeechModelID.qwen3ASR06B.repositoryModelID == "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
            "0.6B should map to the concrete Hugging Face repo id"
        )
        expect(
            SpeechModelID.qwen3ASR17B8Bit.repositoryModelID == "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
            "1.7B should map to the concrete Hugging Face repo id"
        )

        expect(
            SpeechModelID.qwen3ASR06B.repositoryCachePathComponents ==
                ["models", "aufklarer", "Qwen3-ASR-0.6B-MLX-4bit"],
            "0.6B cache path should follow Hub repo layout"
        )
        expect(
            SpeechModelID.qwen3ASR17B8Bit.repositoryCachePathComponents ==
                ["models", "aufklarer", "Qwen3-ASR-1.7B-MLX-8bit"],
            "1.7B cache path should follow Hub repo layout"
        )

        print("Speech model cache path tests passed.")
    }
}
