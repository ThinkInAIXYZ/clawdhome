import Foundation

@main
struct UserFilesScopePolicyTests {
    static func main() {
        expectEqual(UserFilesScope.home.rootRelativePath, "", "home scope should point at user home")
        expectEqual(UserFilesScope.runtime(.openclaw).rootRelativePath, ".openclaw", "openclaw scope should point at .openclaw")
        expectEqual(UserFilesScope.runtime(.hermes).rootRelativePath, ".hermes", "hermes scope should point at .hermes")

        expectNil(UserFilesScope.home.shortcutTitle, "home scope should not have runtime shortcut title")
        expectEqual(UserFilesScope.runtime(.openclaw).shortcutTitle ?? "", "OpenClaw 数据", "openclaw scope should expose branded shortcut")
        expectEqual(UserFilesScope.runtime(.hermes).shortcutTitle ?? "", "Hermes 数据", "hermes scope should expose branded shortcut")

        expectFalse(UserFilesRuntimePolicy.shouldShowRuntimeHomeShortcut(scope: .home), "home scope should not show runtime shortcut")
        expectTrue(UserFilesRuntimePolicy.shouldShowRuntimeHomeShortcut(scope: .runtime(.openclaw)), "runtime scope should show shortcut")

        expectTrue(
            UserFilesRuntimePolicy.shouldHideEntryFromRootHomeList(
                name: ".openclaw",
                isDirectory: true,
                scope: .home,
                currentPath: ""
            ),
            "home root should hide openclaw runtime directory"
        )
        expectTrue(
            UserFilesRuntimePolicy.shouldHideEntryFromRootHomeList(
                name: ".hermes",
                isDirectory: true,
                scope: .home,
                currentPath: ""
            ),
            "home root should hide hermes runtime directory"
        )
        expectFalse(
            UserFilesRuntimePolicy.shouldHideEntryFromRootHomeList(
                name: ".openclaw",
                isDirectory: true,
                scope: .runtime(.openclaw),
                currentPath: ".openclaw"
            ),
            "runtime scope should not hide its own root contents"
        )
        expectFalse(
            UserFilesRuntimePolicy.shouldHideEntryFromRootHomeList(
                name: "Documents",
                isDirectory: true,
                scope: .home,
                currentPath: ""
            ),
            "home root should keep normal directories visible"
        )
    }

    private static func expectEqual(_ actual: String, _ expected: String, _ message: String) {
        guard actual == expected else {
            fputs("Assertion failed: \(message). expected=\(expected) actual=\(actual)\n", stderr)
            exit(1)
        }
    }

    private static func expectNil(_ actual: String?, _ message: String) {
        guard actual == nil else {
            fputs("Assertion failed: \(message). actual=\(actual ?? "<nil>")\n", stderr)
            exit(1)
        }
    }

    private static func expectTrue(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("Assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func expectFalse(_ condition: Bool, _ message: String) {
        expectTrue(!condition, message)
    }
}
