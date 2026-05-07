import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HermesFeaturePolicyTests {
    static func main() {
        expect(
            !HermesFeaturePolicy.canSelectHermesForTeamSummon(hasTeamDNA: true),
            "Hermes should not be selectable for team summon while multi-agent support is deferred"
        )

        expect(
            HermesFeaturePolicy.canSelectHermesForTeamSummon(hasTeamDNA: false),
            "Hermes should remain selectable for solo initialization"
        )

        expect(
            !HermesFeaturePolicy.shouldShowMultiAgentEntrypoints,
            "Hermes multi-agent entrypoints should stay hidden before phase two"
        )

        expect(
            HermesFeaturePolicy.nextVersionHint.contains("下一版"),
            "disabled Hermes team summon UI should explain next-version support"
        )

        print("Hermes feature policy tests passed.")
    }
}
