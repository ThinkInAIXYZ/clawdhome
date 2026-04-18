import AppKit
import Foundation

final class LLMWikiLaunchService {
    let appURL = URL(fileURLWithPath: LLMWikiPaths.appBundlePath)

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: appURL.path)
    }

    func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: LLMWikiPaths.bundleIdentifier)
    }

    func isRunning() -> Bool {
        !runningApplications().isEmpty
    }

    @MainActor
    func launchManaged() async throws {
        guard isInstalled() else {
            throw HelperError.operationFailed("LLM Wiki.app 未安装")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.environment = [
            "LLM_WIKI_KB_SOCKET_PATH": LLMWikiPaths.socketPath,
            "LLM_WIKI_KB_HEARTBEAT_SOCKET_PATH": LLMWikiPaths.heartbeatSocketPath,
            "LLM_WIKI_KB_RUNTIME_GROUP": LLMWikiPaths.sharedGroup,
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    func restartManaged() async throws {
        for app in runningApplications() {
            _ = app.terminate()
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await launchManaged()
    }
}
