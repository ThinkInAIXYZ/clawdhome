// ClawdHome/Views/HermesDetailView.swift
// Hermes 运行时专用详情页（独立于 OpenClaw 布局）

import AppKit
import SwiftTerm
import SwiftUI

enum HermesDetailMode: Hashable {
    case chat
    case profiles
    case config
    // 实例管理（与 OpenClaw 共享内容视图）
    case files
    case terminal
    case processes
    case logs
}

struct HermesDetailView: View {
    let user: ManagedUser
    let mode: HermesDetailMode
    let chatTabManager: HermesChatTabManager
    let configTabManager: HermesTerminalTabManager
    let shellTabManager: HermesTerminalTabManager
    let profiles: [AgentProfile]
    let selectedProfileID: String?
    let isConnected: Bool
    let isLoading: Bool
    let runtimeVersion: String?
    let runtimeRunning: Bool
    let runtimePID: Int32?
    let cpuPercent: Double?
    let memRssMB: Double?
    let homeDirBytes: Int64?
    let actionError: String?
    let onStartOrRestart: () -> Void
    let onStop: () -> Void
    let onOpenHealthCheck: () -> Void
    let onShowSetup: () -> Void
    let onRefresh: () -> Void
    let onSelectProfile: (String) -> Void
    let onCreateProfile: (String, String) -> Void
    let onUpdateProfile: (String, String, String) -> Void
    let onDeleteProfile: (String) -> Void
    let onShowChat: () -> Void

    @Environment(HelperClient.self) private var helperClient

    @State private var isRightPanelExpanded = false
    @State private var pendingCloseTabID: UUID?
    @State private var newProfileName = ""
    @State private var newProfileEmoji = "🤖"
    @State private var showNewProfilePopover = false
    @State private var editingProfileID: String?
    @State private var editingProfileName = ""
    @State private var editingProfileEmoji = ""
    @State private var deleteProfileID: String?
    @State private var showOnlySelectedProfileTabs = false
    @State private var hermesLogSearchText = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // chatBody / configBody 始终保留在视图层级，仅通过 opacity 控制可见性。
            // 若使用 switch/if 条件渲染，SwiftUI 会在切换菜单时销毁并重建
            // TerminalView（NSViewRepresentable），导致 hermes 进程发出的 CPR 查询
            // 无法得到及时响应（SwiftTerm 断开），进而触发 "CPR not supported" 警告
            // 并产生 TUI 渲染错乱。保留视图层级可确保 SwiftTerm 始终连接、CPR 正常工作。
            ZStack {
                chatBody
                    .opacity(mode == .chat ? 1 : 0)
                    .allowsHitTesting(mode == .chat)

                configBody
                    .opacity(mode == .config ? 1 : 0)
                    .allowsHitTesting(mode == .config)

                shellBody
                    .opacity(mode == .terminal ? 1 : 0)
                    .allowsHitTesting(mode == .terminal)

                if mode == .profiles {
                    profilesBody
                } else if mode == .files {
                    UserFilesView(users: [user], preselectedUser: user, prefersHermesBrand: true)
                } else if mode == .processes {
                    ProcessTabView(username: user.username)
                } else if mode == .logs {
                    GatewayLogViewer(username: user.username, runtime: .hermes, externalSearchQuery: $hermesLogSearchText)
                }
            }
            .padding(.top, 44)
            .padding(.trailing, isRightPanelExpanded ? UserDetailWindowLayout.expandedSidebarWidth + 12 : 0)

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    if mode == .profiles {
                        Button {
                            showNewProfilePopover = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("新建 Profile")
                        .popover(isPresented: $showNewProfilePopover, arrowEdge: .bottom) {
                            VStack(spacing: 10) {
                                Text("新建 Profile")
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    TextField("名称", text: $newProfileName)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 160)
                                    TextField("🤖", text: $newProfileEmoji)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 50)
                                }
                                HStack {
                                    Spacer()
                                    Button("取消") {
                                        showNewProfilePopover = false
                                        newProfileName = ""
                                        newProfileEmoji = "🤖"
                                    }
                                    .buttonStyle(.bordered)
                                    Button("创建") {
                                        let rawName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !rawName.isEmpty else { return }
                                        let emoji = newProfileEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                                        onCreateProfile(rawName, emoji.isEmpty ? "🤖" : emoji)
                                        newProfileName = ""
                                        newProfileEmoji = "🤖"
                                        showNewProfilePopover = false
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(16)
                            .frame(width: 280)
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isRightPanelExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isRightPanelExpanded ? "sidebar.right" : "sidebar.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isRightPanelExpanded ? "收起状态面板" : "展开状态面板")
                }

                if isRightPanelExpanded {
                    rightPanel
                        .frame(width: UserDetailWindowLayout.expandedSidebarWidth)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.2), radius: 18, x: 0, y: 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(5)
                }
            }
            .padding(.top, 44)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            configureChatTabsIfNeeded()
        }
        .onChange(of: user.username) { _, _ in
            configureChatTabsIfNeeded()
        }
        .alert(
            "关闭会话标签？",
            isPresented: Binding(
                get: { pendingCloseTabID != nil },
                set: { if !$0 { pendingCloseTabID = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingCloseTabID = nil
            }
            Button("关闭", role: .destructive) {
                guard let tabID = pendingCloseTabID else { return }
                chatTabManager.closeTab(id: tabID)
                pendingCloseTabID = nil
            }
        } message: {
            Text("关闭后该标签中的 Hermes 会话会被终止，无法恢复。")
        }
        .alert(
            "删除 Profile？",
            isPresented: Binding(
                get: { deleteProfileID != nil },
                set: { if !$0 { deleteProfileID = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                deleteProfileID = nil
            }
            Button("删除", role: .destructive) {
                guard let profileID = deleteProfileID else { return }
                onDeleteProfile(profileID)
                deleteProfileID = nil
            }
        } message: {
            Text("删除后该 profile 的会话和配置不可恢复。")
        }
    }

    private var chatBody: some View {
        terminalColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var configBody: some View {
        HermesTerminalConsole(username: user.username, tabManager: configTabManager)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shellBody: some View {
        HermesTerminalConsole(username: user.username, tabManager: shellTabManager)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminalColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Chat")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleChatTabs) { tab in
                            tabChip(tab)
                        }
                        addTabButton
                    }
                    .padding(.vertical, 2)
                }
                Spacer()
            }

            if !chatTabManager.tabs.isEmpty {
                let activeID = chatTabManager.selectedTabID ?? chatTabManager.tabs.first?.id
                ZStack {
                    ForEach(chatTabManager.tabs) { tab in
                        let isActive = tab.id == activeID
                        HermesChatTerminalPanel(
                            session: tab.session,
                            theme: .black,
                            minHeight: 520,
                            tabTitle: tab.title,
                            isActive: isActive
                        )
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("点击下方按钮开始与 Hermes 对话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        if let selectedProfile {
                            chatTabManager.addTab(for: selectedProfile)
                        } else {
                            chatTabManager.addTab()
                        }
                    } label: {
                        Label("启动会话", systemImage: "play.fill")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var addTabButton: some View {
        Button {
            if let selectedProfile {
                chatTabManager.addTab(for: selectedProfile)
            } else {
                chatTabManager.addTab()
            }
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
        .help("新建会话标签")
    }

    @ViewBuilder
    private func tabChip(_ tab: HermesChatTabManager.Tab) -> some View {
        let isSelected = tab.id == chatTabManager.selectedTabID
        HStack(spacing: 6) {
            Circle()
                .fill(profileAccentColor(index: tab.profileColorIndex))
                .frame(width: 7, height: 7)
            Button {
                chatTabManager.selectTab(id: tab.id)
                onSelectProfile(tab.profileID)
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
            .help("关闭标签")
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

    private var profilesBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profiles")
                .font(.title3.weight(.semibold))

            if profiles.isEmpty {
                ContentUnavailableView("暂无 profile", systemImage: "person.2.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                        ForEach(profiles) { profile in
                            profileCard(profile)
                        }
                    }
                }
            }
        }
    }

    private func profileCard(_ profile: AgentProfile) -> some View {
        let isActive = profile.id == selectedProfileID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(profile.emoji.isEmpty ? "🤖" : profile.emoji)
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("@\(profile.id == "main" ? "default" : profile.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                Button {
                    onSelectProfile(profile.id)
                } label: {
                    Label("设为当前", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isActive)

                Button {
                    onShowChat()
                    chatTabManager.addTab(for: profile)
                } label: {
                    Label("Chat", systemImage: "message")
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    Button {
                        editingProfileID = profile.id
                        editingProfileName = profile.name
                        editingProfileEmoji = profile.emoji.isEmpty ? "🤖" : profile.emoji
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    if profile.id != "main" {
                        Button(role: .destructive) {
                            deleteProfileID = profile.id
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }

            HStack(spacing: 8) {
                if let provider = profile.modelProvider, !provider.isEmpty {
                    Text(provider.capitalized)
                } else {
                    Text("Provider -")
                }
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(profile.modelPrimary ?? "model 未配置")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("\(profile.skillCount ?? 0) skills")
                Text("•")
                    .foregroundStyle(.tertiary)
                Text((profile.gatewayRunning ?? false) ? "Gateway on" : "Gateway off")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if editingProfileID == profile.id {
                HStack(spacing: 8) {
                    TextField("名称", text: $editingProfileName)
                        .textFieldStyle(.roundedBorder)
                    TextField("🤖", text: $editingProfileEmoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                    Button("保存") {
                        onUpdateProfile(
                            profile.id,
                            editingProfileName.trimmingCharacters(in: .whitespacesAndNewlines),
                            editingProfileEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        editingProfileID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") {
                        editingProfileID = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: isActive ? 1.5 : 1)
        )
    }

    private var selectedProfile: AgentProfile? {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    private var visibleChatTabs: [HermesChatTabManager.Tab] {
        guard showOnlySelectedProfileTabs, let selectedProfileID else {
            return chatTabManager.tabs
        }
        let filtered = chatTabManager.tabs.filter { $0.profileID == selectedProfileID }
        return filtered.isEmpty ? chatTabManager.tabs : filtered
    }

    private func profileAccentColor(index: Int) -> SwiftUI.Color {
        let palette: [SwiftUI.Color] = [.blue, .teal, .green, .orange, .pink, .indigo, .mint, .red]
        return palette[max(0, index) % palette.count]
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("状态与版本") {
                fixedSectionContent {
                    row("状态", runtimeRunning ? "运行中" : "未运行")
                    row("版本", runtimeVersion.map { "v\($0)" } ?? "—")
                    row("PID", runtimePID.map(String.init) ?? "—")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("资源占用") {
                fixedSectionContent {
                    let cpu = cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
                    let mem = memRssMB.map { String(format: "%.0f MB", $0) } ?? "—"
                    let storage = homeDirBytes.map { FormatUtils.formatBytes($0) } ?? "—"
                    row("CPU", cpu)
                    row("内存", mem)
                    row("存储", storage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("操作") {
                VStack(alignment: .leading, spacing: 8) {
                    Button(runtimeRunning ? "重启 Hermes" : "启动 Hermes", action: onStartOrRestart)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConnected || isLoading)

                    Button("停止 Hermes", action: onStop)
                        .buttonStyle(.bordered)
                        .disabled(!isConnected || isLoading || !runtimeRunning)

                    HStack(spacing: 8) {
                        Button("体检", action: onOpenHealthCheck)
                            .buttonStyle(.bordered)
                        Button("Hermes 设置", action: onShowSetup)
                            .buttonStyle(.bordered)
                    }

                    Button("刷新状态", action: onRefresh)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(!isConnected || isLoading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionError, !actionError.isEmpty {
                GroupBox {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fixedSectionContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func configureChatTabsIfNeeded() {
        guard mode == .chat else { return }
        chatTabManager.configureIfNeeded(
            username: user.username,
            helperClient: helperClient,
            defaultProfile: selectedProfile
        )
    }
}

@MainActor
final class HermesChatTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let title: String
        let profileID: String
        let profileName: String
        let profileColorIndex: Int
        let session: HermesChatTerminalSession
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?

    private var username: String?
    private weak var helperClient: HelperClient?

    var selectedTab: Tab? {
        if let selectedTabID,
           let match = tabs.first(where: { $0.id == selectedTabID }) {
            return match
        }
        return tabs.first
    }

    func configureIfNeeded(username: String, helperClient: HelperClient, defaultProfile: AgentProfile?) {
        let shouldReset = self.username != username || self.helperClient !== helperClient
        self.username = username
        self.helperClient = helperClient
        if shouldReset {
            closeAllTabs()
        }
        // 不自动创建 tab，由用户点击「启动会话」按钮手动开启
    }

    func addTab() {
        addTab(for: nil)
    }

    func addTab(for profile: AgentProfile?) {
        guard let username, let helperClient else { return }
        let profileID = profile?.id ?? "main"
        let profileName = profile?.name ?? "默认角色"
        let sessionIndex = tabs.filter { $0.profileID == profileID }.count + 1
        let title = "\(profileName) · 会话 \(sessionIndex)"
        let command: [String] = if profileID == "main" {
            ["hermes"]
        } else {
            ["hermes", "-p", profileID]
        }
        let profileColorIndex = colorIndexForProfileID(profileID)
        let newTab = Tab(
            id: UUID(),
            title: title,
            profileID: profileID,
            profileName: profileName,
            profileColorIndex: profileColorIndex,
            session: HermesChatTerminalSession(
                helperClient: helperClient,
                username: username,
                command: command
            )
        )
        tabs.append(newTab)
        selectedTabID = newTab.id
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

    private func colorIndexForProfileID(_ profileID: String) -> Int {
        let paletteCount = 8
        let hash = profileID.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) & 0x7fffffff }
        return hash % paletteCount
    }
}

private struct HermesChatTerminalPanel: View {
    @ObservedObject var session: HermesChatTerminalSession
    let theme: MaintenanceTerminalTheme
    let minHeight: CGFloat
    let tabTitle: String
    let isActive: Bool

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
                Label("Helper 会话", systemImage: "bolt.horizontal.circle")
                    .font(.caption2)
                    .foregroundStyle(theme.headerSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            HermesChatTerminalNSView(
                session: session,
                theme: theme,
                fontSize: 11,
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

private struct HermesChatTerminalNSView: NSViewRepresentable {
    @ObservedObject var session: HermesChatTerminalSession
    let theme: MaintenanceTerminalTheme
    let fontSize: CGFloat
    let isActive: Bool

    func makeCoordinator() -> HermesChatTerminalSession {
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

    static func dismantleNSView(_ nsView: TerminalView, coordinator: HermesChatTerminalSession) {
        coordinator.detachTerminalView(nsView)
    }
}

@MainActor
final class HermesChatTerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
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

private func firstHermesOAuthAuthorizeURL(in text: String) -> URL? {
    for token in text.split(whereSeparator: { $0.isWhitespace }) {
        let candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[]<>.,"))
        guard candidate.hasPrefix("https://auth.openai.com/oauth/authorize") else { continue }
        if let url = URL(string: candidate) {
            return url
        }
    }
    return nil
}

private func openHermesExternalURL(_ url: URL) {
    DispatchQueue.main.async {
        _ = NSWorkspace.shared.open(url)
    }
}


// MARK: - 终端 Tab 管理器

@MainActor
final class HermesTerminalTabManager: ObservableObject {
    struct Tab: Identifiable {
        let id: UUID
        let title: String
        let session: HermesChatTerminalSession
    }

    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: UUID?

    let titlePrefix: String
    let defaultCommand: [String]

    private var username: String?
    private weak var helperClient: HelperClient?
    private var tabCounter = 0

    init(titlePrefix: String = "配置", defaultCommand: [String] = ["hermes", "setup"]) {
        self.titlePrefix = titlePrefix
        self.defaultCommand = defaultCommand
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

    func addTab(command: [String]? = nil) {
        guard let username, let helperClient else { return }
        let cmd = command ?? defaultCommand
        tabCounter += 1
        let title = "\(titlePrefix) \(tabCounter)"
        let newTab = Tab(
            id: UUID(),
            title: title,
            session: HermesChatTerminalSession(
                helperClient: helperClient,
                username: username,
                command: cmd
            )
        )
        tabs.append(newTab)
        selectedTabID = newTab.id
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

// MARK: - 终端 Console（侧边栏 Tab 内容）

struct HermesTerminalConsole: View {
    let username: String
    @ObservedObject var tabManager: HermesTerminalTabManager

    @Environment(HelperClient.self) private var helperClient
    @State private var pendingCloseTabID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tab 栏
            HStack(spacing: 10) {
                Text("终端")
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabManager.tabs) { tab in
                            terminalTabChip(tab)
                        }
                        addTabButton
                    }
                    .padding(.vertical, 2)
                }
                Spacer()
            }

            // 终端内容
            if !tabManager.tabs.isEmpty {
                let activeID = tabManager.selectedTabID ?? tabManager.tabs.first?.id
                ZStack {
                    ForEach(tabManager.tabs) { tab in
                        let isActive = tab.id == activeID
                        HermesChatTerminalPanel(
                            session: tab.session,
                            theme: .black,
                            minHeight: 520,
                            tabTitle: tab.title,
                            isActive: isActive
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
                    Text("点击下方按钮打开终端会话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        tabManager.addTab()
                    } label: {
                        Label("打开终端", systemImage: "play.fill")
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
            if tabManager.tabs.isEmpty {
                tabManager.addTab()
            }
        }
        .alert(
            "关闭终端标签？",
            isPresented: Binding(
                get: { pendingCloseTabID != nil },
                set: { if !$0 { pendingCloseTabID = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingCloseTabID = nil
            }
            Button("关闭", role: .destructive) {
                guard let tabID = pendingCloseTabID else { return }
                tabManager.closeTab(id: tabID)
                pendingCloseTabID = nil
            }
        } message: {
            Text("关闭后该终端会话将被终止，无法恢复。")
        }
    }

    @ViewBuilder
    private func terminalTabChip(_ tab: HermesTerminalTabManager.Tab) -> some View {
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
            .help("关闭标签")
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

    private var addTabButton: some View {
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
        .help("新建终端标签")
    }
}

// MARK: - Hermes 详情容器（独立窗口入口）

/// ClawDetailWindow 会根据 `user.prefersHermesRuntime` 分流到此容器。
/// 管理侧边栏 Tab、profiles、gateway 操作等全部状态。
struct HermesDetailContainer: View {
    let user: ManagedUser
    var onDeleted: (() -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow

    @State private var mode: HermesDetailMode = .chat
    @StateObject private var chatTabManager = HermesChatTabManager()
    @StateObject private var configTabManager = HermesTerminalTabManager()
    @StateObject private var shellTabManager = HermesTerminalTabManager(titlePrefix: "终端", defaultCommand: ["zsh", "-l"])
    @State private var profiles: [AgentProfile] = []
    @State private var selectedProfileID: String? = nil
    @State private var isLoading = false
    @State private var actionError: String? = nil
    @State private var showHealthCheck = false
    @State private var showHermesSetup = false
    @State private var showTeamWizard = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteHomeOption: DeleteHomeOption = .deleteHome
    @State private var deleteAdminPassword = ""
    @State private var deleteError: String? = nil
    @State private var isDetailSidebarCollapsed = false
    @State private var showStopWithTerminalsAlert = false

    private var detailWindowTitle: String {
        user.fullName.isEmpty ? user.username : user.fullName
    }

    private var detailSidebarShowsLabels: Bool {
        !isDetailSidebarCollapsed
    }

    private var detailSidebarWidth: CGFloat {
        isDetailSidebarCollapsed ? 76 : UserDetailWindowLayout.expandedSidebarWidth
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                sidebar
                Divider()
                HermesDetailView(
                    user: user,
                    mode: mode,
                    chatTabManager: chatTabManager,
                    configTabManager: configTabManager,
                    shellTabManager: shellTabManager,
                    profiles: profiles,
                    selectedProfileID: selectedProfileID,
                    isConnected: helperClient.isConnected,
                    isLoading: isLoading,
                    runtimeVersion: user.hermesVersion,
                    runtimeRunning: user.isRunning,
                    runtimePID: user.pid,
                    cpuPercent: user.cpuPercent,
                    memRssMB: user.memRssMB,
                    homeDirBytes: user.openclawDirBytes > 0 ? user.openclawDirBytes : nil,
                    actionError: actionError,
                    onStartOrRestart: { Task { await startOrRestart() } },
                    onStop: {
                        if !shellTabManager.tabs.isEmpty {
                            showStopWithTerminalsAlert = true
                        } else {
                            Task { await stop() }
                        }
                    },
                    onOpenHealthCheck: { showHealthCheck = true },
                    onShowSetup: { showHermesSetup = true },
                    onRefresh: { Task { await refreshAll() } },
                    onSelectProfile: { id in Task { await selectProfile(id) } },
                    onCreateProfile: { name, emoji in Task { await createProfile(name: name, emoji: emoji) } },
                    onUpdateProfile: { id, name, emoji in Task { await updateProfile(id: id, name: name, emoji: emoji) } },
                    onDeleteProfile: { id in Task { await deleteProfile(id: id) } },
                    onShowChat: { mode = .chat }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(detailWindowTitle)
            .navigationSubtitle("@\(user.username)")
            .background(UserDetailWindowTitleBinder(title: detailWindowTitle, subtitle: "@\(user.username)"))
            .background(UserDetailWindowWidthBinder(shouldApplyHermesPreset: true))
        }
        .sheet(isPresented: $showHermesSetup) {
            HermesSetupSheet(user: user)
        }
        .sheet(isPresented: $showTeamWizard) {
            HermesTeamWizard(username: user.username)
        }
        .sheet(isPresented: $showHealthCheck) {
            DiagnosticsSheet(user: user, engineHint: "hermes")
        }
        .sheet(isPresented: $showDeleteConfirm) {
            deleteConfirmSheet
        }
        .alert(
            "有 \(shellTabManager.tabs.count) 个终端会话正在运行",
            isPresented: $showStopWithTerminalsAlert
        ) {
            Button("取消", role: .cancel) {}
            Button("关闭终端并停止", role: .destructive) {
                shellTabManager.closeAllTabs()
                Task { await stop() }
            }
        } message: {
            Text("停止 Hermes 将终止所有打开的终端会话，无法恢复。")
        }
        .task { await refreshAll() }
        .onAppear { pool.addLiveSnapshotConsumer() }
        .onDisappear { pool.removeLiveSnapshotConsumer() }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 折叠/展开
            HStack {
                if detailSidebarShowsLabels {
                    Text("概览")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDetailSidebarCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isDetailSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, detailSidebarShowsLabels ? 2 : 4)
            .frame(maxWidth: .infinity)

            // Hermes logo
            Image("HermesLogo")
                .resizable()
                .scaledToFit()
                .frame(width: detailSidebarShowsLabels ? 48 : 32, height: detailSidebarShowsLabels ? 48 : 32)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)

            // 默认角色
            if detailSidebarShowsLabels {
                let currentProfile = profiles.first(where: { $0.id == selectedProfileID })
                HStack(spacing: 4) {
                    let emoji = currentProfile?.emoji.isEmpty == false ? currentProfile!.emoji : "🤖"
                    Text("\(emoji) \(currentProfile?.name ?? "默认角色")")
                        .lineLimit(1)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.horizontal, 10)
            }

            Divider()
                .padding(.horizontal, detailSidebarShowsLabels ? 10 : 4)
                .padding(.vertical, 2)

            // 分组：当前角色
            if detailSidebarShowsLabels {
                Text(L10n.k("user.detail.sidebar.agent_section", fallback: "当前角色"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
            hermesSidebarButton(.chat, label: "会话", icon: "bubble.left.and.text.bubble.right")
            hermesSidebarButton(.profiles, label: "角色", icon: "theatermasks")
            hermesSidebarButton(.config, label: "配置", icon: "gearshape")

            Divider()
                .padding(.horizontal, detailSidebarShowsLabels ? 10 : 4)
                .padding(.vertical, 2)

            // 分组：实例
            if detailSidebarShowsLabels {
                Text(L10n.k("user.detail.sidebar.instance_section", fallback: "实例"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
            hermesSidebarButton(.files, label: L10n.k("user.detail.auto.files", fallback: "文件"), icon: "folder")
            hermesSidebarButton(.terminal, label: "终端", icon: "terminal")
            hermesSidebarButton(.processes, label: L10n.k("user.detail.auto.processes", fallback: "进程"), icon: "square.3.layers.3d")
            hermesSidebarButton(.logs, label: L10n.k("user.detail.auto.logs", fallback: "日志"), icon: "doc.text.magnifyingglass")

            Spacer()

            // 底部操作
            if detailSidebarShowsLabels {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                // 团队初始化向导入口（PR-4，≤3次点击：打开 Hermes 详情 → 点此按钮）
                Button {
                    showTeamWizard = true
                } label: {
                    Label("团队初始化", systemImage: "wand.and.stars")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除用户", systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(
            minWidth: detailSidebarWidth,
            idealWidth: detailSidebarWidth,
            maxWidth: detailSidebarWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(.bar)
    }

    @ViewBuilder
    private func hermesSidebarButton(_ tab: HermesDetailMode, label: String, icon: String) -> some View {
        let selected = mode == tab
        Button { mode = tab } label: {
            HStack(spacing: detailSidebarShowsLabels ? 8 : 0) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: 36, height: 36)
                if detailSidebarShowsLabels {
                    Text(label)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 14, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, detailSidebarShowsLabels ? 10 : 0)
            .padding(.vertical, detailSidebarShowsLabels ? 4 : 0)
            .frame(maxWidth: .infinity, alignment: detailSidebarShowsLabels ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 操作

    private func startOrRestart() async {
        isLoading = true
        actionError = nil
        do {
            if user.isRunning {
                try await helperClient.stopHermesGateway(username: user.username)
                try? await Task.sleep(for: .seconds(1))
            }
            try await helperClient.startHermesGateway(username: user.username)
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        } catch {
            actionError = error.localizedDescription
        }
        isLoading = false
    }

    private func stop() async {
        isLoading = true
        actionError = nil
        do {
            try await helperClient.stopHermesGateway(username: user.username)
            shellTabManager.closeAllTabs()
            try? await Task.sleep(for: .seconds(1))
            await refreshStatus()
        } catch {
            actionError = error.localizedDescription
        }
        isLoading = false
    }

    private func refreshAll() async {
        await refreshStatus()
        await loadProfiles()
    }

    private func refreshStatus() async {
        let status = await helperClient.getHermesGatewayStatus(username: user.username)
        user.isRunning = status.running
        user.pid = status.pid > 0 ? status.pid : nil
        user.hermesVersion = await helperClient.getHermesVersion(username: user.username)
    }

    private func loadProfiles() async {
        do {
            profiles = try await helperClient.listHermesProfiles(username: user.username)
        } catch {
            profiles = []
        }
        // 确保 main profile 存在
        if !profiles.contains(where: { $0.id == "main" }) {
            profiles.insert(AgentProfile(id: "main", name: "默认角色", emoji: "🤖", modelPrimary: nil, modelFallbacks: [], workspacePath: nil, isDefault: true), at: 0)
        }
        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = await helperClient.getHermesActiveProfile(username: user.username)
        }
    }

    private func selectProfile(_ id: String) async {
        selectedProfileID = id
        do {
            try await helperClient.setHermesActiveProfile(username: user.username, profileID: id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func createProfile(name: String, emoji: String) async {
        let profileID = nextAvailableProfileID(baseName: name)
        let newProfile = AgentProfile(
            id: profileID,
            name: name,
            emoji: emoji,
            modelPrimary: nil,
            modelFallbacks: [],
            workspacePath: nil,
            isDefault: false
        )
        do {
            try await helperClient.createHermesProfile(username: user.username, config: newProfile)
            await loadProfiles()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func nextAvailableProfileID(baseName: String) -> String {
        var chars: [Character] = []
        for ch in baseName.lowercased() {
            if ch.isASCII, (ch.isLetter || ch.isNumber) {
                chars.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" {
                chars.append("_")
            }
        }

        var normalized = String(chars)
        while normalized.contains("__") {
            normalized = normalized.replacingOccurrences(of: "__", with: "_")
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if normalized.isEmpty {
            normalized = "profile"
        }
        if let first = normalized.first,
           !(first.isASCII && (first.isLetter || first.isNumber)) {
            normalized = "p_\(normalized)"
        }
        if normalized.count > 64 {
            normalized = String(normalized.prefix(64))
        }

        let existing = Set(profiles.map(\.id))
        if !existing.contains(normalized) {
            return normalized
        }

        var index = 2
        while index < 10_000 {
            let suffix = "_\(index)"
            let maxPrefixLength = max(1, 64 - suffix.count)
            let candidate = String(normalized.prefix(maxPrefixLength)) + suffix
            if !existing.contains(candidate) {
                return candidate
            }
            index += 1
        }
        return "profile_\(Int(Date().timeIntervalSince1970))"
    }

    private func updateProfile(id: String, name: String, emoji: String) async {
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        profile.name = name
        profile.emoji = emoji
        do {
            try await helperClient.createHermesProfile(username: user.username, config: profile)
            await loadProfiles()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteProfile(id: String) async {
        do {
            try await helperClient.removeHermesProfile(username: user.username, profileID: id)
            await loadProfiles()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func openMaintenanceShell() {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: "命令行维护 · @\(user.username)",
            command: ["zsh", "-l"]
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }

    // MARK: - 删除确认

    private var deleteConfirmSheet: some View {
        VStack(spacing: 16) {
            Text("确认删除 @\(user.username)？")
                .font(.headline)
            Text("此操作不可撤销，将删除该用户的所有数据。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let deleteError {
                Text(deleteError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("取消", role: .cancel) {
                    showDeleteConfirm = false
                }
                .keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    Task { await performDelete() }
                }
                .disabled(isDeleting)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func performDelete() async {
        isDeleting = true
        deleteError = nil
        do {
            try await helperClient.deleteUser(
                username: user.username,
                keepHome: false,
                adminUser: NSUserName(),
                adminPassword: ""
            )
            showDeleteConfirm = false
            pool.removeUser(username: user.username)
            onDeleted?()
        } catch {
            deleteError = error.localizedDescription
        }
        isDeleting = false
    }
}
