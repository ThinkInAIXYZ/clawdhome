// ClawdHome/Services/HelperServiceLocator.swift
// 运行时识别当前机器真正可用的 Helper Mach service，避免 release/dev 模式混用时整机断连。

import Foundation

enum HelperServiceLocator {
    static let releaseLabel = "ai.clawdhome.mac.helper"
    static let devLabel = "ai.clawdhome.mac.helper.dev"

    private static let launchDaemonsDir = "/Library/LaunchDaemons"
    private static let helperToolsDir = "/Library/PrivilegedHelperTools"

    static func preferredMachServiceName(default defaultName: String = kHelperMachServiceName) -> String {
        let candidates = orderedCandidates(default: defaultName)

        for candidate in candidates where isLoaded(label: candidate) {
            return candidate
        }
        for candidate in candidates where isInstalled(label: candidate) {
            return candidate
        }
        return defaultName
    }

    static func restartLabels(default defaultName: String = kHelperMachServiceName) -> [String] {
        let candidates = orderedCandidates(default: defaultName)
        let loaded = candidates.filter { isLoaded(label: $0) }
        if !loaded.isEmpty { return loaded }

        let installed = candidates.filter { isInstalled(label: $0) }
        if !installed.isEmpty { return installed }

        return [defaultName]
    }

    private static func orderedCandidates(default defaultName: String) -> [String] {
        [defaultName] + [releaseLabel, devLabel].filter { $0 != defaultName }
    }

    private static func isInstalled(label: String) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(label: label)) ||
        FileManager.default.fileExists(atPath: helperPath(label: label))
    }

    private static func isLoaded(label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/\(label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return false
        }

        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func plistPath(label: String) -> String {
        "\(launchDaemonsDir)/\(label).plist"
    }

    private static func helperPath(label: String) -> String {
        "\(helperToolsDir)/\(label)"
    }
}
