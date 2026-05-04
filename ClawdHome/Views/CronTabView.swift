// ClawdHome/Views/CronTabView.swift

import SwiftUI

// MARK: - Cron Tab

struct CronTabView: View {
    let username: String
    var agentId: String? = nil
    @Environment(GatewayHub.self) private var hub

    private var isConnected: Bool {
        hub.connectedUsernames.contains(username)
    }

    var body: some View {
        CronTabContent(store: hub.cronStore(for: username))
            .task(id: isConnected) {
                guard isConnected else { return }
                await hub.ensureCronStarted(for: username)
            }
    }
}

struct CronTabContent: View {
    let store: GatewayCronStore

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Text(L10n.k("user.detail.auto.scheduled_tasks", fallback: "定时任务"))
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(.bar)

            Divider()

            if let err = store.error {
                ContentUnavailableView(err, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.jobs.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    L10n.k("user.detail.cron.no_jobs", fallback: "暂无定时任务"),
                    systemImage: "clock",
                    description: Text(L10n.k("user.detail.cron.no_jobs_hint", fallback: "等待 Gateway 连接后自动加载"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // 左栏：任务列表
                    List(store.jobs, selection: Binding(
                        get: { store.selectedJobId },
                        set: { store.selectedJobId = $0 }
                    )) { job in
                        CronJobListRow(job: job)
                            .tag(job.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)

                    // 右栏：详情
                    if let jobId = store.selectedJobId,
                       let job = store.jobs.first(where: { $0.id == jobId }) {
                        CronJobDetailPane(job: job, store: store)
                    } else {
                        ContentUnavailableView(
                            L10n.k("user.detail.cron.select_job", fallback: "选择一个任务"),
                            systemImage: "clock"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .task { await store.refresh() }
    }
}

struct CronJobListRow: View {
    let job: GatewayCronJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(job.enabled ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(job.name)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if let next = job.state.nextRunAtMs {
                    Text(relativeTime(ms: next))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                CronTagBadge(job.sessionTarget)
                CronTagBadge(job.wakeMode)
            }
        }
        .padding(.vertical, 2)
    }

    private func relativeTime(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let diff = date.timeIntervalSinceNow
        if diff < 0 { return L10n.k("user.detail.cron.expired", fallback: "已过期") }
        if diff < 60 { return "< 1m" }
        let mins = Int(diff / 60)
        if mins < 60 { return "in \(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "in \(hrs)h" }
        return "in \(hrs / 24)d"
    }
}

struct CronTagBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}

struct CronJobDetailPane: View {
    let job: GatewayCronJob
    let store: GatewayCronStore
    @State private var isRunning = false
    @State private var showRemoveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 头部
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.name).font(.title3).fontWeight(.semibold)
                        Text(job.id).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { job.enabled },
                        set: { _ in Task { try? await store.toggleEnabled(job: job) } }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                    Button(L10n.k("user.detail.cron.run", fallback: "Run")) {
                        isRunning = true
                        Task {
                            defer { isRunning = false }
                            try? await store.run(jobId: job.id)
                        }
                    }
                    .disabled(isRunning)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(16)

                Divider()

                // 详情字段
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    CronDetailGridRow(label: "Schedule", value: scheduleText)
                    CronDetailGridRow(label: "Auto-delete", value: job.deleteAfterRun == true ? "after success" : "—")
                    CronDetailGridRow(label: "Session", value: job.sessionTarget)
                    CronDetailGridRow(label: "Wake", value: job.wakeMode)
                    CronDetailGridRow(label: "Next run", value: timeText(ms: job.state.nextRunAtMs))
                    CronDetailGridRow(label: "Last run", value: timeText(ms: job.state.lastRunAtMs))
                    if let status = job.state.lastStatus {
                        CronDetailGridRow(label: "Last status", value: status)
                    }
                }
                .padding(16)

                Divider()

                // Payload
                VStack(alignment: .leading, spacing: 8) {
                    Text("Payload")
                        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                        .padding(.horizontal, 16).padding(.top, 16)
                    Text(payloadText)
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }

                Divider()

                // Run history
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Run history")
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        Button {
                            Task { await store.refreshRuns(jobId: job.id) }
                        } label: {
                            Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    }

                    if store.runEntries.isEmpty {
                        Text("No run log entries yet.")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(store.runEntries) { entry in
                                CronRunEntryRow(entry: entry)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .task(id: job.id) {
            await store.refreshRuns(jobId: job.id)
        }
    }

    private var scheduleText: String {
        switch job.schedule {
        case let .at(at): return "at \(at)"
        case let .every(ms, _):
            let secs = ms / 1000
            if secs < 60 { return "every \(secs)s" }
            if secs < 3600 { return "every \(secs / 60)m" }
            return "every \(secs / 3600)h"
        case let .cron(expr, tz):
            return tz.map { "cron: \(expr) (\($0))" } ?? "cron: \(expr)"
        }
    }

    private var payloadText: String {
        switch job.payload {
        case let .systemEvent(text): return text
        case let .agentTurn(message, _, _, _, _, _, _): return message
        }
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private func timeText(ms: Int?) -> String {
        guard let ms else { return "—" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

struct CronDetailGridRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

struct CronRunEntryRow: View {
    let entry: GatewayCronRunLogEntry
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.status == "ok" ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(entry.action).font(.caption)
            if let dur = entry.durationMs {
                Text("\(dur)ms").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Date(timeIntervalSince1970: TimeInterval(entry.ts) / 1000), style: .time)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
