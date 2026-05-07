// ClawdHome/Views/TerminalLogView.swift
// 两种模式：
//   TerminalLogPanel       — 只读，轮询日志文件（auto 安装步骤用）
//   InteractiveTerminalPanel — 交互，LocalProcessTerminalView 跑 openclaw 向导

import SwiftUI
import SwiftTerm

private func firstOAuthAuthorizeURL(in text: String) -> URL? {
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<>.,"))
        guard candidate.hasPrefix("https://auth.openai.com/oauth/authorize") else { continue }
        if let url = URL(string: candidate) {
            return url
        }
    }
    return nil
}

private func openExternalURL(_ url: URL) {
    DispatchQueue.main.async {
        _ = NSWorkspace.shared.open(url)
    }
}

private func writeToPasteboard(_ content: Data) {
    guard !content.isEmpty else { return }
    DispatchQueue.main.async {
        let board = NSPasteboard.general
        board.clearContents()
        if let text = String(data: content, encoding: .utf8) {
            board.setString(text, forType: .string)
        } else {
            board.setData(content, forType: .string)
        }
    }
}

// MARK: - 对外接口（与原 InitLogPanel 接口兼容）

final class LocalTerminalControl: ObservableObject {
    fileprivate weak var terminalView: LocalProcessTerminalView?
    fileprivate var sendRawHandler: ((Data) -> Void)?
    fileprivate var terminateHandler: (() -> Void)?
    private var pendingRawInputs: [Data] = []

    private func flushPendingInputsIfNeeded() {
        guard let handler = sendRawHandler, !pendingRawInputs.isEmpty else { return }
        for data in pendingRawInputs {
            handler(data)
        }
        pendingRawInputs.removeAll(keepingCapacity: false)
    }

    private func enqueueOrSend(_ data: Data) {
        guard !data.isEmpty else { return }
        if let handler = sendRawHandler {
            handler(data)
        } else {
            pendingRawInputs.append(data)
        }
    }

    fileprivate func attach(_ view: LocalProcessTerminalView) {
        terminalView = view
        sendRawHandler = { [weak view] data in
            guard let view else { return }
            view.process.send(data: ArraySlice(data))
        }
        terminateHandler = { [weak view] in
            view?.terminate()
        }
        flushPendingInputsIfNeeded()
    }

    fileprivate func attachHandlers(sendRaw: ((Data) -> Void)?, terminate: (() -> Void)?) {
        terminalView = nil
        sendRawHandler = sendRaw
        terminateHandler = terminate
        flushPendingInputsIfNeeded()
    }

    func sendInterrupt() {
        enqueueOrSend(Data([0x03]))
    }

    func terminate() {
        terminateHandler?()
    }

    func sendText(_ text: String) {
        if let data = text.data(using: .utf8) {
            enqueueOrSend(data)
        }
    }

    func sendLine(_ text: String) {
        sendText(text)
        sendText("\r")
    }
}

final class OutputObservingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutputBytes: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutputBytes?(slice)
        super.dataReceived(slice: slice)
    }
}

struct TerminalLogPanel: View {
    let username: String

    @State private var autoScroll = true
    @State private var searchText = ""
    @State private var searchRequest = LogSearchRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.k("auto.terminal_log_view.logs", fallback: "日志输出"))
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                TextField(L10n.k("auto.terminal_log_view.searchlogs", fallback: "搜索日志"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.caption)
                    .onSubmit { issueSearch(.next) }
                Button {
                    issueSearch(.previous)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    issueSearch(.next)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Toggle(L10n.k("auto.terminal_log_view.auto_scroll", fallback: "自动滚动"), isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            LogTextNSView(
                username: username,
                autoScroll: $autoScroll,
                searchText: $searchText,
                searchRequest: $searchRequest
            )
                .frame(height: 180)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func issueSearch(_ direction: LogSearchDirection) {
        searchRequest = LogSearchRequest(token: searchRequest.token + 1, direction: direction)
    }
}

// MARK: - NSViewRepresentable

private enum LogSearchDirection {
    case next
    case previous
}

private struct LogSearchRequest: Equatable {
    var token: Int = 0
    var direction: LogSearchDirection = .next
}

private struct LogTextNSView: NSViewRepresentable {
    let username: String
    @Binding var autoScroll: Bool
    @Binding var searchText: String
    @Binding var searchRequest: LogSearchRequest

    func makeCoordinator() -> LogFeedCoordinator {
        LogFeedCoordinator(username: username)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = ""

        scrollView.documentView = textView
        context.coordinator.start(scrollView: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(autoScroll: autoScroll)
        context.coordinator.updateSearchText(searchText)
        context.coordinator.handleSearchRequest(searchRequest)
    }
}

// MARK: - 协调器：轮询日志文件，增量写入文本视图

final class LogFeedCoordinator: NSObject {
    let username: String
    var autoScroll = true

    private var fileOffset = 0
    private var timer: Timer?
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var lastSearchToken = 0
    private var normalizedSearchText = ""
    private let logAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.labelColor
    ]

    init(username: String) {
        self.username = username
    }

    deinit { timer?.invalidate() }

    func start(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        // 0.3s 轮询，进度条动画流畅
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollLog()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(autoScroll: Bool) {
        let wasEnabled = self.autoScroll
        self.autoScroll = autoScroll
        if autoScroll && !wasEnabled {
            scrollToEnd()
        }
    }

    func updateSearchText(_ searchText: String) {
        normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSearchText.isEmpty {
            textView?.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    fileprivate func handleSearchRequest(_ request: LogSearchRequest) {
        guard request.token != lastSearchToken else { return }
        lastSearchToken = request.token
        performSearch(direction: request.direction)
    }

    private func pollLog() {
        let path = "/tmp/clawdhome-init-\(username).log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber,
           size.intValue < fileOffset {
            fileOffset = 0
            textView?.string = ""
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(fileOffset))
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        fileOffset += data.count
        let chunk = String(decoding: data, as: UTF8.self)
        appendLog(chunk)
    }

    private func appendLog(_ chunk: String) {
        guard !chunk.isEmpty, let textView else { return }
        let previousOrigin = autoScroll ? nil : currentScrollOrigin()
        if let storage = textView.textStorage {
            storage.append(NSAttributedString(string: chunk, attributes: logAttributes))
        } else {
            textView.string += chunk
        }
        if autoScroll {
            scrollToEnd()
        } else if let previousOrigin {
            restoreScrollOrigin(previousOrigin)
        }
    }

    private func scrollToEnd() {
        guard let textView else { return }
        let end = NSRange(location: textView.string.utf16.count, length: 0)
        textView.scrollRangeToVisible(end)
    }

    private func currentScrollOrigin() -> NSPoint? {
        scrollView?.contentView.bounds.origin
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        guard let scrollView, let docView = scrollView.documentView else { return }
        let maxY = max(0, docView.frame.height - scrollView.contentSize.height)
        let target = NSPoint(x: max(0, origin.x), y: min(max(0, origin.y), maxY))
        docView.scroll(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let scrollView = self.scrollView,
                  let docView = scrollView.documentView else { return }
            let maxY = max(0, docView.frame.height - scrollView.contentSize.height)
            let stabilized = NSPoint(x: max(0, origin.x), y: min(max(0, origin.y), maxY))
            docView.scroll(stabilized)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func performSearch(direction: LogSearchDirection) {
        guard let textView else { return }
        let term = normalizedSearchText
        guard !term.isEmpty else { return }

        let text = textView.string as NSString
        let fullLength = text.length
        guard fullLength > 0 else { return }

        let current = textView.selectedRange()
        let options: NSString.CompareOptions = [.caseInsensitive]

        let result: NSRange
        switch direction {
        case .next:
            let start = min(fullLength, max(0, NSMaxRange(current)))
            let forwardRange = NSRange(location: start, length: fullLength - start)
            let forwardResult = text.range(of: term, options: options, range: forwardRange)
            if forwardResult.location != NSNotFound {
                result = forwardResult
            } else {
                let wrappedRange = NSRange(location: 0, length: start)
                result = text.range(of: term, options: options, range: wrappedRange)
            }
        case .previous:
            let anchor = max(0, min(fullLength - 1, current.location - 1))
            let backwardRange = NSRange(location: 0, length: anchor + 1)
            let backwardResult = text.range(of: term, options: options.union(.backwards), range: backwardRange)
            if backwardResult.location != NSNotFound {
                result = backwardResult
            } else {
                let wrappedStart = anchor + 1
                let wrappedLength = fullLength - wrappedStart
                let wrappedRange = NSRange(location: wrappedStart, length: max(0, wrappedLength))
                result = text.range(of: term, options: options.union(.backwards), range: wrappedRange)
            }
        }

        guard result.location != NSNotFound else { return }
        textView.setSelectedRange(result)
        textView.scrollRangeToVisible(result)
    }
}

// MARK: - 交互终端面板（运行 openclaw 向导）

struct InteractiveTerminalPanel: View {
    let username: String
    var onExit: ((Int32?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.k("auto.terminal_log_view.command_output", fallback: "命令输出"))
                    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                Spacer()
                Label(L10n.k("auto.terminal_log_view.interactive_mode", fallback: "交互模式"), systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            LocalProcessNSView(username: username, onExit: onExit)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

// MARK: - NSViewRepresentable for LocalProcessTerminalView

/// 通用交互终端：以指定用户身份运行 openclaw 子命令
/// subcommandArgs 为空时启动 openclaw 交互 TUI（原有行为）
struct LocalProcessNSView: NSViewRepresentable {
    let username: String
    /// openclaw 后追加的子命令参数，如 ["channels","add","--channel","telegram","--token","xxx"]
    var subcommandArgs: [String] = []
    /// 可选：覆盖执行命令（默认执行 openclaw）
    var executable: String? = nil
    var executableArgs: [String] = []
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)?

    func makeCoordinator() -> LocalProcessCoordinator {
        LocalProcessCoordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = OutputObservingLocalProcessTerminalView(frame: .zero)
        tv.processDelegate = context.coordinator
        // Keep text selection stable while output is streaming.
        tv.allowMouseReporting = false
        tv.nativeForegroundColor = NSColor.labelColor
        tv.nativeBackgroundColor = NSColor.textBackgroundColor
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.onOutputBytes = { bytes in
            let chunk = String(decoding: Array(bytes), as: UTF8.self)
            guard !chunk.isEmpty else { return }
            context.coordinator.handleOutputChunk(chunk)
            guard let onOutput else { return }
            DispatchQueue.main.async {
                onOutput(chunk)
            }
        }

        let npmGlobalBin = "/Users/\(username)/.npm-global/bin"
        let npmGlobalDir = "/Users/\(username)/.npm-global"
        let npmSharedCache = "/var/lib/clawdhome/cache/npm"
        let userBrewBin = "/Users/\(username)/.brew/bin"
        let pathEnv  = "\(npmGlobalBin):\(userBrewBin):/usr/bin:/bin"
        let openclawPath = "\(npmGlobalBin)/openclaw"
        let command = executable ?? openclawPath
        let commandArgs = executable != nil ? executableArgs : subcommandArgs
        let homePath = "/Users/\(username)"

        // 所有交互命令都强制以虾用户身份执行，避免落到当前 GUI 登录用户。
        let runtimeExecutable = "/usr/bin/sudo"
        let runtimeArgs = ["-n", "-u", username, "-H",
                           "/usr/bin/env",
                           "HOME=\(homePath)",
                           "PATH=\(pathEnv)",
                           "NPM_CONFIG_PREFIX=\(npmGlobalDir)",
                           "npm_config_prefix=\(npmGlobalDir)",
                           "NPM_CONFIG_CACHE=\(npmSharedCache)",
                           "npm_config_cache=\(npmSharedCache)",
                           "TERM=xterm-256color",
                           command] + commandArgs

        tv.startProcess(
            executable: runtimeExecutable,
            args: runtimeArgs,
            environment: nil
        )
        control?.attach(tv)
        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

// MARK: - 命令终端面板（执行单条 openclaw 子命令，显示输出）

/// 运行指定 openclaw 子命令并展示输出，支持交互式提示响应
/// 每次 id 变化会重新创建，实现L10n.k("views.terminal_log_view.text_d4eec25c", fallback: "重跑命令")效果
struct CommandTerminalPanel: View {
    let username: String
    let subcommandArgs: [String]
    var minHeight: CGFloat = 160
    var onExit: ((Int32?) -> Void)? = nil

    /// 展示的命令行摘要（用于标题栏）
    private var commandSummary: String {
        "openclaw " + subcommandArgs.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(commandSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            LocalProcessNSView(username: username, subcommandArgs: subcommandArgs, onExit: onExit)
                .frame(minHeight: minHeight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

/// 运行任意用户态命令并提供交互式终端（实时输出 + 可输入）
struct UserCommandTerminalPanel: View {
    let username: String
    let executable: String
    let args: [String]
    var minHeight: CGFloat = 220
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)? = nil

    private var commandSummary: String {
        ([executable] + args).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(commandSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(L10n.k("auto.terminal_log_view.interactive_mode", fallback: "交互模式"), systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            LocalProcessNSView(
                username: username,
                executable: executable,
                executableArgs: args,
                onOutput: onOutput,
                control: control,
                onExit: onExit
            )
            .frame(minHeight: minHeight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

/// Helper 侧 PTY 会话终端（XPC 轮询输出 + 输入转发）
struct HelperMaintenanceTerminalPanel: View {
    let username: String
    let command: [String]
    @Environment(HelperClient.self) private var helperClient
    var minHeight: CGFloat = 220
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text(command.joined(separator: " "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Label(L10n.k("auto.terminal_log_view.helper_session", fallback: "Helper 会话"), systemImage: "bolt.horizontal.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            HelperMaintenanceTerminalNSView(
                helperClient: helperClient,
                username: username,
                command: command,
                onOutput: onOutput,
                control: control,
                onExit: onExit
            )
            .padding(8)
            .frame(minHeight: minHeight)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }
}

private struct HelperMaintenanceTerminalNSView: NSViewRepresentable {
    let helperClient: HelperClient
    let username: String
    let command: [String]
    var onOutput: ((String) -> Void)? = nil
    var control: LocalTerminalControl? = nil
    var onExit: ((Int32?) -> Void)? = nil

    func makeCoordinator() -> HelperMaintenanceTerminalCoordinator {
        HelperMaintenanceTerminalCoordinator(
            helperClient: helperClient,
            username: username,
            command: command,
            onOutput: onOutput,
            control: control,
            onExit: onExit
        )
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        // Keep text selection stable while output is streaming.
        tv.allowMouseReporting = false
        tv.nativeForegroundColor = NSColor.labelColor
        tv.nativeBackgroundColor = NSColor.textBackgroundColor
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        context.coordinator.start(with: tv)
        // 窗口打开后自动聚焦到终端，用户可直接输入。
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

final class HelperMaintenanceTerminalCoordinator: NSObject, TerminalViewDelegate {
    private let helperClient: HelperClient
    private let username: String
    private let command: [String]
    private let onOutput: ((String) -> Void)?
    private let control: LocalTerminalControl?
    private let onExit: ((Int32?) -> Void)?
    private weak var terminalView: TerminalView?
    private var sessionID: String?
    private var offset: Int64 = 0
    private var timer: Timer?
    private var polling = false
    private var exitNotified = false
    private var isCleaningUp = false
    private var transientPollRetryCount = 0
    private let maxTransientPollRetries = 1
    private var lastResizeSent: (cols: Int, rows: Int)?
    private var pendingResize: (cols: Int, rows: Int)?
    private var openedOAuthURLs: Set<String> = []

    init(
        helperClient: HelperClient,
        username: String,
        command: [String],
        onOutput: ((String) -> Void)?,
        control: LocalTerminalControl?,
        onExit: ((Int32?) -> Void)?
    ) {
        self.helperClient = helperClient
        self.username = username
        self.command = command
        self.onOutput = onOutput
        self.control = control
        self.onExit = onExit
    }

    deinit {
        timer?.invalidate()
        cleanupSession()
    }

    func start(with terminalView: TerminalView) {
        self.terminalView = terminalView
        Task { [weak self] in
            await self?.startSession()
        }
    }

    private func startPollingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollIfNeeded()
        }
    }

    private func startSession() async {
        let startResult = await helperClient.startMaintenanceTerminalSession(
            username: username,
            command: command
        )
        // 首次打开窗口时可能恰逢 XPC 连接未就绪：自动重试一次，减少"点重跑才成功"。
        let finalResult: (Bool, String, String?)
        if !startResult.0, startResult.2 == L10n.k("services.helper_client.disconnected", fallback: "未连接") {
            helperClient.connect()
            try? await Task.sleep(nanoseconds: 400_000_000)
            finalResult = await helperClient.startMaintenanceTerminalSession(
                username: username,
                command: command
            )
        } else {
            finalResult = startResult
        }

        guard finalResult.0 else {
            let msg = L10n.f(
                "views.terminal_log_view.command_start_failed",
                fallback: "命令启动失败：%@\r\n",
                finalResult.2 ?? "unknown error"
            )
            await MainActor.run {
                self.feedToTerminal(msg)
                self.onOutput?(msg)
            }
            notifyExitOnce(code: -1)
            return
        }
        await MainActor.run {
            self.sessionID = finalResult.1
            self.offset = 0
            self.isCleaningUp = false
            let initialResize = self.pendingResize ?? self.lastResizeSent
            if let initialResize {
                self.pendingResize = nil
                self.sendResize(cols: initialResize.cols, rows: initialResize.rows)
            }
            self.control?.attachHandlers(sendRaw: { [weak self] data in
                self?.sendInput(data)
            }, terminate: { [weak self] in
                self?.cleanupSession()
            })
            self.startPollingTimer()
        }
    }

    private func pollIfNeeded() {
        guard !polling, let sessionID else { return }
        polling = true
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await helperClient.pollMaintenanceTerminalSession(
                sessionID: sessionID,
                fromOffset: self.offset
            )
            await MainActor.run {
                self.handlePollResult(snapshot)
            }
        }
    }

    private func handlePollResult(_ snapshot: (Bool, Data, Int64, Bool, Int32, String?)) {
        polling = false
        let (ok, chunk, nextOffset, exited, exitCode, err) = snapshot
        if !ok {
            let message = err ?? ""
            if shouldRetryPoll(message: message), transientPollRetryCount < maxTransientPollRetries {
                transientPollRetryCount += 1
                helperClient.connect(reason: "maintenance poll retry")
                feedToTerminal(L10n.k("views.terminal_log.session_interrupted", fallback: "会话连接中断，正在自动重试...") + "\r\n")
                return
            }
            if let err, !err.isEmpty {
                feedToTerminal(L10n.f("views.terminal_log_view.r_n", fallback: "会话错误：%@\r\n", String(describing: err)))
            }
            notifyExitOnce(code: -1)
            timer?.invalidate()
            return
        }
        transientPollRetryCount = 0
        offset = nextOffset
        if !chunk.isEmpty {
            feedToTerminal(chunk)
            let outputText = String(decoding: chunk, as: UTF8.self)
            onOutput?(outputText)
            autoOpenOAuthIfNeeded(outputText)
        }
        if exited {
            timer?.invalidate()
            notifyExitOnce(code: exitCode)
            cleanupSession()
        }
    }

    private func feedToTerminal(_ text: String) {
        guard let terminalView else { return }
        let bytes = ArraySlice(Array(text.utf8))
        terminalView.feed(byteArray: bytes)
    }

    private func feedToTerminal(_ data: Data) {
        guard let terminalView else { return }
        let bytes = ArraySlice([UInt8](data))
        terminalView.feed(byteArray: bytes)
    }

    private func sendInput(_ data: Data) {
        guard let sessionID else { return }
        Task {
            let (ok, err) = await helperClient.sendMaintenanceTerminalSessionInput(
                sessionID: sessionID,
                input: data
            )
            if !ok, let err {
                await MainActor.run { [weak self] in
                    self?.feedToTerminal(L10n.f("views.terminal_log_view.r_n_r_n", fallback: "\r\n输入失败：%@\r\n", String(describing: err)))
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
        Task { [helperClient, sessionID] in
            _ = await helperClient.resizeMaintenanceTerminalSession(
                sessionID: sessionID,
                cols: cols,
                rows: rows
            )
        }
    }

    private func cleanupSession() {
        timer?.invalidate()
        timer = nil
        guard !isCleaningUp else { return }
        guard let sessionID else { return }
        isCleaningUp = true
        self.sessionID = nil
        let client = helperClient
        Task { [sessionID] in
            _ = await client.terminateMaintenanceTerminalSession(sessionID: sessionID)
        }
    }

    private func notifyExitOnce(code: Int32?) {
        guard !exitNotified else { return }
        exitNotified = true
        onExit?(code)
    }

    private func shouldRetryPoll(message: String) -> Bool {
        if message.isEmpty { return false }
        let lowered = message.lowercased()
        if message.contains("XPC 调用超时") { return true }
        if message.contains("未连接") { return true }
        if lowered.contains("xpc") && lowered.contains("timeout") { return true }
        if lowered.contains("not connected") { return true }
        return false
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendInput(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        if let lastResizeSent, lastResizeSent.cols == newCols, lastResizeSent.rows == newRows {
            return
        }
        lastResizeSent = (newCols, newRows)
        sendResize(cols: newCols, rows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        openExternalURL(url)
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        writeToPasteboard(content)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func autoOpenOAuthIfNeeded(_ chunk: String) {
        guard let url = firstOAuthAuthorizeURL(in: chunk) else { return }
        let raw = url.absoluteString
        guard !raw.isEmpty, !openedOAuthURLs.contains(raw) else { return }
        openedOAuthURLs.insert(raw)
        openExternalURL(url)
    }
}

// MARK: - LocalProcessTerminalViewDelegate

final class LocalProcessCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    var onExit: ((Int32?) -> Void)?
    private var openedOAuthURLs: Set<String> = []

    init(onExit: ((Int32?) -> Void)?) {
        self.onExit = onExit
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(exitCode)
        }
    }

    func handleOutputChunk(_ chunk: String) {
        guard let url = firstOAuthAuthorizeURL(in: chunk) else { return }
        let raw = url.absoluteString
        guard !raw.isEmpty, !openedOAuthURLs.contains(raw) else { return }
        openedOAuthURLs.insert(raw)
        openExternalURL(url)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        openExternalURL(url)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        writeToPasteboard(content)
    }
}
