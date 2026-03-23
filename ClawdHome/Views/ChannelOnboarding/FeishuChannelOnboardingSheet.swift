import SwiftUI
import AppKit

enum ChannelOnboardingFlow: String, Identifiable, CaseIterable {
    case feishu
    case weixin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feishu: return "飞书"
        case .weixin: return "微信"
        }
    }

    var commandArgs: [String] {
        switch self {
        case .feishu:
            return ["-y", "@larksuite/openclaw-lark-tools", "install"]
        case .weixin:
            return ["-y", "@tencent-weixin/openclaw-weixin-cli@latest", "install"]
        }
    }
}

struct FeishuChannelOnboardingSheet: View {
    let flow: ChannelOnboardingFlow
    let username: String

    @Environment(\.dismiss) private var dismiss

    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var showTerminal = false
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()
    @State private var outputBuffer = ""

    private let commandExecutable = "npx"
    private let waitingThreshold: TimeInterval = 8
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var commandArgs: [String] { flow.commandArgs }
    private var logPrefix: String { flow.rawValue }

    private var commandSummary: String {
        ([commandExecutable] + commandArgs).joined(separator: " ")
    }

    private var isRunning: Bool {
        showTerminal && exitCode == nil
    }

    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }

    private var stageTitle: String {
        if !showTerminal { return "待开始" }
        if isRunning { return isWaitingInput ? "运行中（等待输入）" : "运行中" }
        if exitCode == 0 { return "已完成" }
        return "已退出"
    }

    private enum PairingButtonState {
        case idle
        case running
        case succeeded
        case failed
    }

    private var pairingButtonState: PairingButtonState {
        if isRunning { return .running }
        guard showTerminal else { return .idle }
        if exitCode == 0 { return .succeeded }
        return .failed
    }

    private var pairingButtonTitle: String {
        switch pairingButtonState {
        case .idle: return "生成配对二维码"
        case .running: return "生成中…"
        case .succeeded: return "重新生成二维码"
        case .failed: return "重试生成二维码"
        }
    }

    private var pairingButtonIcon: String {
        switch pairingButtonState {
        case .idle: return "qrcode.viewfinder"
        case .running: return "hourglass"
        case .succeeded: return "arrow.clockwise.circle"
        case .failed: return "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var pairingStatusLabelText: String {
        switch pairingButtonState {
        case .idle: return "未开始"
        case .running: return isWaitingInput ? "等待扫码/输入" : "命令执行中"
        case .succeeded: return "已完成，可再次生成"
        case .failed: return "生成失败，可重试"
        }
    }

    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        let min = elapsed / 60
        let sec = elapsed % 60
        return String(format: "%02d:%02d", min, sec)
    }

    private var windowTitle: String {
        "ClawdHome 正在生产 \(username) 虾 · \(flow.title)通道配置 · \(stageTitle)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请点击按钮生成二维码，扫码配对后给龙虾发消息测试，正常即可关闭窗口。")
                .font(.callout)
                .foregroundStyle(.secondary)
            actionRow
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
            }
            if showTerminal {
                runtimeToolbar
                HelperMaintenanceTerminalPanel(
                    username: username,
                    command: [commandExecutable] + commandArgs,
                    minHeight: 280,
                    onOutput: handleTerminalOutput,
                    control: terminalControl
                ) { code in
                    handleCommandExit(code)
                }
                .id(terminalRunID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .onDisappear {
            terminalControl.terminate()
            appLog("[\(logPrefix)] ui onboarding window disappeared; terminate active terminal session @\(username)")
        }
        .background(ChannelOnboardingWindowTitleBinder(title: windowTitle))
        .frame(minWidth: 900, minHeight: 460)
    }


    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                startInteractiveRun()
            }
            label: {
                Label(pairingButtonTitle, systemImage: pairingButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingButtonState == .running)

            if pairingButtonState == .running {
                Button("中断生成") {
                    terminalControl.sendInterrupt()
                    appLog("[\(logPrefix)] ui interactive interrupt from action row @\(username)")
                }
            }

            Text("状态：\(pairingStatusLabelText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    @ViewBuilder
    private var runtimeToolbar: some View {
        HStack(spacing: 10) {
            Label(
                isRunning
                ? (isWaitingInput ? "运行中（等待输入）" : "运行中")
                : "已退出",
                systemImage: isRunning ? (isWaitingInput ? "hourglass" : "play.circle.fill") : "stop.circle"
            )
            .font(.caption)
            .foregroundStyle(isRunning ? .secondary : .secondary)

            Text("耗时 \(elapsedText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("中断") {
                terminalControl.sendInterrupt()
                appLog("[\(logPrefix)] ui interactive interrupt @\(username)")
            }
            .disabled(!isRunning)

            Button("重跑") {
                startInteractiveRun()
            }

            Button("复制输出") {
                copyTerminalOutput()
            }
            .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func startInteractiveRun() {
        appLog("[\(logPrefix)] ui interactive run start @\(username) cmd=\(commandSummary)")
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        showTerminal = true
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        outputBuffer += chunk
        // 控制内存占用：仅保留最近 300KB 文本
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "暂无可复制的命令输出。"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = "命令输出已复制。"
        appLog("[\(logPrefix)] ui interactive output copied @\(username) bytes=\(text.utf8.count)")
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        if normalized == 0 {
            statusText = "命令执行完成。若终端输出了二维码，请直接扫码完成配对。"
            appLog("[\(logPrefix)] ui interactive run success @\(username)")
        } else {
            statusText = "命令已退出（exit \(normalized)）。请查看上方终端输出并重试。"
            appLog("[\(logPrefix)] ui interactive run failed @\(username) exit=\(normalized)", level: .error)
        }
    }
}

private struct ChannelOnboardingWindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
