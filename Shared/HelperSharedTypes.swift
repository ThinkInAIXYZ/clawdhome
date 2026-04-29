// Shared/HelperSharedTypes.swift
// HelperProtocol.swift 中提取的业务类型（App 与 Helper 共用）

import Foundation

enum GatewayStartFailureType: Equatable {
    case nodeToolchainMissing
    case startupTimeout
    case xpcUnavailable
    case other
}

enum XPCTimeoutPolicy {
    /// 为 XPC 调用增加冗余超时，降低偶发抖动造成的误伤。
    /// 规则：
    /// - 最小冗余 3 秒
    /// - 冗余按基础超时的 33% 计算
    /// - 最大冗余 20 秒
    static func effectiveTimeoutSeconds(requested requestedSeconds: Int) -> Int {
        let base = max(1, requestedSeconds)
        let slack = min(20, max(3, base / 3))
        return base + slack
    }
}

enum HermesFeaturePolicy {
    static let supportsMultiAgent = false
    static let nextVersionHint = "Hermes 团队召唤将在下一版支持"

    static var shouldShowMultiAgentEntrypoints: Bool {
        supportsMultiAgent
    }

    static func canSelectHermesForTeamSummon(hasTeamDNA: Bool) -> Bool {
        !hasTeamDNA || supportsMultiAgent
    }
}

enum HermesProfileRuntimeSummary {
    static func badgeText(
        profileIDs: [String],
        runningProfileIDs: Set<String>,
        mainRuntimeRunning: Bool,
        profilesLoaded: Bool
    ) -> String {
        guard profilesLoaded else {
            return "Hermes · 加载中…"
        }
        let running = runningCount(
            profileIDs: profileIDs,
            runningProfileIDs: runningProfileIDs,
            mainRuntimeRunning: mainRuntimeRunning
        )
        return "Hermes · \(running)/\(profileIDs.count) 运行中"
    }

    static func runningCount(
        profileIDs: [String],
        runningProfileIDs: Set<String>,
        mainRuntimeRunning: Bool
    ) -> Int {
        profileIDs.reduce(0) { count, profileID in
            if runningProfileIDs.contains(profileID) {
                return count + 1
            }
            if profileID == "main" && mainRuntimeRunning {
                return count + 1
            }
            return count
        }
    }
}

enum ManagedHomeRuntime: String, Codable, Sendable {
    case openclaw
    case hermes

    var relativeHomePath: String {
        switch self {
        case .openclaw:
            return ".openclaw"
        case .hermes:
            return ".hermes"
        }
    }
}

enum UserFilesScope: Codable, Sendable, Equatable {
    case home
    case runtime(ManagedHomeRuntime)

    var rootRelativePath: String {
        switch self {
        case .home:
            return ""
        case .runtime(let runtime):
            return runtime.relativeHomePath
        }
    }

    var runtime: ManagedHomeRuntime? {
        switch self {
        case .home:
            return nil
        case .runtime(let runtime):
            return runtime
        }
    }

    var shortcutTitle: String? {
        switch self {
        case .home:
            return nil
        case .runtime(.openclaw):
            return "OpenClaw 数据"
        case .runtime(.hermes):
            return "Hermes 数据"
        }
    }
}

enum UserFilesRuntimePolicy {
    static func shouldShowRuntimeHomeShortcut(scope: UserFilesScope) -> Bool {
        scope.runtime != nil
    }

    static func shouldHideEntryFromRootHomeList(name: String, isDirectory: Bool, scope: UserFilesScope, currentPath: String) -> Bool {
        guard scope == .home, currentPath.isEmpty, isDirectory else {
            return false
        }
        return name == ManagedHomeRuntime.openclaw.relativeHomePath || name == ManagedHomeRuntime.hermes.relativeHomePath
    }
}

enum MaintenanceTerminalCommandPolicy {
    static func commandForRuntime(command: [String], runtime: ManagedHomeRuntime?) -> [String] {
        guard runtime == .hermes,
              let executable = command.first,
              isShellExecutable(executable) else {
            return command
        }
        return ["hermes-shell"] + command.dropFirst()
    }

    private static func isShellExecutable(_ executable: String) -> Bool {
        let normalized = (executable as NSString).lastPathComponent.lowercased()
        return normalized == "zsh" || normalized == "bash" || normalized == "sh"
    }
}

enum WizardDraftPersistencePolicy {
    static func shouldUseOpenClawWorkspace(selectedEngineRaw: String?) -> Bool {
        selectedEngineRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "openclaw"
    }
}

enum AccidentalOpenClawDraftDetector {
    static func shouldDelete(topLevelEntries: [String], hasOpenClawBinary: Bool) -> Bool {
        guard !hasOpenClawBinary else { return false }
        let normalized = Set(topLevelEntries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if normalized.isEmpty { return true }
        return normalized == ["workspace"]
    }
}

enum GatewayStartFailureClassifier {
    static func classify(_ message: String) -> GatewayStartFailureType {
        let lowered = message.lowercased()

        if isLikelyNodeToolchainMissing(lowered) {
            return .nodeToolchainMissing
        }
        if isLikelyXPCUnavailable(lowered) {
            return .xpcUnavailable
        }
        if isLikelyGatewayStartupTimeout(lowered) {
            return .startupTimeout
        }
        return .other
    }

    /// nodeInstalledProbe:
    /// - `true`: 已确认 Node 可用
    /// - `false`: 已确认 Node 缺失
    /// - `nil`: 当前无法确认（例如 XPC 不可用）
    static func shouldSuggestNodeRepair(
        startupErrorMessage: String,
        nodeInstalledProbe: Bool?
    ) -> Bool {
        switch classify(startupErrorMessage) {
        case .nodeToolchainMissing:
            return true
        case .xpcUnavailable:
            return false
        case .startupTimeout:
            guard let installed = nodeInstalledProbe else { return false }
            return !installed
        case .other:
            guard let installed = nodeInstalledProbe else { return false }
            return !installed
        }
    }

    private static func isLikelyGatewayStartupTimeout(_ lowered: String) -> Bool {
        if lowered.contains("启动 gateway 超时") { return true }
        if lowered.contains("start gateway timeout") { return true }
        if lowered.contains("gateway start timeout") { return true }
        return false
    }

    private static func isLikelyXPCUnavailable(_ lowered: String) -> Bool {
        if lowered.contains("未能与帮助应用程序通信") { return true }
        if lowered.contains("xpc 调用超时") { return true }
        if lowered.contains("sec code lookup failed") { return true }
        if lowered.contains("seccode lookup failed") { return true }
        if lowered.contains("not connected") { return true }
        return false
    }

    private static func isLikelyNodeToolchainMissing(_ lowered: String) -> Bool {
        if lowered.contains("env: node: no such file or directory") { return true }
        if lowered.contains("未找到 npm，请先完成 node.js 安装步骤") { return true }
        if lowered.contains("node.js 未安装就绪") { return true }
        if lowered.contains("未找到隔离用户环境 npx") { return true }
        if lowered.contains("npx is restricted to the isolated user environment") { return true }
        if lowered.contains("exit 127")
            && lowered.contains("openclaw")
            && lowered.contains("gateway.port") {
            return true
        }
        return false
    }
}

enum ManagedUserFilter {
    static let minimumStandardUID = 500
    private static let systemAccounts: Set<String> = ["nobody", "root", "daemon", "Guest"]
    private static let usersDirectorySkipEntries: Set<String> = ["Shared", ".localized"]

    static func isExcludedUsername(_ username: String) -> Bool {
        username.hasPrefix("_") || systemAccounts.contains(username)
    }

    static func isEligibleManagedUser(username: String, uid: Int, adminNames: Set<String>) -> Bool {
        uid >= minimumStandardUID
            && !adminNames.contains(username)
            && !isExcludedUsername(username)
    }

    static func shouldConsiderUsersDirectoryEntry(_ name: String) -> Bool {
        !name.hasPrefix(".") && !usersDirectorySkipEntries.contains(name)
    }
}

// MARK: - 运行时配置（~/.clawdhome/runtime.json）

/// ClawdHome 写入的 shrimp 运行时声明，是识别引擎的唯一锚点。
/// 无此文件时回退到 openclaw 文件检测（向下兼容历史安装）。
struct ShrimpRuntimeConfig: Codable, Sendable {
    /// "hermes" 或 "openclaw"
    var runtime: String
}

struct XcodeEnvStatus: Codable, Sendable {
    var commandLineToolsInstalled: Bool
    var clangAvailable: Bool
    var licenseAccepted: Bool
    var detail: String

    var isHealthy: Bool {
        commandLineToolsInstalled && clangAvailable && licenseAccepted
    }
}

enum PairingOutputParser {
    private static let ansiPattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"

    static func extractQRCodeBlock(from output: String) -> String? {
        let plain = stripANSI(output)
        let lines = plain.components(separatedBy: .newlines)

        var current: [String] = []
        var best: [String] = []

        for line in lines {
            if isQRCodeLike(line) {
                current.append(line)
                if current.count > best.count {
                    best = current
                }
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }

        guard best.count >= 4 else { return nil }
        return best.joined(separator: "\n")
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: ansiPattern,
            with: "",
            options: .regularExpression
        )
    }

    private static func isQRCodeLike(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let qrChars = CharacterSet(charactersIn: "█▀▄▌▐▖▗▘▙▚▛▜▝▞▟▔▁▂▃▄▅▆▇▓▒░")
        return trimmed.unicodeScalars.contains(where: { qrChars.contains($0) })
    }
}
