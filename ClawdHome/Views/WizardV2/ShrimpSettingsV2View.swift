// ClawdHome/Views/WizardV2/ShrimpSettingsV2View.swift
// Shrimp 二次配置设置页面（v2）—— 6 Tab
//
// Tab:
// 1. agents    —— Agent 列表：增删改、每个 agent 的基础配置
// 2. im        —— IM 账号列表：添加/删除 Bot 账号（飞书/微信/...）
// 3. bindings  —— 绑定矩阵：agent ↔ IM 账号 / peer
// 4. model     —— 模型提供商配置（沿用现有模型管理 UI）
// 5. advanced  —— 高级：dmScope / session 隔离配置
// 6. plugins   —— OpenClaw 插件管理

import SwiftUI

struct ShrimpSettingsV2View: View {
    let user: ManagedUser

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .agents

    // 共享可变状态（从 openclaw.json 读取，保存时写回）
    @State private var config: ShrimpConfigV2 = .init()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isDirty = false

    // Sheets
    @State private var showAddBot = false
    @State private var showBindingForm = false
    @State private var editingBinding: IMBinding? = nil

    // Plugins
    @State private var installedPlugins: [String] = []
    @State private var isLoadingPlugins = false
    @State private var pluginInstallTarget = ""
    @State private var pluginError: String?

    enum SettingsTab: String, CaseIterable {
        case agents, im, bindings, model, advanced, plugins

        var title: String {
            switch self {
            case .agents:   return L10n.k("settings_v2.tab.agents", fallback: "Agents")
            case .im:       return L10n.k("settings_v2.tab.im", fallback: "IM 账号")
            case .bindings: return L10n.k("settings_v2.tab.bindings", fallback: "绑定矩阵")
            case .model:    return L10n.k("settings_v2.tab.model", fallback: "模型")
            case .advanced: return L10n.k("settings_v2.tab.advanced", fallback: "高级")
            case .plugins:  return L10n.k("settings_v2.tab.plugins", fallback: "插件")
            }
        }

        var icon: String {
            switch self {
            case .agents:   return "person.2"
            case .im:       return "ellipsis.message"
            case .bindings: return "link"
            case .model:    return "cpu"
            case .advanced: return "slider.horizontal.3"
            case .plugins:  return "puzzlepiece.extension"
            }
        }
    }

    var body: some View {
        NavigationStack {
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
                tabContent
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { loadConfig() }
    }

    // MARK: - Tab content

    private var tabContent: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.rawValue) { tab in
                    tabBarItem(tab)
                }
            }
            .padding(.horizontal)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            // Content
            Group {
                switch selectedTab {
                case .agents:   agentsTab
                case .im:       imTab
                case .bindings: bindingsTab
                case .model:    modelTab
                case .advanced: advancedTab
                case .plugins:  pluginsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            // Bottom save bar
            if isDirty {
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
        }
        .sheet(isPresented: $showAddBot) {
            AddBotSheet(username: user.username, agentId: "") { newAccount in
                if !config.imAccounts.contains(where: { $0.id == newAccount.id && $0.platform == newAccount.platform }) {
                    config.imAccounts.append(newAccount)
                    isDirty = true
                }
            }
        }
        .sheet(isPresented: $showBindingForm) {
            BindingFormSheet(
                agents: config.agents,
                imAccounts: config.imAccounts,
                existingBinding: editingBinding
            ) { saved in
                if let idx = config.bindings.firstIndex(where: { $0.id == saved.id }) {
                    config.bindings[idx] = saved
                } else {
                    config.bindings.append(saved)
                }
                isDirty = true
            }
        }
    }

    private func tabBarItem(_ tab: SettingsTab) -> some View {
        let selected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                Text(tab.title)
                    .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    // MARK: - Tab 1: Agents

    private var agentsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.k("settings_v2.agents.hint", fallback: "管理 Shrimp 下的 Agent 列表"))
                    .foregroundStyle(.secondary)
                    .font(.caption)

                AgentListEditor(agents: $config.agents) {
                    isDirty = true
                }
            }
            .padding(20)
        }
    }

    // MARK: - Tab 2: IM Accounts

    private var imTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.k("settings_v2.im.hint", fallback: "管理 IM Bot 账号，每个 Bot 对应一个飞书/微信应用"))
                    .foregroundStyle(.secondary)
                    .font(.caption)

                IMAccountListEditor(
                    accounts: $config.imAccounts,
                    username: user.username,
                    onAdd: { isDirty = true }
                )
            }
            .padding(20)
        }
    }

    // MARK: - Tab 3: Bindings

    private var bindingsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.k("settings_v2.bindings.hint", fallback: "配置 Agent ↔ IM 账号的路由绑定"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button(action: {
                    editingBinding = nil
                    showBindingForm = true
                }) {
                    Label(L10n.k("settings_v2.bindings.add", fallback: "添加绑定"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if config.bindings.isEmpty {
                Text(L10n.k("settings_v2.bindings.empty", fallback: "暂无绑定"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(config.bindings) { binding in
                        bindingRow(binding)
                    }
                    .onDelete { idx in
                        config.bindings.remove(atOffsets: idx)
                        isDirty = true
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func bindingRow(_ binding: IMBinding) -> some View {
        let agent = config.agents.first { $0.id == binding.agentId }
        let account = config.imAccounts.first { $0.id == binding.accountId }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent?.displayName ?? binding.agentId)
                    .fontWeight(.medium)
                Text("→ \(account?.platform.displayName ?? binding.channel) · \(account?.displayName ?? binding.accountId ?? "通配")"
                     + (binding.peer.map { " · \($0.kind.rawValue):\($0.id)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: {
                editingBinding = binding
                showBindingForm = true
            }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tab 4: Model

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
                    Text("自动（推荐）").tag(Optional<DmScope>.none)
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
        }
        .formStyle(.grouped)
        .padding()
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
            let jsonDict = await helperClient.getConfigJSON(username: user.username)
            await MainActor.run {
                isLoading = false
                guard !jsonDict.isEmpty else { return }
                if let data = try? JSONSerialization.data(withJSONObject: jsonDict),
                   let parsed = try? JSONDecoder().decode(ShrimpConfigV2.self, from: data) {
                    config = parsed
                }
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
}
