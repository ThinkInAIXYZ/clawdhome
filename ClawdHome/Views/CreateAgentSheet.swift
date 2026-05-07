// ClawdHome/Views/CreateAgentSheet.swift
// 新建 Agent 弹窗：选择来源 → 从零创建表单 / 从角色市场导入

import SwiftUI
import WebKit

struct CreateAgentSheet: View {
    let username: String
    var onCreated: ((AgentProfile) -> Void)? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .chooseSource
    @State private var name = ""
    @State private var emoji = ""
    @State private var agentId = ""
    @State private var modelPrimary = ""
    @State private var isCreating = false
    @State private var error: String?

    // 角色市场相关状态
    @State private var selectedDNA: AgentDNA?
    @State private var dnaAgentId = ""
    @State private var marketCoordinator = RoleMarketCoordinator()
    @State private var isMarketPageLoaded = false

    enum Step { case chooseSource, createManual, fromMarket, confirmDNA }

    // MARK: - 校验

    /// Agent ID 规则：小写字母/数字/下划线/短横线，1-32 位
    private var agentIdValid: Bool {
        let id = effectiveAgentId
        return id.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }

    private var effectiveAgentId: String {
        if !agentId.isEmpty { return agentId }
        // 从名称生成 ID：取拼音/ASCII 字符，非 ASCII 字符用下划线替代
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "" }
            .joined()
        // 如果全是非 ASCII（如纯中文），用 "agent" 前缀 + 时间戳后 4 位
        if base.isEmpty || base.first?.isLetter != true {
            return "agent_\(base.isEmpty ? String(Int(Date().timeIntervalSince1970) % 10000) : base)"
        }
        return String(base.prefix(32))
    }

    /// DNA 导入时的 agent ID
    private var effectiveDNAAgentId: String {
        if !dnaAgentId.isEmpty { return dnaAgentId }
        guard let dna = selectedDNA else { return "" }
        let base = dna.id.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "" }
            .joined()
        if base.isEmpty || base.first?.isLetter != true {
            return "agent_\(base.isEmpty ? String(Int(Date().timeIntervalSince1970) % 10000) : base)"
        }
        return String(base.prefix(32))
    }

    private var dnaAgentIdValid: Bool {
        let id = effectiveDNAAgentId
        return id.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && agentIdValid
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .chooseSource:
                chooseSourceView
            case .createManual:
                createManualView
            case .fromMarket:
                fromMarketView
            case .confirmDNA:
                confirmDNAView
            }
        }
        .padding(step == .fromMarket ? 0 : 24)
        .frame(
            width: step == .fromMarket ? 700 : 420,
            height: step == .fromMarket ? 520 : nil
        )
    }

    // MARK: - 模式1：选择来源

    private var chooseSourceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            Text(L10n.k("agent.create.title", fallback: "新建角色"))
                .font(.title2)
                .fontWeight(.semibold)
            Text(L10n.k("agent.create.subtitle", fallback: "为你的虾添加一个新的专业角色"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // 选项卡片
            VStack(spacing: 12) {
                // 从角色市场选择
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .fromMarket
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "storefront")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.k("agent.create.from_market", fallback: "从角色市场选择"))
                                .fontWeight(.medium)
                            Text(L10n.k("agent.create.from_market.desc", fallback: "浏览预设角色模板，快速上手"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // 从零创建
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .createManual
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.square")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.k("agent.create.from_scratch", fallback: "从零创建"))
                                .fontWeight(.medium)
                            Text(L10n.k("agent.create.from_scratch.desc", fallback: "自定义角色的所有细节"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            // 取消按钮
            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - 模式2：从零创建

    private var createManualView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题 + 返回
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .chooseSource
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)

                Text(L10n.k("agent.create.manual.title", fallback: "创建角色"))
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.bottom, 16)

            Form {
                Section {
                    TextField(L10n.k("agent.create.form.name", fallback: "角色名称"), text: $name)
                    TextField(L10n.k("agent.create.form.emoji", fallback: "Emoji 图标"), text: $emoji)
                        .onChange(of: emoji) { _, newValue in
                            // 只保留第一个 emoji/字符
                            if newValue.count > 1 {
                                emoji = String(newValue.prefix(1))
                            }
                        }
                } header: {
                    Text(L10n.k("agent.create.form.basic_info", fallback: "基本信息"))
                }

                Section {
                    TextField(L10n.k("agent.create.form.agent_id", fallback: "Agent ID"), text: $agentId)
                        .textContentType(.username)
                    if !name.isEmpty || !agentId.isEmpty {
                        Text(L10n.k("agent.create.form.agent_id.preview", fallback: "实际 ID：") + effectiveAgentId)
                            .font(.caption)
                            .foregroundColor(agentIdValid ? .secondary : .red)
                    }
                } header: {
                    Text(L10n.k("agent.create.form.identifier", fallback: "标识符"))
                } footer: {
                    Text(L10n.k("agent.create.form.agent_id.hint", fallback: "留空则根据名称自动生成。仅限小写字母、数字、下划线和短横线。"))
                        .font(.caption)
                }

                Section {
                    TextField(L10n.k("agent.create.form.model", fallback: "模型（可选）"), text: $modelPrimary)
                } header: {
                    Text(L10n.k("agent.create.form.model_config", fallback: "模型配置"))
                } footer: {
                    Text(L10n.k("agent.create.form.model.hint", fallback: "留空则使用默认模型。例如：claude-sonnet-4-20250514"))
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            // 错误提示
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            // 按钮
            HStack {
                Spacer()
                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.k("common.action.create", fallback: "创建")) {
                    Task { await createAgent() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding(.top, 16)
        }
    }

    // MARK: - 模式3：角色市场浏览

    private var fromMarketView: some View {
        VStack(spacing: 0) {
            // 顶栏：返回 + 标题
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .chooseSource
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)

                Text(L10n.k("agent.create.from_market", fallback: "从角色市场选择"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 内嵌 WebView
            ZStack {
                CreateAgentMarketWebView(coordinator: marketCoordinator)
                    .opacity(isMarketPageLoaded ? 1 : 0)
                    .animation(.easeIn(duration: 0.25), value: isMarketPageLoaded)

                if !isMarketPageLoaded {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.k("agent.create.market_loading", fallback: "加载角色市场..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            marketCoordinator.onAdoptAgent = { dna in
                self.selectedDNA = dna
                // 根据 DNA 预填 agent ID
                let base = dna.id.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .unicodeScalars
                    .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "" }
                    .joined()
                self.dnaAgentId = String(base.prefix(32))
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .confirmDNA
                }
            }
            marketCoordinator.onPageLoaded = {
                withAnimation {
                    self.isMarketPageLoaded = true
                }
            }
        }
    }

    // MARK: - 模式4：DNA 确认/预览

    private var confirmDNAView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dna = selectedDNA {
                // 标题 + 返回
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            step = .fromMarket
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Text(L10n.k("agent.create.confirm_import.title", fallback: "导入角色"))
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                .padding(.bottom, 16)

                // DNA 信息卡片
                HStack(spacing: 12) {
                    Text(dna.emoji)
                        .font(.system(size: 36))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dna.name)
                            .font(.headline)
                        Text(dna.soul)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.06))
                )
                .padding(.bottom, 12)

                // Persona 文件预览
                if let soul = dna.fileSoul, !soul.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("SOUL.md", systemImage: "doc.text")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(String(soul.prefix(200)) + (soul.count > 200 ? "..." : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .padding(.bottom, 8)
                }

                // Agent ID 输入
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("agent.create.form.agent_id", fallback: "Agent ID"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("agent_id", text: $dnaAgentId)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.k("agent.create.form.agent_id.preview", fallback: "实际 ID：") + effectiveDNAAgentId)
                        .font(.caption)
                        .foregroundColor(dnaAgentIdValid ? .secondary : .red)
                }
                .padding(.bottom, 8)

                // 错误提示
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 8)
                }

                Spacer()

                // 按钮
                HStack {
                    Spacer()
                    Button(L10n.k("common.action.cancel", fallback: "取消")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.k("agent.create.confirm_import.action", fallback: "导入为角色")) {
                        Task { await importFromDNA(dna) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dnaAgentIdValid || isCreating)
                }
            }
        }
    }

    // MARK: - 创建逻辑

    private func createAgent() async {
        isCreating = true
        defer { isCreating = false }

        let id = effectiveAgentId
        let profile = AgentProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            emoji: emoji,
            modelPrimary: modelPrimary.isEmpty ? nil : modelPrimary,
            workspacePath: nil,
            isDefault: false
        )

        do {
            try await helperClient.createAgent(username: username, config: profile)
            onCreated?(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - 从 DNA 导入

    private func importFromDNA(_ dna: AgentDNA) async {
        isCreating = true
        defer { isCreating = false }

        let id = effectiveDNAAgentId

        let profile = AgentProfile(
            id: id,
            name: dna.name,
            emoji: dna.emoji,
            modelPrimary: nil,
            workspacePath: nil,
            isDefault: false
        )

        do {
            // 1. 创建 agent 配置 + workspace 目录
            try await helperClient.createAgent(username: username, config: profile)

            // 2. 写入 persona 文件到 agent workspace
            let wsDir = ".openclaw/workspace-\(id)"
            if let soul = dna.fileSoul, !soul.isEmpty {
                try? await helperClient.writeFile(username: username, relativePath: "\(wsDir)/SOUL.md", data: soul.data(using: .utf8) ?? Data())
            }
            if let identity = dna.fileIdentity, !identity.isEmpty {
                try? await helperClient.writeFile(username: username, relativePath: "\(wsDir)/IDENTITY.md", data: identity.data(using: .utf8) ?? Data())
            }
            if let user = dna.fileUser, !user.isEmpty {
                try? await helperClient.writeFile(username: username, relativePath: "\(wsDir)/USER.md", data: user.data(using: .utf8) ?? Data())
            }

            // 3. 重启 gateway 使新 agent 生效
            try? await helperClient.restartGateway(username: username)

            onCreated?(profile)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 独立的角色市场 WebView（不复用全局缓存，避免冲突）

private struct CreateAgentMarketWebView: NSViewRepresentable {
    let coordinator: RoleMarketCoordinator

    func makeCoordinator() -> RoleMarketCoordinator { coordinator }

    func makeNSView(context: Context) -> WKWebView {
        let localeIdentifier = resolvedMarketLocaleIdentifier()
        let config = WKWebViewConfiguration()
        let localeLiteral = jsonStringLiteral(localeIdentifier)
        let bootstrap = "window.__clawdhomeLocale = \(localeLiteral);"
        let script = WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "ClawdHomeBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let url = Bundle.main.url(forResource: "roles", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // 解析当前 locale 标识符
    private func resolvedMarketLocaleIdentifier() -> String {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        guard let appLanguage = AppLanguage(rawValue: selected) else { return "en" }
        switch appLanguage {
        case .english: return "en"
        case .chineseSimplified: return "zh-CN"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? "zh-CN" : "en"
        }
    }

    // 安全转义 JS 字符串字面量
    private func jsonStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        guard let data,
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "\"en\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}
