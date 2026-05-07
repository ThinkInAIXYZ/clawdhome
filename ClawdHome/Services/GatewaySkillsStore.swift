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
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var shrimpName: String = ""

    func isBusy(skill: GatewaySkillStatus) -> Bool {
        pendingOps[skill.skillKey] != nil
    }

    // MARK: - 生命周期

    func start(client: GatewayClient, shrimpName: String) async {
        self.client = client
        self.shrimpName = shrimpName
        await refresh()
        startEventSubscription(client: client)
        startPolling()
    }

    /// 幂等启动：仅在 client 尚未设置时执行完整启动；已有 client 时仅 refresh
    func startIfNeeded(client: GatewayClient, shrimpName: String) async {
        self.shrimpName = shrimpName
        if self.client != nil {
            self.client = client
            if eventTask == nil { startEventSubscription(client: client) }
            if pollTask == nil { startPolling() }
            await refresh()
            return
        }
        await start(client: client, shrimpName: shrimpName)
    }

    func stop() {
        eventTask?.cancel(); eventTask = nil
        pollTask?.cancel(); pollTask = nil
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
            appLog("GatewaySkillsStore refresh error [@\(shrimpName)]: \(error.localizedDescription)", level: .error)
            self.error = error.localizedDescription
        }
    }

    func install(skill: GatewaySkillStatus, option: GatewaySkillInstallOption) async {
        await withBusy(skill.skillKey, label: L10n.k("service.skills_store.installing", fallback: "安装中")) {
            self.statusMessage = L10n.f("service.skills_store.installing_name", fallback: "正在安装 %@…", skill.name)
            do {
                guard let client = self.client else { throw GatewayClientError.notConnected }
                let result = try await client.skillsInstall(name: skill.name, installId: option.id, timeoutMs: 300_000)
                let installFailureMessage = result.ok ? nil : Self.formatInstallFailureMessage(result)
                let baseMessage = Self.trimmed(result.message)
                self.statusMessage = baseMessage?.isEmpty == false ? baseMessage : (result.ok ? L10n.k("service.skills_store.install_verifying", fallback: "安装命令已完成，正在验证结果…") : L10n.k("service.skills_store.install_abnormal_verifying", fallback: "安装命令返回异常，正在验证结果…"))

                let verification = await self.waitForInstallCompletion(
                    skillKey: skill.skillKey,
                    expectedBins: option.bins,
                    timeoutSeconds: 20
                )
                switch verification {
                case .ready:
                    if let installFailureMessage {
                        self.statusMessage = Self.formatRecoveredInstallMessage(result, fallback: installFailureMessage)
                    } else {
                        if let msg = baseMessage, !msg.isEmpty {
                            self.statusMessage = msg
                        } else {
                            self.statusMessage = L10n.k("service.skills_store.install_success", fallback: "安装成功")
                        }
                    }
                case .stillMissing(let bins):
                    if let installFailureMessage {
                        throw GatewaySkillsStoreError.installFailed(installFailureMessage)
                    }
                    let missing = bins.joined(separator: ", ")
                    if missing.isEmpty {
                        self.statusMessage = L10n.k("service.skills_store.install_done_refresh_later", fallback: "安装命令已结束，但状态未及时刷新，请稍后重试刷新。")
                    } else {
                        self.statusMessage = L10n.f("service.skills_store.install_done_missing_deps", fallback: "安装命令已结束，但仍缺少依赖: %@", missing)
                    }
                }
            } catch {
                self.statusMessage = error.localizedDescription
                await self.refresh()
            }
        }
    }

    func remove(skillKey: String) async {
        await withBusy(skillKey, label: L10n.k("service.skills_store.removing", fallback: "卸载中")) {
            do {
                try await self.client?.skillsRemove(skillKey: skillKey)
                self.statusMessage = L10n.k("service.skills_store.removed", fallback: "已卸载")
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func update(skillKey: String) async {
        await withBusy(skillKey, label: L10n.k("service.skills_store.updating", fallback: "更新中")) {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey)
                self.statusMessage = L10n.k("service.skills_store.updated", fallback: "已更新")
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func toggleEnabled(skillKey: String, enabled: Bool) async {
        await withBusy(skillKey, label: enabled ? L10n.k("service.skills_store.enabling", fallback: "启用中") : L10n.k("service.skills_store.disabling", fallback: "禁用中")) {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, enabled: enabled)
                self.statusMessage = enabled ? L10n.k("service.skills_store.enabled", fallback: "已启用") : L10n.k("service.skills_store.disabled", fallback: "已禁用")
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func setApiKey(skillKey: String, value: String) async {
        await withBusy(skillKey, label: L10n.k("service.skills_store.saving", fallback: "保存中")) {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, apiKey: value)
                self.statusMessage = L10n.k("service.skills_store.api_key_saved", fallback: "API Key 已保存")
            } catch {
                self.statusMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func setEnvVar(skillKey: String, envKey: String, value: String) async {
        await withBusy(skillKey, label: L10n.k("service.skills_store.saving", fallback: "保存中")) {
            do {
                _ = try await self.client?.skillsUpdate(skillKey: skillKey, env: [envKey: value])
                self.statusMessage = L10n.f("service.skills_store.env_saved", fallback: "%@ 已保存", envKey)
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

    private func startEventSubscription(client: GatewayClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.eventStream {
                guard !Task.isCancelled else { break }
                guard event.name.hasPrefix("skills.") else { continue }
                await self?.handleSkillsEvent(event)
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

    private func handleSkillsEvent(_ event: GatewayEvent) async {
        if !pendingOps.isEmpty, let msg = Self.messageFromSkillsEvent(event) {
            statusMessage = msg
        }
        await refresh()
    }

    private func waitForInstallCompletion(
        skillKey: String,
        expectedBins: [String],
        timeoutSeconds: Int
    ) async -> InstallVerificationResult {
        let waitSeconds = max(1, timeoutSeconds)
        let expected = Set(expectedBins)
        for second in 0..<waitSeconds {
            pendingOps[skillKey] = second == 0 ? L10n.k("service.skills_store.installing", fallback: "安装中") : L10n.f("service.skills_store.installing_elapsed", fallback: "安装中 %ds", second)
            await refresh()

            if let current = skills.first(where: { $0.skillKey == skillKey }) {
                let relevantMissing: [String]
                if expected.isEmpty {
                    relevantMissing = current.missing.bins
                } else {
                    relevantMissing = current.missing.bins.filter { expected.contains($0) }
                }
                if relevantMissing.isEmpty {
                    return .ready
                }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let fallbackMissing: [String]
        if let current = skills.first(where: { $0.skillKey == skillKey }) {
            if expected.isEmpty {
                fallbackMissing = current.missing.bins
            } else {
                fallbackMissing = current.missing.bins.filter { expected.contains($0) }
            }
        } else {
            fallbackMissing = expectedBins
        }
        return .stillMissing(fallbackMissing)
    }

    private static func formatInstallFailureMessage(_ result: GatewaySkillInstallResult) -> String {
        var segments: [String] = []
        if let message = trimmed(result.message), !message.isEmpty {
            segments.append(message)
        }
        if let stderrLine = lastNonEmptyLine(result.stderr), !stderrLine.isEmpty {
            segments.append(stderrLine)
        } else if let stdoutLine = lastNonEmptyLine(result.stdout), !stdoutLine.isEmpty {
            segments.append(stdoutLine)
        }
        if segments.isEmpty {
            return L10n.k("service.skills_store.install_failed_no_info", fallback: "安装失败，网关未返回可用错误信息。")
        }
        return L10n.f("service.skills_store.install_failed_detail", fallback: "安装失败：%@", segments.joined(separator: " | "))
    }

    private static func formatRecoveredInstallMessage(
        _ result: GatewaySkillInstallResult,
        fallback: String
    ) -> String {
        let suffix = lastNonEmptyLine(result.stderr)
            ?? lastNonEmptyLine(result.stdout)
            ?? trimmed(result.message)
            ?? fallback
        return L10n.f("service.skills_store.install_recovered", fallback: "安装已完成（安装器返回异常）：%@", suffix)
    }

    private static func messageFromSkillsEvent(_ event: GatewayEvent) -> String? {
        guard let payload = event.payload else { return nil }
        if let message = payload["message"] as? String, let normalized = trimmed(message), !normalized.isEmpty {
            return normalized
        }
        if let status = payload["status"] as? String, let normalized = trimmed(status), !normalized.isEmpty {
            return normalized
        }
        return nil
    }

    private static func lastNonEmptyLine(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last.flatMap(trimmed)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.count <= 240 { return text }
        let idx = text.index(text.startIndex, offsetBy: 240)
        return String(text[..<idx]) + "..."
    }
}

private enum InstallVerificationResult {
    case ready
    case stillMissing([String])
}

private enum GatewaySkillsStoreError: LocalizedError {
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .installFailed(let message):
            return message
        }
    }
}
