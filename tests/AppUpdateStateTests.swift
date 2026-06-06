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

        let bilingualJSON = """
        {"releaseNotes":"中文更新","releaseNotesEN":"English notes","source":"helper"}
        """
        let bilingual = try! JSONDecoder().decode(AppUpdateState.self, from: Data(bilingualJSON.utf8))
        expect(bilingual.localizedReleaseNotes(languageIdentifier: "zh-Hans") == "中文更新", "should prefer Chinese release notes for Chinese language")
        expect(bilingual.localizedReleaseNotes(languageIdentifier: "en-US") == "English notes", "should prefer English release notes for English language")
        expect(bilingual.localizedReleaseNotes(languageIdentifier: "fr-FR") == "English notes", "should prefer English release notes for non-Chinese languages")

        let chineseOnlyJSON = """
        {"releaseNotes":"只有中文","source":"helper"}
        """
        let chineseOnly = try! JSONDecoder().decode(AppUpdateState.self, from: Data(chineseOnlyJSON.utf8))
        expect(chineseOnly.localizedReleaseNotes(languageIdentifier: "en-US") == "只有中文", "should fall back to Chinese notes when English notes are missing")

        print("App update state tests passed.")
    }
}
