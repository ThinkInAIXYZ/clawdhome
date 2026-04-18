import Foundation

struct UserAdoptionExistingUser: Equatable {
    let username: String
    let fullName: String
}

struct UserAdoptionNormalizedInput: Equatable {
    let username: String
    let fullName: String
}

enum UserAdoptionValidationError: LocalizedError, Equatable {
    case emptyUsername
    case invalidUsername
    case emptyFullName
    case duplicateUsername(String)
    case duplicateFullName(String)

    var errorDescription: String? {
        switch self {
        case .emptyUsername:
            return String(localized: "adoption.error.empty_username", defaultValue: "系统用户名不能为空")
        case .invalidUsername:
            return String(localized: "adoption.error.invalid_username", defaultValue: "用户名只能包含小写字母、数字和下划线，且须以字母开头")
        case .emptyFullName:
            return String(localized: "adoption.error.empty_fullname", defaultValue: "显示名不能为空")
        case .duplicateUsername(let username):
            return String(format: String(localized: "adoption.error.duplicate_username", defaultValue: "用户名 @%@ 已存在，请换一个再试"), username)
        case .duplicateFullName(let fullName):
            return String(format: String(localized: "adoption.error.duplicate_fullname", defaultValue: "显示名\u{201C}%@\u{201D}已被使用，请换一个名字"), fullName)
        }
    }
}

enum UserAdoptionInputValidator {
    private static let usernamePattern = #"^[a-z][a-z0-9_]{0,31}$"#

    static func validate(
        username: String,
        fullName: String,
        existingUsers: [UserAdoptionExistingUser]
    ) throws -> UserAdoptionNormalizedInput {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            throw UserAdoptionValidationError.emptyUsername
        }
        guard normalizedUsername.range(of: usernamePattern, options: .regularExpression) != nil else {
            throw UserAdoptionValidationError.invalidUsername
        }

        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFullName = trimmedFullName.isEmpty ? normalizedUsername : trimmedFullName
        guard !normalizedFullName.isEmpty else {
            throw UserAdoptionValidationError.emptyFullName
        }

        if existingUsers.contains(where: { $0.username.caseInsensitiveCompare(normalizedUsername) == .orderedSame }) {
            throw UserAdoptionValidationError.duplicateUsername(normalizedUsername)
        }
        if existingUsers.contains(where: { $0.fullName.caseInsensitiveCompare(normalizedFullName) == .orderedSame }) {
            throw UserAdoptionValidationError.duplicateFullName(normalizedFullName)
        }

        return UserAdoptionNormalizedInput(
            username: normalizedUsername,
            fullName: normalizedFullName
        )
    }
}

/// 将任意文案稳定转换为 ASCII 标识符（用于 @username / agentId）。
enum ASCIIIdentifier {
    private static let transliterationLocale = Locale(identifier: "en_US_POSIX")
    private static let asciiLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    private static let asciiAlnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let usernameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
    private static let agentIDAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

    static func username(from source: String, fallbackPrefix: String = "team", maxLength: Int = 30) -> String {
        let candidate = normalizedASCII(from: source, allowed: usernameAllowed)
        guard let first = candidate.unicodeScalars.first, asciiLetters.contains(first) else {
            return fallbackValue(prefix: fallbackPrefix)
        }
        return String(candidate.prefix(maxLength))
    }

    static func agentID(from source: String, fallbackPrefix: String = "agent", maxLength: Int = 64) -> String {
        let candidate = normalizedASCII(from: source, allowed: agentIDAllowed)
        guard let first = candidate.unicodeScalars.first, asciiAlnum.contains(first) else {
            return fallbackValue(prefix: fallbackPrefix)
        }
        return String(candidate.prefix(maxLength))
    }

    private static func normalizedASCII(from source: String, allowed: CharacterSet) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let latin = (trimmed as NSString).applyingTransform(.toLatin, reverse: false) ?? trimmed
        let folded = latin.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: transliterationLocale
        )
        let normalizedWhitespace = folded
            .lowercased()
            .replacingOccurrences(of: #"[[:space:]/]+"#, with: "_", options: .regularExpression)

        var output = ""
        var previousIsUnderscore = false

        for scalar in normalizedWhitespace.unicodeScalars {
            if allowed.contains(scalar) {
                let ch = Character(scalar)
                if ch == "_" {
                    if previousIsUnderscore { continue }
                    previousIsUnderscore = true
                } else {
                    previousIsUnderscore = false
                }
                output.append(ch)
                continue
            }

            if !previousIsUnderscore {
                output.append("_")
                previousIsUnderscore = true
            }
        }

        return output.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    private static func fallbackValue(prefix: String) -> String {
        "\(prefix)_\(Int(Date().timeIntervalSince1970) % 10000)"
    }
}
