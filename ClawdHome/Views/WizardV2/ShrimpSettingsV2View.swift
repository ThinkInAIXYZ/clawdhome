// ClawdHome/Views/WizardV2/ShrimpSettingsV2View.swift
// Shrimp 二次配置设置页面（v2）—— 4 Tab
//
// Tab:
// 1. agents    —— Agent 卡片：增删改 + 每个 agent 的模型 picker + IM 绑定列表
//                 （由 AgentBotListEditor 共用组件渲染；原 IM 账号 / 绑定矩阵 tab 合并进此处）
// 2. model     —— Shrimp 模型池（共享 ModelConfigWizard）
// 3. advanced  —— 高级：dmScope / session 隔离配置
// 4. plugins   —— OpenClaw 插件管理

import SwiftUI

struct ShrimpSettingsV2View: View {
    let user: ManagedUser
    let includeAgentsTab: Bool

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab

    init(user: ManagedUser, initialTab: SettingsTab = .agents, includeAgentsTab: Bool = true) {
        self.user = user
        self.includeAgentsTab = includeAgentsTab
        _selectedTab = State(initialValue: initialTab)
    }

    // 共享可变状态（从 openclaw.json 读取，保存时写回）
    @State private var config: ShrimpConfigV2 = .init()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isDirty = false

    // Plugins
    @State private var installedPlugins: [String] = []
    @State private var isLoadingPlugins = false
    @State private var pluginInstallTarget = ""
    @State private var pluginError: String?
    @State private var browserAccountStatus: BrowserAccountStatus?
    @State private var opencliVersion: String?
    @State private var isInstallingBrowserTool = false
    @State private var isInstallingOpenCLI = false
    @State private var isRunningOpenCLIDoctor = false
    @State private var dependencyMessage: String?

    enum SettingsTab: String, CaseIterable {
        case agents, model, advanced

        var title: String {
            switch self {
            case .agents:   return L10n.k("settings_v2.tab.agents", fallback: "Agents")
            case .model:    return L10n.k("settings_v2.tab.model", fallback: "模型")
            case .advanced: return L10n.k("settings_v2.tab.advanced", fallback: "高级")
            }
        }

        var icon: String {
            switch self {
            case .agents:   return "person.2"
            case .model:    return "cpu"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 12) {
                    Text(err).foregroundStyle(.red)
                    Button(L10n.k("common.retry", fallback: "重试")) { loadConfig() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                splitContent
            }
        }
        .onAppear {
            if !visibleTabs.contains(selectedTab), let first = visibleTabs.first {
                selectedTab = first
            }
            loadConfig()
        }
    }

    // MARK: - 内嵌布局：左侧二级 sidebar + 右侧 content

    private var splitContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 二级 sidebar
                secondarySidebar
                Divider()
                // 右侧 content
                Group {
                    switch selectedTab {
                    case .agents:   agentsTab
                    case .model:    modelTab
                    case .advanced: advancedTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 底部保存条（dirty 时出现）
            if isDirty {
                Divider()
                bottomSaveBar
            }
        }
    }

    private var secondarySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleTabs, id: \.rawValue) { tab in
                sidebarRow(tab)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 160, alignment: .topLeading)
        .background(.bar)
    }

    private var visibleTabs: [SettingsTab] {
        includeAgentsTab ? SettingsTab.allCases : [.model, .advanced]
    }

    @ViewBuilder
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = selectedTab == tab
        Button { selectedTab = tab } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 20, height: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bottomSaveBar: some View {
        HStack {
            if let err = saveError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            Spacer()
            Button(L10n.k("common.discard", fallback: "放弃修改")) {
                loadConfig()
                isDirty = false
            }
            .buttonStyle(.plain)
            Button(isSaving ? L10n.k("common.saving", fallback: "保存中…") : L10n.k("common.save", fallback: "保存")) {
                saveConfig()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tab 1: Agents（agent 卡片 + 模型 picker + IM 绑定 一站式管理）

    private var agentsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.k("settings_v2.agents.hint",
                            fallback: "管理 Agent + 每个 agent 的模型与 IM 绑定。一个 IM 入口对应一个 Agent；解绑同时移除账号。"))
                    .foregroundStyle(.secondary)
                    .font(.caption)

                AgentBotListEditor(
                    agents: $config.agents,
                    imAccounts: $config.imAccounts,
                    bindings: $config.bindings,
                    username: user.username,
                    showModelPicker: true,
                    allowAddAgent: true,
                    onChange: { isDirty = true }
                )
            }
            .padding(20)
        }
    }

    // MARK: - Tab 2: Model

    /// 模型池管理 — 复用 ModelConfigWizard，让向导 / 详情页 / 设置三处共享同一套交互。
    private var modelTab: some View {
        ModelConfigWizard(user: user, presentation: .settingsPane)
            .padding(.horizontal, 20)
    }

    // MARK: - Tab 5: Advanced

    private var advancedTab: some View {
        Form {
            Section(L10n.k("settings_v2.advanced.dm_scope", fallback: "会话隔离（dmScope）")) {
                Picker(L10n.k("settings_v2.advanced.dm_scope_label", fallback: "dmScope"),
                       selection: $config.sessionDmScope) {
                    Text(L10n.k("settings_v2.dm_scope.auto", fallback: "自动（推荐）")).tag(Optional<DmScope>.none)
                    Text("main").tag(Optional(DmScope.main))
                    Text("per-peer").tag(Optional(DmScope.perPeer))
                    Text("per-channel-peer").tag(Optional(DmScope.perChannelPeer))
                    Text("per-account-channel-peer").tag(Optional(DmScope.perAccountChannelPeer))
                }
                .onChange(of: config.sessionDmScope) { _, _ in isDirty = true }

                if config.needsAccountScopedDmSession {
                    Label(L10n.k("settings_v2.advanced.multi_account_warning",
                                 fallback: "检测到多账号，dmScope 将自动设为 per-account-channel-peer"),
                          systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }

            Section("依赖工具") {
                dependencyRow(
                    title: "浏览器工具",
                    subtitle: "用于 OAuth 登录、网页自动化与授权回调。",
                    statusText: browserAccountStatus?.toolInstalled == true ? "已安装" : "未安装",
                    statusColor: browserAccountStatus?.toolInstalled == true ? .green : .secondary,
                    actionTitle: isInstallingBrowserTool ? "安装中…" : "安装/重装"
                ) {
                    installBrowserTool()
                }
                .disabled(isInstallingBrowserTool || isInstallingOpenCLI || isRunningOpenCLIDoctor)

                dependencyRow(
                    title: "OpenCLI",
                    subtitle: "统一自动化 CLI，便于后续网站工具编排与执行。",
                    statusText: opencliVersion.map { "已安装（\($0)）" } ?? "未安装",
                    statusColor: opencliVersion == nil ? .secondary : .green,
                    actionTitle: isInstallingOpenCLI ? "安装中…" : "安装/升级"
                ) {
                    installOpenCLI()
                }
                .disabled(isInstallingBrowserTool || isInstallingOpenCLI || isRunningOpenCLIDoctor)

                HStack(spacing: 10) {
                    Button(isRunningOpenCLIDoctor ? "检测中…" : "运行 OpenCLI Doctor") {
                        runOpenCLIDoctor()
                    }
                    .disabled(isInstallingBrowserTool || isInstallingOpenCLI || isRunningOpenCLIDoctor || opencliVersion == nil)

                    Spacer()
                    Button("刷新状态") {
                        refreshDependencyToolsStatus()
                    }
                    .disabled(isInstallingBrowserTool || isInstallingOpenCLI || isRunningOpenCLIDoctor)
                }

                if let dependencyMessage {
                    Text(dependencyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshDependencyToolsStatus()
        }
    }

    private func dependencyRow(
        title: String,
        subtitle: String,
        statusText: String,
        statusColor: Color,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.12))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tab 6: Plugins

    private var pluginsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.k("settings_v2.plugins.hint", fallback: "管理 OpenClaw 插件"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button(action: { loadPlugins() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoadingPlugins)
            }

            if isLoadingPlugins {
                ProgressView()
            } else if installedPlugins.isEmpty {
                Text(L10n.k("settings_v2.plugins.empty", fallback: "暂无已安装插件"))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(installedPlugins, id: \.self) { plugin in
                    HStack {
                        Text(plugin)
                        Spacer()
                        Button(action: { removePlugin(plugin) }) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                }
            }

            HStack {
                TextField(L10n.k("settings_v2.plugins.add_placeholder", fallback: "@scope/plugin-name"), text: $pluginInstallTarget)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.k("settings_v2.plugins.install", fallback: "安装")) {
                    installPlugin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pluginInstallTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let err = pluginError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(20)
        .onAppear { loadPlugins() }
    }

    // MARK: - Data loading

    private func loadConfig() {
        isLoading = true
        loadError = nil
        Task {
            // openclaw.json 的实际结构是嵌套的（agents.list / channels.<id>.accounts / bindings[]…），
            // 不能直接 JSONDecoder 解码到扁平 ShrimpConfigV2，必须走 parseShrimpConfig 平铺逻辑。
            let jsonDict = await helperClient.getConfigJSON(username: user.username)
            await MainActor.run {
                isLoading = false
                guard !jsonDict.isEmpty else { return }
                config = OpenclawConfigSerializerV2.parseShrimpConfig(jsonDict)
            }
        }
    }

    private func saveConfig() {
        isSaving = true
        saveError = nil
        let username = user.username
        var cfg = config
        // 自动修正 dmScope
        if cfg.needsAccountScopedDmSession {
            cfg.sessionDmScope = .perAccountChannelPeer
        }
        Task {
            do {
                let data = try JSONEncoder().encode(cfg)
                let configJSON = String(data: data, encoding: .utf8) ?? "{}"
                let (ok, err) = await helperClient.applyV2Config(username: username, configJSON: configJSON)
                await MainActor.run {
                    isSaving = false
                    if ok {
                        isDirty = false
                    } else {
                        saveError = err ?? "保存失败"
                    }
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Plugin actions

    private func loadPlugins() {
        isLoadingPlugins = true
        Task {
            let (json, _) = await helperClient.listOpenclawPlugins(username: user.username)
            await MainActor.run {
                isLoadingPlugins = false
                if let j = json, let data = j.data(using: .utf8),
                   let list = try? JSONDecoder().decode([String].self, from: data) {
                    installedPlugins = list
                }
            }
        }
    }

    private func installPlugin() {
        let spec = pluginInstallTarget.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return }
        pluginError = nil
        Task {
            let (ok, err) = await helperClient.installOpenclawPlugin(username: user.username, packageSpec: spec)
            await MainActor.run {
                if ok {
                    pluginInstallTarget = ""
                    loadPlugins()
                } else {
                    pluginError = err
                }
            }
        }
    }

    private func removePlugin(_ spec: String) {
        pluginError = nil
        Task {
            let (ok, err) = await helperClient.removeOpenclawPlugin(username: user.username, packageSpec: spec)
            await MainActor.run {
                if ok {
                    loadPlugins()
                } else {
                    pluginError = err
                }
            }
        }
    }

    private func refreshDependencyToolsStatus() {
        Task {
            let status = await helperClient.getBrowserAccountStatus(username: user.username)
            let version = await helperClient.getOpenCLIVersion(username: user.username)
            await MainActor.run {
                browserAccountStatus = status
                opencliVersion = version
            }
        }
    }

    private func installBrowserTool() {
        isInstallingBrowserTool = true
        dependencyMessage = nil
        Task {
            do {
                _ = try await helperClient.installBrowserAccountTool(username: user.username)
                await MainActor.run {
                    dependencyMessage = "浏览器工具安装完成。"
                }
            } catch {
                await MainActor.run {
                    dependencyMessage = "浏览器工具安装失败：\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                isInstallingBrowserTool = false
            }
            refreshDependencyToolsStatus()
        }
    }

    private func installOpenCLI() {
        isInstallingOpenCLI = true
        dependencyMessage = nil
        Task {
            do {
                try await helperClient.installOpenCLI(username: user.username)
                await MainActor.run {
                    dependencyMessage = "OpenCLI 安装完成。"
                }
            } catch {
                await MainActor.run {
                    dependencyMessage = "OpenCLI 安装失败：\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                isInstallingOpenCLI = false
            }
            refreshDependencyToolsStatus()
        }
    }

    private func runOpenCLIDoctor() {
        isRunningOpenCLIDoctor = true
        dependencyMessage = nil
        Task {
            let (ok, output) = await helperClient.runOpenCLIDoctor(username: user.username)
            await MainActor.run {
                dependencyMessage = ok ? "Doctor 通过：\(output.trimmingCharacters(in: .whitespacesAndNewlines))" : "Doctor 失败：\(output)"
                isRunningOpenCLIDoctor = false
            }
        }
    }
}
