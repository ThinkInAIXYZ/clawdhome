import Foundation

@main
struct UserInitPresentationRoutingTests {
    private static func expect(
        _ route: UserInitPresentationRoute,
        equals expected: UserInitPresentationRoute,
        _ message: String
    ) {
        guard route == expected else {
            fputs("FAIL: \(message)\nexpected: \(expected)\nactual: \(route)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        expect(
            resolveUserInitPresentation(
                versionChecked: true,
                hasInitStep: false,
                hasPendingInitWizard: true,
                isAdmin: false,
                isMacOSUser: true
            ),
            equals: .standaloneWizard,
            "pending init sessions for macOS users should use the standalone wizard window"
        )

        expect(
            resolveUserInitPresentation(
                versionChecked: false,
                hasInitStep: false,
                hasPendingInitWizard: false,
                isAdmin: false,
                isMacOSUser: true
            ),
            equals: .loading,
            "detail view should stay in loading state before version check completes"
        )

        expect(
            resolveUserInitPresentation(
                versionChecked: true,
                hasInitStep: true,
                hasPendingInitWizard: true,
                isAdmin: true,
                isMacOSUser: true
            ),
            equals: .detailTabs,
            "admin users should never be forced into the init wizard window"
        )

        expect(
            resolveUserInitPresentation(
                versionChecked: true,
                hasInitStep: false,
                hasPendingInitWizard: false,
                isAdmin: false,
                isMacOSUser: true
            ),
            equals: .detailTabs,
            "initialized users should stay in the normal detail tabs"
        )

        guard shouldEmbedOverviewGatewayConsole(
            selectedTabRawValue: "overview",
            initPresentationRoute: .detailTabs,
            isAdmin: true,
            versionChecked: true,
            hasInstalledOpenClaw: false,
            isGatewayOperational: true
        ) else {
            fputs(
                "FAIL: admin users with running gateway should still keep overview console\n",
                stderr
            )
            exit(1)
        }

        guard !shouldEmbedOverviewGatewayConsole(
            selectedTabRawValue: "overview",
            initPresentationRoute: .detailTabs,
            isAdmin: true,
            versionChecked: true,
            hasInstalledOpenClaw: false,
            isGatewayOperational: false
        ) else {
            fputs(
                "FAIL: admin users without install and without running gateway should show unavailable state\n",
                stderr
            )
            exit(1)
        }

        print("User init presentation routing tests passed.")
    }
}
