import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct DiagnosticsAutostartPolicyTests {
    static func main() {
        let frozenOpenClaw = DiagnosticsGatewayAutostartPolicy.openClawItem(
            globalAutostartEnabled: true,
            userAutostartEnabled: false,
            intentionalStopActive: false,
            plistExists: false,
            runAtLoad: false,
            keepAlive: false,
            running: false
        )
        expect(frozenOpenClaw.severity == "info", "OpenClaw should skip autostart check when instance is frozen")
        expect(frozenOpenClaw.id == "gw-openclaw-autostart-user-disabled", "OpenClaw skip item should use an OpenClaw-specific id")
        expect(frozenOpenClaw.title.contains("冻结"), "OpenClaw frozen skip item should explicitly indicate frozen state")

        let brokenOpenClaw = DiagnosticsGatewayAutostartPolicy.openClawItem(
            globalAutostartEnabled: true,
            userAutostartEnabled: true,
            intentionalStopActive: false,
            plistExists: true,
            runAtLoad: true,
            keepAlive: true,
            running: false
        )
        expect(brokenOpenClaw.severity == "warn", "OpenClaw should warn when autostart is enabled but gateway is not running")
        expect(brokenOpenClaw.title.contains("OpenClaw"), "OpenClaw autostart item should be visibly distinct from Hermes")

        let frozenHermes = DiagnosticsGatewayAutostartPolicy.hermesItem(
            profileID: "main",
            globalAutostartEnabled: true,
            userAutostartEnabled: false,
            profileAutostartEnabled: true,
            plistExists: false,
            runAtLoad: false,
            keepAlive: false,
            running: false
        )
        expect(frozenHermes.severity == "info", "Hermes should skip autostart check when instance is frozen")
        expect(frozenHermes.id == "gw-hermes-main-autostart-user-disabled", "Hermes skip item should use a Hermes profile-specific id")
        expect(frozenHermes.title.contains("冻结"), "Hermes frozen skip item should explicitly indicate frozen state")

        let missingHermesPlist = DiagnosticsGatewayAutostartPolicy.hermesItem(
            profileID: "main",
            globalAutostartEnabled: true,
            userAutostartEnabled: true,
            profileAutostartEnabled: true,
            plistExists: false,
            runAtLoad: false,
            keepAlive: false,
            running: false
        )
        expect(missingHermesPlist.severity == "warn", "Hermes should warn when a whitelisted profile has no LaunchDaemon plist")
        expect(missingHermesPlist.title.contains("Hermes"), "Hermes autostart item should be visibly distinct from OpenClaw")

        let disabledHermesProfile = DiagnosticsGatewayAutostartPolicy.hermesItem(
            profileID: "coder",
            globalAutostartEnabled: true,
            userAutostartEnabled: true,
            profileAutostartEnabled: false,
            plistExists: false,
            runAtLoad: false,
            keepAlive: false,
            running: false
        )
        expect(disabledHermesProfile.severity == "info", "Hermes should not warn for profiles that are intentionally not in the autostart whitelist")

        print("Diagnostics autostart policy tests passed.")
    }
}
