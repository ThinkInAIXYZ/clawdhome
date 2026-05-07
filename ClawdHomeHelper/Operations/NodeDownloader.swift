// ClawdHomeHelper/Operations/NodeDownloader.swift
// 直接从 nodejs.org 下载预编译包安装 Node.js，不依赖 Homebrew
// 安装路径：/Users/<username>/.brew/lib/nodejs/<version>/<arch>/
// 符号链接：/Users/<username>/.brew/bin/node|npm|npx

import Foundation

struct NodeDownloader {

    static let nodeVersion = "v24.9.0"

    /// 持久缓存目录（避免每次初始化重复下载）
    private static let cacheDir = "/Users/Shared/ClawdHome/cache/nodejs"

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
        try FileManager.default.createDirectory(
            atPath: cacheDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        pruneCachedTarballs(keeping: tarName)

        if FileManager.default.fileExists(atPath: cachePath) {
            log("✓ 使用本地缓存：\(cachePath)\n")
        } else {
            let partPath = "\(cachePath).part.\(username).\(ProcessInfo.processInfo.processIdentifier)"
            try? FileManager.default.removeItem(atPath: partPath)
            log("⬇ 下载 Node.js \(nodeVersion)（\(archSuffix)）\n")
            log("  \(downloadURL)\n")
            try downloadWithProgress(from: downloadURL, to: partPath, logURL: logURL, log: log)
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
        _ = try? run("/usr/sbin/chown", args: ["-R", "\(username):\(username)", brewRoot])

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
    case extractedDirNotFound(expectedPaths: [String], existingNodeDirs: [String], searchRoot: String)
    case binaryMissing(binary: String, path: String)
    case symlinkCreateFailed(binary: String, source: String, destination: String, underlying: String)
    var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "非法下载 URL：\(s)"
        case .cancelled:         return "已终止"
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
