// ClawdHome/Views/HealthCheckSheet.swift
// 体检面板：环境隔离检查 + 应用安全审计

import SwiftUI

struct HealthCheckSheet: View {
    let user: ManagedUser
    /// 每次检查完成后回调（用于更新状态行的摘要）
    var onCompleted: ((HealthCheckResult) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var result: HealthCheckResult?
    @State private var isLoading = false
    @State private var isFixing = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.tint)
                Text(L10n.k("auto.health_check_sheet.health_check", fallback: "体检结果")).font(.headline)
                Text("@\(user.username)").foregroundStyle(.secondary)
                Spacer()
                Button(L10n.k("auto.health_check_sheet.done", fallback: "完成")) { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 内容区
            if isLoading {
                ProgressView(L10n.k("auto.health_check_sheet.text_5fc65af5b3", fallback: "检查中…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryBar(r)
                        isolationSection(r)
                        auditSection(r)
                    }
                    .padding(20)
                }

                Divider()

                // 底部操作栏
                HStack(spacing: 12) {
                    if r.fixableIssueCount > 0 {
                        Button(isFixing ? L10n.k("auto.health_check_sheet.text_114268798e", fallback: "修复中…") : "修复全部（\(r.fixableIssueCount) 项）") {
                            Task { await runCheck(fix: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFixing)
                    }
                    Spacer()
                    Button(isLoading || isFixing ? L10n.k("auto.health_check_sheet.text_5fc65af5b3", fallback: "检查中…") : L10n.k("auto.health_check_sheet.recheck", fallback: "重新检查")) {
                        Task { await runCheck(fix: false) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || isFixing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            } else if let err = loadError {
                ContentUnavailableView(
                    L10n.k("auto.health_check_sheet.check_failed", fallback: "检查失败"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 460)
        .task { await runCheck(fix: false) }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func summaryBar(_ r: HealthCheckResult) -> some View {
        HStack(spacing: 16) {
            if r.criticalCount > 0 {
                Label(L10n.f("views.health_check_sheet.text_977a5060", fallback: "%@ 个严重问题", String(describing: r.criticalCount)), systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if r.warnCount > 0 {
                Label(L10n.f("views.health_check_sheet.text_600eda8e", fallback: "%@ 个警告", String(describing: r.warnCount)), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !r.hasIssues {
                Label(L10n.k("auto.health_check_sheet.all_good", fallback: "一切正常"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer()
            // 检查时间
            let date = Date(timeIntervalSince1970: r.checkedAt)
            let timeText = date.formatted(date: .omitted, time: .shortened)
            Text(L10n.f("views.health_check_sheet.text_7eba8ea1", fallback: "检查于 %@", timeText))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline.weight(.medium))
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func isolationSection(_ r: HealthCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.k("auto.health_check_sheet.environment_isolation_check", fallback: "环境隔离检查"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            let issues = r.isolationFindings
            if issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.k("auto.health_check_sheet.configuration", fallback: "权限配置正常，无隔离风险"))
                }
                .font(.callout)
                .padding(.vertical, 4)
            } else {
                ForEach(issues) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }

    @ViewBuilder
    private func auditSection(_ r: HealthCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.k("auto.health_check_sheet.security_audit", fallback: "应用安全审计"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if r.auditSkipped {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    Text(L10n.k("views.health_check_sheet.openclaw", fallback: "openclaw 未安装，跳过审计"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            } else if let err = r.auditError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout)
                }
                .padding(.vertical, 4)
            } else if r.auditFindings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.k("auto.health_check_sheet.security_audit", fallback: "无安全审计问题"))
                }
                .font(.callout)
                .padding(.vertical, 4)
            } else {
                ForEach(r.auditFindings) { finding in
                    FindingRow(finding: finding)
                }
            }
        }
    }

    // MARK: - 操作

    private func runCheck(fix: Bool) async {
        if fix { isFixing = true } else { isLoading = true }
        loadError = nil
        if let r = await helperClient.runHealthCheck(username: user.username, fix: fix) {
            result = r
            onCompleted?(r)
        } else {
            loadError = L10n.k("auto.health_check_sheet.helper_clawdhome", fallback: "无法连接到 Helper 服务，请确认 ClawdHome 已正确安装")
        }
        isFixing = false
        isLoading = false
    }
}

// MARK: - 单条检查项视图

private struct FindingRow: View {
    let finding: HealthFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 状态图标（固定宽度，左对齐）
            statusIcon
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.callout.weight(.medium))
                    if let fixed = finding.fixed {
                        if fixed {
                            Text(L10n.k("auto.health_check_sheet.fixed", fallback: "已修复"))
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.12), in: Capsule())
                        } else {
                            Text(L10n.k("auto.health_check_sheet.fix_failed", fallback: "修复失败"))
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.red.opacity(0.12), in: Capsule())
                        }
                    }
                }
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = finding.fixError {
                    Text(L10n.f("views.health_check_sheet.text_c5187b4b", fallback: "修复出错：%@", String(describing: err)))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        // 已修复时覆盖为绿色
        if finding.fixed == true {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if finding.fixed == false {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            switch finding.severity {
            case "critical":
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case "warn":
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case "info":
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            default:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}
