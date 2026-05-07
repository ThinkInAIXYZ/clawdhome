import Darwin
import Foundation

final class AppUpdateHeartbeatService {
    static let shared = AppUpdateHeartbeatService()

    private static let appApiURL = "https://clawdhome.app/api/version.json"
    private static let cacheDirectory = "/var/lib/clawdhome"
    private static let cachePath = "\(cacheDirectory)/app-update-state.json"
    private static let clientIDPath = "\(cacheDirectory)/client-id"
    private static let checkInterval: TimeInterval = 8 * 3600

    private let queue = DispatchQueue(label: "ai.clawdhome.helper.app-update-heartbeat", qos: .utility)
    private var started = false

    private init() {}

    func start() {
        queue.sync {
            guard !started else { return }
            started = true
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.runLoop()
            }
        }
    }

    func cachedStateJSON() -> String? {
        guard let state = loadCachedState(),
              let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func runLoop() async {
        await checkNow()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.checkInterval * 1_000_000_000))
            await checkNow()
        }
    }

    private func checkNow() async {
        guard let url = URL(string: Self.appApiURL) else { return }

        let previous = loadCachedState()
        let appVersion = installedAppVersion()
        let systemLanguage = preferredSystemLanguage()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(buildUserAgent(appVersion: appVersion, systemLanguage: systemLanguage), forHTTPHeaderField: "User-Agent")
        request.setValue(
            buildClientHeader(appVersion: appVersion, systemLanguage: systemLanguage),
            forHTTPHeaderField: "X-ClawdHome-Client"
        )

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let now = Date().timeIntervalSinceReferenceDate
            var state = previous ?? AppUpdateState(source: "helper")
            state.latestVersion = json["version"] as? String
            state.downloadURL = json["download_url"] as? String
            state.releaseNotes = json["release_notes"] as? String ?? json["release_notes_en"] as? String
            state.minimumVersion = json["min_version"] as? String
            state.lastSuccessfulCheckAt = now
            state.lastHeartbeatAt = now
            state.lastError = nil
            state.source = "helper"
            saveCachedState(state)
        } catch {
            var state = previous ?? AppUpdateState(source: "helper")
            state.lastError = error.localizedDescription
            state.source = "helper"
            saveCachedState(state)
            helperLog("[app-update] check failed: \(error.localizedDescription)", level: .warn)
        }
    }

    private func saveCachedState(_ state: AppUpdateState) {
        do {
            try ensureCacheDirectory()
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL(fileURLWithPath: Self.cachePath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.cachePath)
        } catch {
            helperLog("[app-update] save cache failed: \(error.localizedDescription)", level: .warn)
        }
    }

    private func loadCachedState() -> AppUpdateState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.cachePath)) else { return nil }
        return try? JSONDecoder().decode(AppUpdateState.self, from: data)
    }

    private func clientIdentifier() -> String {
        if let existing = try? String(contentsOfFile: Self.clientIDPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        do {
            try ensureCacheDirectory()
            try generated.write(toFile: Self.clientIDPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.clientIDPath)
        } catch {
            helperLog("[app-update] save client id failed: \(error.localizedDescription)", level: .warn)
        }
        return generated
    }

    private func ensureCacheDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: Self.cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
    }

    private func installedAppVersion() -> String {
        let candidates = [
            "/Applications/ClawdHome.app/Contents/Info.plist",
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("ClawdHome.app/Contents/Info.plist")
                .path
        ]
        for path in candidates {
            if let info = NSDictionary(contentsOfFile: path),
               let version = info["CFBundleShortVersionString"] as? String,
               !version.isEmpty {
                return version
            }
        }
        return "0"
    }

    private func buildUserAgent(appVersion: String, systemLanguage: String) -> String {
        "ClawdHome/\(appVersion) (macOS \(Self.systemVersionString()); \(Self.cpuArchitecture()); \(Self.cpuModel()); \(Self.physicalMemoryString()); \(systemLanguage))"
    }

    private func buildClientHeader(appVersion: String, systemLanguage: String) -> String {
        "id=\(clientIdentifier()); app=\(appVersion); lang=\(systemLanguage); os=\(Self.systemVersionString()); arch=\(Self.cpuArchitecture()); cpu=\(sanitizeHeaderValue(Self.cpuModel())); ram=\(Self.physicalMemoryString())"
    }

    private func preferredSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preferred, !preferred.isEmpty else { return "en" }
        return preferred
    }

    private func sanitizeHeaderValue(_ value: String) -> String {
        value.replacingOccurrences(of: ";", with: ",")
    }

    private static func systemVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func cpuArchitecture() -> String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "unknown-arch" }
        let capacity = MemoryLayout.size(ofValue: uts.machine)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func cpuModel() -> String {
        if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty {
            return brand
        }
        if let model = sysctlString("hw.model"), !model.isEmpty {
            return model
        }
        return "unknown-cpu"
    }

    private static func physicalMemoryString() -> String {
        let bytes = ProcessInfo.processInfo.physicalMemory
        guard bytes > 0 else { return "unknown" }
        let gib = Double(bytes) / 1_073_741_824.0
        if gib >= 10 {
            return "\(Int(gib.rounded()))GB"
        }
        return String(format: "%.1fGB", gib)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
