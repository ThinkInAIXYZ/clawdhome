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

struct HermesResolvedRelease {
    let displayVersion: String
    let installRef: String?
}

enum HermesReleaseVersionResolver {
    static func githubRelease(from data: Data) -> HermesResolvedRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            return nil
        }

        let releaseName = json["name"] as? String
        let displayVersion = packageVersion(fromReleaseName: releaseName) ?? normalizeVersion(tagName)
        return HermesResolvedRelease(displayVersion: displayVersion, installRef: tagName)
    }

    static func pypiRelease(from data: Data) -> HermesResolvedRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["info"] as? [String: Any],
              let version = info["version"] as? String else {
            return nil
        }
        return HermesResolvedRelease(displayVersion: normalizeVersion(version), installRef: nil)
    }

    static func normalizeVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let leftParts = numericVersionParts(from: normalizeVersion(lhs))
        let rightParts = numericVersionParts(from: normalizeVersion(rhs))
        let maxCount = max(leftParts.count, rightParts.count)
        for idx in 0..<maxCount {
            let left = idx < leftParts.count ? leftParts[idx] : 0
            let right = idx < rightParts.count ? rightParts[idx] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func packageVersion(fromReleaseName releaseName: String?) -> String? {
        guard let releaseName else { return nil }
        let pattern = #"(?:^|[^0-9])v?([0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(releaseName.startIndex..<releaseName.endIndex, in: releaseName)
        guard let match = regex.firstMatch(in: releaseName, range: range),
              match.numberOfRanges > 1,
              let versionRange = Range(match.range(at: 1), in: releaseName) else {
            return nil
        }
        return String(releaseName[versionRange])
    }

    private static func numericVersionParts(from value: String) -> [Int] {
        value
            .split(separator: ".")
            .map { component -> Int in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}
