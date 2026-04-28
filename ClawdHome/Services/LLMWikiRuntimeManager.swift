import Foundation

@MainActor
final class LLMWikiRuntimeManager {
    static let shared = LLMWikiRuntimeManager()

    private var process: Process?
    private let session: URLSession
    private let kbClient = KnowledgeBaseSocketClient()

    private init(session: URLSession = .shared) {
        self.session = session
    }

    var executableURL: URL? {
        Bundle.main.url(
            forResource: LLMWikiPaths.runtimeExecutableName,
            withExtension: nil,
            subdirectory: LLMWikiPaths.embeddedResourceDirectoryName
        )
    }

    func isInstalled() -> Bool {
        guard let executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    func clipServerStatus() async -> String {
        if await canReachClipServerStatus() {
            return "running"
        }
        return isRunning() ? "starting" : "error"
    }

    func ensureRunning() async throws {
        let hasTrackedProcess = process?.isRunning == true
        let hasReachableRuntime = await canReachClipServerStatus()
        if !hasTrackedProcess && !hasReachableRuntime {
            try startProcess()
        }
        try await waitUntilHealthy()
        try await bindSharedProject()
    }

    func restart() async throws {
        if process?.isRunning == true {
            stop()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try await ensureRunning()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func bindSharedProject() async throws {
        let projectBody: [String: Any] = [
            "path": LLMWikiPaths.projectRoot,
        ]
        let recentProjectsBody: [String: Any] = [
            "projects": [[
                "name": LLMWikiPaths.sharedProjectName,
                "path": LLMWikiPaths.projectRoot,
            ]],
        ]
        _ = try await postJSON(to: "http://127.0.0.1:19827/project", body: projectBody)
        _ = try await postJSON(to: "http://127.0.0.1:19827/projects", body: recentProjectsBody)
    }

    func takePendingIngestRequests(projectPath: String?) async throws -> Any {
        appLog("[LLMWikiRuntimeManager] taking pending ingest requests for projectPath=\(projectPath ?? "<nil>")")
        let payload: [String: Any] = ["projectPath": projectPath ?? NSNull()]
        let response = try await postJSON(to: "http://127.0.0.1:19827/pending-ingest/take", body: payload)
        guard let dictionary = response as? [String: Any],
              let requests = dictionary["requests"]
        else {
            return []
        }
        return requests
    }

    func invoke(command: String, payload: Any) async throws -> Any {
        appLog("[LLMWikiRuntimeManager] invoke start: \(command)")
        guard let executableURL else {
            throw NSError(
                domain: "LLMWikiRuntimeManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Embedded LLM Wiki runtime is missing from the app bundle."]
            )
        }

        let executablePath = executableURL.path
        let inputData = try JSONSerialization.data(withJSONObject: payload, options: [])

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: executablePath)
                    proc.arguments = ["invoke", command]
                    proc.environment = Self.runtimeEnvironment()

                    let stdout = Pipe()
                    let stderr = Pipe()
                    let stdin = Pipe()
                    proc.standardOutput = stdout
                    proc.standardError = stderr
                    proc.standardInput = stdin

                    try proc.run()
                    stdin.fileHandleForWriting.write(inputData)
                    try? stdin.fileHandleForWriting.close()
                    proc.waitUntilExit()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

                    guard proc.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "Runtime invoke failed with exit code \(proc.terminationStatus)"
                        throw NSError(
                            domain: "LLMWikiRuntimeManager",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    if outputData.isEmpty {
                        appLog("[LLMWikiRuntimeManager] invoke finished: \(command) (empty response)")
                        continuation.resume(returning: NSNull())
                        return
                    }

                    let object = try JSONSerialization.jsonObject(with: outputData, options: [.fragmentsAllowed])
                    appLog("[LLMWikiRuntimeManager] invoke finished: \(command)")
                    continuation.resume(returning: object)
                } catch {
                    appLog("[LLMWikiRuntimeManager] invoke failed: \(command) (\(error.localizedDescription))", level: .error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startProcess() throws {
        guard let executableURL else {
            throw NSError(
                domain: "LLMWikiRuntimeManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Embedded LLM Wiki runtime executable not found."]
            )
        }

        if process?.isRunning == true { return }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["serve"]
        proc.environment = Self.runtimeEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            appLog("[LLMWikiRuntime] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            appLog("[LLMWikiRuntime][stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))", level: .warn)
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
            }
        }

        try proc.run()
        process = proc
    }

    private func waitUntilHealthy() async throws {
        for _ in 0..<40 {
            if let health = try? await kbClient.health(), health.ok {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NSError(
            domain: "LLMWikiRuntimeManager",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Embedded LLM Wiki runtime did not become healthy in time."]
        )
    }

    private func canReachClipServerStatus() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:19827/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func postJSON(to urlString: String, body: [String: Any]) async throws -> Any {
        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "LLMWikiRuntimeManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid runtime URL: \(urlString)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "LLMWikiRuntimeManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Runtime returned an invalid response."]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(
                domain: "LLMWikiRuntimeManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        if data.isEmpty {
            return NSNull()
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    nonisolated private static func runtimeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["LLM_WIKI_KB_SOCKET_PATH"] = LLMWikiPaths.socketPath
        environment["LLM_WIKI_KB_HEARTBEAT_SOCKET_PATH"] = LLMWikiPaths.heartbeatSocketPath
        environment["LLM_WIKI_KB_RUNTIME_GROUP"] = LLMWikiPaths.sharedGroup
        return environment
    }
}
