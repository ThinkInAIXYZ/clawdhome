import Foundation

struct OpenCLINetworkSupport {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    static func fetch(url: URL, timeout: TimeInterval, username: String, acceptJSON: Bool = false) throws -> Response {
        let proxyEnv = ConfigWriter.proxyEnvironment(username: username)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clawdhome-opencli-fetch-\(UUID().uuidString)", isDirectory: true)
        let bodyURL = tempDir.appendingPathComponent("body.bin")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var args = OpenCLINetworkDiagnostics.curlEnvironmentAssignments(from: proxyEnv)
        args.append("/usr/bin/curl")
        args += [
            "-sS",
            "-L",
            "--connect-timeout", "\(max(1, Int(ceil(timeout))))",
            "--max-time", "\(max(1, Int(ceil(timeout))))",
            "-o", bodyURL.path,
            "-w", "%{http_code}",
        ]
        if acceptJSON {
            args += ["-H", "Accept: application/vnd.github+json"]
        }
        args.append(url.absoluteString)

        let statusText: String
        do {
            statusText = try run("/usr/bin/env", args: args)
        } catch {
            throw BrowserAccountError.commandFailed(
                failureMessage(
                    action: "网络请求失败",
                    url: url,
                    statusCode: nil,
                    body: nil,
                    underlying: error.localizedDescription,
                    proxyEnv: proxyEnv
                )
            )
        }

        let statusCode = Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let body = (try? Data(contentsOf: bodyURL)) ?? Data()
        guard (200..<300).contains(statusCode) else {
            throw BrowserAccountError.commandFailed(
                failureMessage(
                    action: "网络请求失败",
                    url: url,
                    statusCode: statusCode,
                    body: body,
                    underlying: nil,
                    proxyEnv: proxyEnv
                )
            )
        }
        return Response(statusCode: statusCode, data: body)
    }

    static func curlEnvironmentAssignments(from proxyEnv: [String: String]) -> [String] {
        OpenCLINetworkDiagnostics.curlEnvironmentAssignments(from: proxyEnv)
    }

    static func proxySummary(from proxyEnv: [String: String]) -> String {
        OpenCLINetworkDiagnostics.proxySummary(from: proxyEnv)
    }

    static func failureMessage(
        action: String,
        url: URL,
        statusCode: Int?,
        body: Data?,
        underlying: String?,
        proxyEnv: [String: String]
    ) -> String {
        OpenCLINetworkDiagnostics.failureMessage(
            action: action,
            url: url,
            statusCode: statusCode,
            body: body,
            underlying: underlying,
            proxyEnv: proxyEnv
        )
    }
}
