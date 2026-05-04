import Foundation

@main
struct BrowserAccountModelsTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let base = URL(fileURLWithPath: "/Users/admin/Library/Application Support/ClawdHome")
        let paths = BrowserAccountPaths(username: "agent.one", appSupportDirectory: base)

        expect(
            paths.profileDirectory.path == "/Users/admin/Library/Application Support/ClawdHome/BrowserProfiles/agent.one",
            "profile directory should be scoped by username"
        )
        expect(
            paths.sessionRelativePath == ".clawdhome/browser/session.json",
            "session file should live under the user clawdhome browser directory"
        )
        expect(
            BrowserAccountPaths.toolBrowserProfileRelativePath == ".clawdhome/browser/profile",
            "tool-launched Chrome should use the user home browser profile"
        )
        expect(
            BrowserAccountPaths.browserCommandWrapperNames.contains("open")
            && BrowserAccountPaths.browserCommandWrapperNames.contains("google-chrome")
            && BrowserAccountPaths.browserCommandWrapperNames.contains("xdg-open"),
            "browser command wrappers should cover common URL open commands"
        )
        expect(
            BrowserAccountPaths.openCLIRealExecutableName == "opencli.clawdhome-real",
            "opencli wrapper should preserve the real executable separately"
        )
        expect(
            BrowserAccountPaths.openCLINPMExecutableName == "open-cli",
            "open-cli wrapper should cover the npm URL opener command name"
        )
        expect(
            BrowserAccountPaths.profileExtensionsDirectoryName == "ClawdHomeExtensions"
            && BrowserAccountPaths.openCLIBrowserBridgeExtensionDirectoryName == "opencli-browser-bridge",
            "OpenCLI Browser Bridge should live under the Chrome profile extension directory"
        )
        expect(
            paths.openCLIBrowserBridgeExtensionDirectory.path == "/Users/admin/Library/Application Support/ClawdHome/BrowserProfiles/agent.one/ClawdHomeExtensions/opencli-browser-bridge",
            "OpenCLI Browser Bridge extension should be installed inside the managed Chrome profile"
        )

        let activePort = BrowserAccountActivePort.parse("39123\n/devtools/browser/abc-def\n")
        expect(activePort?.port == 39123, "DevToolsActivePort should parse the first line as port")
        expect(
            activePort?.webSocketPath == "/devtools/browser/abc-def",
            "DevToolsActivePort should parse the second line as websocket path"
        )
        expect(
            activePort?.httpEndpoint == "http://127.0.0.1:39123",
            "CDP HTTP endpoint should always be localhost scoped"
        )
        expect(
            activePort?.webSocketDebuggerURL == "ws://127.0.0.1:39123/devtools/browser/abc-def",
            "CDP websocket URL should include localhost, port, and browser path"
        )

        expect(
            BrowserAccountPaths.isValidUsername("agent-01.alpha"),
            "valid macOS-style usernames should be accepted"
        )
        expect(
            !BrowserAccountPaths.isValidUsername("../admin"),
            "path traversal usernames should be rejected"
        )

        print("Browser account model tests passed.")
    }
}
