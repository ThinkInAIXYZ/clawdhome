import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct HermesReleaseVersionResolverTests {
    static func main() {
        let githubPayload = """
        {"tag_name":"v2026.5.16","name":"Hermes Agent v0.14.0 (2026.5.16)"}
        """.data(using: .utf8)!

        let release = HermesReleaseVersionResolver.githubRelease(from: githubPayload)

        expect(release?.displayVersion == "0.14.0", "GitHub date tag should not be used as the comparable package version")
        expect(release?.installRef == "v2026.5.16", "GitHub tag should remain available as the install branch/ref")
        expect(
            HermesReleaseVersionResolver.compareVersions("0.14.0", "0.14.0") == .orderedSame,
            "equal package versions should compare as same"
        )
        expect(
            HermesReleaseVersionResolver.compareVersions("0.14.0", "2026.5.16") == .orderedAscending,
            "legacy date tags should still compare numerically when explicitly supplied"
        )

        print("Hermes release version resolver tests passed.")
    }
}
