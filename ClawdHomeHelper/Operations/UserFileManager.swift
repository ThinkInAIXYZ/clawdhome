// ClawdHomeHelper/Operations/UserFileManager.swift
// 以 root 身份执行文件操作，写操作后纠正所有权归还给虾用户

import Foundation

enum UserFileError: LocalizedError {
    case pathTraversal
    case fileTooLarge
    case notFound
    case notAFile
    case notADirectory

    var errorDescription: String? {
        switch self {
        case .pathTraversal:  return "路径超出用户目录范围"
        case .fileTooLarge:   return "文件超过 10MB 限制"
        case .notFound:       return "No such file or directory"
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
        // 基于“用户请求的相对目录 + 子项名称”拼接展示路径，避免符号链接目录被解析到
        // /Users/Shared/... 后丢失相对路径（例如 ~/clawdhome_shared/private）。
        let baseRelativePath = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
        let ownerProbeLimit = 200
        let entries: [FileEntry] = items.enumerated().compactMap { idx, itemURL in
            let rv = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDir  = rv?.isDirectory ?? false
            let isLink = rv?.isSymbolicLink ?? false
            let size   = Int64(rv?.fileSize ?? 0)
            let mod    = rv?.contentModificationDate
            let relPath = baseRelativePath.isEmpty
                ? itemURL.lastPathComponent
                : "\(baseRelativePath)/\(itemURL.lastPathComponent)"
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw UserFileError.notFound
        }
        guard !isDir.boolValue else { throw UserFileError.notAFile }
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
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw UserFileError.notFound
        }
        guard !isDir.boolValue else { throw UserFileError.notAFile }

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
            try FilePermissionHelper.chown(url.path, owner: username)
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

    /// 检查归档条目列表是否包含路径穿越（绝对路径或 .. 分量）
    private static func validateArchiveEntries(_ listing: String) throws {
        for line in listing.split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            // 拒绝绝对路径
            if entry.hasPrefix("/") {
                throw UserFileError.pathTraversal
            }
            // 拒绝包含 .. 路径分量（防 Zip Slip）
            let components = entry.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if components.contains("..") {
                throw UserFileError.pathTraversal
            }
        }
    }

    /// 列出 tar 归档内容用于安全校验
    private static func tarListArgs(for name: String, archivePath: String) -> [String]? {
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return ["-tzf", archivePath]
        } else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") {
            return ["-tjf", archivePath]
        } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") {
            return ["-tJf", archivePath]
        }
        return nil
    }

    /// 解压压缩包到其所在目录，支持 .zip / .tar.gz / .tgz / .tar.bz2 / .tar.xz
    /// 解压前校验条目路径，防止 Zip Slip 路径穿越攻击
    static func extractArchive(username: String, relativePath: String) throws {
        let url = try resolvedPath(username: username, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { throw UserFileError.notAFile }

        let destDir = url.deletingLastPathComponent().path
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".zip") {
            // 先列出条目校验路径安全性
            let listing = try ClawdHomeHelper.run("/usr/bin/unzip", args: ["-l", url.path])
            // unzip -l 输出格式：每行末尾为文件名，跳过表头/表尾
            // 解析实际文件名列（第4列起），逐条校验
            let zipEntries = listing.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // unzip -l 的数据行格式: "  Length      Date    Time    Name"
                // 数据行以数字开头，取最后一个字段作为文件名
                guard let first = trimmed.first, first.isNumber else { return nil }
                let parts = trimmed.split(separator: " ", maxSplits: 3)
                guard parts.count >= 4 else { return nil }
                return String(parts[3])
            }.joined(separator: "\n")
            try validateArchiveEntries(zipEntries)
            try ClawdHomeHelper.run("/usr/bin/unzip", args: ["-o", url.path, "-d", destDir])
        } else if let listArgs = tarListArgs(for: name, archivePath: url.path) {
            // tar 归档：先列出条目校验
            let listing = try ClawdHomeHelper.run("/usr/bin/tar", args: listArgs)
            try validateArchiveEntries(listing)
            // 构造解压参数：将 -t 替换为 -x，追加 -C destDir
            var extractArgs = listArgs
            if let idx = extractArgs.firstIndex(where: { $0.contains("t") }) {
                extractArgs[idx] = extractArgs[idx].replacingOccurrences(of: "t", with: "x")
            }
            extractArgs += ["-C", destDir]
            try ClawdHomeHelper.run("/usr/bin/tar", args: extractArgs)
        } else {
            throw NSError(domain: "UserFileManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不支持的压缩格式"])
        }

        // 解压后纠正所有权
        do {
            try FilePermissionHelper.chownRecursive(destDir, owner: username)
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
        
        let homePath = "/Users/\(username)"
        var currentUrl = url
        while currentUrl.path != homePath && currentUrl.path.hasPrefix(homePath) && currentUrl.path.count > homePath.count {
            do {
                try FilePermissionHelper.chown(currentUrl.path, owner: username)
            } catch {
                helperLog("[FileManager] chown failed for \(currentUrl.path): \(error.localizedDescription)", level: .warn)
            }
            currentUrl = currentUrl.deletingLastPathComponent().standardized
        }

        // 纠正所有权（递归处理目标目录自身及其可能已存在的内容）
        do {
            try FilePermissionHelper.chownRecursive(url.path, owner: username)
        } catch {
            helperLog("[FileManager] chown -R failed for \(url.path): \(error.localizedDescription)", level: .warn)
        }
    }
}
