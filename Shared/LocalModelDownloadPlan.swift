import Foundation

struct LocalModelDownloadPlan: Codable {
    let repoID: String
    let destinationPath: String
    let cachePath: String
    let requiresPythonHuggingFaceHub: Bool

    static func make(modelId: String, modelRootPath: String) throws -> LocalModelDownloadPlan {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidHuggingFaceRepoID(trimmed) else {
            throw LocalModelDownloadPlanError.invalidModelId(modelId)
        }

        let dirName = trimmed.components(separatedBy: "/").last ?? trimmed
        return LocalModelDownloadPlan(
            repoID: trimmed,
            destinationPath: "\(modelRootPath)/\(dirName)",
            cachePath: "\(modelRootPath)/.hf-cache",
            requiresPythonHuggingFaceHub: false
        )
    }

    private static func isValidHuggingFaceRepoID(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { char in
                char.isLetter || char.isNumber || char == "." || char == "_" || char == "-"
            }
        }
    }
}

enum LocalModelDownloadPlanError: LocalizedError {
    case invalidModelId(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelId(let modelId):
            return "无效的 Hugging Face 模型 ID：\(modelId)"
        }
    }
}
