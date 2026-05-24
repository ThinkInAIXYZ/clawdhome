import XCTest

final class OpenCLINetworkSupportTests: XCTestCase {
    func testProxySummaryIncludesConfiguredProxyKeys() {
        let summary = OpenCLINetworkDiagnostics.proxySummary(from: [
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "NO_PROXY": "localhost,127.0.0.1",
        ])

        XCTAssertEqual(summary, "HTTPS_PROXY=http://127.0.0.1:7890, NO_PROXY=localhost,127.0.0.1")
    }

    func testProxySummaryFallsBackWhenNoProxyConfigured() {
        XCTAssertEqual(OpenCLINetworkDiagnostics.proxySummary(from: [:]), "未配置代理")
    }

    func testFailureMessageIncludesStatusResponseSnippetAndProxySummary() throws {
        let message = OpenCLINetworkDiagnostics.failureMessage(
            action: "网络请求失败",
            url: try XCTUnwrap(URL(string: "https://api.github.com/repos/jackwener/opencli/releases/latest")),
            statusCode: 403,
            body: Data("rate limited".utf8),
            underlying: nil,
            proxyEnv: ["HTTPS_PROXY": "http://127.0.0.1:7890"]
        )

        XCTAssertTrue(message.contains("HTTP 403"))
        XCTAssertTrue(message.contains("响应片段：rate limited"))
        XCTAssertTrue(message.contains("代理环境：HTTPS_PROXY=http://127.0.0.1:7890"))
    }
}
