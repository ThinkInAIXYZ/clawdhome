// ClawdHomeHelper/Operations/NodeDownloader.swift
// 直接从 nodejs.org 下载预编译包安装 Node.js，不依赖 Homebrew
// 安装路径：/Users/<username>/.brew/lib/nodejs/<version>/<arch>/
// 符号链接：/Users/<username>/.brew/bin/node|npm|npx

import Foundation
import CryptoKit

struct NodeDownloader {

    static let nodeVersion = "v24.9.0"

    /// 持久缓存目录（root:wheel 0700，防止非 root 用户投毒）
    private static let cacheDir = "/var/lib/clawdhome/cache/nodejs"

    // MARK: - 公共接口

    /// 检测指定用户隔离环境的 Node.js 是否已就绪
    static func isInstalled(for username: String) -> Bool {
        let binDir = userBinDir(username: username)
        return FileManager.default.isExecutableFile(atPath: "\(binDir)/node")
            && FileManager.default.isExecutableFile(atPath: "\(binDir)/npm")
            && FileManager.default.isExecutableFile(atPath: "\(binDir)/npx")
    }

    /// 下载、解压并注册 Node.js
    /// - Parameters:
    ///   - distBaseURL: 下载源根 URL，默认 npmmirror
    ///   - logURL: 追加日志的文件 URL（可选）
    static func install(username: String,
                        distBaseURL: String = NodeDistOption.npmmirror.rawValue,
                        logURL: URL? = nil) throws {
        func log(_ msg: String) {
            guard let url = logURL,
                  let fh = FileHandle(forWritingAtPath: url.path) else { return }
            fh.seekToEndOfFile()
            fh.write(Data(msg.utf8))
            fh.closeFile()
        }

        // 1. 检测架构
        #if arch(arm64)
        let archSuffix = "darwin-arm64"
        #else
        let archSuffix = "darwin-x64"
        #endif

        let tarName = "node-\(nodeVersion)-\(archSuffix).tar.gz"
        let distOption = NodeDistOption(rawValue: distBaseURL) ?? .npmmirror
        let downloadURL = distOption.tarGzURL(version: nodeVersion, archSuffix: archSuffix)
        let cachePath = "\(cacheDir)/\(tarName)"
        let libDir = userLibDir(username: username)
        let binDir = userBinDir(username: username)
        let brewRoot = userBrewRoot(username: username)
        let expectedExtractedDir = "\(libDir)/node-\(nodeVersion)-\(archSuffix)"

        // 2. 下载（优先复用持久缓存）
        // 缓存目录设为 root:wheel 0700，防止低权限用户预植恶意 tarball
        try FileManager.default.createDirectory(
            atPath: cacheDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .ownerAccountName: "root", .groupOwnerAccountName: "wheel"]
        )
        // 修正已有目录权限（升级场景）
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700, .ownerAccountName: "root", .groupOwnerAccountName: "wheel"],
            ofItemAtPath: cacheDir
        )
        pruneCachedTarballs(keeping: tarName)

        // 获取 SHASUMS256.txt 用于完整性校验
        let shasumsURL = distOption.shasumsURL(version: nodeVersion)
        log("⬇ 获取 SHASUMS256.txt\n")
        let expectedHash = try fetchExpectedSHA256(shasumsURL: shasumsURL, tarName: tarName, log: log)
        log("✓ 期望 SHA-256：\(expectedHash.prefix(16))…\n")

        if FileManager.default.fileExists(atPath: cachePath) {
            // 缓存命中：重新校验哈希，防止篡改
            log("✓ 使用本地缓存：\(cachePath)\n")
            log("🔒 校验缓存文件完整性…\n")
            try verifySHA256(filePath: cachePath, expectedHash: expectedHash)
            log("✓ SHA-256 校验通过\n")
        } else {
            let partPath = "\(cachePath).part.\(username).\(ProcessInfo.processInfo.processIdentifier)"
            try? FileManager.default.removeItem(atPath: partPath)
            log("⬇ 下载 Node.js \(nodeVersion)（\(archSuffix)）\n")
            log("  \(downloadURL)\n")
            try downloadWithProgress(from: downloadURL, to: partPath, logURL: logURL, log: log)
            // 校验下载文件完整性后再移入缓存
            log("🔒 校验下载文件完整性…\n")
            try verifySHA256(filePath: partPath, expectedHash: expectedHash)
            log("✓ SHA-256 校验通过\n")
            try? FileManager.default.removeItem(atPath: cachePath)
            try FileManager.default.moveItem(atPath: partPath, toPath: cachePath)
            log("✓ 下载完成\n")
        }

        // 3. 创建安装目录
        log("$ mkdir -p \(libDir)\n")
        try FileManager.default.createDirectory(
            atPath: libDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // 4. 解压（覆盖旧版本）
        log("$ tar -xzf \(cachePath) -C \(libDir)\n")
        try run("/usr/bin/tar", args: ["-xzf", cachePath, "-C", libDir])
        log("✓ 解压完成：\(expectedExtractedDir)\n")

        // 4.1 解析真实解压目录（兼容部分镜像目录名不带 v 前缀）
        let extractedDir = try resolveExtractedDir(
            nodeVersion: nodeVersion,
            archSuffix: archSuffix,
            preferredDir: expectedExtractedDir,
            installRootDir: libDir
        )
        if extractedDir != expectedExtractedDir {
            log("⚠ 使用实际目录：\(extractedDir)\n")
        }

        // 5. 创建符号链接
        log("$ mkdir -p \(binDir)\n")
        try FileManager.default.createDirectory(
            atPath: binDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        for binary in ["node", "npm", "npx"] {
            let src = "\(extractedDir)/bin/\(binary)"
            let dst = "\(binDir)/\(binary)"
            guard FileManager.default.fileExists(atPath: src) else {
                throw NodeDownloadError.binaryMissing(binary: binary, path: src)
            }
            try? FileManager.default.removeItem(atPath: dst)
            do {
                try FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: src)
            } catch {
                throw NodeDownloadError.symlinkCreateFailed(
                    binary: binary,
                    source: src,
                    destination: dst,
                    underlying: error.localizedDescription
                )
            }
            log("✓ 链接：\(dst) → \(src)\n")
        }

        // 6. 校验
        guard FileManager.default.isExecutableFile(atPath: "\(binDir)/node") else {
            throw NodeDownloadError.binaryMissing(binary: "node", path: "\(binDir)/node")
        }
        let version = try run("\(binDir)/node", args: ["--version"])
        log("✓ Node.js 安装完成：\(version)\n")

        // 8. 修复归属，确保目标用户可写可升级
        _ = try? run("/usr/sbin/chown", args: ["-R", username, brewRoot])

        // 7. 保留 cachePath 供后续快速安装复用（不再删除）
    }

    // MARK: - 内部工具

    /// URLSession 同步下载，每 0.5s 写一次进度到日志（百分比 + 进度条）
    private static func downloadWithProgress(
        from urlString: String,
        to destPath: String,
        logURL: URL?,
        log: (String) -> Void
    ) throws {
        guard let url = URL(string: urlString) else {
            throw NodeDownloadError.invalidURL(urlString)
        }

        var downloadError: Error?
        let sema = DispatchSemaphore(value: 0)

        let logPath = logURL?.path ?? ""
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: url) { tmpURL, _, error in
            defer {
                if !logPath.isEmpty { unregisterDownloadTask(logPath: logPath) }
                sema.signal()
            }
            if let error { downloadError = error; return }
            guard let tmpURL else { return }
            do {
                try? FileManager.default.removeItem(atPath: destPath)
                try FileManager.default.moveItem(atPath: tmpURL.path, toPath: destPath)
            } catch {
                downloadError = error
            }
        }
        if !logPath.isEmpty { registerDownloadTask(task, logPath: logPath) }
        task.resume()

        // 每 0.5s 轮询进度，用 \r 覆盖同行（终端面板会正确渲染）
        var lastLine = ""
        while sema.wait(timeout: .now() + 0.5) == .timedOut {
            let received = task.countOfBytesReceived
            let expected  = task.countOfBytesExpectedToReceive
            let line: String
            if expected > 0 {
                let pct   = Int(Double(received) / Double(expected) * 100)
                let rcvMB = String(format: "%.1f", Double(received) / 1_048_576)
                let totMB = String(format: "%.1f", Double(expected) / 1_048_576)
                line = "  [\(progressBar(pct))] \(pct)%  \(rcvMB)/\(totMB) MB\r"
            } else if received > 0 {
                let rcvMB = String(format: "%.1f", Double(received) / 1_048_576)
                line = "  ⬇ \(rcvMB) MB 已下载…\r"
            } else {
                continue
            }
            if line != lastLine {
                log(line)
                lastLine = line
            }
        }
        if !lastLine.isEmpty { log("\n") }

        if let error = downloadError {
            // URLSession.cancel() 产生 URLError.cancelled，映射为统一的「已终止」错误
            if (error as? URLError)?.code == .cancelled {
                throw NodeDownloadError.cancelled
            }
            throw error
        }
    }

    private static func progressBar(_ pct: Int) -> String {
        let filled = max(0, min(20, pct / 5))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
    }

    // MARK: - SHA-256 完整性校验

    /// 从 SHASUMS256.txt 获取指定 tarball 的期望哈希
    private static func fetchExpectedSHA256(shasumsURL: String, tarName: String, log: (String) -> Void) throws -> String {
        guard let url = URL(string: shasumsURL) else {
            throw NodeDownloadError.integrityCheckFailed("非法 SHASUMS256 URL：\(shasumsURL)")
        }
        var result: Result<String, Error>?
        let sema = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: url) { data, response, error in
            defer { sema.signal() }
            if let error { result = .failure(error); return }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                result = .failure(NodeDownloadError.integrityCheckFailed("无法读取 SHASUMS256.txt"))
                return
            }
            result = .success(text)
        }
        task.resume()
        sema.wait()

        let text: String
        switch result {
        case .success(let t): text = t
        case .failure(let e): throw e
        case .none: throw NodeDownloadError.integrityCheckFailed("SHASUMS256.txt 下载无响应")
        }

        // 格式：<sha256hex>  <filename>
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[1] == tarName {
                let hash = parts[0].lowercased()
                // 校验格式：64 位十六进制
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
                return hash
            }
        }
        throw NodeDownloadError.integrityCheckFailed("SHASUMS256.txt 中未找到 \(tarName) 的哈希")
    }

    /// 校验文件 SHA-256 哈希
    private static func verifySHA256(filePath: String, expectedHash: String) throws {
        guard let fh = FileHandle(forReadingAtPath: filePath) else {
            throw NodeDownloadError.integrityCheckFailed("无法打开文件：\(filePath)")
        }
        defer { try? fh.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = fh.readData(ofLength: 1_048_576) // 1MB 分块读取
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        let actualHash = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            throw NodeDownloadError.integrityCheckFailed(
                "SHA-256 不匹配：期望 \(expectedHash.prefix(16))…，实际 \(actualHash.prefix(16))…"
            )
        }
    }

    /// 仅保留当前版本安装包，避免缓存目录无限增长。
    private static func pruneCachedTarballs(keeping tarName: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cacheDir) else { return }
        for entry in entries where entry.hasPrefix("node-") && entry.hasSuffix(".tar.gz") && entry != tarName {
            try? FileManager.default.removeItem(atPath: "\(cacheDir)/\(entry)")
        }
    }

    /// 兼容目录命名差异：
    /// - node-v24.9.0-darwin-arm64（官方常见）
    /// - node-24.9.0-darwin-arm64（部分镜像/打包差异）
    private static func resolveExtractedDir(
        nodeVersion: String,
        archSuffix: String,
        preferredDir: String,
        installRootDir: String
    ) throws -> String {
        let normalizedVersion = nodeVersion.hasPrefix("v") ? String(nodeVersion.dropFirst()) : nodeVersion
        let candidates = [
            preferredDir,
            "\(installRootDir)/node-\(normalizedVersion)-\(archSuffix)",
        ]
        for dir in candidates {
            if FileManager.default.fileExists(atPath: "\(dir)/bin/node") {
                return dir
            }
        }

        let existingNodeDirs: [String]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: installRootDir) {
            existingNodeDirs = entries.filter { $0.hasPrefix("node-") }.sorted()
        } else {
            existingNodeDirs = []
        }
        throw NodeDownloadError.extractedDirNotFound(
            expectedPaths: candidates,
            existingNodeDirs: existingNodeDirs,
            searchRoot: installRootDir
        )
    }

    private static func userBrewRoot(username: String) -> String {
        "/Users/\(username)/.brew"
    }

    private static func userLibDir(username: String) -> String {
        "\(userBrewRoot(username: username))/lib/nodejs"
    }

    private static func userBinDir(username: String) -> String {
        "\(userBrewRoot(username: username))/bin"
    }
}

enum NodeDownloadError: LocalizedError {
    case invalidURL(String)
    case cancelled
    case integrityCheckFailed(String)
    case extractedDirNotFound(expectedPaths: [String], existingNodeDirs: [String], searchRoot: String)
    case binaryMissing(binary: String, path: String)
    case symlinkCreateFailed(binary: String, source: String, destination: String, underlying: String)
    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "非法下载 URL：\(s)"
        case .cancelled:         return "已终止"
        case .integrityCheckFailed(let s): return "完整性校验失败：\(s)"
        case .extractedDirNotFound(let expectedPaths, let existingNodeDirs, let searchRoot):
            let expected = expectedPaths.joined(separator: ", ")
            let existing = existingNodeDirs.isEmpty ? "(empty)" : existingNodeDirs.joined(separator: ", ")
            return "未找到 Node.js 解压目录。期望路径：[\(expected)]，当前 \(searchRoot) 内容：[\(existing)]"
        case .binaryMissing(let binary, let path):
            return "未找到 \(binary) 可执行文件：\(path)"
        case .symlinkCreateFailed(let binary, let source, let destination, let underlying):
            return "创建 \(binary) 链接失败：\(destination) -> \(source)（\(underlying)）"
        }
    }
}
