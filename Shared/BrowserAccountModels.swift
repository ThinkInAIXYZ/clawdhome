import Foundation

struct BrowserAccountPaths: Codable, Equatable {
    let username: String
    let appSupportDirectory: URL

    static let sessionRelativePath = ".openclaw/clawdhome-browser-session.json"
    static let toolDirectoryRelativePath = ".openclaw/tools/clawdhome-browser"
    static let toolExecutableRelativePath = ".openclaw/tools/clawdhome-browser/clawdhome-browser"
    static let toolLauncherRelativePath = ".openclaw/tools/clawdhome-browser/clawdhome-browser-launcher"
    static let toolBrowserProfileRelativePath = ".openclaw/browser-profile"
    static let openCLIRealExecutableName = "opencli.clawdhome-real"
    static let browserCommandWrapperNames = [
        "open",
        "xdg-open",
        "sensible-browser",
        "google-chrome",
        "chrome",
        "chromium",
        "chromium-browser",
    ]

    var profileDirectory: URL {
        appSupportDirectory
            .appendingPathComponent("BrowserProfiles", isDirectory: true)
            .appendingPathComponent(username, isDirectory: true)
    }

    var devToolsActivePortFile: URL {
        profileDirectory.appendingPathComponent("DevToolsActivePort")
    }

    var sessionRelativePath: String {
        Self.sessionRelativePath
    }

    static func isValidUsername(_ username: String) -> Bool {
        !username.isEmpty
        && username.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        && !username.contains("..")
    }
}

struct BrowserAccountActivePort: Codable, Equatable {
    let port: Int
    let webSocketPath: String

    var httpEndpoint: String {
        "http://127.0.0.1:\(port)"
    }

    var webSocketDebuggerURL: String {
        "ws://127.0.0.1:\(port)\(webSocketPath)"
    }

    static func parse(_ raw: String) -> BrowserAccountActivePort? {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let port = Int(lines[0]),
              port > 0,
              lines[1].hasPrefix("/") else {
            return nil
        }
        return BrowserAccountActivePort(port: port, webSocketPath: lines[1])
    }
}

struct BrowserAccountSession: Codable, Equatable {
    let username: String
    let profilePath: String
    let devToolsActivePortPath: String
    let httpEndpoint: String
    let webSocketDebuggerURL: String
    let cdpPort: Int
    let launchedAt: TimeInterval
    let consoleUsername: String
}

struct BrowserAccountStatus: Codable, Equatable {
    let username: String
    let profilePath: String
    let sessionPath: String
    let toolPath: String
    let toolInstalled: Bool
    let sessionExists: Bool
    let browserReachable: Bool
    let httpEndpoint: String?
    let message: String
}
