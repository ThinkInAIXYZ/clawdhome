// ClawdHome/Views/WizardV2/HermesQRBindingStep.swift
// PR-5 T5.1 / T5.2：扫码类 IM 绑定子视图（whatsapp / weixin / 飞书 QR）
//
// 使用方式：
//   - 在 HermesTeamWizard.Step4IMBindingView 中嵌入（替换 PR-4 的 qrPlaceholder）
//   - 在 HermesPendingBindingsSheet 中独立复用（T5.3 继续绑定）
//
// 设计决定（报告说明）：
//   T5.2 doctor 触发方式 = 用户主动点"我已扫完"后单次触发（非 3s 轮询）。
//   原因：hermes 扫码完成时没有可靠的进程退出信号可供监听；强制用户确认一次
//   更干净，且能避免反复 doctor 调用带来的 race condition。
//
//   5 分钟超时：通过 Task.sleep 实现 deferredTimer，若用户在此之前点确认/稍后完成则取消。

import SwiftUI

// MARK: - 子视图状态枚举

private enum QRStepPhase {
    case idle            // 初始：显示"打开扫码终端"按钮
    case terminalOpen    // 终端已弹出：显示三按钮
    case verifying       // Doctor 验收中
    case success         // 验收通过（短暂显示，随即 onCompleted）
    case failed(String)  // 验收失败，显示错误 + 重试/稍后完成
}

// MARK: - HermesQRBindingStep

struct HermesQRBindingStep: View {
    let username: String
    let profileID: String
    let platform: HermesIMPlatformInfo
    let onCompleted: () -> Void
    let onDeferred: () -> Void

    @Environment(HelperClient.self) private var helperClient
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow

    @State private var phase: QRStepPhase = .idle
    /// 5 分钟超时 Task —— 保留引用以便取消
    @State private var deferredTimer: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            platformHeader

            switch phase {
            case .idle:
                idleView
            case .terminalOpen:
                terminalOpenView
            case .verifying:
                verifyingView
            case .success:
                successView
            case .failed(let msg):
                failedView(message: msg)
            }
        }
        .onDisappear {
            deferredTimer?.cancel()
        }
    }

    // MARK: - 平台头部

    private var platformHeader: some View {
        HStack(spacing: 10) {
            platformIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.displayName)
                    .font(.headline)
                Text("需要在终端内完成扫码授权")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var platformIcon: some View {
        let icon: String = {
            switch platform.key {
            case "whatsapp": return "message.badge.filled.fill"
            case "weixin":   return "ellipsis.bubble.fill"
            default:         return "qrcode"
            }
        }()
        Image(systemName: icon)
            .font(.title2)
            .foregroundStyle(platformColor)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(platformColor.opacity(0.12))
            )
    }

    private var platformColor: Color {
        switch platform.key {
        case "whatsapp": return .green
        case "weixin":   return Color(red: 0.17, green: 0.69, blue: 0.34)
        default:         return .accentColor
        }
    }

    // MARK: - idle：初始界面

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("扫码流程说明", systemImage: "info.circle")
                        .font(.callout.weight(.medium))

                    Text(instructionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            openQRTerminal()
                        } label: {
                            Label("打开扫码终端", systemImage: "terminal")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("稍后完成") {
                            defer_()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: - terminalOpen：终端已弹出

    private var terminalOpenView: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("终端已打开，请在终端窗口完成扫码", systemImage: "terminal.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("完成后回到此页面点【我已扫完】进行验证。若 5 分钟内未确认，本步骤将自动标为【稍后完成】。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await verifyWithDoctor() }
                        } label: {
                            Label("我已扫完（验证）", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("稍后完成") {
                            defer_()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.orange)

                        Button("重新打开终端") {
                            openQRTerminal()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: - verifying：验收中

    private var verifyingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在通过 hermes doctor 验证连接…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - success：验收通过（短暂）

    private var successView: some View {
        Label("验证通过！", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
    }

    // MARK: - failed：验收失败

    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    openQRTerminal()
                    phase = .terminalOpen
                } label: {
                    Label("再扫一次", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("稍后完成") {
                    defer_()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - 逻辑

    private var instructionText: String {
        switch platform.key {
        case "whatsapp":
            return "点击下方按钮，终端将运行 hermes whatsapp 并显示二维码，用手机 WhatsApp 扫描即可完成配对。"
        case "weixin":
            return "点击下方按钮，终端将进入 hermes gateway setup 交互界面，选择【微信】平台后扫描二维码完成 iLink 登录。"
        default:
            return "点击下方按钮，在终端内完成扫码后回到此页面确认。"
        }
    }

    /// 弹出 MaintenanceTerminal 并运行对应命令
    private func openQRTerminal() {
        let command = terminalCommand(for: platform.key)
        let payload = maintenanceWindowRegistry.makePayload(
            username: username,
            title: "扫码绑定 \(platform.displayName) · @\(username)",
            command: command,
            engine: .hermes
        )
        openWindow(id: "maintenance-terminal", value: payload)

        // 切换到"终端已打开"状态
        phase = .terminalOpen

        // 启动 5 分钟超时 deferredTimer
        deferredTimer?.cancel()
        deferredTimer = Task {
            // 5 分钟 = 300 秒
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 如果用户还没手动确认/稍后完成，自动转 deferred
                if case .terminalOpen = phase {
                    defer_()
                }
            }
        }
    }

    /// 组装终端命令
    private func terminalCommand(for platformKey: String) -> [String] {
        // whatsapp: hermes -p <profileID> whatsapp
        // weixin:   hermes -p <profileID> gateway setup
        //   （hermes_cli/main.py 没有独立的 weixin-pair 子命令；gateway setup 是进入 TUI 让用户选平台）
        switch platformKey {
        case "whatsapp":
            return ["hermes", "-p", profileID, "whatsapp"]
        case "weixin":
            return ["hermes", "-p", profileID, "gateway", "setup"]
        default:
            return ["hermes", "-p", profileID, "gateway", "setup"]
        }
    }

    /// 用户点"我已扫完" → 单次触发 doctor 验收
    private func verifyWithDoctor() async {
        deferredTimer?.cancel()
        phase = .verifying

        let jsonStr = await helperClient.runHermesDoctor(username: username, profileID: profileID)

        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            phase = .failed("Doctor 返回结果无法解析：\(jsonStr.prefix(200))")
            return
        }

        let platforms = obj["platforms"] as? [String: String] ?? [:]
        let status = platforms[platform.key]

        switch status {
        case "ready":
            phase = .success
            try? await Task.sleep(for: .milliseconds(600))
            onCompleted()
        case "missing_token":
            phase = .failed("hermes doctor 报告：\(platform.displayName) 缺少 token（missing_token）。请重新扫码。")
        case let s? where !s.isEmpty:
            phase = .failed("hermes doctor 报告：\(platform.displayName) 连接异常（\(s)）。请重新扫码或稍后完成。")
        default:
            // platforms dict 中无此 key，视为 unknown_error（T5.2 约定）
            let rawSnippet = (obj["raw"] as? String)?.prefix(300) ?? ""
            phase = .failed("hermes doctor 未能确认 \(platform.displayName) 状态（unknown_error）。\(rawSnippet.isEmpty ? "" : "\n\n原始输出：\(rawSnippet)")")
        }
    }

    /// 标记为 deferred 并回调
    private func defer_() {
        deferredTimer?.cancel()
        onDeferred()
    }
}
