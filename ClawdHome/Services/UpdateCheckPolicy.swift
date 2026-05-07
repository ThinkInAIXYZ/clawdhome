import Foundation

enum UpdateCheckPolicy {
    static func shouldCheck(
        now: TimeInterval,
        lastChecked: TimeInterval?,
        cachedVersion: String?,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let lastChecked else { return true }
        guard cachedVersion != nil else { return true }
        return now - lastChecked >= minimumInterval
    }
}
