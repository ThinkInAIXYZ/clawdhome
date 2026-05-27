import AppKit
import ApplicationServices
import Carbon
import Observation

enum HostPermissionRequirement: Equatable {
    case accessibility
    case chromeAutomation
}

enum HostPermissionSettingsDestination: Equatable {
    case accessibility
    case automation
}

enum HostPermissionPromptPolicy {
    static func missingBrowserAutomationPermissions(
        accessibilityStatus: HostPermissionCenter.PermissionStatus,
        chromeInstalled: Bool,
        chromeAutomationStatus: HostPermissionCenter.PermissionStatus
    ) -> [HostPermissionRequirement] {
        var missing: [HostPermissionRequirement] = []

        if accessibilityStatus != .granted {
            missing.append(.accessibility)
        }
        if chromeInstalled, chromeAutomationStatus != .granted {
            missing.append(.chromeAutomation)
        }

        return missing
    }

    static func preferredSettingsDestination(
        for missingPermissions: [HostPermissionRequirement]
    ) -> HostPermissionSettingsDestination? {
        if missingPermissions.contains(.accessibility) {
            return .accessibility
        }
        if missingPermissions.contains(.chromeAutomation) {
            return .automation
        }
        return nil
    }
}

@MainActor
@Observable
final class HostPermissionCenter {
    enum PermissionStatus: Equatable {
        case granted
        case requiresConsent
        case denied
        case unavailable
    }

    private let chromeBundleID = "com.google.Chrome"
    private let chromeAppPath = "/Applications/Google Chrome.app"

    var accessibilityStatus: PermissionStatus = .granted
    var chromeAutomationStatus: PermissionStatus = .unavailable
    var chromeInstalled = false
    var isRefreshing = false
    var lastCheckedAt: Date?
    var lastAutomationOSStatus: OSStatus = noErr

    var hasIssues: Bool {
        if accessibilityStatus != .granted { return true }
        if chromeInstalled, chromeAutomationStatus != .granted { return true }
        return false
    }

    var accessibilityMissing: Bool {
        accessibilityStatus != .granted
    }

    var chromeAutomationMissing: Bool {
        chromeInstalled && chromeAutomationStatus != .granted
    }

    func missingBrowserAutomationPermissions() -> [HostPermissionRequirement] {
        HostPermissionPromptPolicy.missingBrowserAutomationPermissions(
            accessibilityStatus: accessibilityStatus,
            chromeInstalled: chromeInstalled,
            chromeAutomationStatus: chromeAutomationStatus
        )
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }

        chromeInstalled = FileManager.default.fileExists(atPath: chromeAppPath)
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
        chromeAutomationStatus = evaluateChromeAutomationPermission(askUserIfNeeded: false)
        lastCheckedAt = Date()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestChromeAutomationPermission() {
        _ = evaluateChromeAutomationPermission(askUserIfNeeded: true)
        refresh()
    }

    func requestBrowserAutomationPermissions(_ permissions: [HostPermissionRequirement]) {
        if permissions.contains(.accessibility) {
            requestAccessibilityPermission()
        }
        if permissions.contains(.chromeAutomation) {
            requestChromeAutomationPermission()
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSettings(for permissions: [HostPermissionRequirement]) {
        switch HostPermissionPromptPolicy.preferredSettingsDestination(for: permissions) {
        case .accessibility:
            openAccessibilitySettings()
        case .automation:
            openAutomationSettings()
        case nil:
            break
        }
    }

    private func evaluateChromeAutomationPermission(askUserIfNeeded: Bool) -> PermissionStatus {
        guard chromeInstalled else {
            lastAutomationOSStatus = noErr
            return .unavailable
        }

        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: chromeBundleID)
        guard let rawTarget = targetDescriptor.aeDesc?.pointee else {
            lastAutomationOSStatus = OSStatus(paramErr)
            return .unavailable
        }

        var mutableTarget = rawTarget
        let status = AEDeterminePermissionToAutomateTarget(
            &mutableTarget,
            AEEventClass(kCoreEventClass),
            AEEventID(kAEOpenApplication),
            askUserIfNeeded
        )
        lastAutomationOSStatus = status

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .requiresConsent
        case OSStatus(errAEEventNotPermitted):
            return .denied
        default:
            return .unavailable
        }
    }
}
