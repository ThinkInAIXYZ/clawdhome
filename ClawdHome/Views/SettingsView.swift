// ClawdHome/Views/SettingsView.swift

import SwiftUI
import AppKit
import CFNetwork

struct SettingsView: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label(L10n.k("views.settings_view.text_aa05fd09", fallback: "通用"), systemImage: "gearshape") }
                .tag(0)

            AppLogTab()
                .tabItem { Label(L10n.k("views.settings_view.app", fallback: "App 日志"), systemImage: "app.badge") }
                .tag(1)

            HelperLogTab()
                .tabItem { Label(L10n.k("views.settings_view.helper", fallback: "Helper 日志"), systemImage: "terminal") }
                .tag(2)

            AboutTab()
                .tabItem { Label(L10n.k("views.settings_view.about", fallback: "关于"), systemImage: "info.circle") }
                .tag(3)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 400)
    }
}

// MARK: - 通用设置

private struct GeneralSettingsTab: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @State private var gatewayAutostart = true
    @State private var showGatewayActivationPreview = false
    @AppStorage("clawPoolShowCurrentAdmin") private var showCurrentAdminInPool = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage("proxyEnabled") private var proxyEnabled = false
    @AppStorage("proxyScheme") private var proxySchemeRaw = ProxyScheme.http.rawValue
    @AppStorage("proxyHost") private var proxyHost = ""
    @AppStorage("proxyPort") private var proxyPort = "7890"
    @AppStorage("proxyUsername") private var proxyUsername = ""
    @AppStorage("proxyPassword") private var proxyPassword = ""
    @AppStorage("proxyNoProxy") private var proxyNoProxy = "localhost,127.0.0.1"
    @AppStorage("debugForceEmptyClawPool") private var debugForceEmptyClawPool = false
    @State private var isApplyingProxy = false
    @State private var proxyMessage: String? = nil
    @State private var proxyError: String? = nil
    @State private var proxyProgressText: String? = nil
    @State private var proxyExpanded = false

    private enum ProxyScheme: String, CaseIterable, Identifiable {
        case http
        case socks5
        var id: String { rawValue }
        var title: String {
            switch self {
            case .http: return "HTTP"
            case .socks5: return "SOCKS5"
            }
        }
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { appLanguageRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(L10n.k("views.settings_view.language", fallback: "语言")) {
                Picker(L10n.k("views.settings_view.language_4c0678", fallback: "显示语言"), selection: appLanguageBinding) {
                    Text(L10n.k("views.settings_view.follow_system", fallback: "跟随系统")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text(L10n.k("views.settings_view.simplified_chinese", fallback: "简体中文")).tag(AppLanguage.chineseSimplified)
                }
                Text(L10n.k("views.settings_view.text_6f04bbdd", fallback: "切换后会立即作用到所有窗口。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.k("views.settings_view.gateway", fallback: "Gateway")) {
                Toggle(L10n.k("views.settings_view.autostart_all_gateway_on_boot", fallback: "开机自动启动所有虾的 Gateway"), isOn: $gatewayAutostart)
                    .onChange(of: gatewayAutostart) { _, newValue in
                        Task { try? await helperClient.setGatewayAutostart(enabled: newValue) }
                    }
                Text(L10n.k("views.settings_view.mac_helper_gateway_account", fallback: "Mac 开机后，Helper 会自动为所有已初始化的虾启动 Gateway，无需登录管理员账户。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup(L10n.k("views.settings_view.proxy", fallback: "代理"), isExpanded: $proxyExpanded) {
                Toggle(L10n.k("views.settings_view.enable_proxy_for_shrimp_users", fallback: "为虾用户启用代理"), isOn: $proxyEnabled)

                Group {
                    Picker(L10n.k("views.settings_view.proxy_scheme", fallback: "协议"), selection: $proxySchemeRaw) {
                        ForEach(ProxyScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    LabeledContent(L10n.k("views.settings_view.proxy_server", fallback: "服务器")) {
                        HStack(spacing: 8) {
                            TextField(
                                "",
                                text: $proxyHost,
                                prompt: Text(L10n.k("views.settings_view.proxy_host_prompt", fallback: "地址（例如 127.0.0.1）"))
                            )
                                .textFieldStyle(.roundedBorder)
                            Text(":")
                                .foregroundStyle(.secondary)
                            TextField("", text: $proxyPort, prompt: Text(L10n.k("views.settings_view.proxy_port", fallback: "端口")))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }
                    }

                    LabeledContent(L10n.k("views.settings_view.proxy_authentication", fallback: "认证")) {
                        HStack(spacing: 8) {
                            TextField("", text: $proxyUsername, prompt: Text(L10n.k("views.settings_view.proxy_username_optional", fallback: "用户名（可选）")))
                                .textFieldStyle(.roundedBorder)
                            SecureField("", text: $proxyPassword, prompt: Text(L10n.k("views.settings_view.proxy_password_optional", fallback: "密码（可选）")))
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    TextField(
                        L10n.k("views.settings_view.proxy_bypass", fallback: "绕过代理"),
                        text: $proxyNoProxy,
                        prompt: Text(L10n.k("views.settings_view.proxy_bypass_prompt", fallback: "用逗号分隔，例如 localhost,127.0.0.1"))
                    )
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(!proxyEnabled)
                .opacity(proxyEnabled ? 1.0 : 0.6)

                LabeledContent("") {
                    HStack {
                        Button {
                            loadFromSystemProxy()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "macwindow")
                                Text(L10n.k("views.settings_view.load_system_proxy", fallback: "读取系统代理"))
                            }
                        }
                        
                        Spacer()
                        
                        Button {
                            Task { await applyProxyToAllUsers() }
                        } label: {
                            HStack(spacing: 4) {
                                if isApplyingProxy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                                Text(isApplyingProxy ? "应用中…" : "应用到所有虾")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplyingProxy || !helperClient.isConnected || (proxyEnabled && !isProxyInputValid))
                    }
                }

                Text(
                    L10n.k(
                        "views.settings_view.proxy_apply_hint",
                        fallback: "将写入虾用户环境变量：HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY（含小写同名），并重启运行中的 Gateway。"
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let proxyProgressText {
                    HStack(spacing: 8) {
                        if isApplyingProxy { ProgressView().controlSize(.small) }
                        Text(proxyProgressText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let proxyMessage {
                    Text(proxyMessage).font(.caption).foregroundStyle(.green)
                }
                if let proxyError {
                    Text(proxyError).font(.caption).foregroundStyle(.red)
                }
                }
            }

            Section(L10n.k("views.settings_view.text_ffa993d5", fallback: "虾塘显示")) {
                Toggle(L10n.k("views.settings_view.current_account", fallback: "显示当前管理员账户（不推荐）"), isOn: $showCurrentAdminInPool)
                if showCurrentAdminInPool {
                    Label(L10n.k("views.settings_view.account_configuration", fallback: "风险提示：管理员账户权限高，误操作会影响系统级配置。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L10n.k("views.settings_view.clawdhome_account_delete_account", fallback: "安全保障：ClawdHome 已对管理员账户禁用部分高风险动作（如重置/删除），但仍建议日常只使用标准用户账户。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.k("views.settings_view.account", fallback: "默认隐藏管理员账户，仅展示标准用户。需要排障时可临时开启。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if DEBUG
            Section(L10n.k("settings.debug.section", fallback: "调试")) {
                Toggle(L10n.k("settings.debug.force_empty_pool", fallback: "强制显示空虾塘"), isOn: $debugForceEmptyClawPool)
                Text(L10n.k("settings.debug.force_empty_pool_hint", fallback: "仅影响当前 App 的虾塘展示，用于预览空状态，不会删除或修改任何真实虾数据。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(L10n.k("settings.debug.preview_gateway_activation", fallback: "预览 Gateway 启动页")) {
                    showGatewayActivationPreview = true
                }
                .buttonStyle(.bordered)

                Text(L10n.k("settings.debug.preview_gateway_activation_hint", fallback: "打开独立预览窗口查看“正在启动 OpenClaw Gateway…”动画，不会触发真实启动。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            HelperStatusSection()

            AppLockSection()
        }
        .formStyle(.grouped)
#if DEBUG
        .sheet(isPresented: $showGatewayActivationPreview) {
            DebugGatewayActivationPreviewSheet()
        }
#endif
        .task {
            if helperClient.isConnected {
                gatewayAutostart = await helperClient.getGatewayAutostart()
            }
        }
    }

    private var isProxyInputValid: Bool {
        !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && Int(proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private func loadFromSystemProxy() {
        guard let raw = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            proxyError = "无法读取系统代理配置。"
            proxyMessage = nil
            return
        }
        func intFlag(_ key: String) -> Bool { (raw[key] as? Int ?? 0) == 1 }
        func str(_ key: String) -> String { (raw[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

        if intFlag(kCFNetworkProxiesSOCKSEnable as String) {
            proxySchemeRaw = ProxyScheme.socks5.rawValue
            proxyHost = str(kCFNetworkProxiesSOCKSProxy as String)
            if let port = raw[kCFNetworkProxiesSOCKSPort as String] as? Int { proxyPort = String(port) }
            proxyEnabled = !proxyHost.isEmpty
        } else if intFlag(kCFNetworkProxiesHTTPSEnable as String) {
            proxySchemeRaw = ProxyScheme.http.rawValue
            proxyHost = str(kCFNetworkProxiesHTTPSProxy as String)
            if let port = raw[kCFNetworkProxiesHTTPSPort as String] as? Int { proxyPort = String(port) }
            proxyEnabled = !proxyHost.isEmpty
        } else if intFlag(kCFNetworkProxiesHTTPEnable as String) {
            proxySchemeRaw = ProxyScheme.http.rawValue
            proxyHost = str(kCFNetworkProxiesHTTPProxy as String)
            if let port = raw[kCFNetworkProxiesHTTPPort as String] as? Int { proxyPort = String(port) }
            proxyEnabled = !proxyHost.isEmpty
        } else {
            proxyError = "未检测到系统代理，请手动填写。"
            proxyMessage = nil
            return
        }

        proxyMessage = "已读取系统代理，可按需修改后应用。"
        proxyError = nil
    }

    private func applyProxyToAllUsers() async {
        proxyError = nil
        proxyMessage = nil
        proxyProgressText = nil
        isApplyingProxy = true
        defer {
            isApplyingProxy = false
            if proxyError == nil { proxyProgressText = nil }
        }

        let users = pool.users.filter { !$0.isAdmin && $0.clawType == .macosUser }
        if users.isEmpty {
            proxyError = "没有可应用代理的虾用户。"
            return
        }

        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let noProxy = proxyNoProxy.trimmingCharacters(in: .whitespacesAndNewlines)

        var auth = ""
        let username = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            let password = proxyPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            auth = "\(username):\(password)@"
        }

        let proxyURL = "\(proxySchemeRaw)://\(auth)\(host):\(port)"
        let value = proxyEnabled ? proxyURL : ""
        let noProxyValue = proxyEnabled ? noProxy : ""

        var failed: [String] = []
        let total = users.count
        for (idx, u) in users.enumerated() {
            proxyProgressText = "正在应用 \(idx + 1)/\(total)：\(u.username)"
            do {
                try await helperClient.applyProxySettings(
                    username: u.username,
                    enabled: proxyEnabled,
                    proxyURL: value,
                    noProxy: noProxyValue,
                    restartGatewayIfRunning: true
                )
            } catch {
                failed.append("\(u.username): \(error.localizedDescription)")
            }
        }

        if failed.isEmpty {
            proxyMessage = "代理配置已应用到 \(users.count) 个虾用户。"
            proxyProgressText = "应用完成：\(users.count)/\(users.count)"
        } else {
            proxyError = "部分用户应用失败：\n" + failed.joined(separator: "\n")
            proxyProgressText = "应用完成：成功 \(users.count - failed.count)，失败 \(failed.count)"
        }
    }
}

#if DEBUG
private struct DebugGatewayActivationPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activationProgress: Double = 0.12
    @State private var activationShrimpLifted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.k("settings.debug.gateway_preview_title", fallback: "Gateway 启动页预览"))
                    .font(.headline)
                Spacer()
                Button(L10n.k("auto.model_config_wizard.close", fallback: "关闭")) { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(spacing: 24) {
                GatewayActivationCard(
                    progress: activationProgress,
                    isAnimating: true,
                    isShrimpLifted: activationShrimpLifted
                )

                HStack(spacing: 12) {
                    Button(L10n.k("settings.debug.replay", fallback: "重新播放")) {
                        activationProgress = 0.12
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text(L10n.k("settings.debug.preview_warning", fallback: "DEBUG 预览，不会启动真实 Gateway"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 560)
        .task {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                activationShrimpLifted = true
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(220))
                activationProgress += 0.03
                if activationProgress >= 0.92 {
                    activationProgress = 0.12
                }
            }
        }
    }
}
#endif

// MARK: - Helper 状态

private struct HelperStatusSection: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var healthState: HelperHealthState = .disconnected
    @State private var isProbing = false
    @State private var isRestarting = false
    @State private var lastProbeTime: Date?

    var body: some View {
        Section("Helper 服务") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .fontWeight(.medium)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isProbing || isRestarting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await probe() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isProbing || isRestarting)
                .help("检测 Helper 健康状态")
            }

            if case .unresponsive = healthState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Helper 进程存活但无响应，建议重启恢复。")
                        .font(.caption)
                    Spacer()
                    Button("重启 Helper") {
                        Task { await restartHelper() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                    .disabled(isRestarting)
                }
            }

            if case .disconnected = healthState, !helperClient.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Helper 未连接。如已安装，尝试重启恢复。")
                        .font(.caption)
                    Spacer()
                    Button("重启 Helper") {
                        Task { await restartHelper() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(isRestarting)
                }
            }

            Text("Helper 是以 root 运行的后台服务（LaunchDaemon），负责所有特权操作。正常情况下由 launchd 自动管理，无需手动干预。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await probe() }
    }

    private var statusColor: Color {
        switch healthState {
        case .connected: return .green
        case .unresponsive: return .orange
        case .disconnected: return helperClient.isConnected ? .yellow : .red
        }
    }

    private var statusTitle: String {
        switch healthState {
        case .connected(let version): return "运行中（v\(version)）"
        case .unresponsive: return "无响应"
        case .disconnected: return helperClient.isConnected ? "连接中…" : "未连接"
        }
    }

    private var statusDetail: String {
        if let t = lastProbeTime {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "上次检测：\(fmt.localizedString(for: t, relativeTo: Date()))"
        }
        return "正在检测…"
    }

    private func probe() async {
        isProbing = true
        healthState = await helperClient.probeHealth()
        lastProbeTime = Date()
        isProbing = false
    }

    private func restartHelper() async {
        isRestarting = true
        // 先尝试 XPC 优雅重启
        let sent = await helperClient.requestHelperRestart()
        if sent {
            try? await Task.sleep(for: .seconds(2))
            helperClient.connect()
            try? await Task.sleep(for: .seconds(1))
        } else {
            // XPC 不通 → launchctl 强制重启
            let ok = DaemonInstaller().forceRestart()
            if ok {
                try? await Task.sleep(for: .seconds(2))
                helperClient.connect()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        healthState = await helperClient.probeHealth()
        lastProbeTime = Date()
        isRestarting = false
    }
}

// MARK: - App 锁定设置区

private struct AppLockSection: View {
    @Environment(AppLockStore.self) private var lockStore
    @State private var showSetPassword = false
    @State private var showDisableLock = false
    @State private var showChangePassword = false

    var body: some View {
        Section(L10n.k("views.settings_view.privacy_security", fallback: "隐私与安全")) {
            if lockStore.isEnabled {
                LabeledContent(L10n.k("views.settings_view.app_lock", fallback: "App 锁定")) {
                    HStack(spacing: 8) {
                        Text(L10n.k("views.settings_view.enabled", fallback: "已启用")).foregroundStyle(.secondary)
                        Button(L10n.k("views.settings_view.change_password", fallback: "更改密码")) { showChangePassword = true }
                            .buttonStyle(.borderless)
                        Button(L10n.k("views.settings_view.disable_lock", fallback: "关闭锁定")) { showDisableLock = true }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                }

                if lockStore.isBiometricAvailable {
                    Toggle(L10n.k("views.settings_view.touch_id_unlock", fallback: "使用 Touch ID 解锁"), isOn: Binding(
                        get: { lockStore.isBiometricEnabled },
                        set: { lockStore.setBiometricEnabled($0) }
                    ))
                }

                Text(L10n.k("views.settings_view.admin_password_clawdhome", fallback: "启用锁定后，每次开机或系统屏幕锁定后需输入管理密码才能使用 ClawdHome。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(L10n.k("views.settings_view.app_lock", fallback: "App 锁定")) {
                    Button(L10n.k("views.settings_view.settings", fallback: "设置密码…")) { showSetPassword = true }
                        .buttonStyle(.borderless)
                }
                Text(L10n.k("views.settings_view.settings_admin_password_app", fallback: "设置管理密码后，App 启动及系统锁屏后将需要验证身份。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSetPassword) {
            SetPasswordSheet(mode: .set)
        }
        .sheet(isPresented: $showChangePassword) {
            SetPasswordSheet(mode: .change)
        }
        .sheet(isPresented: $showDisableLock) {
            DisableLockSheet()
        }
    }
}

// MARK: - 设置/更改密码 Sheet

private struct SetPasswordSheet: View {
    enum Mode { case set, change }
    let mode: Mode

    @Environment(AppLockStore.self) private var lockStore
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode == .set
                 ? L10n.k("settings.lock.set_password", fallback: "设置管理密码")
                 : L10n.k("settings.lock.change_password", fallback: "更改管理密码"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                if mode == .change {
                    SecureField(L10n.k("views.settings_view.current_password", fallback: "当前密码"), text: $oldPassword)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField(L10n.k("views.settings_view.new_password_min_6", fallback: "新密码（至少 6 位）"), text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField(L10n.k("views.settings_view.confirm_new_password", fallback: "确认新密码"), text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(L10n.k("views.settings_view.cancel", fallback: "取消")) { dismiss() }
                Spacer()
                Button(mode == .set
                       ? L10n.k("settings.lock.enable", fallback: "启用锁定")
                       : L10n.k("settings.lock.confirm_change", fallback: "确认更改")) { commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPassword.count < 6 || newPassword != confirmPassword)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func commit() {
        guard newPassword == confirmPassword else {
            error = L10n.k("settings.lock.error.password_mismatch", fallback: "两次输入的密码不一致"); return
        }
        guard newPassword.count >= 6 else {
            error = L10n.k("settings.lock.error.password_too_short", fallback: "密码至少需要 6 位"); return
        }
        if mode == .change {
            switch lockStore.changePassword(old: oldPassword, new: newPassword) {
            case .success: break
            case .wrongPassword:  error = L10n.k("settings.lock.error.current_password_incorrect", fallback: "当前密码错误"); return
            case .keychainDenied: error = L10n.k("settings.lock.error.keychain_denied", fallback: "Keychain 访问被拒绝，请在系统弹窗中允许"); return
            }
        } else {
            lockStore.setPassword(newPassword)
        }
        dismiss()
    }
}

// MARK: - 关闭锁定 Sheet

private struct DisableLockSheet: View {
    @Environment(AppLockStore.self) private var lockStore
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.k("views.settings_view.app_lock_a79063", fallback: "关闭 App 锁定")).font(.headline)
            Text(L10n.k("views.settings_view.current_admin_password_confirm", fallback: "请输入当前管理密码以确认关闭。"))
                .font(.subheadline).foregroundStyle(.secondary)

            SecureField(L10n.k("views.settings_view.current_password", fallback: "当前密码"), text: $password)
                .textFieldStyle(.roundedBorder)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button(L10n.k("views.settings_view.cancel", fallback: "取消")) { dismiss() }
                Spacer()
                Button(L10n.k("views.settings_view.disable_lock", fallback: "关闭锁定")) {
                    switch lockStore.disableLock(password: password) {
                    case .success:        dismiss()
                    case .wrongPassword:  error = L10n.k("settings.lock.error.password_incorrect", fallback: "密码错误")
                    case .keychainDenied: error = L10n.k("settings.lock.error.keychain_denied", fallback: "Keychain 访问被拒绝，请在系统弹窗中允许")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - App 日志查看器

private struct AppLogTab: View {
    private enum LogLevelFilter: String, CaseIterable, Identifiable {
        case all
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var id: String { rawValue }
        var levelValue: String? { self == .all ? nil : rawValue }
        var title: String {
            switch self {
            case .all: return L10n.k("common.filter.all", fallback: "全部")
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    @State private var appLogger = AppLogger.shared
    @State private var isFollowing = true
    @State private var levelFilter: LogLevelFilter = .all
    @State private var searchQuery = ""

    private var filteredLines: [AppLogger.LogLine] {
        var lines = appLogger.lines
        if let level = levelFilter.levelValue {
            lines = lines.filter { $0.level.rawValue == level }
        }
        lines = lines.filter { LogSearchMatcher.matches(text: $0.formatted, query: searchQuery) }
        return lines
    }
    private var filteredLogText: String {
        filteredLines.map(\.formatted).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text(L10n.k("settings.app_log.header", fallback: "App 内存日志（最近 500 条）"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $levelFilter) {
                        ForEach(LogLevelFilter.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Toggle(L10n.k("common.toggle.auto_scroll", fallback: "自动滚动"), isOn: $isFollowing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    TextField(L10n.k("common.search.by_space", fallback: "搜索（空格分词）"), text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button(L10n.k("common.action.copy_filtered", fallback: "复制筛选")) { copyFilteredLogs() }
                        .controlSize(.small)
                    Button(L10n.k("common.action.clear", fallback: "清空")) { appLogger.clear() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filteredLines.isEmpty
                             ? L10n.k("settings.app_log.empty", fallback: "（暂无日志）")
                             : filteredLogText)
                            .foregroundStyle(filteredLines.isEmpty ? .tertiary : .primary)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredLines.count) { _, _ in
                    if isFollowing {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func copyFilteredLogs() {
        let text = filteredLines.map(\.formatted).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Helper 日志查看器

struct HelperLogTab: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var logLines: [ParsedLogLine] = []
    @State private var isFollowing = true
    @State private var timer: Timer?
    @State private var levelFilter: LogLevelFilter = .all
    @State private var selectedChannel: LogChannel = .all
    @State private var debugLoggingEnabled = false
    @State private var suppressDebugToggleCallback = false
    @State private var searchQuery = ""
    @State private var isPaused = false
    @State private var fileOffset: UInt64 = 0
    @State private var pendingFragment = ""
    @State private var nextLineID: Int = 0
    @State private var isReading = false

    private struct JSONLogLine: Codable {
        let ts: String
        let level: String
        let channel: String
        let message: String
        let pid: Int32?
        let username: String?
        let requestId: String?
        let component: String?
        let event: String?
        let fields: [String: String]?
    }

    private struct ParsedLogLine: Identifiable {
        let id: String
        let text: String
        let level: String?
        let channel: String?
    }

    private enum LogLevelFilter: String, CaseIterable, Identifiable {
        case all
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var id: String { rawValue }
        var levelValue: String? { self == .all ? nil : rawValue }
        var title: String {
            switch self {
            case .all: return L10n.k("common.filter.all", fallback: "全部")
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    private enum LogChannel: String, CaseIterable, Identifiable {
        case all
        case primary
        case fileIO
        case diagnostics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L10n.k("common.filter.all", fallback: "全部")
            case .primary: return L10n.k("settings.helper_log.channel.primary", fallback: "主日志")
            case .fileIO: return L10n.k("settings.helper_log.channel.file_io", fallback: "文件IO")
            case .diagnostics: return L10n.k("settings.helper_log.channel.diagnostics", fallback: "诊断")
            }
        }
        var channelKey: String? {
            switch self {
            case .all: return nil
            case .primary: return "PRIMARY"
            case .fileIO: return "FILEIO"
            case .diagnostics: return "DIAG"
            }
        }
    }

    private let logPath = "/tmp/clawdhome-helper.log"
    private let maxRenderedLines = 400

    private var filteredLines: [ParsedLogLine] {
        var lines = logLines
        if let level = levelFilter.levelValue {
            lines = lines.filter { $0.level == level }
        }
        if let key = selectedChannel.channelKey {
            lines = lines.filter { $0.channel == key }
        }
        lines = lines.filter { LogSearchMatcher.matches(text: $0.text, query: searchQuery) }
        return lines
    }
    private var filteredLogText: String {
        filteredLines.map(\.text).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text(logPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $selectedChannel) {
                        ForEach(LogChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Picker(selection: $levelFilter) {
                        ForEach(LogLevelFilter.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    Toggle(L10n.k("settings.helper_log.toggle.debug_log", fallback: "DEBUG 日志"), isOn: $debugLoggingEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: debugLoggingEnabled) { oldValue, newValue in
                            if suppressDebugToggleCallback {
                                suppressDebugToggleCallback = false
                                return
                            }
                            Task {
                                do {
                                    try await helperClient.setHelperDebugLogging(enabled: newValue)
                                } catch {
                                    suppressDebugToggleCallback = true
                                    debugLoggingEnabled = oldValue
                                }
                            }
                        }
                    Toggle(L10n.k("common.toggle.auto_scroll", fallback: "自动滚动"), isOn: $isFollowing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Toggle(L10n.k("settings.helper_log.toggle.pause_refresh", fallback: "暂停刷新"), isOn: $isPaused)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    TextField(L10n.k("common.search.by_space", fallback: "搜索（空格分词）"), text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button(L10n.k("common.action.copy_filtered", fallback: "复制筛选")) { copyFilteredLogs() }
                        .controlSize(.small)
                    Button(L10n.k("common.action.clear", fallback: "清空")) {
                        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
                        for idx in 1...3 {
                            try? FileManager.default.removeItem(atPath: "\(logPath).\(idx)")
                        }
                        logLines = []
                        fileOffset = 0
                        pendingFragment = ""
                        nextLineID = 0
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(filteredLines.isEmpty
                             ? L10n.k("settings.helper_log.empty", fallback: "（日志为空）")
                             : filteredLogText)
                            .foregroundStyle(filteredLines.isEmpty ? .tertiary : .primary)
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: filteredLines.count) { _, _ in
                    if isFollowing {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .onAppear {
            loadLog(reset: true)
            startTimer()
            Task { debugLoggingEnabled = await helperClient.getHelperDebugLogging() }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func loadLog(reset: Bool = false) {
        guard !isReading else { return }
        isReading = true

        let startOffset = reset ? 0 : fileOffset
        let startFragment = reset ? "" : pendingFragment
        let startLines = reset ? [] : logLines
        let startID = reset ? 0 : nextLineID

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: logPath),
                  let sizeNum = attrs[.size] as? NSNumber else {
                DispatchQueue.main.async {
                    logLines = []
                    fileOffset = 0
                    pendingFragment = ""
                    nextLineID = 0
                    isReading = false
                }
                return
            }

            let fileSize = UInt64(sizeNum.int64Value)
            var offset = startOffset
            var fragment = startFragment
            var lines = startLines
            var runningID = startID

            // 文件被轮转或截断
            if fileSize < offset {
                offset = 0
                fragment = ""
                lines = []
                runningID = 0
            }

            guard let fh = FileHandle(forReadingAtPath: logPath) else {
                DispatchQueue.main.async {
                    isReading = false
                }
                return
            }
            defer { try? fh.close() }

            try? fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            let newOffset = offset + UInt64(data.count)

            if data.isEmpty {
                DispatchQueue.main.async {
                    fileOffset = newOffset
                    isReading = false
                }
                return
            }

            let chunk = String(data: data, encoding: .utf8) ?? ""
            let merged = fragment + chunk
            var parts = merged.components(separatedBy: "\n")
            fragment = parts.popLast() ?? ""

            for raw in parts {
                guard let parsed = parseLine(raw, id: runningID) else { continue }
                lines.append(parsed)
                runningID += 1
            }

            if lines.count > maxRenderedLines {
                lines.removeFirst(lines.count - maxRenderedLines)
            }

            DispatchQueue.main.async {
                logLines = lines
                fileOffset = newOffset
                pendingFragment = fragment
                nextLineID = runningID
                isReading = false
            }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            if !isPaused { loadLog() }
        }
    }

    private func copyFilteredLogs() {
        let text = filteredLines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func parseLine(_ raw: String, id: Int) -> ParsedLogLine? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if let data = line.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONLogLine.self, from: data) {
            let normalizedTs = LogTimestampFormatter.normalizeTimestamp(json.ts)
            var tags: [String] = []
            if let username = json.username, !username.isEmpty {
                tags.append("user=\(username)")
            }
            if let requestId = json.requestId, !requestId.isEmpty {
                tags.append("req=\(requestId)")
            }
            if let component = json.component, !component.isEmpty {
                if let event = json.event, !event.isEmpty {
                    tags.append("\(component).\(event)")
                } else {
                    tags.append(component)
                }
            }
            if let fields = json.fields, !fields.isEmpty {
                let summary = fields
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",")
                if !summary.isEmpty {
                    tags.append(summary)
                }
            }
            let tagText = tags.map { "[\($0)]" }.joined(separator: " ")
            let text = "[\(normalizedTs)] [\(json.level)] [\(json.channel)]"
                + (tagText.isEmpty ? "" : " \(tagText)")
                + " \(json.message)"
            return ParsedLogLine(
                id: "\(id)-\(normalizedTs)-\(json.level)-\(json.channel)",
                text: text,
                level: json.level,
                channel: json.channel
            )
        }

        let normalizedLine = LogTimestampFormatter.normalizeLinePrefix(line)
        let level = ["DEBUG", "INFO", "WARN", "ERROR"].first { line.contains("[\($0)]") }
        let channel = ["PRIMARY", "FILEIO", "DIAG"].first { line.contains("[\($0)]") }
        return ParsedLogLine(
            id: "\(id)-legacy-\(line.hashValue)",
            text: normalizedLine,
            level: level,
            channel: channel
        )
    }
}

// MARK: - 关于页

private struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color(red: 0.95, green: 0.2, blue: 0.35)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
}

private struct AboutTab: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(UpdateChecker.self) private var updater
    @State private var healthState: HelperHealthState = .disconnected
    @State private var isProbing = false
    @State private var isRestarting = false
    @State private var updateCheckMessage: String? = nil

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "—"
        let buildVersion = info?["CFBundleVersion"] as? String ?? ""
        return buildVersion.isEmpty ? shortVersion : "\(shortVersion) (\(buildVersion))"
    }

    private var helperVersion: String {
        if case .connected(let v) = healthState { return v }
        return "—"
    }

    private var statusColor: Color {
        switch healthState {
        case .connected: return .green
        case .unresponsive: return .orange
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch healthState {
        case .connected: return L10n.k("views.settings_view.connected", fallback: "已连接")
        case .unresponsive: return "无响应"
        case .disconnected: return L10n.k("views.settings_view.disconnected", fallback: "未连接")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // App 头部信息
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                HStack(alignment: .center, spacing: 8) {
                    Text("ClawdHome")
                        .font(.title2)
                        .fontWeight(.semibold)
                    BetaBadge()
                }
            }
            .padding(.bottom, 4)

            Divider()

            GroupBox("Helper 服务") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(statusText)
                        Spacer()

                        if isProbing || isRestarting {
                            ProgressView().controlSize(.small)
                        }

                        Button {
                            Task { await probe() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isProbing || isRestarting)
                        .help("重新检测 Helper 状态")
                    }

                    LabeledContent(L10n.k("views.settings_view.helper_version", fallback: "Helper 版本"), value: helperVersion)
                    LabeledContent(L10n.k("views.settings_view.app_version", fallback: "App 版本"), value: appVersion)

                    // 异常状态提示 + 重启按钮
                    if case .unresponsive = healthState {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Helper 进程存活但无响应，建议重启恢复。")
                                .font(.caption)
                            Spacer()
                            Button("重启 Helper") {
                                Task { await restartHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                            .disabled(isRestarting)
                        }
                    } else if case .disconnected = healthState {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Helper 未连接，无法执行任何操作。")
                                    .font(.caption)
                                Text(L10n.k("views.settings_view.run_install_helper_dev_sh", fallback: "请运行 sudo scripts/install-helper-dev.sh"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重启 Helper") {
                                Task { await restartHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                            .disabled(isRestarting)
                        }
                    } else {
                        // 正常状态下显示更新检查
                        HStack(spacing: 10) {
                            Button {
                                Task { await checkForAppUpdate() }
                            } label: {
                                if updater.isCheckingAppUpdate {
                                    Text(L10n.k("views.settings_view.checking_update", fallback: "检查中..."))
                                } else {
                                    Text(L10n.k("views.settings_view.check_update", fallback: "检查更新"))
                                }
                            }
                            .disabled(updater.isCheckingAppUpdate)

                            if let message = updateCheckMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(4)
            }

            Link(destination: URL(string: "https://clawdhome.app")!) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                    Text("ClawdHome.app")
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Link(destination: URL(string: "https://ClawdHome.app/docs")!) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                    Text(L10n.k("views.settings_view.docs", fallback: "文档"))
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .task { await probe() }
    }

    private func probe() async {
        isProbing = true
        healthState = await helperClient.probeHealth()
        isProbing = false
    }

    private func restartHelper() async {
        isRestarting = true
        let sent = await helperClient.requestHelperRestart()
        if sent {
            try? await Task.sleep(for: .seconds(2))
            helperClient.connect()
            try? await Task.sleep(for: .seconds(1))
        } else {
            // XPC 不通 → launchctl 强制重启
            let ok = DaemonInstaller().forceRestart()
            if ok {
                try? await Task.sleep(for: .seconds(2))
                helperClient.connect()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        healthState = await helperClient.probeHealth()
        isRestarting = false
    }

    @MainActor
    private func checkForAppUpdate() async {
        await updater.checkApp()
        if let err = updater.appCheckError, !err.isEmpty {
            updateCheckMessage = L10n.f(
                "views.settings_view.update_check_failed_fmt",
                fallback: "检查失败：%@",
                err
            )
            return
        }
        if updater.appNeedsUpdate, let latest = updater.appLatestVersion {
            updateCheckMessage = L10n.f(
                "views.settings_view.new_version_available_fmt",
                fallback: "发现新版本：v%@",
                latest
            )
        } else {
            updateCheckMessage = L10n.k("views.settings_view.up_to_date", fallback: "当前已是最新版本")
        }
    }
}
