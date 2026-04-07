import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct XPCTimeoutPolicyTests {
    static func main() {
        expect(
            XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: 3) == 6,
            "short timeout should reserve at least 3s slack"
        )

        expect(
            XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: 25) == 33,
            "25s timeout should include ~33% slack"
        )

        expect(
            XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: 35) == 46,
            "35s timeout should include wider slack"
        )

        expect(
            XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: 120) == 140,
            "long timeout slack should be capped at 20s"
        )

        expect(
            XPCTimeoutPolicy.effectiveTimeoutSeconds(requested: 0) == 4,
            "non-positive timeout should still have sane minimum effective timeout"
        )

        print("XPC timeout policy tests passed.")
    }
}
