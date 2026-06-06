import Foundation

struct AppUpdateState: Codable {
    var latestVersion: String? = nil
    var downloadURL: String? = nil
    var releaseNotes: String? = nil
    var releaseNotesEN: String? = nil
    var minimumVersion: String? = nil
    var lastSuccessfulCheckAt: TimeInterval? = nil
    var lastHeartbeatAt: TimeInterval? = nil
    var lastError: String? = nil
    var source: String = "unknown"

    func localizedReleaseNotes(languageIdentifier: String) -> String? {
        let normalizedLanguage = languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedLanguage.hasPrefix("zh") {
            return firstNonEmpty(releaseNotes, releaseNotesEN)
        }
        return firstNonEmpty(releaseNotesEN, releaseNotes)
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates.first { note in
            guard let note else { return false }
            return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }
}
