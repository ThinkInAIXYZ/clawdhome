import Foundation

@main
struct UpdateCheckPolicyTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let day: TimeInterval = 24 * 3600
        let now = 1_000_000.0

        expect(
            UpdateCheckPolicy.shouldCheck(
                now: now,
                lastChecked: Optional<TimeInterval>.none,
                cachedVersion: "1.4.0",
                minimumInterval: day
            ),
            "should check immediately when there is no last-checked timestamp"
        )

        expect(
            !UpdateCheckPolicy.shouldCheck(
                now: now,
                lastChecked: now - (day - 1),
                cachedVersion: "1.4.0",
                minimumInterval: day
            ),
            "should not check again before 24 hours have elapsed"
        )

        expect(
            UpdateCheckPolicy.shouldCheck(
                now: now,
                lastChecked: now - day,
                cachedVersion: "1.4.0",
                minimumInterval: day
            ),
            "should check again once 24 hours have elapsed"
        )

        expect(
            UpdateCheckPolicy.shouldCheck(
                now: now,
                lastChecked: now - 60,
                cachedVersion: Optional<String>.none,
                minimumInterval: day
            ),
            "should check immediately when there is no cached version"
        )

        print("Update check policy tests passed.")
    }
}
