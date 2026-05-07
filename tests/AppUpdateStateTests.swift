import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AppUpdateStateTests {
    static func main() {
        let json = """
        {"latestVersion":"1.5.0","downloadURL":"https://example.com/app.pkg","releaseNotes":"notes","minimumVersion":"1.4.0","lastSuccessfulCheckAt":1234,"lastHeartbeatAt":1234,"lastError":null,"source":"helper"}
        """
        let data = Data(json.utf8)
        let decoded = try! JSONDecoder().decode(AppUpdateState.self, from: data)
        expect(decoded.latestVersion == "1.5.0", "should decode latest version")
        expect(decoded.downloadURL == "https://example.com/app.pkg", "should decode download URL")
        expect(decoded.minimumVersion == "1.4.0", "should decode minimum version")
        expect(decoded.source == "helper", "should decode source")
        print("App update state tests passed.")
    }
}
