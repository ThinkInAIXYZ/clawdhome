// ClawdHome/Services/GatewayCronStore.swift
// per-shrimp 定时任务状态管理，订阅 Gateway 事件流
// 参考 openclaw/apps/macos/Sources/OpenClaw/CronJobsStore.swift

import Foundation
import Observation

@MainActor @Observable
final class GatewayCronStore {

    private(set) var jobs: [GatewayCronJob] = []
    private(set) var runEntries: [GatewayCronRunLogEntry] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var selectedJobId: String?

    private var client: GatewayClient?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: - 生命周期

    func start(client: GatewayClient) async {
        self.client = client
        await refresh()
        startEventSubscription(client: client)
        startPolling()
    }

    /// 幂等启动：仅在 client 尚未设置时执行完整启动；已有 client 时仅 refresh
    func startIfNeeded(client: GatewayClient) async {
        if self.client != nil {
            await refresh()
            return
        }
        await start(client: client)
    }

    func stop() {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
        client = nil
        jobs = []
        runEntries = []
        selectedJobId = nil
        error = nil
    }

    // MARK: - 数据操作

    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await client.cronList()
            error = nil
        } catch {
            appLog("GatewayCronStore refresh error: \(error.localizedDescription)", level: .error)
            self.error = error.localizedDescription
        }
    }

    func refreshRuns(jobId: String) async {
        guard let client else { return }
        do {
            runEntries = try await client.cronRuns(jobId: jobId)
        } catch {
            appLog("GatewayCronStore refreshRuns(\(jobId)) error: \(error.localizedDescription)", level: .error)
        }
    }

    func toggleEnabled(job: GatewayCronJob) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        try await client.cronUpdate(jobId: job.id, enabled: !job.enabled)
        await refresh()
    }

    func run(jobId: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        try await client.cronRun(jobId: jobId)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refresh()
    }

    func remove(jobId: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        try await client.cronRemove(jobId: jobId)
        if selectedJobId == jobId { selectedJobId = nil }
        await refresh()
    }

    func add(_ params: GatewayCronAddParams) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        let newJob = try await client.cronAdd(params)
        jobs.append(newJob)
        selectedJobId = newJob.id
    }

    // MARK: - 私有

    private func startEventSubscription(client: GatewayClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.eventStream {
                guard !Task.isCancelled else { break }
                guard event.name.hasPrefix("cron.") else { continue }
                await self?.refresh()
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
