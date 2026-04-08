import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct GatewayStartFailureClassifierTests {
    static func main() {
        expect(
            GatewayStartFailureClassifier.classify("启动 Gateway 超时，请检查 Helper 日志后重试") == .startupTimeout,
            "should classify gateway timeout separately"
        )

        expect(
            GatewayStartFailureClassifier.classify("未能与帮助应用程序通信。") == .xpcUnavailable,
            "should classify xpc communication errors separately"
        )

        expect(
            GatewayStartFailureClassifier.shouldSuggestNodeRepair(
                startupErrorMessage: "启动 Gateway 超时，请检查 Helper 日志后重试",
                nodeInstalledProbe: nil
            ) == false,
            "timeout without node evidence should not prompt node repair"
        )

        expect(
            GatewayStartFailureClassifier.shouldSuggestNodeRepair(
                startupErrorMessage: "启动 Gateway 超时，请检查 Helper 日志后重试",
                nodeInstalledProbe: false
            ) == true,
            "timeout with explicit node-missing probe should prompt repair"
        )

        expect(
            GatewayStartFailureClassifier.shouldSuggestNodeRepair(
                startupErrorMessage: "未能与帮助应用程序通信。",
                nodeInstalledProbe: nil
            ) == false,
            "xpc failure should never suggest node repair"
        )

        print("Gateway start failure classifier tests passed.")
    }
}
