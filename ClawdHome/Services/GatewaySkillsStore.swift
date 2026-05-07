// ClawdHome/Services/GatewaySkillsStore.swift
// per-shrimp Skills 状态管理
// 参考 openclaw/apps/macos/Sources/OpenClaw/SkillsSettings.swift
// 参考 openclaw commit 505b980f63 (2026-04-07)

import Foundation
import Observation

@MainActor @Observable
final class GatewaySkillsStore {

    private(set) var skills: [GatewaySkillStatus] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var statusMessage: String?
    /// skillKey → 正在执行的操作描述（"安装中" / "卸载中" / "更新中"）
    private(set) var pendingOps: [String: String] = [:]

    /// 搜索关键词
    var searchText: String = ""

    private var client: GatewayClient?

    func isBusy(skill: GatewaySkillStatus) -> Bool {
        pendingOps[skill.skillKey] != nil
    }

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
        statusMessage = nil
        pendingOps = [:]
    }

    // MARK: - 数据操作

    func refresh() async {
        guard let client else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let report = try await client.skillsStatus()
            skills = report.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            appLog("GatewaySkillsStore refresh error: \(error.localizedDescription)", level: .error)
            self.error = error.localizedDescription
        }
    }

    func install(skill: GatewaySkillStatus, option: GatewaySkillInstallOption) async {
        await withBusy(skill.skillKey, label: "安装中") {
            do {
                let result = try await self.client?.skillsInstall(
                    name: skill.name, installId: option.id, timeoutMs: 300_000)
                self.statusMessage = result?.message
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func remove(skillKey: String) async {
        await withBusy(skillKey, label: "卸载中") {
            do {
                try await self.client?.skillsRemove(skillKey: skillKey)
                self.statusMessage = "已卸载"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func update(skillKey: String) async {
        await withBusy(skillKey, label: "更新中") {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey)
                self.statusMessage = "已更新"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func toggleEnabled(skillKey: String, enabled: Bool) async {
        await withBusy(skillKey, label: enabled ? "启用中" : "禁用中") {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, enabled: enabled)
                self.statusMessage = enabled ? "已启用" : "已禁用"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func setApiKey(skillKey: String, value: String) async {
        await withBusy(skillKey, label: "保存中") {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, apiKey: value)
                self.statusMessage = "API Key 已保存"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func setEnvVar(skillKey: String, envKey: String, value: String) async {
        await withBusy(skillKey, label: "保存中") {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, env: [envKey: value])
                self.statusMessage = "\(envKey) 已保存"
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    // MARK: - Private

    private func withBusy(_ skillKey: String, label: String, _ work: @escaping () async -> Void) async {
        pendingOps[skillKey] = label
        defer { pendingOps.removeValue(forKey: skillKey) }
        await work()
    }
}
