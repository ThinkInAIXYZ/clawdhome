// ClawdHome/Services/GatewaySkillsStore.swift
// per-shrimp Skills 状态管理
// 参考 openclaw/apps/macos/Sources/OpenClaw/SkillsSettings.swift

import Foundation
import Observation

@MainActor @Observable
final class GatewaySkillsStore {

    private(set) var skills: [GatewaySkillStatus] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// skillKey → 正在执行的操作描述（"安装中" / "卸载中" / "更新中"）
    private(set) var pendingOps: [String: String] = [:]

    private var client: GatewayClient?

    // MARK: - 生命周期

    func start(client: GatewayClient) async {
        self.client = client
        await refresh()
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
        client = nil
        skills = []
        error = nil
        pendingOps = [:]
    }

    // MARK: - 数据操作

    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await client.skillsStatus()
            skills = report.skills
            error = nil
        } catch {
            appLog("GatewaySkillsStore refresh error: \(error.localizedDescription)", level: .error)
            self.error = error.localizedDescription
        }
    }

    func install(skill: GatewaySkillStatus, optionId: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        pendingOps[skill.skillKey] = "安装中"
        defer { pendingOps.removeValue(forKey: skill.skillKey) }
        _ = try await client.skillsInstall(skillKey: skill.skillKey, optionId: optionId)
        await refresh()
    }

    func remove(skillKey: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        pendingOps[skillKey] = "卸载中"
        defer { pendingOps.removeValue(forKey: skillKey) }
        try await client.skillsRemove(skillKey: skillKey)
        await refresh()
    }

    func update(skillKey: String) async throws {
        guard let client else { throw GatewayClientError.notConnected }
        pendingOps[skillKey] = "更新中"
        defer { pendingOps.removeValue(forKey: skillKey) }
        _ = try await client.skillsUpdate(skillKey: skillKey)
        await refresh()
    }
}
