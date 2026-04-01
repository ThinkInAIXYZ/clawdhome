import Foundation

func formatManagedUserDisplayName(fullName: String, username: String) -> String {
    let normalizedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalizedUsername.isEmpty else { return normalizedFullName }
    guard !normalizedFullName.isEmpty else { return "@\(normalizedUsername)" }
    return "\(normalizedFullName)(@\(normalizedUsername))"
}
