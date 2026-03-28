// ClawdHome/ClawdHomeApp.swift

import AppKit
import Observation
import SwiftUI

final class ClawdHomeAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}

@main
struct ClawdHomeApp: App {
    @NSApplicationDelegateAdaptor(ClawdHomeAppDelegate.self) private var appDelegate
    @State private var helperClient: HelperClient
    @State private var shrimpPool: ShrimpPool
    @State private var updater = UpdateChecker()
    @State private var modelStore = GlobalModelStore()
    @State private var keychainStore = ProviderKeychainStore()
    @State private var gatewayHub = GatewayHub()
    @State private var lockStore = AppLockStore()
    @State private var maintenanceWindowRegistry = MaintenanceWindowRegistry()
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue

    init() {
        // 强制忽略上次会话窗口恢复，确保每次启动从全新窗口开始
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let client = HelperClient()
        _helperClient = State(initialValue: client)
        _shrimpPool   = State(initialValue: ShrimpPool(helperClient: client))
    }

    var body: some Scene {
        let appLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system
        WindowGroup {
            ContentView()
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
                .task { await maintainConnection() }
                .task { await updater.checkIfNeeded() }
                .task { await updater.checkAppIfNeeded() }
                .task { await MainActor.run { shrimpPool.start() } }
                .onAppear { modelStore.load() }
                .task {
                    // 主界面稳定后延迟 2s 预热角色中心 WebView，用户无感知
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run {
                        RoleMarketWebViewCache.shared.preloadIfNeeded()
                    }
                }
        }
        .windowStyle(.titleBar)
        // .contentSize 会随 inspector 列宽变化不断触发窗口 resize，造成约束死循环崩溃
        // .automatic 让窗口可自由拖动，列宽只约束 minimum，不产生反馈
        .windowResizability(.automatic)
        .defaultSize(width: 1040, height: 660)
        .commands {
            // 隐藏主窗口L10n.k("clawd_home_app.text_ededdc48", fallback: "新建窗口")菜单项（单主窗口）
            CommandGroup(replacing: .newItem) { }
        }

        // 龙虾详情独立窗口：每个 username 唯一，重复触发时置前
        // 默认宽度略窄于主窗口，避免详情首开过宽
        WindowGroup(id: "claw-detail", for: String.self) { $username in
            if let name = username {
                ClawDetailWindow(username: name)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(updater)
                    .environment(modelStore)
                    .environment(keychainStore)
                    .environment(gatewayHub)
                    .environment(maintenanceWindowRegistry)
                    .environment(\.locale, appLanguage.locale)
                    .background(ClawDetailWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 920, height: 660)

        WindowGroup(id: "channel-onboarding", for: String.self) { $payload in
            ChannelOnboardingWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 520)

        WindowGroup(id: "maintenance-terminal", for: String.self) { $payload in
            MaintenanceTerminalWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 860, height: 560)
    }

    /// 首次连接，断开后每 5 秒自动重试
    private func maintainConnection() async {
        helperClient.connect()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !helperClient.isConnected {
                helperClient.connect()
            }
        }
    }
}

// MARK: - 通用维护终端窗口模型

@MainActor
@Observable
final class MaintenanceWindowRegistry {
    private var nextIndexByUser: [String: Int] = [:]

    func makePayload(
        username: String,
        title: String,
        command: [String],
        completionToken: String? = nil,
        completionContext: String? = nil
    ) -> String {
        let next = (nextIndexByUser[username] ?? 0) + 1
        nextIndexByUser[username] = next
        let req = MaintenanceTerminalWindowRequest(
            token: UUID().uuidString,
            username: username,
            title: title,
            command: command,
            index: next,
            completionToken: completionToken,
            completionContext: completionContext
        )
        return req.payload
    }
}

struct MaintenanceTerminalWindowRequest: Codable {
    let token: String
    let username: String
    let title: String
    let command: [String]
    let index: Int
    let completionToken: String?
    let completionContext: String?

    var payload: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    init(
        token: String,
        username: String,
        title: String,
        command: [String],
        index: Int,
        completionToken: String? = nil,
        completionContext: String? = nil
    ) {
        self.token = token
        self.username = username
        self.title = title
        self.command = command
        self.index = index
        self.completionToken = completionToken
        self.completionContext = completionContext
    }

    init?(payload: String?) {
        guard let payload,
              let data = Data(base64Encoded: payload),
              let req = try? JSONDecoder().decode(MaintenanceTerminalWindowRequest.self, from: data) else {
            return nil
        }
        self = req
    }
}

extension Notification.Name {
    static let maintenanceTerminalWindowClosed = Notification.Name("MaintenanceTerminalWindowClosed")
}

// MARK: - 维护终端快捷命令

private struct OpenClawQuickCommand: Identifiable {
    let id = UUID()
    let label: String
    let command: String
}

private let openClawQuickCommandSections: [(section: String, items: [OpenClawQuickCommand])] = [
    (L10n.k("app.maintenance.quick.section.query_diagnose", fallback: "查询 / 诊断"), [
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.version", fallback: "版本查询"), command: "openclaw --version"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.status_overview", fallback: "状态概览"), command: "openclaw status"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.model_status", fallback: "模型状态"), command: "openclaw models status --probe"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.connected_devices", fallback: "已连设备"), command: "openclaw devices list"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.system_check", fallback: "系统体检"), command: "openclaw doctor"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.security_audit", fallback: "安全审计"), command: "openclaw security audit"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.live_logs", fallback: "实时日志"), command: "openclaw logs --follow"),
    ]),
    (L10n.k("app.maintenance.quick.section.config_control", fallback: "配置 / 控制"), [
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.configure", fallback: "交互配置"), command: "openclaw configure"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.auto_fix", fallback: "自动修复"), command: "openclaw doctor --fix"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.channel_login", fallback: "频道登录"), command: "openclaw channels login"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.restart_service", fallback: "重启服务"), command: "openclaw gateway restart"),
    ]),
]

// MARK: - 通用维护终端窗口

private struct MaintenanceTerminalWindow: View {
    let payload: String?

    var body: some View {
        if let request = MaintenanceTerminalWindowRequest(payload: payload) {
            MaintenanceTerminalWindowContent(request: request)
        } else {
            ContentUnavailableView(
                L10n.k("app.maintenance.invalid_params", fallback: "维护终端参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.maintenance.invalid_params.desc", fallback: "请从虾详情页或初始化向导重新打开维护终端。"))
            )
        }
    }
}

private struct MaintenanceTerminalWindowContent: View {
    let request: MaintenanceTerminalWindowRequest

    @Environment(ShrimpPool.self) private var pool
    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()
    @State private var outputBuffer = ""
    @State private var didStart = false
    @State private var didPostCloseNotification = false

    private let waitingThreshold: TimeInterval = 8
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var windowTitle: String {
        L10n.f(
            "app.maintenance.window.title",
            fallback: L10n.k("clawd_home_app.arg_num", fallback: "@%@ · 维护窗口 #%d"),
            request.username,
            request.index
        )
    }
    private var isRunning: Bool { didStart && exitCode == nil }
    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }
    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 10) {
            if isRunning {
                Label(
                    isWaitingInput
                        ? L10n.k("app.maintenance.status.running_waiting", fallback: "运行中（等待输入）")
                        : L10n.k("app.maintenance.status.running", fallback: "运行中"),
                    systemImage: isWaitingInput ? "hourglass" : "play.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(L10n.k("app.maintenance.status.exited", fallback: "已退出"), systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.f("app.maintenance.elapsed", fallback: "耗时 %@", elapsedText))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.k("common.action.interrupt", fallback: "中断")) { terminalControl.sendInterrupt() }
                .disabled(!isRunning)
            Button(L10n.k("common.action.rerun", fallback: "重跑")) { startRun() }
            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) { copyTerminalOutput() }
                .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 0)

            quickCommandMenu
        }
    }

    @ViewBuilder
    private var quickCommandMenu: some View {
        Menu {
            ForEach(openClawQuickCommandSections, id: \.section) { group in
                Section(group.section) {
                    ForEach(group.items) { cmd in
                        Button {
                            terminalControl.sendLine(cmd.command)
                        } label: {
                            Text(cmd.label)
                        }
                    }
                }
            }
        } label: {
            Text(L10n.k("app.maintenance.quick.menu_title", fallback: "🦞openclaw 指令"))
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            terminalPanel
            statusBar
            resourceUsageBar
        }
        .padding(10)
        .background(WindowTitleBinder(title: windowTitle))
        .onAppear {
            if !didStart {
                didStart = true
                startRun()
            }
        }
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .onDisappear {
            postCloseNotificationIfNeeded()
            terminalControl.terminate()
            appLog("[maintenance-window] closed user=\(request.username) index=\(request.index) title=\(request.title)")
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var terminalPanel: some View {
        HelperMaintenanceTerminalPanel(
            username: request.username,
            command: request.command,
            minHeight: 280,
            onOutput: { chunk in
                handleTerminalOutput(chunk)
            },
            control: terminalControl,
            onExit: { code in
                handleCommandExit(code)
            }
        )
        .id(terminalRunID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let st = statusText {
            Text(st)
                .font(.caption)
                .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
        }
    }


    private func startRun() {
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        outputBuffer += chunk
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        if normalized == 0 {
            statusText = L10n.k("app.clawd_home_app.done", fallback: "维护命令执行完成。")
            appLog("[maintenance-window] command success user=\(request.username) index=\(request.index)")
        } else {
            statusText = String(format: L10n.k("app.clawd_home_app.command_exit_code", fallback: "命令已退出（exit %d）。请查看终端输出。"), normalized)
            appLog(
                "[maintenance-window] command failed user=\(request.username) index=\(request.index) exit=\(normalized)",
                level: .error
            )
        }
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("app.clawd_home_app.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = L10n.k("app.clawd_home_app.output_copied", fallback: "命令输出已复制。")
    }

    @ViewBuilder
    private var resourceUsageBar: some View {
        if let shrimp = pool.snapshot?.shrimps.first(where: { $0.username == request.username }) {
            HStack(spacing: 10) {
                resourceChip(icon: "cpu", title: "CPU", value: shrimp.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                resourceChip(icon: "memorychip", title: L10n.k("common.resource.memory", fallback: "内存"), value: shrimp.memRssMB.map { formatMem($0) } ?? "—")
                resourceChip(icon: "arrow.down.circle", title: L10n.k("common.resource.net_in", fallback: "入网"), value: FormatUtils.formatBps(shrimp.netRateInBps))
                resourceChip(icon: "arrow.up.circle", title: L10n.k("common.resource.net_out", fallback: "出网"), value: FormatUtils.formatBps(shrimp.netRateOutBps))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func postCloseNotificationIfNeeded() {
        guard !didPostCloseNotification, let completionToken = request.completionToken else { return }
        didPostCloseNotification = true
        NotificationCenter.default.post(
            name: .maintenanceTerminalWindowClosed,
            object: nil,
            userInfo: [
                "token": completionToken,
                "username": request.username,
                "title": request.title,
                "context": request.completionContext ?? "",
                "exitCode": exitCode.map(NSNumber.init(value:)) ?? NSNull()
            ]
        )
    }

    @ViewBuilder
    private func resourceChip(icon: String, title: String, value: String) -> some View {
        Label("\(title) \(value)", systemImage: icon)
            .lineLimit(1)
    }

    private func formatMem(_ memMB: Double) -> String {
        if memMB < 1024 {
            return String(format: "%.0f MB", memMB)
        }
        return String(format: "%.2f GB", memMB / 1024)
    }

private struct WindowTitleBinder: NSViewRepresentable {
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
}

// MARK: - 通道配置窗口

private struct ChannelOnboardingWindow: View {
    let payload: String?

    var body: some View {
        if let payload, let req = ChannelOnboardingRequest(payload: payload) {
            switch req.flow {
            case .feishu:
                FeishuChannelOnboardingSheet(flow: .feishu, username: req.username)
            case .weixin:
                FeishuChannelOnboardingSheet(flow: .weixin, username: req.username)
            }
        } else {
            ContentUnavailableView(
                L10n.k("app.channel.invalid_params", fallback: "通道参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.channel.invalid_params.desc", fallback: "请从虾详情页重新打开通道配置窗口。"))
            )
        }
    }
}

private struct ChannelOnboardingRequest {
    let flow: ChannelOnboardingFlow
    let username: String

    init?(payload: String) {
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let flow = ChannelOnboardingFlow(rawValue: parts[0]),
              !parts[1].isEmpty else { return nil }
        self.flow = flow
        self.username = parts[1]
    }
}

// MARK: - 龙虾详情窗口定位器

/// 首次出现时把 claw-detail 窗口定位到主窗口右侧区域（侧栏宽度 idealSidebar）
private struct ClawDetailWindowPositioner: NSViewRepresentable {
    private let idealSidebar: CGFloat = 200
    private let preferredSize = NSSize(width: 920, height: 660)
    private let minimumSize = NSSize(width: 820, height: 560)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(
                view: view,
                sidebar: idealSidebar,
                preferredSize: preferredSize,
                minimumSize: minimumSize
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(
        view: NSView,
        sidebar: CGFloat,
        preferredSize: NSSize,
        minimumSize: NSSize
    ) {
        guard let detailWindow = view.window else { return }
        detailWindow.contentMinSize = minimumSize
        // 找到主窗口（同进程、可见、非 claw-detail 自身）
        let mainWindow = NSApp.windows.first {
            $0 !== detailWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }
        let visibleFrame = main.screen?.visibleFrame ?? detailWindow.screen?.visibleFrame ?? main.frame

        // 主窗口右侧 detail 区的屏幕坐标：跳过侧栏；首开时同时钳住默认尺寸，
        // 避免被内容理想宽度直接撑成过宽窗口。
        let originX = min(main.frame.minX + sidebar, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let width = min(preferredSize.width, visibleFrame.maxX - originX)
        let height = min(preferredSize.height, visibleFrame.maxY - originY)
        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: max(minimumSize.width, width),
            height: max(minimumSize.height, height)
        )
        detailWindow.setFrame(frame, display: true)
    }
}

// MARK: - 龙虾详情窗口容器

/// 通过 username 从 ShrimpPool 查找用户并展示 UserDetailView。
/// 同一 username 的窗口由 SwiftUI 去重：再次 openWindow 只会置前已有窗口。
private struct ClawDetailWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss)       private var dismiss

    private var user: ManagedUser? {
        pool.users.first { $0.username == username }
    }

    var body: some View {
        NavigationStack {
            if let user {
                UserDetailView(user: user, onDeleted: {
                    pool.removeUser(username: username)
                    dismiss()
                })
            } else {
                ContentUnavailableView(
                    "@\(username)",
                    systemImage: "person.slash",
                    description: Text(L10n.k("app.claw_detail.user_missing", fallback: "该用户已被删除或尚未加载"))
                )
                .navigationTitle("@\(username)")
            }
        }
    }
}
