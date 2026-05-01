// ClawdHome/Views/QuickFileTransfer.swift

import AppKit
import SwiftUI

struct QuickFileTransferOutcome {
    let destinationRootPath: String
    let uploadedTopLevelPaths: [String]
    let failures: [String]

    var clipboardText: String {
        if uploadedTopLevelPaths.isEmpty { return destinationRootPath }
        return uploadedTopLevelPaths.joined(separator: "\n")
    }

    var summaryMessage: String {
        var blocks: [String] = []
        if uploadedTopLevelPaths.isEmpty {
            blocks.append(L10n.k("user.detail.auto.text_accbdb5ed1", fallback: "未检测到可上传项目。"))
        } else {
            let shownPaths = uploadedTopLevelPaths.prefix(2).map(Self.displayPath)
            var uploadedBlock = L10n.f("views.user_detail_view.text_7b6b4044", fallback: "已上传 %@ 项。", String(describing: uploadedTopLevelPaths.count))
            if let first = shownPaths.first {
                uploadedBlock += L10n.f("views.user_detail_view.n_n_n", fallback: "\n\n路径：\n%@", String(describing: first))
                if shownPaths.count > 1 {
                    uploadedBlock += "\n\(shownPaths[1])"
                }
            }
            if uploadedTopLevelPaths.count > 2 {
                uploadedBlock += L10n.f("views.user_detail_view.n", fallback: "\n…以及另外 %@ 项", String(describing: uploadedTopLevelPaths.count - 2))
            }
            blocks.append(uploadedBlock)
        }
        if !failures.isEmpty {
            let shownFailures = failures.prefix(2).joined(separator: "\n")
            var failedBlock = L10n.f("views.user_detail_view.n_8d3d10", fallback: "失败 %@ 项：\n%@", String(describing: failures.count), String(describing: shownFailures))
            if failures.count > 2 {
                failedBlock += L10n.f("views.user_detail_view.n", fallback: "\n…以及另外 %@ 项", String(describing: failures.count - 2))
            }
            blocks.append(failedBlock)
        }
        blocks.append(L10n.k("user.detail.auto.tips_file", fallback: "Tips：已复制到剪贴板，可以贴给你的虾，来处理文件。"))
        return blocks.joined(separator: "\n\n")
    }

    private static func displayPath(_ absolutePath: String) -> String {
        let tail = absolutePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropFirst(2)
            .joined(separator: "/")
        if absolutePath.hasPrefix("/Users/"), !tail.isEmpty {
            return "~/" + tail
        }
        return absolutePath
    }
}

enum QuickFileTransferService {
    static let destinationRelativePath = "clawdhome_shared/private/upload"

    static func destinationAbsolutePath(username: String) -> String {
        "/Users/\(username)/\(destinationRelativePath)"
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        _ = pb.setString(text, forType: .string)
    }

    static func uploadDroppedItems(
        _ droppedURLs: [URL],
        username: String,
        helperClient: HelperClient
    ) async -> QuickFileTransferOutcome {
        let destinationRoot = destinationAbsolutePath(username: username)
        let fileURLs = uniqueFileURLs(from: droppedURLs)
        guard !fileURLs.isEmpty else {
            return QuickFileTransferOutcome(
                destinationRootPath: destinationRoot,
                uploadedTopLevelPaths: [],
                failures: []
            )
        }

        var uploaded: [String] = []
        var failures: [String] = []

        do {
            try await helperClient.createDirectory(username: username, relativePath: destinationRelativePath)
        } catch {
            return QuickFileTransferOutcome(
                destinationRootPath: destinationRoot,
                uploadedTopLevelPaths: [],
                failures: [L10n.f("views.user_detail_view.text_e9b3435d", fallback: "创建目录失败：%@", String(describing: error.localizedDescription))]
            )
        }

        for srcURL in fileURLs {
            let scoped = srcURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { srcURL.stopAccessingSecurityScopedResource() }
            }

            let topName = srcURL.lastPathComponent
            let destTopRel = "\(destinationRelativePath)/\(topName)"
            let destTopAbs = "\(destinationRoot)/\(topName)"
            let isDir = (try? srcURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            do {
                if isDir {
                    try await uploadDirectory(srcURL, username: username, baseRelativePath: destTopRel, helperClient: helperClient)
                } else {
                    let data = try Data(contentsOf: srcURL)
                    try await helperClient.writeFile(username: username, relativePath: destTopRel, data: data)
                }
                uploaded.append(destTopAbs)
            } catch {
                failures.append("\(topName)：\(error.localizedDescription)")
            }
        }

        return QuickFileTransferOutcome(
            destinationRootPath: destinationRoot,
            uploadedTopLevelPaths: uploaded,
            failures: failures
        )
    }

    private static func uniqueFileURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .filter(\.isFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    private static func uploadDirectory(
        _ srcURL: URL,
        username: String,
        baseRelativePath: String,
        helperClient: HelperClient
    ) async throws {
        try await helperClient.createDirectory(username: username, relativePath: baseRelativePath)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: srcURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw NSError(
                domain: "QuickFileTransferService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.k("user.detail.auto.folder", fallback: "无法读取文件夹内容")]
            )
        }

        let items = enumerator.allObjects.compactMap { $0 as? URL }
        for itemURL in items {
            let relativeSuffix = String(itemURL.path.dropFirst(srcURL.path.count + 1))
            guard !relativeSuffix.isEmpty else { continue }
            let destRel = "\(baseRelativePath)/\(relativeSuffix)"
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                try await helperClient.createDirectory(username: username, relativePath: destRel)
            } else {
                let data = try Data(contentsOf: itemURL)
                try await helperClient.writeFile(username: username, relativePath: destRel, data: data)
            }
        }
    }
}
