// ClawdHome/Services/GatewayChannelStore.swift
// per-shrimp 频道绑定状态管理

import Foundation
import Observation

@MainActor @Observable
final class GatewayChannelStore {

    /// 频道 ID 列表（有序）
    private(set) var channelOrder: [String] = []
    /// 频道显示名
    private(set) var channelLabels: [String: String] = [:]
    /// 每个频道的账号快照
    private(set) var channelAccounts: [String: [ChannelAccountSnapshot]] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    private var client: GatewayClient?
    private var pollTask: Task<Void, Never>?
    private var shrimpName: String = ""

    // MARK: - 查询接口

    /// 频道是否已配置（任一 account 的 configured/linked 为 true）
    func isBound(_ channelId: String) -> Bool {
        channelAccounts[channelId]?.contains(where: { $0.isBound }) ?? false
    }

    /// 频道的已绑定 account 列表
    func boundAccounts(_ channelId: String) -> [ChannelAccountSnapshot] {
        channelAccounts[channelId]?.filter(\.isBound) ?? []
    }

    /// 频道显示名（优先使用 Gateway 返回的 label）
    func label(for channelId: String) -> String {
        channelLabels[channelId] ?? channelId
    }

    // MARK: - 生命周期

    func start(client: GatewayClient, shrimpName: String) async {
        self.client = client
        self.shrimpName = shrimpName
        await refresh()
        startPolling()
    }

    func startIfNeeded(client: GatewayClient, shrimpName: String) async {
        self.shrimpName = shrimpName
        if self.client != nil {
            self.client = client
            if pollTask == nil { startPolling() }
            await refresh()
            return
        }
        await start(client: client, shrimpName: shrimpName)
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        client = nil
        channelOrder = []
        channelLabels = [:]
        channelAccounts = [:]
        error = nil
    }

    // MARK: - 数据刷新

    func refresh() async {
        guard let client else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.channelsStatus()
            channelOrder = result.channelOrder
            channelLabels = result.channelLabels
            channelAccounts = result.channelAccounts
            error = nil
        } catch {
            appLog("GatewayChannelStore refresh error [@\(shrimpName)]: \(error.localizedDescription)", level: .error)
            self.error = error.localizedDescription
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
