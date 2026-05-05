// ClawdHome/Views/Terminal/ShrimpTerminalSession.swift
// 通用 PTY 终端会话 + NSView 包装 + 面板 UI（引擎无关，可供 Hermes / OpenClaw 复用）

import AppKit
import SwiftTerm
import SwiftUI

// MARK: - ShrimpTerminalPanel

struct ShrimpTerminalPanel: View {
    @ObservedObject var session: ShrimpTerminalSession
    let theme: MaintenanceTerminalTheme
    let minHeight: CGFloat
    let tabTitle: String
    let isActive: Bool
    /// 终端字号，由父级 console 的"设置"菜单控制
    var fontSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(theme.headerSecondary)
                Text(tabTitle)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.headerSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(L10n.k("hermes.chat.helper_session", fallback: "Helper 会话"), systemImage: "bolt.horizontal.circle")
                    .font(.caption2)
                    .foregroundStyle(theme.headerSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ShrimpTerminalNSView(
                session: session,
                theme: theme,
                fontSize: fontSize,
                isActive: isActive
            )
            .padding(8)
            .frame(minHeight: minHeight)
        }
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor))
    }
}

// MARK: - ShrimpTerminalNSView

struct ShrimpTerminalNSView: NSViewRepresentable {
    @ObservedObject var session: ShrimpTerminalSession
    let theme: MaintenanceTerminalTheme
    let fontSize: CGFloat
    let isActive: Bool

    func makeCoordinator() -> ShrimpTerminalSession {
        session
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.allowMouseReporting = false
        tv.nativeForegroundColor = theme.terminalForeground
        tv.nativeBackgroundColor = theme.terminalBackground
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        context.coordinator.attachTerminalView(tv)
        if isActive {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.terminalDelegate = context.coordinator
        if !nsView.nativeForegroundColor.isEqual(theme.terminalForeground) {
            nsView.nativeForegroundColor = theme.terminalForeground
        }
        if !nsView.nativeBackgroundColor.isEqual(theme.terminalBackground) {
            nsView.nativeBackgroundColor = theme.terminalBackground
        }
        if abs(nsView.font.pointSize - fontSize) > 0.01 {
            nsView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if isActive, nsView.window?.firstResponder !== nsView {
            nsView.window?.makeFirstResponder(nsView)
        }
        context.coordinator.attachTerminalView(nsView)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: ShrimpTerminalSession) {
        coordinator.detachTerminalView(nsView)
    }
}

// MARK: - ShrimpTerminalSession

@MainActor
final class ShrimpTerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    private let helperClient: HelperClient
    private let username: String
    private let command: [String]

    private weak var terminalView: TerminalView?
    private var sessionID: String?
    private var offset: Int64 = 0
    private var isStarting = false
    private var isClosed = false
    private var didExit = false

    private var outputBuffer = ""
    private let maxBufferLength = 180_000
    private var consecutivePollErrors = 0
    private let maxConsecutivePollErrors = 3

    private var startTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var openedOAuthURLs: Set<String> = []

    private var lastResizeSent: (cols: Int, rows: Int)?
    private var pendingResize: (cols: Int, rows: Int)?
    private var isReplaying = false

    init(helperClient: HelperClient, username: String, command: [String]) {
        self.helperClient = helperClient
        self.username = username
        self.command = command
        super.init()
    }

    deinit {
        startTask?.cancel()
        pollTask?.cancel()
        if let sessionID {
            let client = helperClient
            Task {
                _ = await client.terminateMaintenanceTerminalSession(sessionID: sessionID)
            }
        }
    }

    func attachTerminalView(_ view: TerminalView) {
        let isNewView = terminalView !== view
        terminalView = view
        if isNewView {
            // 清空尺寸缓存，确保新 view layout 后触发 sizeChanged → SIGWINCH → hermes 重绘
            lastResizeSent = nil
            // replay 期间屏蔽 send()：防止历史 buffer 中的 CPR 查询触发响应，
            // 这些响应会污染仍在运行的 hermes 进程，导致渲染错乱。
            isReplaying = true
            replayOutputIfNeeded()
            isReplaying = false
        }
        startIfNeeded()
        if let pendingResize {
            self.pendingResize = nil
            sendResize(cols: pendingResize.cols, rows: pendingResize.rows)
        }
    }

    func detachTerminalView(_ view: TerminalView) {
        guard terminalView === view else { return }
        terminalView = nil
    }

    // MARK: - 公开 API（供 ShrimpTerminalConsole 顶栏菜单调用）

    /// 当前 session 是否还在运行（已启动且未退出未关闭）
    var isRunning: Bool {
        sessionID != nil && !didExit && !isClosed
    }

    /// 提供给"复制输出"的只读快照
    var bufferedOutput: String {
        outputBuffer
    }

    /// 直接向 PTY 发送字符串（不追加换行）
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        sendInput(Data(text.utf8))
    }

    /// 发送一行命令（自动追加 `\n`，行内无换行也不裁剪）
    func sendLine(_ line: String) {
        sendText(line + "\n")
    }

    /// 发送中断信号（Ctrl-C，0x03）
    func sendInterrupt() {
        sendInput(Data([0x03]))
    }

    /// 清屏：本地 SwiftTerm view 回滚区清空 + 当前屏清空 + 光标归位 + 内部输出 buffer 重置。
    /// PTY 端 shell 历史不动，仅影响可见输出与"复制输出"的快照。
    func clearScreen() {
        outputBuffer = ""
        // ESC[3J 清空 scrollback；ESC[2J 清空可视区域；ESC[H 光标归位
        let clearSeq = "\u{1b}[3J\u{1b}[2J\u{1b}[H"
        feedToTerminal(clearSeq)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        startTask?.cancel()
        pollTask?.cancel()

        let sid = sessionID
        sessionID = nil
        guard let sid else { return }
        let client = helperClient
        Task {
            _ = await client.terminateMaintenanceTerminalSession(sessionID: sid)
        }
    }

    private func startIfNeeded() {
        guard !isClosed, !didExit, !isStarting, sessionID == nil else { return }
        isStarting = true
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startSession()
        }
    }

    private func startSession() async {
        let startResult = await helperClient.startMaintenanceTerminalSession(
            username: username,
            command: command
        )

        let finalResult: (Bool, String, String?)
        if !startResult.0,
           startResult.2 == L10n.k("services.helper_client.disconnected", fallback: "未连接") {
            helperClient.connect()
            try? await Task.sleep(nanoseconds: 400_000_000)
            finalResult = await helperClient.startMaintenanceTerminalSession(
                username: username,
                command: command
            )
        } else {
            finalResult = startResult
        }

        await MainActor.run {
            self.isStarting = false
            if finalResult.0 {
                self.sessionID = finalResult.1
                self.offset = 0
                self.beginPolling(sessionID: finalResult.1)
                if let pendingResize = self.pendingResize {
                    self.pendingResize = nil
                    self.sendResize(cols: pendingResize.cols, rows: pendingResize.rows)
                }
            } else {
                let message = L10n.f(
                    "views.terminal_log_view.command_start_failed",
                    fallback: "命令启动失败：%@\r\n",
                    finalResult.2 ?? "unknown error"
                )
                self.appendOutput(message)
                self.feedToTerminal(message)
                self.didExit = true
            }
        }
    }

    private func beginPolling(sessionID: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = await helperClient.pollMaintenanceTerminalSession(
                    sessionID: sessionID,
                    fromOffset: self.offset
                )
                let shouldStop = await MainActor.run {
                    self.handlePollResult(snapshot, expectedSessionID: sessionID)
                }
                if shouldStop {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    @discardableResult
    private func handlePollResult(
        _ snapshot: (Bool, Data, Int64, Bool, Int32, String?),
        expectedSessionID: String
    ) -> Bool {
        guard sessionID == expectedSessionID else { return true }
        let (ok, chunk, nextOffset, exited, exitCode, err) = snapshot

        if !ok {
            consecutivePollErrors += 1
            if consecutivePollErrors >= maxConsecutivePollErrors {
                let text = "会话错误（连续 \(consecutivePollErrors) 次失败）：\(err ?? "unknown")\r\n"
                appendOutput(text)
                feedToTerminal(text)
                didExit = true
                sessionID = nil
                return true
            }
            // 瞬时错误，跳过本轮继续轮询
            return false
        }

        consecutivePollErrors = 0
        offset = nextOffset
        if !chunk.isEmpty {
            let text = String(decoding: chunk, as: UTF8.self)
            appendOutput(text)
            feedToTerminal(text)
            autoOpenOAuthIfNeeded(text)
        }

        if exited {
            let exitLine = "\r\n[会话已结束，exit \(exitCode)]\r\n"
            appendOutput(exitLine)
            feedToTerminal(exitLine)
            didExit = true
            sessionID = nil
            return true
        }
        return false
    }

    private func sendInput(_ data: Data) {
        guard let sessionID else { return }
        Task {
            let (ok, err) = await helperClient.sendMaintenanceTerminalSessionInput(
                sessionID: sessionID,
                input: data
            )
            if !ok {
                let msg = "\r\n输入失败：\(err ?? "unknown")\r\n"
                await MainActor.run {
                    self.appendOutput(msg)
                    self.feedToTerminal(msg)
                }
            }
        }
    }

    private func sendResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard let sessionID else {
            pendingResize = (cols, rows)
            return
        }
        Task {
            _ = await helperClient.resizeMaintenanceTerminalSession(
                sessionID: sessionID,
                cols: cols,
                rows: rows
            )
        }
    }

    private func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        outputBuffer += text
        if outputBuffer.count > maxBufferLength {
            let overflow = outputBuffer.count - maxBufferLength
            outputBuffer.removeFirst(overflow)
        }
    }

    private func replayOutputIfNeeded() {
        guard let terminalView, !outputBuffer.isEmpty else { return }
        let bytes = ArraySlice(Array(outputBuffer.utf8))
        terminalView.feed(byteArray: bytes)
    }

    private func feedToTerminal(_ text: String) {
        guard let terminalView else { return }
        let bytes = ArraySlice(Array(text.utf8))
        terminalView.feed(byteArray: bytes)
    }

    private func autoOpenOAuthIfNeeded(_ chunk: String) {
        guard let url = firstHermesOAuthAuthorizeURL(in: chunk) else { return }
        let raw = url.absoluteString
        guard !raw.isEmpty, !openedOAuthURLs.contains(raw) else { return }
        openedOAuthURLs.insert(raw)
        openHermesExternalURL(url)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isReplaying else { return }
        sendInput(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        if let lastResizeSent,
           lastResizeSent.cols == newCols,
           lastResizeSent.rows == newRows {
            return
        }
        lastResizeSent = (newCols, newRows)
        sendResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        openHermesExternalURL(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard !content.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            board.setString(text, forType: .string)
        } else {
            board.setData(content, forType: .string)
        }
    }
}

// MARK: - OAuth helpers（Hermes 专用，URL 匹配规则绑定 hermes auth）

fileprivate func firstHermesOAuthAuthorizeURL(in text: String) -> URL? {
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<>.,"))
        guard candidate.hasPrefix("https://auth.openai.com/oauth/authorize") else { continue }
        if let url = URL(string: candidate) {
            return url
        }
    }
    return nil
}

fileprivate func openHermesExternalURL(_ url: URL) {
    DispatchQueue.main.async {
        _ = NSWorkspace.shared.open(url)
    }
}
