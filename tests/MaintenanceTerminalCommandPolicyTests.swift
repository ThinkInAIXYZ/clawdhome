import Foundation

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message)\nactual: \(actual)\nexpected: \(expected)\n", stderr)
        exit(1)
    }
}

@main
struct MaintenanceTerminalCommandPolicyTests {
    static func main() {
        expectEqual(
            MaintenanceTerminalCommandPolicy.commandForRuntime(command: ["zsh", "-l"], runtime: .hermes),
            ["hermes-shell", "-l"],
            "Hermes maintenance shell should use hermes-shell so helper applies Hermes PATH"
        )

        expectEqual(
            MaintenanceTerminalCommandPolicy.commandForRuntime(
                command: ["zsh", "-lc", "cd '/Users/a/.hermes' && exec /bin/zsh -l"],
                runtime: .hermes
            ),
            ["hermes-shell", "-lc", "cd '/Users/a/.hermes' && exec /bin/zsh -l"],
            "Hermes file-manager shell should preserve shell arguments"
        )

        expectEqual(
            MaintenanceTerminalCommandPolicy.commandForRuntime(command: ["zsh", "-l"], runtime: .openclaw),
            ["zsh", "-l"],
            "OpenClaw maintenance shell should keep the normal shell command"
        )

        expectEqual(
            MaintenanceTerminalCommandPolicy.commandForRuntime(command: ["hermes", "whatsapp"], runtime: .hermes),
            ["hermes", "whatsapp"],
            "Direct Hermes commands should not be rewritten"
        )

        print("Maintenance terminal command policy tests passed.")
    }
}
