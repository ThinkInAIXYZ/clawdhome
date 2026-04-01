import Foundation
import UniformTypeIdentifiers

func normalizedFileInputAcceptTokens(_ accept: String) -> [String] {
    accept
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func resolvedFileInputAllowedContentTypeIdentifiers(_ accept: String) -> [String] {
    normalizedFileInputAcceptTokens(accept).compactMap(resolveFileInputAllowedContentTypeIdentifier)
}

func resolvedFileInputAllowedContentTypes(_ accept: String) -> [UTType] {
    resolvedFileInputAllowedContentTypeIdentifiers(accept).compactMap(UTType.init)
}

private func resolveFileInputAllowedContentTypeIdentifier(_ token: String) -> String? {
    if token.hasPrefix(".") {
        return UTType(filenameExtension: String(token.dropFirst()))?.identifier
    }

    if token.contains("/") {
        if token.hasSuffix("/*") {
            switch token.lowercased() {
            case "image/*": return UTType.image.identifier
            case "audio/*": return UTType.audio.identifier
            case "video/*": return UTType.movie.identifier
            case "text/*": return UTType.text.identifier
            default: return nil
            }
        }

        return UTType(mimeType: token)?.identifier
    }

    return UTType(token) != nil ? token : nil
}
