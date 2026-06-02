import Foundation
import HuggingFace

enum LocalModelDownloader {
    static func download(plan: LocalModelDownloadPlan) async throws {
        guard let repoID = Repo.ID(rawValue: plan.repoID) else {
            throw LocalModelDownloaderError.invalidRepoID(plan.repoID)
        }

        let client = HubClient(
            userAgent: "ClawdHome/LocalLLM",
            cache: HubCache(cacheDirectory: URL(fileURLWithPath: plan.cachePath, isDirectory: true))
        )

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: URL(fileURLWithPath: plan.destinationPath, isDirectory: true),
            revision: "main",
            maxConcurrentDownloads: 4
        )
    }
}

enum LocalModelDownloaderError: LocalizedError {
    case invalidRepoID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let repoID):
            return "无效的 Hugging Face 模型 ID：\(repoID)"
        }
    }
}
