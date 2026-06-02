import Foundation

enum BrowserAccountManager {
    static var openCLIProfile: String?
    static var cdpEndpoint: String?

    static func readOpenCLIProfile(username: String) -> String? {
        openCLIProfile
    }

    static func reachableCDPEndpoint(username: String) -> String? {
        cdpEndpoint
    }
}

enum ConfigWriter {
    static func proxyEnvironment(username: String) -> [String: String] {
        [:]
    }
}

@main
struct UserEnvContractBrowserCDPTests {
    static func main() {
        BrowserAccountManager.openCLIProfile = "shrimp-main"
        BrowserAccountManager.cdpEndpoint = "http://127.0.0.1:39123"

        let env = UserEnvContract.runtimeEnvironment(
            username: "shrimp-a",
            nodePath: "/Users/shrimp-a/.npm-global/bin:/usr/bin:/bin"
        )
        expectEqual(
            env["OPENCLI_PROFILE"],
            "shrimp-main",
            "runtime env should continue to export OPENCLI_PROFILE when Browser Bridge is configured"
        )
        expectEqual(
            env["BROWSER_CDP_URL"],
            "http://127.0.0.1:39123",
            "runtime env should export the reachable browser CDP endpoint for OpenClaw"
        )

        let orderedKeys = UserEnvContract
            .orderedRuntimeEnvironment(
                username: "shrimp-a",
                nodePath: "/Users/shrimp-a/.npm-global/bin:/usr/bin:/bin"
            )
            .map(\.0)
        expectTrue(
            orderedKeys.contains("BROWSER_CDP_URL"),
            "ordered runtime environment should include BROWSER_CDP_URL when a CDP endpoint is available"
        )
    }

    private static func expectEqual(_ actual: String?, _ expected: String, _ message: String) {
        guard actual == expected else {
            fputs("Assertion failed: \(message). expected=\(expected) actual=\(actual ?? "<nil>")\n", stderr)
            exit(1)
        }
    }

    private static func expectTrue(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("Assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
