import XCTest
@testable import ClawdHome

final class HostPermissionPromptPolicyTests: XCTestCase {
    func testMissingBrowserAutomationPermissionsDoesNotRequireAccessibilityForBrowserLaunch() {
        let missing = HostPermissionPromptPolicy.missingBrowserAutomationPermissions(
            accessibilityStatus: .denied,
            chromeInstalled: true,
            chromeAutomationStatus: .requiresConsent
        )

        XCTAssertEqual(missing, [.chromeAutomation])
    }

    func testMissingBrowserAutomationPermissionsIgnoresChromeWhenNotInstalled() {
        let missing = HostPermissionPromptPolicy.missingBrowserAutomationPermissions(
            accessibilityStatus: .granted,
            chromeInstalled: false,
            chromeAutomationStatus: .denied
        )

        XCTAssertTrue(missing.isEmpty)
    }

    func testPreferredSettingsDestinationPrefersAccessibilityWhenExplicitlyRequested() {
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

    func testRequestSatisfactionIgnoresPermissionsThatWereNotRequested() {
        let isSatisfied = HostPermissionPromptPolicy.isSatisfied(
            missingPermissions: [.chromeAutomation],
            accessibilityStatus: .denied,
            chromeInstalled: true,
            chromeAutomationStatus: .granted
        )

        XCTAssertTrue(isSatisfied)
    }
}
