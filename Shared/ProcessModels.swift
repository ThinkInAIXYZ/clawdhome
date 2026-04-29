// Shared/ProcessModels.swift

import Foundation

// MARK: - 进程格式化协议（消除 ProcessEntry / ProcessDetail 重复计算属性）

protocol ProcessFormattable {
    var state: String { get }
    var elapsedSeconds: Int { get }
    var memRssMB: Double { get }
}

extension ProcessFormattable {
    var stateLabel: String {
        switch state.prefix(1) {
        case "R": return String(localized: "process.state.running", defaultValue: "运行")
        case "S": return String(localized: "process.state.sleeping", defaultValue: "等待")
        case "I": return String(localized: "process.state.idle", defaultValue: "空闲")
        case "Z": return String(localized: "process.state.zombie", defaultValue: "僵尸")
        case "T": return String(localized: "process.state.stopped", defaultValue: "暂停")
        default:  return String(state.prefix(1))
        }
    }

    var uptimeLabel: String {
        let secs = elapsedSeconds
        guard secs >= 0 else { return "—" }
        if secs < 60    { return "\(secs)s" }
        if secs < 3600  { return "\(secs / 60)m" }
        let h = secs / 3600; let m = (secs % 3600) / 60
        if h < 24       { return "\(h)h\(m)m" }
        let d = h / 24; let rh = h % 24
        return "\(d)d\(rh)h"
    }

    var memLabel: String {
        memRssMB < 1024
            ? String(format: "%.0fM", memRssMB)
            : String(format: "%.1fG", memRssMB / 1024)
    }
}

struct ProcessEntry: Codable, Identifiable, ProcessFormattable {
    let pid: Int32
    let ppid: Int32
    let name: String        // 短名（comm）
    let cmdline: String     // 完整命令行
    let cpuPercent: Double
    let memRssMB: Double    // RSS，单位 MB
    let state: String       // R/S/I/Z/T…
    let threads: Int32
    let elapsedSeconds: Int // 运行时长（秒）
    var listeningPorts: [String] = [] // ["tcp:8080", "tcp:443"]

    var id: Int32 { pid }

    var portsLabel: String {
        listeningPorts.joined(separator: ",")
    }

    var purposeDescription: String {
        ProcessPurposeCatalog.description(forName: name, cmdline: cmdline)
    }
}

struct ProcessListSnapshot: Codable {
    let entries: [ProcessEntry]
    let portsLoading: Bool
    let updatedAt: TimeInterval
}

enum ClawPoolVisibilityPolicy {
    static func shouldShowUser(
        username: String,
        isAdmin: Bool,
        currentUsername: String,
        showCurrentAdmin: Bool
    ) -> Bool {
        if !isAdmin { return true }
        return showCurrentAdmin && username == currentUsername
    }
}

struct ProcessDetail: Codable, ProcessFormattable {
    let pid: Int32
    let ppid: Int32
    let name: String
    let cmdline: String
    let cpuPercent: Double
    let memRssMB: Double
    let state: String
    let elapsedSeconds: Int
    let startTime: TimeInterval?

    let executablePath: String?
    let executableExists: Bool
    let executableFileSizeBytes: Int64?
    let executableCreatedAt: TimeInterval?
    let executableModifiedAt: TimeInterval?
    let executableAccessedAt: TimeInterval?
    let executableMetadataChangedAt: TimeInterval?
    let executableInode: UInt64?
    let executableLinkCount: UInt64?
    let executableOwner: String?
    let executablePermissions: String?

    let listeningPorts: [String]
}

private enum ProcessPurposeCatalog {
    private static let known: [String: String] = [
        "distnoted":     String(localized: "process.desc.distnoted",    defaultValue: "MacOS 系统通知分发服务，负责跨进程通知通信。"),
        "lsd":           String(localized: "process.desc.lsd",          defaultValue: "MacOS LaunchServices 服务，负责应用/文档关联与启动解析。"),
        "cfprefsd":      String(localized: "process.desc.cfprefsd",     defaultValue: "MacOS 系统偏好设置守护进程，负责读写配置缓存。"),
        "trustd":        String(localized: "process.desc.trustd",       defaultValue: "MacOS 证书信任服务（TLS/证书校验），系统网络安全所需。"),
        "secd":          String(localized: "process.desc.secd",         defaultValue: "MacOS 钥匙串与安全策略服务，管理密钥与凭据访问。"),
        "launchd":       String(localized: "process.desc.launchd",      defaultValue: "MacOS 系统初始化与守护进程管理器，负责拉起后台服务。"),
        "WindowServer":  String(localized: "process.desc.windowserver", defaultValue: "MacOS 窗口与图形合成服务，负责桌面图形显示。"),
        "kernel_task":   String(localized: "process.desc.kernel_task",  defaultValue: "MacOS 内核任务，管理硬件与系统底层资源。"),
        "mds":           String(localized: "process.desc.mds",          defaultValue: "MacOS Spotlight 索引服务，负责文件搜索索引。"),
        "mDNSResponder": String(localized: "process.desc.mdnsresponder",defaultValue: "MacOS Bonjour/mDNS 网络发现服务。"),
        "logd":          String(localized: "process.desc.logd",         defaultValue: "MacOS 统一日志服务，负责系统日志采集与查询。"),
        "runningboardd": String(localized: "process.desc.runningboardd",defaultValue: "MacOS 进程生命周期与资源调度管理服务。"),
        "tccd":          String(localized: "process.desc.tccd",         defaultValue: "MacOS 隐私权限服务（相机/麦克风/文件等授权）。"),
    ]

    static func description(forName rawName: String, cmdline _: String) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return known[name] ?? ""
    }
}

enum ProcessKillSelectionResolver {
    static func resolveTargets(
        clickedPID: Int32,
        selectedPIDs: Set<Int32>,
        processes: [ProcessEntry]
    ) -> [ProcessEntry] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let selectedEntries = selectedPIDs.compactMap { byPID[$0] }.sorted { $0.pid < $1.pid }

        if selectedPIDs.contains(clickedPID), selectedEntries.count > 1 {
            return selectedEntries
        }
        guard let clicked = byPID[clickedPID] else { return [] }
        return [clicked]
    }
}

enum ProcessBulkActionResolver {
    static func resolveTargets(
        selectedPIDs: Set<Int32>,
        processes: [ProcessEntry]
    ) -> [ProcessEntry] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return selectedPIDs
            .compactMap { byPID[$0] }
            .sorted { $0.pid < $1.pid }
    }
}

enum ProcessEmergencyFreezeResolver {
    enum Runtime: Sendable {
        case openclaw
        case hermes
    }

    static func resolveTargets(processes: [ProcessEntry]) -> [ProcessEntry] {
        resolveTargets(processes: processes, runtime: .openclaw)
    }

    static func resolveTargets(processes: [ProcessEntry], runtime: Runtime) -> [ProcessEntry] {
        let filtered = processes.filter { $0.pid > 1 }
        return filtered.sorted { isPreferredKillOrder($0, $1, runtime: runtime) }
    }

    /// 暂停冻结仅作用于 openclaw 相关进程，避免挂起用户其他工作负载
    static func resolvePauseTargets(processes: [ProcessEntry]) -> [ProcessEntry] {
        resolvePauseTargets(processes: processes, runtime: .openclaw)
    }

    static func resolvePauseTargets(processes: [ProcessEntry], runtime: Runtime) -> [ProcessEntry] {
        processes
            .filter { $0.pid > 1 && isRuntimeRelated($0, runtime: runtime) }
            .sorted { $0.pid < $1.pid }
    }

    private static func isPreferredKillOrder(_ lhs: ProcessEntry, _ rhs: ProcessEntry, runtime: Runtime) -> Bool {
        let lhsRuntime = isRuntimeRelated(lhs, runtime: runtime)
        let rhsRuntime = isRuntimeRelated(rhs, runtime: runtime)
        if lhsRuntime != rhsRuntime {
            return lhsRuntime
        }
        return lhs.pid < rhs.pid
    }

    static func isRuntimeRelated(_ process: ProcessEntry, runtime: Runtime) -> Bool {
        switch runtime {
        case .openclaw:
            return isOpenclawRelated(process)
        case .hermes:
            return isHermesRelated(process)
        }
    }

    static func isOpenclawRelated(_ process: ProcessEntry) -> Bool {
        let name = process.name.lowercased()
        let cmdline = process.cmdline.lowercased()
        if name.contains("openclaw") {
            return true
        }
        if cmdline.contains("openclaw") {
            return true
        }
        return false
    }

    static func isHermesRelated(_ process: ProcessEntry) -> Bool {
        let name = process.name.lowercased()
        let cmdline = process.cmdline.lowercased()
        if name.contains("hermes") {
            return true
        }
        if cmdline.contains("hermes") {
            return true
        }
        return false
    }
}

enum GatewayStatusResolver {
    static func resolve(
        launchdPID: Int32?,
        processes: [ProcessEntry]
    ) -> (running: Bool, pid: Int32) {
        if let launchdPID, launchdPID > 0 {
            return (true, launchdPID)
        }

        let candidates = processes.filter(looksLikeGatewayProcess)
        guard !candidates.isEmpty else {
            return (false, -1)
        }

        let parentPIDs = Set(candidates.map(\.ppid))
        let leaves = candidates.filter { !parentPIDs.contains($0.pid) || $0.ppid == $0.pid }
        let preferredPool = leaves.isEmpty ? candidates : leaves
        guard let chosen = preferredPool.sorted(by: isPreferredCandidate).first else {
            return (false, -1)
        }
        return (true, chosen.pid)
    }

    private static func looksLikeGatewayProcess(_ process: ProcessEntry) -> Bool {
        if GatewayProcessCommandMatcher.isGatewayCommand(process.cmdline) {
            return true
        }
        let name = process.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return process.cmdline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name == "openclaw"
    }

    private static func isPreferredCandidate(_ lhs: ProcessEntry, _ rhs: ProcessEntry) -> Bool {
        let lhsPorts = lhs.listeningPorts.isEmpty ? 0 : 1
        let rhsPorts = rhs.listeningPorts.isEmpty ? 0 : 1
        if lhsPorts != rhsPorts {
            return lhsPorts > rhsPorts
        }

        let lhsState = stateRank(lhs.state)
        let rhsState = stateRank(rhs.state)
        if lhsState != rhsState {
            return lhsState < rhsState
        }

        if lhs.cpuPercent != rhs.cpuPercent {
            return lhs.cpuPercent > rhs.cpuPercent
        }

        if lhs.elapsedSeconds != rhs.elapsedSeconds {
            return lhs.elapsedSeconds > rhs.elapsedSeconds
        }

        return lhs.pid < rhs.pid
    }

    private static func stateRank(_ state: String) -> Int {
        switch state.uppercased().prefix(1) {
        case "R": return 0
        case "S", "I": return 1
        case "T": return 2
        case "Z": return 3
        default: return 4
        }
    }
}

enum GatewayProcessCommandMatcher {
    static func isGatewayCommand(_ cmdline: String) -> Bool {
        let normalized = cmdline
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)

        guard !normalized.isEmpty else { return false }

        if normalized.contains("openclaw-gateway") {
            return true
        }

        let tokens = normalized.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let executable = tokens.first else { return false }
        let isOpenclawExecutable = executable == "openclaw" || executable.hasSuffix("/openclaw")

        // Some process listings only keep executable name without argv.
        if isOpenclawExecutable && tokens.count == 1 {
            return true
        }

        if isOpenclawExecutable && tokens.count >= 3
            && tokens[1] == "gateway" && tokens[2] == "run" {
            return true
        }

        return false
    }

    static func orphanGatewayPIDs(fromPSOutput output: String, keepPID: Int32) -> [Int32] {
        var pids: [Int32] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let tokens = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard tokens.count == 2, let pid = Int32(tokens[0]), pid > 0 else { continue }
            guard pid != keepPID else { continue }
            guard isGatewayCommand(String(tokens[1])) else { continue }
            pids.append(pid)
        }
        return pids.sorted()
    }
}

enum LogSearchMatcher {
    /// 多关键词 AND 匹配，大小写不敏感；空查询不过滤。
    static func matches(text: String, query: String) -> Bool {
        let terms = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return true }

        let haystack = text.lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

enum LogTimestampFormatter {
    private static let outputFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let inputFormatters: [ISO8601DateFormatter] = {
        var formatters: [ISO8601DateFormatter] = []

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        formatters.append(plain)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        formatters.append(fractional)

        return formatters
    }()

    static func string(from date: Date) -> String {
        outputFormatter.string(from: date)
    }

    static func normalizeTimestamp(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        return outputFormatter.string(from: date)
    }

    static func normalizeLinePrefix(_ line: String) -> String {
        guard !line.isEmpty else { return line }

        if line.first == "[", let end = line.firstIndex(of: "]"), end > line.startIndex {
            let tsStart = line.index(after: line.startIndex)
            let rawTs = String(line[tsStart..<end])
            guard let date = parse(rawTs) else { return line }
            let suffix = String(line[line.index(after: end)...])
            return "[\(outputFormatter.string(from: date))]\(suffix)"
        }

        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first, let date = parse(String(first)) else {
            return line
        }
        let normalized = outputFormatter.string(from: date)
        if parts.count == 1 {
            return "[\(normalized)]"
        }
        return "[\(normalized)] \(parts[1])"
    }

    private static func parse(_ raw: String) -> Date? {
        for formatter in inputFormatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }
}
