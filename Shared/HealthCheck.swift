// ClawdHome/Models/HealthCheck.swift
// 体检结果数据模型

import Foundation

struct HealthFinding: Codable, Identifiable {
    let id: String
    let source: String    // "isolation" | "audit"
    let severity: String  // "critical" | "warn" | "info" | "ok"
    let title: String
    let detail: String
    let fixable: Bool
    let fixed: Bool?      // nil=未尝试, true=已修复, false=修复失败
    let fixError: String?
}

struct HealthCheckResult: Codable {
    let username: String
    let checkedAt: TimeInterval   // Date().timeIntervalSince1970
    let findings: [HealthFinding]
    let auditSkipped: Bool        // openclaw 未安装时跳过审计
    let auditError: String?       // 审计命令失败时的错误描述

    var isolationFindings: [HealthFinding] { findings.filter { $0.source == "isolation" } }
    var auditFindings: [HealthFinding]     { findings.filter { $0.source == "audit" } }
    var issueFindings: [HealthFinding]     { findings.filter { $0.severity == "critical" || $0.severity == "warn" } }

    var criticalCount: Int { findings.filter { $0.severity == "critical" }.count }
    var warnCount: Int     { findings.filter { $0.severity == "warn" }.count }
    var hasIssues: Bool    { criticalCount + warnCount > 0 }

    /// 可一键修复且尚未修复的问题数
    var fixableIssueCount: Int {
        issueFindings.filter { $0.fixable && $0.fixed == nil }.count
    }
}

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
        case .environment: return "环境检测"
        case .permissions: return "权限检测"
        case .config:      return "配置校验"
        case .security:    return "安全审计"
        case .gateway:     return "Gateway 状态"
        case .network:     return "网络连通"
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
