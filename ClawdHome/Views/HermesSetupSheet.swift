// ClawdHome/Views/HermesSetupSheet.swift
// Hermes Agent 独立安装与管理面板
//
// 设计：与 OpenClaw 安装流程完全分离，步骤不同。
// 当前最小步骤：检测 Python → 安装 Hermes → 完成。
// 不含频道绑定、模型配置（由后续版本或维护终端处理）。

import SwiftUI

struct HermesSetupSheet: View {
    private struct HermesInitSummary: Decodable {
        var provider: String?
        var modelDefault: String?
        var modelBaseURL: String?
        var modelAPIMode: String?
        var envKeys: [String]?
        var version: String?
    }

    private struct HermesInitIssue: Decodable, Identifiable {
        let id = UUID()
        var code: String
        var level: String
        var message: String
    }

    private struct HermesInitValidation: Decodable {
        var valid: Bool
        var issues: [HermesInitIssue]
    }

    let user: ManagedUser

    @Environment(HelperClient.self) private var helperClient
    @Environment(MaintenanceWindowRegistry.self) private var maintenanceWindowRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var hermesVersion: String?
    @State private var isInstalling = false
    @State private var installTask: Task<Void, Never>?
    @State private var installError: String?
    @State private var installDone = false
    @State private var hermesRunning = false
    @State private var hermesPID: Int32 = -1
    @State private var isStarting = false
    @State private var isStopping = false
    @State private var gatewayError: String?
    @State private var initProvider = "openai"
    @State private var initModelDefault = ""
    @State private var initModelBaseURL = ""
    @State private var initModelAPIMode = ""
    @State private var initEnvLines = ""
    @State private var initPrimarySecretKeyName = "OPENAI_API_KEY"
    @State private var initPrimarySecretValue = ""
    @State private var initApplyError: String?
    @State private var initValidateError: String?
    @State private var initValidateReport: HermesInitValidation?
    @State private var initSummaryEnvKeys: [String] = []
    @State private var isApplyingInit = false
    @State private var isValidatingInit = false
    @State private var isLoadingInitSummary = false

    private var isInstalled: Bool { hermesVersion != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    if isInstalled {
                        initConfigSection
                        gatewaySection
                        terminalSection
                    } else {
                        installSection
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await refreshStatus() }
        .onDisappear {
            if isInstalling {
                installTask?.cancel()
                Task {
                    await helperClient.cancelHermesInstall(username: user.username)
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            HermesLogoMark()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes Agent")
                    .font(.headline)
                Text("@\(user.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - 状态

    private var statusSection: some View {
        GroupBox {
            HStack {
                Label {
                    if let version = hermesVersion {
                        Text("v\(version)")
                    } else {
                        Text(L10n.k("hermes.setup.not_installed", fallback: "未安装"))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isInstalled ? .green : .secondary)
                }
                Spacer()
                if isInstalled {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(hermesRunning ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(hermesRunning ? "运行中 (PID \(hermesPID))" : "已停止")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.status_title", fallback: "Hermes 状态"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 安装

    private var installSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("hermes.setup.description", fallback: "Hermes Agent 是一个自进化 AI 代理框架，支持 20+ 消息平台，需要 Python 3.11+。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(L10n.k("hermes.setup.install_steps", fallback: "安装步骤：1) 修复 Homebrew 权限  2) 安装 Hermes Agent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = installError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Spacer()
                    Button {
                        installTask = Task { await performInstall() }
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text(L10n.k("hermes.setup.installing", fallback: "安装中…"))
                        } else {
                            Label(L10n.k("hermes.setup.install_action", fallback: "安装 Hermes Agent"), systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isInstalling)
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.install_button", fallback: "安装"))
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 初始化配置

    private var initConfigSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if installDone {
                    Label(L10n.k("hermes.setup.install_done", fallback: "安装完成，请配置 API 密钥后启动 Gateway。"), systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }

                HStack {
                    Text(L10n.k("hermes.setup.config_hint", fallback: "用于生成 ~/.hermes/config.yaml 与 ~/.hermes/.env"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await loadInitSummary() }
                    } label: {
                        if isLoadingInitSummary {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.k("hermes.setup.read_config", fallback: "读取当前配置"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoadingInitSummary || isApplyingInit || isValidatingInit)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $initProvider) {
                            Text("openai").tag("openai")
                            Text("anthropic").tag("anthropic")
                            Text("gemini").tag("gemini")
                            Text("deepseek").tag("deepseek")
                            Text("custom").tag("custom")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: initProvider) { _, newProvider in
                            initPrimarySecretKeyName = suggestedSecretKeyName(for: newProvider)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model").font(.caption).foregroundStyle(.secondary)
                        TextField("gpt-4.1-mini", text: $initModelDefault)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Mode").font(.caption).foregroundStyle(.secondary)
                        TextField("responses / chat / completions", text: $initModelAPIMode)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("hermes.setup.base_url_optional", fallback: "Base URL (可选)")).font(.caption).foregroundStyle(.secondary)
                    TextField("https://api.openai.com/v1", text: $initModelBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("hermes.setup.primary_key_var", fallback: "主密钥变量名")).font(.caption).foregroundStyle(.secondary)
                        TextField("OPENAI_API_KEY", text: $initPrimarySecretKeyName)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("hermes.setup.primary_key_value", fallback: "主密钥值")).font(.caption).foregroundStyle(.secondary)
                        SecureField("sk-...", text: $initPrimarySecretValue)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("hermes.setup.extra_env_vars", fallback: "附加环境变量（每行 KEY=VALUE）")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $initEnvLines)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    if !initSummaryEnvKeys.isEmpty {
                        Text(L10n.f("hermes.setup.existing_env_keys", fallback: "已存在变量：%@", initSummaryEnvKeys.joined(separator: ", ")))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let initApplyError, !initApplyError.isEmpty {
                    Label(initApplyError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let initValidateError, !initValidateError.isEmpty {
                    Label(initValidateError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let report = initValidateReport {
                    Label(report.valid ? "校验通过" : "校验未通过", systemImage: report.valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(report.valid ? .green : .orange)
                    if !report.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.issues) { issue in
                                Text("• [\(issue.level)] \(issue.message)")
                                    .font(.caption2)
                                    .foregroundStyle(issue.level == "error" ? .red : .orange)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await validateInitConfig() }
                    } label: {
                        if isValidatingInit {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.k("hermes.setup.validate_config", fallback: "校验配置"), systemImage: "checkmark.shield")
                        }
                    }
                    .disabled(isApplyingInit || isValidatingInit || isLoadingInitSummary)

                    Button {
                        Task { await applyInitConfig() }
                    } label: {
                        if isApplyingInit {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.k("hermes.setup.apply_config", fallback: "应用配置"), systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyingInit || isValidatingInit || isLoadingInitSummary)

                    Spacer()
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.init_config", fallback: "初始化配置"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Gateway 控制

    private var gatewaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task { await startHermes() }
                    } label: {
                        Label(L10n.k("common.action.start", fallback: "启动"), systemImage: "play.fill")
                    }
                    .disabled(hermesRunning || isStarting || isStopping)

                    Button {
                        Task { await stopHermes() }
                    } label: {
                        Label(L10n.k("common.action.stop", fallback: "停止"), systemImage: "stop.fill")
                    }
                    .disabled(!hermesRunning || isStarting || isStopping)

                    if isStarting || isStopping {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        Task { await refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.k("common.action.refresh", fallback: "刷新状态"))
                }

                if let gatewayError {
                    Label(gatewayError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.gateway_control_title", fallback: "Gateway 控制"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - 维护终端

    private var terminalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.k("hermes.setup.cli_hint", fallback: "在维护终端中使用 Hermes CLI（独立环境，不含 Node.js/npm）。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Hermes Shell") {
                        openHermesTerminal(["hermes"])
                    }
                    Button("hermes setup") {
                        openHermesTerminal(["hermes", "setup"])
                    }
                    Button("hermes status") {
                        openHermesTerminal(["hermes", "gateway", "--status"])
                    }
                    Spacer()
                }
            }
        } label: {
            Text(L10n.k("hermes.setup.maintenance_terminal", fallback: "维护终端"))
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Actions

    private func refreshStatus() async {
        hermesVersion = await helperClient.getHermesVersion(username: user.username)
        let status = await helperClient.getHermesGatewayStatus(username: user.username)
        hermesRunning = status.running
        hermesPID = status.pid
        await loadInitSummary()
    }

    private func performInstall() async {
        isInstalling = true
        installError = nil
        do {
            try await helperClient.installHermes(username: user.username)
            installDone = true
            await refreshStatus()
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }

    private func startHermes() async {
        isStarting = true
        gatewayError = nil
        do {
            try await helperClient.startHermesGateway(username: user.username)
        } catch {
            gatewayError = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshStatus()
        isStarting = false
    }

    private func stopHermes() async {
        isStopping = true
        gatewayError = nil
        do {
            try await helperClient.stopHermesGateway(username: user.username)
        } catch {
            gatewayError = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(0.5))
        await refreshStatus()
        isStopping = false
    }

    private func suggestedSecretKeyName(for provider: String) -> String {
        switch provider {
        case "anthropic":
            return "ANTHROPIC_API_KEY"
        case "gemini":
            return "GOOGLE_API_KEY"
        case "deepseek":
            return "DEEPSEEK_API_KEY"
        default:
            return "OPENAI_API_KEY"
        }
    }

    private func parseEnvLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private func applyInitConfig() async {
        isApplyingInit = true
        initApplyError = nil
        initValidateError = nil
        let provider = initProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = initModelDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.isEmpty || model.isEmpty {
            initApplyError = "Provider 与 Model 不能为空"
            isApplyingInit = false
            return
        }

        var env = parseEnvLines(initEnvLines)
        let secretKey = initPrimarySecretKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretValue = initPrimarySecretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secretKey.isEmpty, !secretValue.isEmpty {
            env[secretKey] = secretValue
        }

        var payload: [String: Any] = [
            "provider": provider,
            "modelDefault": model,
            "env": env,
        ]
        let baseURL = initModelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseURL.isEmpty { payload["modelBaseURL"] = baseURL }
        let apiMode = initModelAPIMode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiMode.isEmpty { payload["modelAPIMode"] = apiMode }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            initApplyError = "配置序列化失败"
            isApplyingInit = false
            return
        }

        // 客户端预校验
        if provider == "custom", baseURL.isEmpty {
            initApplyError = "provider=custom 时 Base URL 不能为空"
            isApplyingInit = false
            return
        }

        let (ok, err) = await helperClient.applyHermesInitConfig(username: user.username, payloadJSON: text)
        if !ok {
            initApplyError = err ?? "写入失败"
        } else {
            await validateInitConfig()
            await loadInitSummary()
        }
        isApplyingInit = false
    }

    private func validateInitConfig() async {
        isValidatingInit = true
        initValidateError = nil
        initValidateReport = nil
        guard let response = await helperClient.validateHermesInitConfig(username: user.username) else {
            initValidateError = "校验请求失败"
            isValidatingInit = false
            return
        }
        if !response.0 {
            initValidateError = "校验接口失败"
            isValidatingInit = false
            return
        }
        guard let data = response.1.data(using: .utf8),
              let report = try? JSONDecoder().decode(HermesInitValidation.self, from: data) else {
            initValidateError = "校验结果解析失败"
            isValidatingInit = false
            return
        }
        initValidateReport = report
        isValidatingInit = false
    }

    private func loadInitSummary() async {
        isLoadingInitSummary = true
        defer { isLoadingInitSummary = false }
        guard let json = await helperClient.getHermesInitSummary(username: user.username),
              let data = json.data(using: .utf8),
              let summary = try? JSONDecoder().decode(HermesInitSummary.self, from: data) else {
            return
        }
        if let provider = summary.provider, !provider.isEmpty {
            initProvider = provider
            initPrimarySecretKeyName = suggestedSecretKeyName(for: provider)
        }
        if let model = summary.modelDefault {
            initModelDefault = model
        }
        if let baseURL = summary.modelBaseURL {
            initModelBaseURL = baseURL
        }
        if let apiMode = summary.modelAPIMode {
            initModelAPIMode = apiMode
        }
        initSummaryEnvKeys = summary.envKeys ?? []
    }

    private func openHermesTerminal(_ command: [String]) {
        let payload = maintenanceWindowRegistry.makePayload(
            username: user.username,
            title: "Hermes · @\(user.username)",
            command: command,
            engine: .hermes
        )
        openWindow(id: "maintenance-terminal", value: payload)
    }
}
