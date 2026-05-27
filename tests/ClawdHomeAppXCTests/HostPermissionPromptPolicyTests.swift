import XCTest
@testable import ClawdHome

final class HostPermissionPromptPolicyTests: XCTestCase {
    func testMissingBrowserAutomationPermissionsIncludesBothRequiredPermissions() {
        let missing = HostPermissionPromptPolicy.missingBrowserAutomationPermissions(
            accessibilityStatus: .denied,
            chromeInstalled: true,
            chromeAutomationStatus: .requiresConsent
        )

        XCTAssertEqual(missing, [.accessibility, .chromeAutomation])
    }

    func testMissingBrowserAutomationPermissionsIgnoresChromeWhenNotInstalled() {
        let missing = HostPermissionPromptPolicy.missingBrowserAutomationPermissions(
            accessibilityStatus: .granted,
            chromeInstalled: false,
            chromeAutomationStatus: .denied
        )

        XCTAssertTrue(missing.isEmpty)
    }

    func testPreferredSettingsDestinationPrefersAccessibilityWhenBothMissing() {
        let destination = HostPermissionPromptPolicy.preferredSettingsDestination(
            for: [.accessibility, .chromeAutomation]
        )

        XCTAssertEqual(destination, .accessibility)
    }

    func testPreferredSettingsDestinationFallsBackToAutomation() {
        let destination = HostPermissionPromptPolicy.preferredSettingsDestination(
            for: [.chromeAutomation]
        )

        XCTAssertEqual(destination, .automation)
    }
}
