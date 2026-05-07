// ClawdHomeHelper/Operations/UserFileManager.swift
// 以 root 身份执行文件操作，写操作后纠正所有权归还给虾用户

import Foundation

enum UserFileError: LocalizedError {
    case pathTraversal
    case fileTooLarge
    case notAFile
    case notADirectory

    var errorDescription: String? {
        switch self {
        case .pathTraversal:  return "路径超出用户目录范围"
        case .fileTooLarge:   return "文件超过 10MB 限制"
        case .notAFile:       return "目标不是文件"
        case .notADirectory:  return "目标不是目录"
        }
    }
}

struct UserFileManager {

    // MARK: - 路径安全验证

    /// 将相对路径解析为绝对 URL，并验证必须在 /Users/<username>/ 内
    static func resolvedPath(username: String, relativePath: String) throws -> URL {
        // 验证用户名只包含合法字符（防止路径注入）
        guard !username.isEmpty,
              username.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            throw UserFileError.pathTraversal
        }
        let home = URL(fileURLWithPath: "/Users/\(username)")
        let rel = relativePath.isEmpty ? "." : relativePath
        let absolute = home.appendingPathComponent(rel).standardized
        // 必须以 home 路径为前缀，防止路径穿越
        guard absolute.path == home.path
           || absolute.path.hasPrefix(home.path + "/") else {
            throw UserFileError.pathTraversal
        }
        return absolute
    }

    // MARK: - 列目录

    static func listDirectory(username: String, relativePath: String, showHidden: Bool = false) throws -> [FileEntry] {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey,
            .contentModificationDateKey, .isSymbolicLinkKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let items = try fm.contentsOfDirectory(at: url,
                                               includingPropertiesForKeys: keys,
                                               options: options)
        let homePrefix = "/Users/\(username)/"
        let ownerProbeLimit = 200
        let entries: [FileEntry] = items.enumerated().compactMap { idx, itemURL in
            let rv = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir  = rv?.isDirectory ?? false
            let isLink = rv?.isSymbolicLink ?? false
            let size   = Int64(rv?.fileSize ?? 0)
            let mod    = rv?.contentModificationDate
            // 计算相对路径
            let absPath = itemURL.standardized.path
            let relPath: String
            if absPath.hasPrefix(homePrefix) {
                relPath = String(absPath.dropFirst(homePrefix.count))
            } else {
                return nil   // 不在 home 内（罕见，符号链接逸出）
            }
            // owner 查询需要额外 stat；只对前 N 项查询，避免大目录首屏阻塞
            let owner: String? = idx < ownerProbeLimit
                ? ((try? fm.attributesOfItem(atPath: itemURL.path))?[.ownerAccountName] as? String)
                : nil
            return FileEntry(name: itemURL.lastPathComponent,
                             path: relPath,
                             isDirectory: isDir,
                             size: size,
                             modifiedAt: mod,
                             isSymlink: isLink,
                             ownerUsername: owner)
        }
        // 目录优先，同类按名称排序
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - 读文件

    static func readFile(username: String, relativePath: String) throws -> Data {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { throw UserFileError.notAFile }
        // 大小检查
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        guard size <= 10 * 1024 * 1024 else { throw UserFileError.fileTooLarge }
        return try Data(contentsOf: url)
    }

    /// 读取文件尾部字节（不受 10MB readFile 限制），用于日志查看
    static func readFileTail(username: String, relativePath: String, maxBytes: Int) throws -> Data {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { throw UserFileError.notAFile }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        if size <= 0 { return Data() }

        // 防御性裁剪：最小 64KB，最大 4MB
        let capped = min(max(maxBytes, 64 * 1024), 4 * 1024 * 1024)
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        if size > capped {
            try fh.seek(toOffset: UInt64(size - capped))
        }
        return fh.readDataToEndOfFile()
    }

    // MARK: - 写文件

    static func writeFile(username: String, relativePath: String, data: Data) throws {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        try data.write(to: url, options: .atomic)
        // 纠正所有权：root 写入的文件归还给虾用户
        do {
            try ClawdHomeHelper.run("/usr/sbin/chown", args: [username, url.path])
        } catch {
            helperLog("[FileManager] chown failed for \(url.path): \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - 删除

    static func deleteItem(username: String, relativePath: String) throws {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - 重命名 / 移动

    /// 将 sourcePath 重命名（仅文件名，同目录内）为 newName
    static func renameItem(username: String, relativePath: String, newName: String) throws {
        let src = try resolvedPath(username: username, relativePath: relativePath)
        // newName 不能包含路径分隔符
        guard !newName.isEmpty,
              !newName.contains("/"),
              !newName.contains("\0"),
              newName != ".", newName != ".." else {
            throw UserFileError.pathTraversal
        }
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        // dst 也必须在 home 内
        let home = URL(fileURLWithPath: "/Users/\(username)")
        guard dst.standardized.path.hasPrefix(home.path + "/") else {
            throw UserFileError.pathTraversal
        }
        try FileManager.default.moveItem(at: src, to: dst)
    }

    // MARK: - 解压

    /// 解压压缩包到其所在目录，支持 .zip / .tar.gz / .tgz / .tar.bz2 / .tar.xz
    static func extractArchive(username: String, relativePath: String) throws {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { throw UserFileError.notAFile }

        let destDir = url.deletingLastPathComponent().path
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".zip") {
            try ClawdHomeHelper.run("/usr/bin/unzip", args: ["-o", url.path, "-d", destDir])
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            try ClawdHomeHelper.run("/usr/bin/tar", args: ["-xzf", url.path, "-C", destDir])
        } else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") {
            try ClawdHomeHelper.run("/usr/bin/tar", args: ["-xjf", url.path, "-C", destDir])
        } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") {
            try ClawdHomeHelper.run("/usr/bin/tar", args: ["-xJf", url.path, "-C", destDir])
        } else {
            throw NSError(domain: "UserFileManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不支持的压缩格式"])
        }

        // 解压后纠正所有权
        do {
            try ClawdHomeHelper.run("/usr/sbin/chown", args: ["-R", username, destDir])
        } catch {
            helperLog("[FileManager] chown -R failed after extract: \(error.localizedDescription)", level: .warn)
        }
    }

    // MARK: - 新建目录

    static func createDirectory(username: String, relativePath: String) throws {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        // 纠正所有权（递归）
        do {
            try ClawdHomeHelper.run("/usr/sbin/chown", args: ["-R", username, url.path])
        } catch {
            helperLog("[FileManager] chown -R failed for \(url.path): \(error.localizedDescription)", level: .warn)
        }
    }
}
