import Foundation

struct AppUpdateState: Codable {
    var latestVersion: String? = nil
    var downloadURL: String? = nil
    var releaseNotes: String? = nil
    var minimumVersion: String? = nil
    var lastSuccessfulCheckAt: TimeInterval? = nil
    var lastHeartbeatAt: TimeInterval? = nil
    var lastError: String? = nil
    var source: String = "unknown"
}
