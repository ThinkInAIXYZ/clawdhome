// ClawdHome/Views/SkillsTabView.swift

import AppKit
import SwiftUI

// MARK: - Skills Tab
// 参考 openclaw/apps/macos/Sources/OpenClaw/SkillsSettings.swift
// 参考 openclaw commit 505b980f63 (2026-04-07)

struct SkillsTabView: View {
    let username: String
    let gatewayURL: String?
    var agentId: String? = nil
    @Environment(GatewayHub.self) private var hub

    private var isConnected: Bool {
        hub.connectedUsernames.contains(username)
    }

    var body: some View {
        SkillsTabContent(store: hub.skillsStore(for: username), username: username, gatewayURL: gatewayURL)
            .task(id: isConnected) {
                guard isConnected else { return }
                await hub.ensureSkillsStarted(for: username)
            }
    }
}

// MARK: 筛选枚举

enum SkillsFilter: String, CaseIterable, Identifiable {
    case all, ready, needsSetup, disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.k("views.detail.skills_filter_all", fallback: "全部")
        case .ready: return L10n.k("views.detail.skills_filter_ready", fallback: "就绪")
        case .needsSetup: return L10n.k("views.detail.skills_filter_needs_setup", fallback: "需配置")
        case .disabled: return L10n.k("views.detail.skills_filter_disabled", fallback: "已禁用")
        }
    }
}

// MARK: 环境变量编辑状态

struct SkillEnvEditorState: Identifiable {
    let skillKey: String
    let skillName: String
    let envKey: String
    let isPrimary: Bool
    let homepage: String?

    var id: String { "\(skillKey)::\(envKey)" }
}

// MARK: SkillsTabContent

struct SkillsTabContent: View {
    let store: GatewaySkillsStore
    let username: String
    let gatewayURL: String?
    @Environment(HelperClient.self) private var helperClient
    @State private var filter: SkillsFilter = .all
    @State private var envEditor: SkillEnvEditorState?
    @State private var showSkillsMarket = false
    @State private var skillsMarketURL: URL?
    @State private var isPreparingSkillsMarket = false

    private var filteredSkills: [GatewaySkillStatus] {
        let base = store.skills.filter { skill in
            switch filter {
            case .all: return true
            case .ready: return !skill.disabled && skill.eligible
            case .needsSetup: return !skill.disabled && !skill.eligible
            case .disabled: return skill.disabled
            }
        }
        if store.searchText.isEmpty { return base }
        let q = store.searchText.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills").font(.headline)
                    Text(L10n.k("views.detail.skills_auto_enable_hint", fallback: "满足依赖条件（二进制、环境变量、配置）后自动启用"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isPreparingSkillsMarket {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.k("views.detail.skills_preparing", fallback: "准备中…")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await openSkillsMarket() }
                    } label: {
                        Label(L10n.k("views.detail.skills_get_more", fallback: "获取更多 Skills"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if store.isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
                } else {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label(L10n.k("views.detail.skills_refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Picker(L10n.k("views.detail.skills_filter", fallback: "筛选"), selection: $filter) {
                    ForEach(SkillsFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 90)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.k("views.detail.skills_search", fallback: "搜索 Skills…"), text: Bindable(store).searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.bar)

            Divider()

            // 状态消息
            if let msg = store.statusMessage {
                HStack {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.statusMessage = nil } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.06))
            }

            // 内容
            if let err = store.error {
                ContentUnavailableView(err, systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.skills.isEmpty && !store.isLoading {
                ContentUnavailableView(L10n.k("views.detail.skills_empty", fallback: "暂无 Skills"), systemImage: "star.leadinghalf.filled")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSkills.isEmpty {
                ContentUnavailableView(L10n.k("views.detail.skills_no_match", fallback: "没有匹配的 Skills"), systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSkills) { skill in
                    SkillItemRow(skill: skill, store: store, onSetEnv: { envKey, isPrimary in
                        envEditor = SkillEnvEditorState(
                            skillKey: skill.skillKey,
                            skillName: skill.name,
                            envKey: envKey,
                            isPrimary: isPrimary,
                            homepage: skill.homepage
                        )
                    })
                }
                .listStyle(.plain)
            }
        }
        .task { await store.refresh() }
        .sheet(item: $envEditor) { editor in
            SkillEnvEditorSheet(editor: editor) { value in
                Task {
                    if editor.isPrimary {
                        await store.setApiKey(skillKey: editor.skillKey, value: value)
                    } else {
                        await store.setEnvVar(skillKey: editor.skillKey, envKey: editor.envKey, value: value)
                    }
                }
            }
        }
        .sheet(isPresented: $showSkillsMarket) {
            if let url = skillsMarketURL {
                SkillsMarketSheetView(url: url)
            } else {
                ContentUnavailableView(L10n.k("views.detail.skills_store_error", fallback: "无法打开 Skills 商店"), systemImage: "network")
                    .frame(minWidth: 800, minHeight: 520)
            }
        }
    }

    private func openSkillsMarket() async {
        isPreparingSkillsMarket = true
        defer { isPreparingSkillsMarket = false }

        let freshGatewayURL = await helperClient.getGatewayURL(username: username)
        let candidates = [freshGatewayURL, gatewayURL ?? ""].filter { !$0.isEmpty }
        for raw in candidates {
            if let target = makeSkillsMarketURL(from: raw) {
                skillsMarketURL = target
                showSkillsMarket = true
                return
            }
        }
        store.statusMessage = L10n.k("views.detail.skills_no_token", fallback: "未获取到可用 Token，请先确认 Gateway 已启动并就绪。")
    }

    private func makeSkillsMarketURL(from rawURL: String) -> URL? {
        guard var components = URLComponents(string: rawURL) else { return nil }
        guard let fragment = components.fragment, fragment.hasPrefix("token=") else { return nil }
        let token = String(fragment.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        components.scheme = components.scheme ?? "http"
        components.host = components.host ?? "127.0.0.1"
        components.port = components.port ?? 18525
        components.path = "/skills"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        components.fragment = "token=\(token)"
        return components.url
    }
}

struct SkillsMarketSheetView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var store = EmbeddedGatewayConsoleStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.k("views.detail.skills_store_title", fallback: "Skills 商店"))
                    .font(.headline)
                Spacer()
                Button(L10n.k("views.detail.skills_store_reload", fallback: "重载")) {
                    store.reloadCurrent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(L10n.k("views.detail.skills_store_open_browser", fallback: "浏览器打开")) {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(L10n.k("views.detail.skills_store_close", fallback: "关闭")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            EmbeddedGatewayConsoleView(url: url, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 720)
        .onDisappear {
            store.invalidateLoadedURL()
        }
    }
}

// MARK: SkillItemRow

struct SkillItemRow: View {
    let skill: GatewaySkillStatus
    let store: GatewaySkillsStore
    let onSetEnv: (_ envKey: String, _ isPrimary: Bool) -> Void
    @State private var showRemoveConfirm = false

    private var isBusy: Bool { store.isBusy(skill: skill) }
    private var pendingLabel: String { store.pendingOps[skill.skillKey] ?? "" }
    private var requirementsMet: Bool { skill.missing.isEmpty }

    /// 有 missing bins 且存在 install option 时可安装
    private var installOptions: [GatewaySkillInstallOption] {
        guard !skill.missing.bins.isEmpty else { return [] }
        let missingSet = Set(skill.missing.bins)
        return skill.install.filter { opt in
            opt.bins.isEmpty || !missingSet.isDisjoint(with: opt.bins)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Emoji
            Text(skill.emoji ?? "✨").font(.title2)

            // 信息区
            VStack(alignment: .leading, spacing: 4) {
                // 名称
                Text(skill.name).font(.headline)

                // 描述
                Text(skill.description)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)

                // 标签行：来源 + 主页链接
                HStack(spacing: 8) {
                    CronTagBadge(skill.sourceLabel)
                    if let urlStr = skill.homepage,
                       let url = URL(string: urlStr),
                       url.scheme == "http" || url.scheme == "https" {
                        Link(destination: url) {
                            Label(L10n.k("views.detail.skill_website", fallback: "网站"), systemImage: "link")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.link)
                    }
                }

                // 禁用状态提示
                if skill.disabled {
                    Text(L10n.k("views.detail.skill_disabled_in_config", fallback: "已在配置中禁用"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 缺失依赖提示（仅当没有安装选项或有非 bin 缺失时）
                if !skill.disabled, !requirementsMet, shouldShowMissingSummary {
                    missingSummary
                }

                // 配置检查
                if !skill.configChecks.isEmpty {
                    configChecksView
                }

                // 环境变量设置按钮
                if !skill.missing.env.isEmpty {
                    envActionRow
                }
            }

            Spacer(minLength: 0)

            // 右侧操作区
            trailingActions
        }
        .padding(.vertical, 6)
    }

    // MARK: 缺失摘要

    private var shouldShowMissingBins: Bool {
        !skill.missing.bins.isEmpty && installOptions.isEmpty
    }

    private var shouldShowMissingSummary: Bool {
        shouldShowMissingBins || !skill.missing.env.isEmpty || !skill.missing.config.isEmpty
    }

    private var missingSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if shouldShowMissingBins {
                Text(L10n.f("views.detail.skill_missing_bins", fallback: "缺少二进制: %@", skill.missing.bins.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !skill.missing.env.isEmpty {
                Text(L10n.f("views.detail.skill_missing_env", fallback: "缺少环境变量: %@", skill.missing.env.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !skill.missing.config.isEmpty {
                Text(L10n.f("views.detail.skill_missing_config", fallback: "需要配置: %@", skill.missing.config.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 配置检查

    private var configChecksView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(skill.configChecks) { check in
                HStack(spacing: 4) {
                    Image(systemName: check.satisfied ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(check.satisfied ? .green : .secondary)
                        .font(.caption)
                    Text(check.path).font(.caption)
                }
            }
        }
    }

    // MARK: 环境变量按钮

    private var envActionRow: some View {
        HStack(spacing: 6) {
            ForEach(skill.missing.env, id: \.self) { envKey in
                let isPrimary = envKey == skill.primaryEnv
                Button(isPrimary ? L10n.k("views.detail.skill_set_api_key", fallback: "设置 API Key") : L10n.f("views.detail.skill_set_env", fallback: "设置 %@", envKey)) {
                    onSetEnv(envKey, isPrimary)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isBusy)
            }
        }
    }

    // MARK: 右侧操作

    @ViewBuilder
    private var trailingActions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isBusy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(pendingLabel).font(.caption).foregroundStyle(.secondary)
                }
            } else if !installOptions.isEmpty {
                // 有可安装选项 → 显示安装按钮
                ForEach(installOptions) { option in
                    Button(L10n.k("views.detail.skill_install", fallback: "安装")) {
                        Task { await store.install(skill: skill, option: option) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help(option.label)
                }
            } else {
                // 已安装 → 启用/禁用 Toggle
                Toggle("", isOn: Binding(
                    get: { !skill.disabled },
                    set: { enabled in
                        Task { await store.toggleEnabled(skillKey: skill.skillKey, enabled: enabled) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isBusy || !requirementsMet)

                // 卸载按钮（仅非内置 skill）
                if !skill.isBundled {
                    Button(L10n.k("views.detail.skill_uninstall", fallback: "卸载")) {
                        showRemoveConfirm = true
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .foregroundStyle(.secondary)
                    .confirmationDialog(
                        L10n.f("views.detail.skill_uninstall_confirm", fallback: "卸载 %@？", skill.name),
                        isPresented: $showRemoveConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.k("views.detail.skill_uninstall", fallback: "卸载"), role: .destructive) {
                            Task { await store.remove(skillKey: skill.skillKey) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: 环境变量编辑 Sheet

struct SkillEnvEditorSheet: View {
    let editor: SkillEnvEditorState
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.isPrimary ? L10n.k("views.detail.skill_set_api_key", fallback: "设置 API Key") : L10n.k("views.detail.skill_set_env_var", fallback: "设置环境变量"))
                .font(.headline)
            Text("Skill: \(editor.skillName)")
                .font(.subheadline).foregroundStyle(.secondary)

            if let url = homepageUrl {
                Link(L10n.k("views.detail.skill_get_key", fallback: "获取密钥 →"), destination: url).font(.caption)
            }

            SecureField(editor.envKey, text: $value)
                .textFieldStyle(.roundedBorder)

            Text(L10n.f("views.detail.skill_save_hint", fallback: "保存至 openclaw.json 中 skills.entries.%@", editor.skillKey))
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Button(L10n.k("views.detail.skill_cancel", fallback: "取消")) { dismiss() }
                Spacer()
                Button(L10n.k("views.detail.skill_save", fallback: "保存")) {
                    onSave(value)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var homepageUrl: URL? {
        guard let raw = editor.homepage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
