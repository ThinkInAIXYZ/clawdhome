import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct WizardDraftPersistencePolicyTests {
    static func main() {
        expect(
            WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: nil) == false,
            "draft persistence must stay off before the user explicitly selects OpenClaw"
        )

        expect(
            WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: "hermes") == false,
            "draft persistence must stay off for Hermes"
        )

        expect(
            WizardDraftPersistencePolicy.shouldUseOpenClawWorkspace(selectedEngineRaw: "openclaw"),
            "draft persistence should remain on for explicit OpenClaw selection"
        )

        print("Wizard draft persistence policy tests passed.")
    }
}
