import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AccidentalOpenClawDraftDetectorTests {
    static func main() {
        expect(
            AccidentalOpenClawDraftDetector.shouldDelete(
                topLevelEntries: [],
                hasOpenClawBinary: false
            ),
            "an empty .openclaw directory should be treated as removable accidental state"
        )

        expect(
            AccidentalOpenClawDraftDetector.shouldDelete(
                topLevelEntries: ["workspace"],
                hasOpenClawBinary: false
            ),
            "a draft-only workspace directory should be treated as removable accidental state"
        )

        expect(
            !AccidentalOpenClawDraftDetector.shouldDelete(
                topLevelEntries: ["openclaw.json"],
                hasOpenClawBinary: false
            ),
            "a real openclaw config file must block cleanup"
        )

        expect(
            !AccidentalOpenClawDraftDetector.shouldDelete(
                topLevelEntries: ["workspace"],
                hasOpenClawBinary: true
            ),
            "installed OpenClaw must block cleanup even if the directory looks sparse"
        )

        print("Accidental OpenClaw draft detector tests passed.")
    }
}
