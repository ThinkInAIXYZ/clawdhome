import Foundation

struct BrowserAccountPaths: Codable, Equatable {
    let username: String
    let appSupportDirectory: URL

    static let browserDirectoryRelativePath = ".clawdhome/browser"
    static let sessionRelativePath = ".clawdhome/browser/session.json"
    static let legacySessionRelativePath = ".openclaw/clawdhome-browser-session.json"
    static let toolDirectoryRelativePath = ".clawdhome/tools/clawdhome-browser"
    static let toolExecutableRelativePath = ".clawdhome/tools/clawdhome-browser/clawdhome-browser"
    static let toolLauncherRelativePath = ".clawdhome/tools/clawdhome-browser/clawdhome-browser-launcher"
    static let toolBrowserProfileRelativePath = ".clawdhome/browser/profile"
    static let legacyToolBrowserProfileRelativePath = ".openclaw/browser-profile"
    static let debugLogRelativePath = ".clawdhome/browser/debug.log"
    static let installWarmupMarkerRelativePath = ".clawdhome/browser/install-warmup.json"
    static let openCLIBrowserBridgeExtensionDirectoryName = "opencli-browser-bridge"
    static let profileExtensionsDirectoryName = "ClawdHomeExtensions"
    static let userLocalBinRelativePath = ".local/bin"
    static let npmGlobalBinRelativePath = ".npm-global/bin"
    static let toolsGuideRelativePath = ".clawdhome/TOOLS.md"
    static let openCLIRealExecutableName = "opencli.clawdhome-real"
    static let openCLINPMExecutableName = "open-cli"
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

    var openCLIBrowserBridgeExtensionDirectory: URL {
        profileDirectory
            .appendingPathComponent(Self.profileExtensionsDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.openCLIBrowserBridgeExtensionDirectoryName, isDirectory: true)
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

struct BrowserManualLoginSite: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let url: String

    static let defaults: [BrowserManualLoginSite] = [
        BrowserManualLoginSite(id: "xiaohongshu", name: "小红书", url: "https://www.xiaohongshu.com"),
        BrowserManualLoginSite(id: "x", name: "X", url: "https://x.com"),
    ]

    static func customSites(from raw: String) -> [BrowserManualLoginSite] {
        guard let data = raw.data(using: .utf8),
              let sites = try? JSONDecoder().decode([BrowserManualLoginSite].self, from: data) else {
            return []
        }
        return sites.filter { !$0.name.isEmpty && !$0.url.isEmpty }
    }

    static func encodeCustomSites(_ sites: [BrowserManualLoginSite]) -> String {
        guard let data = try? JSONEncoder().encode(sites),
              let raw = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return raw
    }

    static func makeCustom(name: String, url: String) -> BrowserManualLoginSite? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host != nil else {
            return nil
        }
        return BrowserManualLoginSite(
            id: "custom-\(UUID().uuidString)",
            name: trimmedName,
            url: trimmedURL
        )
    }
}
