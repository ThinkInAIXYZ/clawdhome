import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HermesProfileRuntimeSummaryTests {
    static func main() {
        expect(
            HermesProfileRuntimeSummary.badgeText(
                profileIDs: [],
                runningProfileIDs: [],
                mainRuntimeRunning: false,
                profilesLoaded: false
            ) == "Hermes · 加载中…",
            "profile summary should show loading instead of 0/0 before profile list has loaded"
        )

        expect(
            HermesProfileRuntimeSummary.badgeText(
                profileIDs: ["main"],
                runningProfileIDs: [],
                mainRuntimeRunning: true,
                profilesLoaded: true
            ) == "Hermes · 1/1 运行中",
            "profile summary should show the normal count once profile list has loaded"
        )

        expect(
            HermesProfileRuntimeSummary.runningCount(
                profileIDs: ["main"],
                runningProfileIDs: [],
                mainRuntimeRunning: true
            ) == 1,
            "main runtime status should count as running before per-profile status cache is populated"
        )

        expect(
            HermesProfileRuntimeSummary.runningCount(
                profileIDs: ["main", "coder"],
                runningProfileIDs: ["coder"],
                mainRuntimeRunning: true
            ) == 2,
            "main runtime fallback and named profile status should both count"
        )

        expect(
            HermesProfileRuntimeSummary.runningCount(
                profileIDs: ["main", "coder"],
                runningProfileIDs: ["main"],
                mainRuntimeRunning: true
            ) == 1,
            "main should not be double counted when both sources say it is running"
        )

        print("Hermes profile runtime summary tests passed.")
    }
}
