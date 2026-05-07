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
