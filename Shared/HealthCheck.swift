// Shared/HealthCheck.swift
// 诊断结果数据模型

import Foundation

// MARK: - 统一诊断结果

/// 诊断分组类型
enum DiagnosticGroup: String, Codable, CaseIterable {
    case environment  = "environment"   // 环境检测（Node.js、npm）
    case network      = "network"       // 网络连通性
    case permissions  = "permissions"   // 权限检测（7 项隔离检查）
    case config       = "config"        // 配置校验（openclaw doctor）
    case security     = "security"      // 安全审计（openclaw security audit）
    case gateway      = "gateway"       // Gateway 运行状态

    var title: String {
        switch self {
        case .environment: return String(localized: "health.group.environment", defaultValue: "环境检测")
        case .permissions: return String(localized: "health.group.permissions", defaultValue: "权限检测")
        case .config:      return String(localized: "health.group.config",      defaultValue: "配置校验")
        case .security:    return String(localized: "health.group.security",    defaultValue: "安全审计")
        case .gateway:     return String(localized: "health.group.gateway",     defaultValue: "Gateway 状态")
        case .network:     return String(localized: "health.group.network",     defaultValue: "网络连通")
        }
    }

    var systemImage: String {
        switch self {
        case .environment: return "cpu"
        case .permissions: return "lock.shield"
        case .config:      return "doc.badge.gearshape"
        case .security:    return "shield.checkered"
        case .gateway:     return "server.rack"
        case .network:     return "network"
        }
    }

    var fixable: Bool {
        switch self {
        case .environment, .permissions, .config, .security: return true
        case .gateway, .network: return false
        }
    }
}

/// 单项诊断结果
struct DiagnosticItem: Codable, Identifiable {
    let id: String
    let group: DiagnosticGroup
    let severity: String     // "ok" | "info" | "warn" | "critical"
    let title: String
    let detail: String
    let fixable: Bool
    let fixed: Bool?         // nil=未尝试, true=已修复, false=修复失败
    let fixError: String?
    /// 网络检测专用：延迟毫秒数，nil 表示不可达或非网络项
    let latencyMs: Int?
}

/// 完整诊断报告
struct DiagnosticsResult: Codable {
    let username: String
    let checkedAt: TimeInterval
    let items: [DiagnosticItem]

    func items(for group: DiagnosticGroup) -> [DiagnosticItem] {
        items.filter { $0.group == group }
    }

    var issueItems: [DiagnosticItem] {
        items.filter { $0.severity == "critical" || $0.severity == "warn" }
    }

    var criticalCount: Int { items.filter { $0.severity == "critical" }.count }
    var warnCount: Int     { items.filter { $0.severity == "warn" }.count }
    var hasIssues: Bool    { criticalCount + warnCount > 0 }

    var fixableIssueCount: Int {
        issueItems.filter { $0.fixable && $0.fixed == nil }.count
    }

    func groupPassed(_ group: DiagnosticGroup) -> Bool {
        items(for: group).allSatisfy { $0.severity == "ok" || $0.severity == "info" }
    }
}

// MARK: - Gateway 自启动诊断策略

enum DiagnosticsGatewayAutostartPolicy {
    static func openClawItem(
        globalAutostartEnabled: Bool,
        userAutostartEnabled: Bool,
        intentionalStopActive: Bool,
        plistExists: Bool,
        runAtLoad: Bool,
        keepAlive: Bool,
        running: Bool
    ) -> DiagnosticItem {
        if !globalAutostartEnabled {
            return DiagnosticItem(
                id: "gw-openclaw-autostart-global-disabled",
                group: .gateway,
                severity: "info",
                title: "OpenClaw Gateway 全局自启动已关闭",
                detail: "全局开机自启动关闭，跳过自启动检查",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !userAutostartEnabled {
            return DiagnosticItem(
                id: "gw-openclaw-autostart-user-disabled",
                group: .gateway,
                severity: "info",
                title: "OpenClaw Gateway 实例已冻结",
                detail: "该实例当前处于冻结状态，跳过自启动检查",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if intentionalStopActive {
            return DiagnosticItem(
                id: "gw-openclaw-autostart-intentional-stop",
                group: .gateway,
                severity: "info",
                title: "OpenClaw Gateway 已手动停止",
                detail: "检测到手动停止记录，跳过自启动运行态检查",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !plistExists {
            return DiagnosticItem(
                id: "gw-openclaw-autostart-plist-missing",
                group: .gateway,
                severity: "warn",
                title: "OpenClaw Gateway 自启动未注册",
                detail: "自启动已启用，但 LaunchDaemon plist 不存在",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !runAtLoad || !keepAlive {
            let missing = [
                runAtLoad ? nil : "RunAtLoad",
                keepAlive ? nil : "KeepAlive",
            ].compactMap { $0 }.joined(separator: ", ")
            return DiagnosticItem(
                id: "gw-openclaw-autostart-plist-invalid",
                group: .gateway,
                severity: "warn",
                title: "OpenClaw Gateway 自启动配置异常",
                detail: "LaunchDaemon 缺少或关闭：\(missing)",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !running {
            return DiagnosticItem(
                id: "gw-openclaw-autostart-not-running",
                group: .gateway,
                severity: "warn",
                title: "OpenClaw Gateway 自启动未拉起",
                detail: "自启动已启用且 LaunchDaemon 已注册，但当前未运行",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        return DiagnosticItem(
            id: "gw-openclaw-autostart-ok",
            group: .gateway,
            severity: "ok",
            title: "OpenClaw Gateway 自启动正常",
            detail: "LaunchDaemon 已注册并保持运行",
            fixable: false,
            fixed: nil,
            fixError: nil,
            latencyMs: nil
        )
    }

    static func hermesItem(
        profileID: String,
        globalAutostartEnabled: Bool,
        userAutostartEnabled: Bool,
        profileAutostartEnabled: Bool,
        plistExists: Bool,
        runAtLoad: Bool,
        keepAlive: Bool,
        running: Bool
    ) -> DiagnosticItem {
        let safeProfileID = profileID.isEmpty ? "main" : profileID
        let idPrefix = "gw-hermes-\(safeProfileID)-autostart"
        let profileLabel = safeProfileID == "main" ? "main" : safeProfileID

        if !globalAutostartEnabled {
            return DiagnosticItem(
                id: "\(idPrefix)-global-disabled",
                group: .gateway,
                severity: "info",
                title: "Hermes Gateway 全局自启动已关闭",
                detail: "全局开机自启动关闭，跳过 Hermes profile \(profileLabel) 自启动检查",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !userAutostartEnabled {
            return DiagnosticItem(
                id: "\(idPrefix)-user-disabled",
                group: .gateway,
                severity: "info",
                title: "Hermes Gateway 实例已冻结",
                detail: "该实例当前处于冻结状态，跳过 Hermes profile \(profileLabel) 自启动检查",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !profileAutostartEnabled {
            return DiagnosticItem(
                id: "\(idPrefix)-profile-disabled",
                group: .gateway,
                severity: "info",
                title: "Hermes Profile 未启用自启动",
                detail: "profile \(profileLabel) 不在 Hermes 自启动白名单中",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !plistExists {
            return DiagnosticItem(
                id: "\(idPrefix)-plist-missing",
                group: .gateway,
                severity: "warn",
                title: "Hermes Gateway 自启动未注册",
                detail: "profile \(profileLabel) 已启用自启动，但 LaunchDaemon plist 不存在",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !runAtLoad || !keepAlive {
            let missing = [
                runAtLoad ? nil : "RunAtLoad",
                keepAlive ? nil : "KeepAlive",
            ].compactMap { $0 }.joined(separator: ", ")
            return DiagnosticItem(
                id: "\(idPrefix)-plist-invalid",
                group: .gateway,
                severity: "warn",
                title: "Hermes Gateway 自启动配置异常",
                detail: "profile \(profileLabel) LaunchDaemon 缺少或关闭：\(missing)",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        if !running {
            return DiagnosticItem(
                id: "\(idPrefix)-not-running",
                group: .gateway,
                severity: "warn",
                title: "Hermes Gateway 自启动未拉起",
                detail: "profile \(profileLabel) 已启用自启动且 LaunchDaemon 已注册，但当前未运行",
                fixable: false,
                fixed: nil,
                fixError: nil,
                latencyMs: nil
            )
        }
        return DiagnosticItem(
            id: "\(idPrefix)-ok",
            group: .gateway,
            severity: "ok",
            title: "Hermes Gateway 自启动正常",
            detail: "profile \(profileLabel) LaunchDaemon 已注册并保持运行",
            fixable: false,
            fixed: nil,
            fixError: nil,
            latencyMs: nil
        )
    }
}

// MARK: - Node.js 下载源

enum NodeDistOption: String, CaseIterable, Codable {
    case npmmirror = "https://registry.npmmirror.com/-/binary/node"
    case official  = "https://nodejs.org/dist"

    static let defaultForInitialization: NodeDistOption = .npmmirror

    var title: String {
        switch self {
        case .npmmirror: return String(localized: "node.dist.npmmirror", defaultValue: "npmmirror 加速")
        case .official:  return String(localized: "node.dist.official", defaultValue: "nodejs.org 官方")
        }
    }

    func tarGzURL(version: String, archSuffix: String) -> String {
        "\(rawValue)/\(version)/node-\(version)-\(archSuffix).tar.gz"
    }

    func shasumsURL(version: String) -> String {
        "\(rawValue)/\(version)/SHASUMS256.txt"
    }
}

// MARK: - npm 安装源

enum NpmRegistryOption: String, CaseIterable, Codable {
    case taobaoMirror = "https://registry.npmmirror.com"
    case npmOfficial = "https://registry.npmjs.org"

    static let defaultForInitialization: NpmRegistryOption = .taobaoMirror

    var title: String {
        switch self {
        case .taobaoMirror: return String(localized: "npm.registry.taobao", defaultValue: "npm 中国加速")
        case .npmOfficial: return String(localized: "npm.registry.official", defaultValue: "npm 官方")
        }
    }

    var normalizedURL: String {
        Self.normalize(rawValue)
    }

    static func normalize(_ url: String) -> String {
        var value = url
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    static func fromRegistryURL(_ url: String) -> NpmRegistryOption? {
        let normalized = normalize(url)
        return allCases.first { $0.normalizedURL == normalized }
    }
}
