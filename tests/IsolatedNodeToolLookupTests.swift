import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct IsolatedNodeToolLookupTests {
    static func main() {
        let candidates = IsolatedNodeToolLookup.candidateBinaryPaths(
            brewRoot: "/Users/intel_agent/.brew",
            executableName: "npm",
            cellarFormulaVersions: [
                "node": ["26.5.0"],
            ],
            libNodeEntries: [
                "node-v26.5.0-darwin-arm64",
                "not-node",
            ]
        )

        expect(
            candidates.contains("/Users/intel_agent/.brew/opt/node@26/bin/npm"),
            "npm lookup should include the Node.js 26 Homebrew opt candidate"
        )
        expect(
            candidates.contains("/Users/intel_agent/.brew/lib/nodejs/node-v26.5.0-darwin-arm64/bin/npm"),
            "npm lookup should include Node.js 26 lib/nodejs candidates"
        )
        expect(
            candidates.first == "/Users/intel_agent/.brew/bin/npm",
            "npm lookup should still prefer the stable ~/.brew/bin shim first"
        )
        expect(
            !candidates.contains("/Users/intel_agent/.brew/lib/nodejs/not-node/bin/npm"),
            "non-node lib entries should not be treated as binary candidates"
        )

        print("Isolated node tool lookup tests passed.")
    }
}
