// ClawdHome/Models/ManagedUser.swift

import Foundation
import Observation

struct ClawDescriptionStore {
    private let defaults: UserDefaults
    private let storageKey = "claw.description.byUsername"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func description(for username: String) -> String {
        guard let map = defaults.dictionary(forKey: storageKey) as? [String: String] else { return "" }
        return map[username] ?? ""
    }

    func setDescription(_ text: String, for username: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var map = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        if normalized.isEmpty {
            map.removeValue(forKey: username)
        } else {
            map[username] = normalized
        }
        defaults.set(map, forKey: storageKey)
    }
}

// MARK: - 节点来源类型
enum ClawType: String, Sendable, CaseIterable {
    case macosUser
    case docker
    case ssh
    case raspberryPi

    /// SF Symbol 名称
    var icon: String {
        switch self {
        case .macosUser:   return "apple.logo"
        case .docker:      return "shippingbox"
        case .ssh:         return "terminal"
        case .raspberryPi: return "cpu"
        }
    }

    var displayName: String {
        switch self {
        case .macosUser:   return L10n.k("models.managed_user.macosuser", fallback: "macOS用户")
        case .docker:      return "Docker"
        case .ssh:         return "SSH"
        case .raspberryPi: return L10n.k("models.managed_user.esp32", fallback: "树莓派 / ESP32")
        }
    }

    /// 当未提供 identifier 时，按类型生成默认值
    static func defaultIdentifier(for type: ClawType, username: String) -> String {
        switch type {
        case .macosUser:   return "@\(username)"
        case .docker:      return L10n.k("models.managed_user.configuration", fallback: ":未配置")
        case .ssh:         return "unknown-host"
        case .raspberryPi: return "unknown-host"
        }
    }
}

enum FreezeMode: String, Sendable, Equatable, Codable {
    case pause
    case normal
    case flash

    var statusLabel: String {
        switch self {
        case .pause:  L10n.k("models.managed_user.paused", fallback: "已暂停")
        case .normal: L10n.k("models.managed_user.freeze", fallback: "已冻结")
        case .flash:  L10n.k("models.managed_user.flash_frozen", fallback: "已速冻")
        }
    }

    var title: String {
        switch self {
        case .pause:  L10n.k("models.managed_user.pause_freeze_mode", fallback: "暂停冻结")
        case .normal: L10n.k("models.managed_user.normal_freeze_mode", fallback: "普通冻结")
        case .flash:  L10n.k("models.managed_user.flash_freeze", fallback: "速冻")
        }
    }

    var shortDescription: String {
        switch self {
        case .pause:  L10n.k("models.managed_user.suspend_runtime_processes_resume_later_without_releasing_memory", fallback: "挂起运行时相关进程，可恢复继续执行（不释放内存）")
        case .normal: L10n.k("models.managed_user.stop_gateway_userprocess", fallback: "停止 Gateway，保留用户空间其他进程")
        case .flash:  L10n.k("models.managed_user.userprocess_runtime_priority", fallback: "紧急终止用户空间进程（运行时相关优先）")
        }
    }
}

struct ClawFreezeStateRecord: Codable {
    let mode: FreezeMode
    let pausedPIDs: [Int32]
    let updatedAt: TimeInterval
    let previousAutostartEnabled: Bool?
}

struct ClawFreezeStateStore {
    private let defaults: UserDefaults
    private let storageKey = "claw.freeze.byUsername"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func frozenState(for username: String) -> ClawFreezeStateRecord? {
        loadMap()[username]
    }

    func setFrozenState(_ state: ClawFreezeStateRecord?, for username: String) {
        var map = loadMap()
        if let state {
            map[username] = state
        } else {
            map.removeValue(forKey: username)
        }
        saveMap(map)
    }

    private func loadMap() -> [String: ClawFreezeStateRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: ClawFreezeStateRecord].self, from: data) else {
            return [:]
        }
        return map
    }

    private func saveMap(_ map: [String: ClawFreezeStateRecord]) {
        if map.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// 代表一个由 ClawdHome 管理的 macOS 标准用户
/// 使用 @Observable 替代 ObservableObject（iOS/macOS 代码规范）
@Observable
final class ManagedUser: Identifiable, Hashable {
    let id: UUID
    let username: String        // macOS 短账户名（如 "alice"）
    var fullName: String        // 显示名称（如 "Alice"）
    let isAdmin: Bool           // 是否属于 admin 组
    let clawType: ClawType      // 来源类型
    /// 副标识：macOS用户 → "@alice"；Docker → ":8080"；SSH → "user@host"；Pi/ESP32 → "192.168.1.5"
    var identifier: String
    /// 备注描述：用于区分用途/设备位置等
    var profileDescription: String = ""

    // Gateway 运行状态
    var isRunning: Bool = false
    var freezeMode: FreezeMode? = nil
    var pausedProcessPIDs: [Int32] = []
    var freezeWarning: String? = nil
    var freezePreviousAutostartEnabled: Bool? = nil
    var isFrozen: Bool { freezeMode != nil }
    var hasFreezeWarning: Bool { freezeWarning != nil }
    var pid: Int32?
    var openclawVersion: String?
    var hermesVersion: String?
    /// 版本是否已检查过（区分"加载中"与"未初始化"）
    var versionChecked: Bool = false
    var startedAt: Date?
    var lastActiveAt: Date?

    // 资源占用（由 ShrimpPool 每秒从 DashboardSnapshot 同步）
    var cpuPercent: Double? = nil
    var memRssMB: Double? = nil
    var openclawDirBytes: Int64 = 0

    // macOS UID（用于端口映射等）
    var macUID: Int?

    // 错误状态
    var errorMessage: String?

    /// 当前初始化步骤（向导运行中时非 nil，供列表实时显示进度）
    var initStep: String?

    init(username: String, fullName: String, isAdmin: Bool = false,
         clawType: ClawType = .macosUser, identifier: String = "") {
        self.id = UUID()
        self.username = username
        self.fullName = fullName
        self.isAdmin = isAdmin
        self.clawType = clawType
        self.identifier = identifier.isEmpty ? ClawType.defaultIdentifier(for: clawType, username: username) : identifier
    }

    /// 版本号展示字符串，带 v 前缀（如 "v2026.2.15"）
    var openclawVersionLabel: String? { openclawVersion.map { "v\($0)" } }
    var hermesVersionLabel: String? { hermesVersion.map { "v\($0)" } }

    /// 运行时优先级：Hermes > OpenClaw（与详情页保持一致）
    var runtimeDisplayName: String {
        if hermesVersion != nil { return "Hermes" }
        if openclawVersion != nil { return "OpenClaw" }
        return "—"
    }

    var runtimeVersionLabel: String? {
        if let hermesVersionLabel { return hermesVersionLabel }
        if let openclawVersionLabel { return openclawVersionLabel }
        return nil
    }

    var prefersHermesRuntime: Bool {
        hermesVersion != nil
    }

    /// 状态文字，用于 UI 展示
    var statusLabel: String {
        if let msg = errorMessage { return "\(L10n.k("models.managed_user.error_prefix", fallback: "异常:")) \(msg)" }
        if let freezeMode { return freezeMode.statusLabel }
        if isRunning { return L10n.k("models.managed_user.running", fallback: "运行中") }
        return L10n.k("models.managed_user.not_running", fallback: "未运行")
    }

    /// 冻结后强制停止网关；解冻只恢复可操作，不自动启动
    func setFrozen(
        _ frozen: Bool,
        mode: FreezeMode = .normal,
        pausedPIDs: [Int32] = [],
        previousAutostartEnabled: Bool? = nil
    ) {
        freezeMode = frozen ? mode : nil
        pausedProcessPIDs = frozen ? pausedPIDs : []
        freezeWarning = nil
        freezePreviousAutostartEnabled = frozen ? previousAutostartEnabled : nil
        guard frozen else { return }
        isRunning = false
        pid = nil
        startedAt = nil
    }

    // Hashable：基于不可变 id，保证 List 选中状态稳定
    static func == (lhs: ManagedUser, rhs: ManagedUser) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 开发期间使用的 Mock 数据
extension ManagedUser {
    static var mockData: [ManagedUser] {
        let alice = ManagedUser(username: "alice", fullName: "Alice", isAdmin: true)
        alice.isRunning = true
        alice.openclawVersion = "2026.2.24"
        alice.startedAt = Date().addingTimeInterval(-7200)
        alice.lastActiveAt = Date().addingTimeInterval(-180)

        let bob = ManagedUser(username: "bob", fullName: "Bob")

        return [alice, bob]
    }
}
