// ClawdHome/Views/DiagnosticsSheet.swift
// 统一诊断中心：环境检测 + 权限检测 + 配置校验 + 安全审计 + Gateway 状态 + 网络连通

import SwiftUI

struct DiagnosticsSheet: View {
    let user: ManagedUser
    /// 全部检查完成后回调（用于更新状态行的摘要）
    var onCompleted: ((DiagnosticsResult) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    /// 逐组结果：每组完成后立即更新
    @State private var groupResults: [DiagnosticGroup: [DiagnosticItem]] = [:]
    /// 已完成的分组
    @State private var completedGroups: Set<DiagnosticGroup> = []
    @State private var expandedGroups: Set<DiagnosticGroup> = [.network]
    @State private var isRunning = false
    @State private var isFixing = false
    @State private var loadError: String?

    /// 诊断执行顺序
    private let groupOrder: [DiagnosticGroup] = DiagnosticGroup.allCases

    private var allItems: [DiagnosticItem] {
        groupOrder.flatMap { groupResults[$0] ?? [] }
    }
    private var criticalCount: Int { allItems.filter { $0.severity == "critical" }.count }
    private var warnCount: Int { allItems.filter { $0.severity == "warn" }.count }
    private var hasIssues: Bool { criticalCount + warnCount > 0 }
    private var fixableIssueCount: Int {
        allItems.filter { ($0.severity == "critical" || $0.severity == "warn") && $0.fixable && $0.fixed == nil }.count
    }
    private var isComplete: Bool { completedGroups.count == groupOrder.count }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.tint)
                Text("诊断中心").font(.headline)
                Text("@\(user.username)").foregroundStyle(.secondary)
                Spacer()
                Button(L10n.k("auto.health_check_sheet.done", fallback: "完成")) { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let err = loadError, groupResults.isEmpty {
                ContentUnavailableView(
                    "诊断失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryBar
                        ForEach(groupOrder, id: \.rawValue) { group in
                            diagnosticGroupSection(group: group)
                        }
                    }
                    .padding(20)
                }

                Divider()

                // 底部操作栏
                HStack(spacing: 12) {
                    if isComplete && fixableIssueCount > 0 {
                        Button {
                            Task { await runGroupByGroup(fix: true) }
                        } label: {
                            if isFixing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.k("auto.health_check_sheet.text_114268798e", fallback: "修复中…"))
                                }
                            } else {
                                Text("一键修复（\(fixableIssueCount) 项）")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isFixing || isRunning)
                    }
                    Spacer()
                    Button(isRunning || isFixing ? "诊断中…" : "重新诊断") {
                        Task { await runGroupByGroup(fix: false) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning || isFixing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 560, height: 520)
        .task { await runGroupByGroup(fix: false) }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var summaryBar: some View {
        HStack(spacing: 16) {
            if isComplete {
                if criticalCount > 0 {
                    Label("\(criticalCount) 个严重问题", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
                if warnCount > 0 {
                    Label("\(warnCount) 个警告", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !hasIssues {
                    Label(L10n.k("auto.health_check_sheet.all_good", fallback: "一切正常"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("诊断中… \(completedGroups.count)/\(groupOrder.count)")
                }
            }
            Spacer()
            if isComplete {
                Text("检查于 \(Date().formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func diagnosticGroupSection(group: DiagnosticGroup) -> some View {
        let items = groupResults[group]
        let isDone = completedGroups.contains(group)
        let isPending = (isRunning || isFixing) && !isDone

        DisclosureGroup(isExpanded: Binding(
            get: { expandedGroups.contains(group) },
            set: { if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) } }
        )) {
            if let items, !items.isEmpty {
                ForEach(items) { item in
                    DiagnosticItemRow(item: item)
                }
            } else if isPending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.k("auto.health_check_sheet.text_5fc65af5b3", fallback: "检测中…")).foregroundStyle(.secondary)
                }
                .padding(10)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isPending {
                    ProgressView().controlSize(.mini)
                } else if isDone, let items {
                    groupStatusBadge(items: items)
                }
            }
        }
    }

    @ViewBuilder
    private func groupStatusBadge(items: [DiagnosticItem]) -> some View {
        let criticals = items.filter { $0.severity == "critical" }.count
        let warns = items.filter { $0.severity == "warn" }.count
        if criticals > 0 {
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("\(criticals)").foregroundStyle(.red)
            }
            .font(.caption)
        } else if warns > 0 {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(warns)").foregroundStyle(.orange)
            }
            .font(.caption)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    // MARK: - 操作

    private func runGroupByGroup(fix: Bool) async {
        guard !isRunning else { return }
        if fix { isFixing = true } else { isRunning = true }
        loadError = nil
        groupResults = [:]
        completedGroups = []

        // 所有分组并行执行，每组完成后立即更新 UI
        let username = user.username
        let client = helperClient
        await withTaskGroup(of: (DiagnosticGroup, [DiagnosticItem]).self) { taskGroup in
            for group in groupOrder {
                taskGroup.addTask {
                    let items = await client.runDiagnosticGroup(
                        username: username, group: group, fix: fix)
                    return (group, items)
                }
            }
            for await (group, items) in taskGroup {
                if items.isEmpty && completedGroups.isEmpty && group == groupOrder.first {
                    loadError = L10n.k("auto.health_check_sheet.helper_clawdhome", fallback: "无法连接到 Helper 服务，请确认 ClawdHome 已正确安装")
                }
                groupResults[group] = items
                completedGroups.insert(group)
                // 有问题的组自动展开
                if items.contains(where: { $0.severity == "critical" || $0.severity == "warn" }) {
                    expandedGroups.insert(group)
                }
            }
        }

        isRunning = false
        isFixing = false

        if isComplete {
            let result = DiagnosticsResult(
                username: user.username,
                checkedAt: Date().timeIntervalSince1970,
                items: allItems)
            onCompleted?(result)
        }
    }
}

// MARK: - 单条诊断项视图

private struct DiagnosticItemRow: View {
    let item: DiagnosticItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    if let ms = item.latencyMs {
                        Text("\(ms) ms")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let fixed = item.fixed {
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
                if !item.detail.isEmpty && item.latencyMs == nil {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let err = item.fixError {
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
        if item.fixed == true {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if item.fixed == false {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            switch item.severity {
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
