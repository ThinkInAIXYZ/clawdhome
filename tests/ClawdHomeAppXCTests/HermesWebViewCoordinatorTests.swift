import XCTest
@testable import ClawdHome

final class HermesWebViewCoordinatorTests: XCTestCase {
    func testPopupNavigationActionOpensSystemBrowserForNewWindowNavigation() {
        let requestURL = URL(string: "http://localhost:8080")!

        let resolved = HermesWKWebViewRepresentable.Coordinator.popupNavigationAction(
            targetFrameIsMainFrame: nil,
            requestURL: requestURL
        )

        XCTAssertEqual(resolved, .openExternally(requestURL))
    }

    func testPopupNavigationActionIgnoresMainFrameNavigation() {
        let requestURL = URL(string: "http://localhost:8080")!

        let resolved = HermesWKWebViewRepresentable.Coordinator.popupNavigationAction(
            targetFrameIsMainFrame: true,
            requestURL: requestURL
        )

        XCTAssertEqual(resolved, .ignore)
    }
}
