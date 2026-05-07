// ClawdHome/Views/Terminal/ShrimpTerminalConsole.swift
// 通用终端 Tab 管理器 + Console 视图（引擎无关，可供 Hermes / OpenClaw 复用）

import AppKit
import SwiftUI

// MARK: - ShrimpTerminalTabManager

@MainActor
final class ShrimpTerminalTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let title: String
        let session: ShrimpTerminalSession
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?

    let engine: TerminalEngine
    let titlePrefix: String
    let defaultCommand: [String]

    private var username: String?
    private weak var helperClient: HelperClient?
    private var tabCounter = 0

    /// - Parameters:
    ///   - engine: 决定默认 shell 与 `▾` 下拉模板列表
    ///   - titlePrefix: `+` 主按钮新建未命名 tab 时的标题前缀（如 "终端 1"、"配置 1"）
    ///   - defaultCommand: 显式覆盖默认 shell；nil 时使用 `engine.defaultShell`。pinned 用途的 manager（如 hermes `.config` 固定跑 `hermes setup`）通过此字段固化命令。
    init(
        engine: TerminalEngine,
        titlePrefix: String = "终端",
        defaultCommand: [String]? = nil
    ) {
        self.engine = engine
        self.titlePrefix = titlePrefix
        self.defaultCommand = defaultCommand ?? engine.defaultShell
    }

    var selectedTab: Tab? {
        if let selectedTabID,
           let match = tabs.first(where: { $0.id == selectedTabID }) {
            return match
        }
        return tabs.first
    }

    func configureIfNeeded(username: String, helperClient: HelperClient) {
        let shouldReset = self.username != username || self.helperClient !== helperClient
        self.username = username
        self.helperClient = helperClient
        if shouldReset {
            closeAllTabs()
            tabCounter = 0
        }
    }

    /// 新建 tab。
    /// - Parameters:
    ///   - command: nil ⇒ 跑 `defaultCommand`
    ///   - titleOverride: 非 nil 时使用（重名自动追加 ` (2)`）；nil 时按 `titlePrefix N` 计数
    func addTab(command: [String]? = nil, titleOverride: String? = nil) {
        guard let username, let helperClient else { return }
        let cmd = command ?? defaultCommand
        let title: String
        if let titleOverride {
            title = makeUniqueTitle(titleOverride)
        } else {
            tabCounter += 1
            title = "\(titlePrefix) \(tabCounter)"
        }
        let newTab = Tab(
            id: UUID(),
            title: title,
            session: ShrimpTerminalSession(
                helperClient: helperClient,
                username: username,
                command: cmd
            )
        )
        tabs.append(newTab)
        selectedTabID = newTab.id
    }

    /// 通过模板新建 tab：title 用模板 title（重名加序号），命令用模板 command
    func addTab(template: TerminalTemplate) {
        addTab(command: template.command, titleOverride: template.title)
    }

    /// 文件视图调用：新建一个 cd 到指定路径的 shell tab。
    /// - Parameters:
    ///   - cdRelativePath: 相对 home 的路径（空串 = home 根）
    ///   - titleHint: tab 标题；重名时由 makeUniqueTitle 自动追加 ` (2)`
    func addTab(cdRelativePath: String, titleHint: String) {
        guard let username else { return }
        let home = "/Users/\(username)"
        let escaped = cdRelativePath.replacingOccurrences(of: "'", with: "'\\''")
        let target = cdRelativePath.isEmpty ? home : "\(home)/\(escaped)"
        let cmd = ["zsh", "-lc", "cd '\(target)' && exec /bin/zsh -l"]
        addTab(command: cmd, titleOverride: titleHint)
    }

    private func makeUniqueTitle(_ base: String) -> String {
        let existing = Set(tabs.map(\.title))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    func selectTab(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs.remove(at: index)
        closing.session.close()

        if tabs.isEmpty {
            selectedTabID = nil
            return
        }
        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
    }

    func closeAllTabs() {
        let existing = tabs
        tabs = []
        selectedTabID = nil
        for tab in existing {
            tab.session.close()
        }
    }

}

// MARK: - ShrimpTerminalConsole

struct ShrimpTerminalConsole: View {
    let username: String
    @ObservedObject var tabManager: ShrimpTerminalTabManager
    var isActive: Bool = true
    /// `+` 按钮是否带 `▾` 模板下拉菜单。pinned 用途的 console（如 hermes `.config`）传 false 屏蔽下拉。
    var showsTemplateMenu: Bool = true

    @Environment(HelperClient.self) private var helperClient
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow

    @State private var pendingCloseTabID: UUID?
    /// 字号 / 主题 per-console state；不持久化，console 重建即重置（与老维护窗口不同，那是 @AppStorage）
    @State private var terminalFontSize: CGFloat = 12
    @State private var terminalTheme: MaintenanceTerminalTheme = .black

    /// 当前活跃 tab 对应的 session（被 3 个菜单的中断/复制输出/清屏/sendLine 直接调用）
    private var activeTab: ShrimpTerminalTabManager.Tab? {
        guard let id = tabManager.selectedTabID ?? tabManager.tabs.first?.id else { return nil }
        return tabManager.tabs.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tab 栏：tab chips + ⊕ 在左，3 个菜单在右
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabManager.tabs) { tab in
                            terminalTabChip(tab)
                        }
                        addTabButton
                    }
                    .padding(.vertical, 2)
                }
                Spacer(minLength: 12)
                actionsMenu
                settingsMenu
                quickCommandMenu
            }

            // 终端内容
            if !tabManager.tabs.isEmpty {
                let activeID = tabManager.selectedTabID ?? tabManager.tabs.first?.id
                ZStack {
                    ForEach(tabManager.tabs) { tab in
                        let isActive = tab.id == activeID
                        ShrimpTerminalPanel(
                            session: tab.session,
                            theme: terminalTheme,
                            minHeight: 520,
                            tabTitle: tab.title,
                            isActive: isActive,
                            fontSize: terminalFontSize
                        )
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(L10n.k("hermes.terminal.empty_hint", fallback: "点击下方按钮打开终端会话"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        tabManager.addTab()
                    } label: {
                        Label(L10n.k("hermes.terminal.open", fallback: "打开终端"), systemImage: "play.fill")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            tabManager.configureIfNeeded(username: username, helperClient: helperClient)
            if isActive && tabManager.tabs.isEmpty {
                tabManager.addTab()
            }
        }
        .onChange(of: isActive) { _, newActive in
            guard newActive else { return }
            tabManager.configureIfNeeded(username: username, helperClient: helperClient)
            if tabManager.tabs.isEmpty {
                tabManager.addTab()
            }
        }
        .alert(
            L10n.k("hermes.terminal.close_tab_title", fallback: "关闭终端标签？"),
            isPresented: Binding(
                get: { pendingCloseTabID != nil },
                set: { if !$0 { pendingCloseTabID = nil } }
            )
        ) {
            Button(L10n.k("common.action.cancel", fallback: "取消"), role: .cancel) {
                pendingCloseTabID = nil
            }
            Button(L10n.k("common.action.close", fallback: "关闭"), role: .destructive) {
                guard let tabID = pendingCloseTabID else { return }
                tabManager.closeTab(id: tabID)
                pendingCloseTabID = nil
            }
        } message: {
            Text(L10n.k("hermes.terminal.close_tab_message", fallback: "关闭后该终端会话将被终止，无法恢复。"))
        }
    }

    @ViewBuilder
    private func terminalTabChip(_ tab: ShrimpTerminalTabManager.Tab) -> some View {
        let isSelected = tab.id == tabManager.selectedTabID
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Button {
                tabManager.selectTab(id: tab.id)
            } label: {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .buttonStyle(.plain)

            Button {
                pendingCloseTabID = tab.id
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(L10n.k("common.action.close_tab", fallback: "关闭标签"))
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0.22 : 0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var addTabButton: some View {
        if showsTemplateMenu {
            Menu {
                ForEach(tabManager.engine.templates) { tmpl in
                    Button {
                        tabManager.addTab(template: tmpl)
                    } label: {
                        Label(tmpl.title, systemImage: tmpl.icon)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            } primaryAction: {
                tabManager.addTab()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.k("terminal.action.new_session", fallback: "新建会话"))
        } else {
            Button {
                tabManager.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.k("hermes.terminal.new_tab", fallback: "新建终端标签"))
        }
    }

    // MARK: - 顶栏菜单：操作 / 设置 / 引擎指令

    @ViewBuilder
    private var actionsMenu: some View {
        Menu {
            Button(L10n.k("common.action.interrupt", fallback: "中断")) {
                activeTab?.session.sendInterrupt()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(activeTab?.session.isRunning != true)

            Divider()

            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) {
                copyActiveOutput()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!hasCopyableOutput)

            Button(L10n.k("common.action.clear_screen", fallback: "清屏")) {
                activeTab?.session.clearScreen()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(activeTab == nil)

            Divider()

            Button {
                activeTab?.session.sendLine("cd ~/clawdhome_shared/private/")
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.cd_private", fallback: "终端进入 private 目录"),
                    systemImage: "terminal"
                )
            }
            .disabled(activeTab == nil)

            Button {
                openSharedFilesWindow()
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.open_files", fallback: "文件管理打开 private 目录"),
                    systemImage: "folder"
                )
            }

            Button {
                openSharedFinder()
            } label: {
                Label(
                    L10n.k("app.maintenance.shared.open_finder", fallback: "在 Finder 打开 private 目录"),
                    systemImage: "folder.badge.gearshape"
                )
            }
        } label: {
            Label(L10n.k("app.maintenance.actions_menu", fallback: "操作"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Section(L10n.k("app.maintenance.font.section", fallback: "字号")) {
                Button(L10n.k("app.maintenance.font.decrease", fallback: "减小字号")) {
                    terminalFontSize = max(10, terminalFontSize - 1)
                }
                .disabled(terminalFontSize <= 10)
                Button(L10n.k("app.maintenance.font.increase", fallback: "增大字号")) {
                    terminalFontSize = min(16, terminalFontSize + 1)
                }
                .disabled(terminalFontSize >= 16)
                Button(String(format: L10n.k("app.maintenance.font.reset_to", fallback: "恢复默认（%.0f）"), 12.0)) {
                    terminalFontSize = 12
                }
                .disabled(terminalFontSize == 12)
            }
            Section(L10n.k("app.maintenance.theme.section", fallback: "背景")) {
                ForEach(MaintenanceTerminalTheme.allCases) { theme in
                    Button {
                        terminalTheme = theme
                    } label: {
                        if theme == terminalTheme {
                            Label(theme.title, systemImage: "checkmark")
                        } else {
                            Text(theme.title)
                        }
                    }
                }
            }
        } label: {
            Label(L10n.k("app.maintenance.settings_menu", fallback: "设置"), systemImage: "gearshape")
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    @ViewBuilder
    private var quickCommandMenu: some View {
        Menu {
            ForEach(tabManager.engine.quickCommandSections) { group in
                Section(group.title) {
                    ForEach(group.commands) { cmd in
                        Button {
                            activeTab?.session.sendLine(cmd.command)
                        } label: {
                            Text(cmd.label)
                        }
                        .disabled(activeTab?.session.isRunning != true)
                    }
                }
            }
        } label: {
            Text(tabManager.engine.quickCommandMenuTitle)
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    // MARK: - 操作菜单的辅助方法

    private var hasCopyableOutput: Bool {
        guard let session = activeTab?.session else { return false }
        return !session.bufferedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copyActiveOutput() {
        guard let session = activeTab?.session else { return }
        let text = session.bufferedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func openSharedFilesWindow() {
        let payload = maintenanceWindowRegistry.makeToolWindowPayload(
            username: username,
            title: L10n.k("app.maintenance.shared.files_title", fallback: "共享文件夹（private）"),
            kind: .files,
            scope: .home,
            initialRelativePath: "clawdhome_shared/private"
        )
        openWindow(id: "maintenance-files", value: payload)
    }

    private func openSharedFinder() {
        let fm = FileManager.default
        let primary = "/Users/Shared/ClawdHome/vaults/\(username)"
        let legacy = "/Users/\(username)/clawdhome_shared/private"
        let candidates = [primary, legacy, "/Users/Shared/ClawdHome/vaults", "/Users/Shared/ClawdHome"]
        for path in candidates where fm.fileExists(atPath: path) {
            if NSWorkspace.shared.open(URL(fileURLWithPath: path)) { return }
        }
    }
}
