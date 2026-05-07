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
            return "系统用户名不能为空"
        case .invalidUsername:
            return "用户名只能包含小写字母、数字和下划线，且须以字母开头"
        case .emptyFullName:
            return "显示名不能为空"
        case .duplicateUsername(let username):
            return "用户名 @\(username) 已存在，请换一个再试"
        case .duplicateFullName(let fullName):
            return "显示名“\(fullName)”已被使用，请换一个名字"
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
