// ClawdHome/Services/UpdateChecker.swift
// 版本检测：
//   - openclaw 用户端版本（GitHub Releases）→ 提示管理员升级用户
//   - ClawdHome App 自身版本（官网 API）→ 提示管理员升级 App

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class UpdateChecker {

    // MARK: - openclaw 用户端版本检测

    /// 最新发布版本号（如 "2026.2.25"），nil 表示尚未获取
    var latestVersion: String? = nil
    /// 最新发布的 GitHub Release 页面链接
    var latestReleaseURL: URL? = nil
    var isChecking: Bool = false
    var checkError: String? = nil

    private static let udKeyLastChecked       = "updateChecker.lastChecked"
    private static let udKeyLatestVersion     = "updateChecker.latestVersion"
    private static let udKeyLatestReleaseURL  = "updateChecker.latestReleaseURL"
    private static let openclawApiURL         = "https://api.github.com/repos/openclaw/openclaw/releases/latest"
    private let openclawCacheInterval: TimeInterval = 6 * 3600

    // MARK: - ClawdHome App 自身版本检测

    var appLatestVersion: String? = nil
    var appDownloadURL: URL? = nil
    /// 更新说明（从 API 获取，中文优先）
    var appReleaseNotes: String? = nil
    /// 最低要求版本（低于此版本强制升级）
    var appMinVersion: String? = nil
    /// 下载进度：nil=空闲，0.0–1.0=下载中，1.0=完成
    var appUpdateProgress: Double? = nil
    var appUpdateError: String? = nil
    /// 已下载字节数
    var appDownloadedBytes: Int64 = 0
    /// 文件总大小
    var appTotalBytes: Int64 = 0
    /// 下载速率（字节/秒）
    var appDownloadSpeed: Double = 0
    /// 已启动安装器，等待安装完成后自动拉起新版 App
    var isAwaitingAppRelaunch: Bool = false
    /// 当前下载任务（用于取消）
    private var currentDownloadSession: URLSession?
    private var relaunchMonitorTask: Task<Void, Never>?

    private static let udKeyAppLastChecked  = "appUpdate.lastChecked"
    private static let udKeyAppVersion      = "appUpdate.version"
    private static let udKeyAppDownloadURL  = "appUpdate.downloadURL"
    private static let udKeyAppReleaseNotes = "appUpdate.releaseNotes"
    private static let udKeyAppMinVersion   = "appUpdate.minVersion"
    private static let appApiURL            = "https://clawdhome.app/api/version.json"
    private let appCacheInterval: TimeInterval = 3600

    // MARK: - 初始化（从缓存恢复，避免启动时显示L10n.k("services.update_checker.text_f013ea9d", fallback: "加载中")）

    init() {
        // openclaw 缓存
        latestVersion = UserDefaults.standard.string(forKey: Self.udKeyLatestVersion)
        if let urlStr = UserDefaults.standard.string(forKey: Self.udKeyLatestReleaseURL) {
            latestReleaseURL = URL(string: urlStr)
        }
        // App 自身缓存
        appLatestVersion = UserDefaults.standard.string(forKey: Self.udKeyAppVersion)
        if let dl = UserDefaults.standard.string(forKey: Self.udKeyAppDownloadURL) {
            appDownloadURL = URL(string: dl)
        }
        appReleaseNotes = UserDefaults.standard.string(forKey: Self.udKeyAppReleaseNotes)
        appMinVersion   = UserDefaults.standard.string(forKey: Self.udKeyAppMinVersion)
    }

    // MARK: - openclaw 检测

    func checkIfNeeded() async {
        let lastChecked = UserDefaults.standard.double(forKey: Self.udKeyLastChecked)
        let elapsed = Date().timeIntervalSinceReferenceDate - lastChecked
        guard elapsed >= openclawCacheInterval || latestVersion == nil else { return }
        await check()
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        defer { isChecking = false }

        guard let url = URL(string: Self.openclawApiURL) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                latestVersion = version
                UserDefaults.standard.set(version, forKey: Self.udKeyLatestVersion)
                UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                                          forKey: Self.udKeyLastChecked)
                if let htmlURLStr = json["html_url"] as? String {
                    latestReleaseURL = URL(string: htmlURLStr)
                    UserDefaults.standard.set(htmlURLStr, forKey: Self.udKeyLatestReleaseURL)
                }
            }
        } catch {
            checkError = error.localizedDescription
        }
    }

    // MARK: - App 自身版本检测

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 当前 App 是否低于最新版本
    var appNeedsUpdate: Bool {
        guard let latest = appLatestVersion else { return false }
        return compareVersions(currentAppVersion, latest) == .orderedAscending
    }

    /// 当前 App 是否低于最低要求版本（强制升级）
    var appMustUpdate: Bool {
        guard let min = appMinVersion else { return false }
        return compareVersions(currentAppVersion, min) == .orderedAscending
    }

    func checkAppIfNeeded() async {
        let lastChecked = UserDefaults.standard.double(forKey: Self.udKeyAppLastChecked)
        let elapsed = Date().timeIntervalSinceReferenceDate - lastChecked
        // 若缓存显示“当前无需升级”，启动时强制向服务端再确认一次，
        // 避免新版本刚发布时，因本地缓存导致提示延迟。
        let shouldForceRefresh = !appNeedsUpdate
        guard shouldForceRefresh || elapsed >= appCacheInterval || appLatestVersion == nil else { return }
        await checkApp()
    }

    func checkApp() async {
        guard let url = URL(string: Self.appApiURL) else { return }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let v = json["version"] as? String {
                appLatestVersion = v
                UserDefaults.standard.set(v, forKey: Self.udKeyAppVersion)
            }
            if let dl = json["download_url"] as? String {
                appDownloadURL = URL(string: dl)
                UserDefaults.standard.set(dl, forKey: Self.udKeyAppDownloadURL)
            }
            // 中文优先，fallback 英文
            let notes = json["release_notes"] as? String ?? json["release_notes_en"] as? String
            if let notes {
                appReleaseNotes = notes
                UserDefaults.standard.set(notes, forKey: Self.udKeyAppReleaseNotes)
            }
            if let minV = json["min_version"] as? String {
                appMinVersion = minV
                UserDefaults.standard.set(minV, forKey: Self.udKeyAppMinVersion)
            }
            UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate,
                                      forKey: Self.udKeyAppLastChecked)
        } catch {
            // 网络错误静默失败，不影响主功能
        }
    }

    // MARK: - 下载并安装

    func downloadAndInstall() async {
        guard let downloadURL = appDownloadURL else { return }
        relaunchMonitorTask?.cancel()
        isAwaitingAppRelaunch = false
        appUpdateError = nil
        appUpdateProgress = 0.0
        appDownloadedBytes = 0
        appTotalBytes = 0
        appDownloadSpeed = 0

        let version = appLatestVersion ?? "latest"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawdHome-\(version).pkg")

        do {
            let tmp = try await downloadFile(from: downloadURL) { [weak self] metrics in
                Task { @MainActor in
                    self?.appUpdateProgress = metrics.progress
                    self?.appDownloadedBytes = metrics.bytesWritten
                    self?.appTotalBytes = metrics.totalBytes
                    self?.appDownloadSpeed = metrics.speed
                }
            }
            // 验证文件大小合理（至少 100KB，防止下载到错误页面）
            let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            guard fileSize > 100_000 else {
                try? FileManager.default.removeItem(at: tmp)
                throw UpdateError.invalidFile
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            appUpdateProgress = 1.0
            guard NSWorkspace.shared.open(dest) else {
                throw UpdateError.launchInstallerFailed
            }
            appUpdateProgress = nil
            hideAppForUpgrade()
            isAwaitingAppRelaunch = true
            startInstalledAppMonitor(expectedVersion: version)
        } catch is CancellationError {
            appUpdateError = nil
            appUpdateProgress = nil
            isAwaitingAppRelaunch = false
        } catch {
            appUpdateError = error.localizedDescription
            appUpdateProgress = nil
            isAwaitingAppRelaunch = false
        }
        currentDownloadSession = nil
    }

    /// 取消正在进行的下载
    func cancelDownload() {
        currentDownloadSession?.invalidateAndCancel()
        currentDownloadSession = nil
        appUpdateProgress = nil
        appDownloadedBytes = 0
        appTotalBytes = 0
        appDownloadSpeed = 0
    }

    private func hideAppForUpgrade() {
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        NSApp.hide(nil)
    }

    private func startInstalledAppMonitor(expectedVersion: String) {
        relaunchMonitorTask?.cancel()
        relaunchMonitorTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(20 * 60)

            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(2))

                guard let installedVersion = self.installedBundleVersion() else { continue }
                guard self.compareVersions(installedVersion, expectedVersion) != .orderedAscending else { continue }

                // 让安装器完成最后的 bundle 写入和签名校验，再拉起新版。
                try? await Task.sleep(for: .seconds(1))
                self.relaunchInstalledApp()
                return
            }

            if !Task.isCancelled {
                self.isAwaitingAppRelaunch = false
                self.appUpdateError = L10n.k(
                    "services.update_checker.install_complete_reopen_manually",
                    fallback: "安装器已启动，但未检测到新版自动打开。请完成安装后手动重新打开 ClawdHome。"
                )
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func installedBundleVersion() -> String? {
        guard let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }

    private func relaunchInstalledApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.isAwaitingAppRelaunch = false
                    self.appUpdateError = error.localizedDescription
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    enum UpdateError: LocalizedError {
        case invalidFile
        case httpError(Int)
        case launchInstallerFailed

        var errorDescription: String? {
            switch self {
            case .invalidFile: return L10n.k("services.update_checker.file", fallback: "下载的文件无效，请稍后重试")
            case .httpError(let code): return "\(L10n.k("services.update_checker.server_error_prefix", fallback: "服务器返回错误")) (\(code))，\(L10n.k("services.update_checker.retry_later_suffix", fallback: "请稍后重试"))"
            case .launchInstallerFailed: return L10n.k("services.update_checker.open_open_pkg", fallback: "无法打开安装程序，请手动打开下载的 pkg")
            }
        }
    }

    // MARK: - 版本比较

    func needsUpdate(_ installed: String?) -> Bool {
        guard let installed, let latest = latestVersion else { return false }
        return compareVersions(installed, latest) == .orderedAscending
    }

    func upgradableCount(in users: [ManagedUser]) -> Int {
        users.filter { !$0.isAdmin && needsUpdate($0.openclawVersion) }.count
    }

    /// 逐段比较版本号（支持 "YYYY.M.DL10n.k("services.update_checker.text_ed4b80bf", fallback: " 和 ")1.0.180" 两种格式）
    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai < bi { return .orderedAscending }
            if ai > bi { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - 下载进度指标

    struct DownloadMetrics: Sendable {
        let progress: Double
        let bytesWritten: Int64
        let totalBytes: Int64
        let speed: Double // 字节/秒
    }

    // MARK: - 带进度的文件下载

    private func downloadFile(
        from url: URL,
        onProgress: @escaping @Sendable (DownloadMetrics) -> Void
    ) async throws -> URL {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            let onProgress: @Sendable (DownloadMetrics) -> Void
            var continuation: CheckedContinuation<URL, Error>?
            var startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
            var lastSpeedUpdateTime: CFAbsoluteTime = 0
            var lastSpeedUpdateBytes: Int64 = 0
            var currentSpeed: Double = 0

            init(_ onProgress: @escaping @Sendable (DownloadMetrics) -> Void) {
                self.onProgress = onProgress
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didFinishDownloadingTo location: URL) {
                // 检查 HTTP 状态码
                if let httpResponse = downloadTask.response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    continuation?.resume(throwing: UpdateChecker.UpdateError.httpError(httpResponse.statusCode))
                    continuation = nil
                    return
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.copyItem(at: location, to: tmp)
                    continuation?.resume(returning: tmp)
                } catch {
                    continuation?.resume(throwing: error)
                }
                continuation = nil
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                            totalBytesExpectedToWrite: Int64) {
                guard totalBytesExpectedToWrite > 0 else { return }

                // 每 0.5 秒更新一次速率，避免频繁跳动
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - lastSpeedUpdateTime
                if elapsed >= 0.5 {
                    let bytesDelta = totalBytesWritten - lastSpeedUpdateBytes
                    currentSpeed = Double(bytesDelta) / elapsed
                    lastSpeedUpdateTime = now
                    lastSpeedUpdateBytes = totalBytesWritten
                }

                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                onProgress(DownloadMetrics(
                    progress: progress,
                    bytesWritten: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite,
                    speed: currentSpeed
                ))
            }

            func urlSession(_ session: URLSession, task: URLSessionTask,
                            didCompleteWithError error: Error?) {
                if let error, continuation != nil {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }
        }

        let delegate = Delegate(onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        currentDownloadSession = session

        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - 格式化工具

    /// 格式化字节数为人类可读格式
    static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    /// 格式化速率为人类可读格式
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB/s", mb)
    }
}
