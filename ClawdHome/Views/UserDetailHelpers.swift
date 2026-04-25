// ClawdHome/Views/UserDetailHelpers.swift

import AppKit
import SwiftUI

// MARK: - 窗口层级管理

struct UserDetailWindowLevelBinder: NSViewRepresentable {
    let elevated: Bool

    final class Coordinator {
        var lastElevated: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window, context: context)
        }
    }

    private func apply(window: NSWindow?, context: Context) {
        guard let window else { return }
        let targetLevel: NSWindow.Level = elevated ? .floating : .normal
        if window.level != targetLevel {
            window.level = targetLevel
        }
        let changed = context.coordinator.lastElevated != elevated
        context.coordinator.lastElevated = elevated
        guard elevated, changed else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

struct UserDetailWindowWidthBinder: NSViewRepresentable {
    let shouldApplyHermesPreset: Bool

    final class Coordinator {
        var lastAppliedPreset: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window, context: context)
        }
    }

    private func apply(window: NSWindow?, context: Context) {
        guard let window else { return }
        let minimumSize = NSSize(
            width: UserDetailWindowLayout.detailWindowMinimumWidth,
            height: UserDetailWindowLayout.detailWindowMinimumHeight
        )
        if window.contentMinSize != minimumSize {
            window.contentMinSize = minimumSize
        }

        let changed = context.coordinator.lastAppliedPreset != shouldApplyHermesPreset
        context.coordinator.lastAppliedPreset = shouldApplyHermesPreset
        guard shouldApplyHermesPreset, changed else { return }

        let visibleFrame = window.screen?.visibleFrame ?? window.frame
        let targetWidth = min(
            max(UserDetailWindowLayout.hermesDetailWindowPreferredWidth, window.frame.width),
            visibleFrame.width
        )
        guard abs(window.frame.width - targetWidth) > 0.5 else { return }
        var frame = window.frame
        frame.size.width = targetWidth
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - targetWidth)
        window.setFrame(frame, display: true, animate: true)
    }
}

// MARK: - Alerts Modifier（拆分减轻类型检查压力）

struct MainContentAlertsModifier: ViewModifier {
    let user: ManagedUser
    @Binding var showRollbackConfirm: Bool
    @Binding var showLogoutConfirm: Bool
    @Binding var showResetConfirm: Bool
    let preUpgradeVersion: String?
    let performRollback: () async -> Void
    let performLogout: () async -> Void
    let performReset: () async -> Void

    func body(content: Content) -> some View {
        content
            .alert(L10n.f("user.detail.alert.rollback.title", fallback: "回退到 v%@?", preUpgradeVersion ?? ""), isPresented: $showRollbackConfirm) {
                Button(L10n.k("user.detail.auto.rollback", fallback: "回退"), role: .destructive) {
                    Task { await performRollback() }
                }
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
            } message: {
                Text(L10n.f("user.detail.alert.rollback.message", fallback: "将把 @%@ 的 openclaw 降级到 v%@\n\n此操作会短暂停止并重启 Gateway。", user.username, preUpgradeVersion ?? ""))
            }
            .alert(L10n.f("user.detail.alert.logout.title", fallback: "注销 @%@ 的登录会话？", user.username), isPresented: $showLogoutConfirm) {
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
                Button(L10n.k("user.detail.auto.log_out", fallback: "注销"), role: .destructive) {
                    Task { await performLogout() }
                }
            } message: {
                Text(L10n.k("user.detail.alert.logout.message", fallback: "将停止 Gateway 并退出该用户的登录会话（launchctl bootout）。\n\n用户数据不会被删除，可随时重新启动 Gateway。"))
            }
            .alert(L10n.f("user.detail.alert.reset.title", fallback: "重置 @%@ 的生存空间？", user.username), isPresented: $showResetConfirm) {
                Button(L10n.k("user.detail.auto.cancel", fallback: "取消"), role: .cancel) { }
                Button(L10n.k("user.detail.auto.reset", fallback: "重置"), role: .destructive) {
                    Task { await performReset() }
                }
            } message: {
                Text(L10n.f("user.detail.alert.reset.message", fallback: "这将删除：\n• ~/.npm-global（openclaw 及所有 npm 全局包）\n• ~/.openclaw（配置、API Key、会话历史）\n\n建议先备份 /Users/%@/.openclaw/，其中包含 API Key 和历史记录。\n\n重置后需要重新初始化生存空间。", user.username))
            }
    }
}

// MARK: - 概览卡片样式

struct OverviewCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.07), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
    }
}

// MARK: - 存储空间行

struct StorageRowContent: View {
    let snapshot: DashboardSnapshot?
    let username: String

    var body: some View {
        if let shrimp = snapshot?.shrimps.first(where: { $0.username == username }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(FormatUtils.formatBytes(shrimp.openclawDirBytes))
                        .monospacedDigit()
                    Text(".openclaw/").font(.caption2).foregroundStyle(.secondary)
                }
                if shrimp.homeDirBytes > 0 {
                    HStack(spacing: 4) {
                        Text(FormatUtils.formatBytes(shrimp.homeDirBytes))
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        Text(L10n.k("user.detail.auto.directory", fallback: "家目录")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 独立探活（不依赖 DashboardView）

/// 让 UserDetailView 自行对 gateway 发 HTTP 探活，
/// 确保独立窗口或非 Dashboard 页面也能刷新 readiness 状态
struct UserDetailWindowTitleBinder: NSViewRepresentable {
    let title: String
    let subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window)
        }
    }

    private func apply(window: NSWindow?) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
        if #available(macOS 11.0, *), window.subtitle != subtitle {
            window.subtitle = subtitle
        }
    }
}

struct GatewayProbeModifier: ViewModifier {
    let username: String
    let uid: Int
    let gatewayURL: String?
    let hub: GatewayHub
    @Environment(ShrimpPool.self) private var pool

    func body(content: Content) -> some View {
        content.task(id: "\(username)#\(gatewayURL ?? "")") {
            while !Task.isCancelled {
                // 优先使用 getGatewayURL() 的真实端口，避免快照端口滞后导致误判"启动中"
                let portFromURL = gatewayURL
                    .flatMap { GatewayHub.parse(gatewayURL: $0)?.port } ?? 0
                // 回退：快照端口 -> 18000+uid 公式端口
                let portFromSnapshot = pool.snapshot?.shrimps.first(where: { $0.username == username })
                    .map { $0.gatewayPort > 0 ? $0.gatewayPort : (GatewayHub.gatewayPort(for: uid) ?? 0) } ?? 0
                let port = portFromURL > 0
                    ? portFromURL
                    : (portFromSnapshot > 0 ? portFromSnapshot : (GatewayHub.gatewayPort(for: uid) ?? 0))
                guard port > 0 else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                await hub.probeSingle(username: username, port: port)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
