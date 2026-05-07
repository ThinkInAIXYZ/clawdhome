// ClawdHome/Views/CreateAgentSheet.swift
// 新建 Agent 弹窗：选择来源 → 从零创建表单 / 从角色市场导入

import SwiftUI
import WebKit

struct CreateAgentSheet: View {
    let username: String
    var onCreated: ((AgentProfile) -> Void)? = nil

    @Environment(GatewayHub.self) private var gatewayHub
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .chooseSource
    @State private var name = ""
    @State private var emoji = ""
    @State private var agentId = ""
    @State private var modelPrimary = ""
    @State private var modelFallbacks: [String] = []
    @State private var isCreating = false
    @State private var error: String?

    // 角色市场相关状态
    @State private var selectedDNA: AgentDNA?
    @State private var dnaAgentId = ""
    @State private var marketCoordinator = RoleMarketCoordinator()
    @State private var isMarketPageLoaded = false

    enum Step { case chooseSource, createManual, fromMarket, confirmDNA }

    // MARK: - 校验

    /// OpenClaw 服务端保留的 agentId（见 openclaw/src/routing/session-key.ts DEFAULT_AGENT_ID）
    private static let reservedAgentIds: Set<String> = ["main"]

    /// Agent ID 规则与服务端 normalizeAgentId 对齐：
    /// 小写字母/数字/下划线/短横线，首字符必须是字母或数字，1-64 位
    /// 参考：openclaw/src/routing/session-key.ts VALID_ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/i
    private static func validateAgentId(_ id: String) -> Bool {
        guard id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else { return false }
        if reservedAgentIds.contains(id) { return false }
        return true
    }

    /// 返回具体的校验错误文案（nil 表示合法）
    private static func agentIdValidationError(_ id: String) -> String? {
        if id.isEmpty {
            return L10n.k("agent.create.validation.id_empty", fallback: "ID 不能为空")
        }
        if reservedAgentIds.contains(id) {
            return L10n.k("agent.create.validation.id_reserved", fallback: "ID \"\(id)\" 是系统保留字，请换一个")
        }
        if id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) == nil {
            return L10n.k("agent.create.validation.id_format", fallback: "仅限字母或数字开头，小写字母/数字/下划线/短横线，1-64 位")
        }
        return nil
    }

    private var agentIdValid: Bool {
        Self.validateAgentId(effectiveAgentId)
    }

    private var effectiveAgentId: String {
        if !agentId.isEmpty { return agentId }
        return ASCIIIdentifier.agentID(from: name, fallbackPrefix: "agent", maxLength: 64)
    }

    /// DNA 导入时的 agent ID
    private var effectiveDNAAgentId: String {
        if !dnaAgentId.isEmpty { return dnaAgentId }
        guard let dna = selectedDNA else { return "" }
        return ASCIIIdentifier.agentID(from: dna.id, fallbackPrefix: "agent", maxLength: 64)
    }

    private var dnaAgentIdValid: Bool {
        Self.validateAgentId(effectiveDNAAgentId)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.k("agent.create.form.agent_id.preview", fallback: "实际 ID：") + effectiveAgentId)
                                .font(.caption)
                                .foregroundColor(agentIdValid ? .secondary : .red)
                            if let err = Self.agentIdValidationError(effectiveAgentId) {
                                Text(err)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                } header: {
                    Text(L10n.k("agent.create.form.identifier", fallback: "标识符"))
                } footer: {
                    Text(L10n.k("agent.create.form.agent_id.hint", fallback: "留空则根据名称自动生成。仅限小写字母、数字、下划线和短横线。"))
                        .font(.caption)
                }

                Section {
                    LabeledContent(L10n.k("agent.create.form.model", fallback: "主模型")) {
                        ModelPicker(username: username, selection: $modelPrimary, allowsInheritDefault: true)
                    }

                    ForEach(modelFallbacks.indices, id: \.self) { idx in
                        LabeledContent(L10n.f("agent.create.form.fallback_model", fallback: "备用模型 %d", idx + 1)) {
                            HStack(spacing: 6) {
                                ModelPicker(username: username, selection: $modelFallbacks[idx], allowsInheritDefault: false)
                                Button {
                                    modelFallbacks.remove(at: idx)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        modelFallbacks.append("")
                    } label: {
                        Label(L10n.k("agent.create.form.add_fallback", fallback: "添加备用模型"), systemImage: "plus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                } header: {
                    Text(L10n.k("agent.create.form.model_config", fallback: "模型配置"))
                } footer: {
                    Text(L10n.k("agent.create.form.model.hint", fallback: "留空主模型则使用虾的全局默认。从下拉里选已配置的模型，或先去「模型」tab 添加。"))
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
                self.dnaAgentId = ASCIIIdentifier.agentID(from: dna.id, fallbackPrefix: "agent", maxLength: 32)
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
                    if let err = Self.agentIdValidationError(effectiveDNAAgentId) {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
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

    // MARK: - 错误翻译

    /// 把服务端 RPC 错误翻译为用户友好的文案
    private static func humanizeServerError(_ error: Error) -> String {
        let msg = error.localizedDescription
        // OpenClaw agents.create 常见错误
        if msg.contains("\"main\" is reserved") {
            return L10n.k("agent.create.error.main_reserved", fallback: "解析出的 ID 会与系统保留字 \"main\" 冲突，请使用字母/数字作为 ID")
        }
        if msg.contains("already exists") {
            return L10n.k("agent.create.error.already_exists", fallback: "这个 ID 已存在，请换一个")
        }
        if msg.contains("Gateway 未连接") || msg.contains("notConnected") {
            return L10n.k("agent.create.error.gateway_offline", fallback: "Gateway 未运行，请先启动该 Shrimp 再创建角色")
        }
        return msg
    }

    // MARK: - 创建逻辑

    private func createAgent() async {
        isCreating = true
        defer { isCreating = false }

        let id = effectiveAgentId
        let workspace = "~/.openclaw/workspace-\(id)"
        let displayName = name.trimmingCharacters(in: .whitespaces)

        do {
            // 第 1 步：以 ASCII id 作为 name 调 agents.create
            // （服务端从 name 派生 agentId，纯中文输入会被 normalize 为 "main" 冲突）
            var profile = try await gatewayHub.agentsCreate(
                username: username,
                name: id,
                workspace: workspace,
                emoji: emoji.isEmpty ? nil : emoji,
                modelPrimary: modelPrimary.isEmpty ? nil : modelPrimary,
                modelFallbacks: modelFallbacks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            )

            // 第 2 步：若显示名与 id 不同，调 agents.update 设置真实显示名
            if !displayName.isEmpty && displayName != id {
                try await gatewayHub.agentsUpdate(
                    username: username,
                    agentId: profile.id,
                    name: displayName
                )
                profile.name = displayName
            }

            onCreated?(profile)
            dismiss()
        } catch {
            self.error = Self.humanizeServerError(error)
        }
    }

    // MARK: - 从 DNA 导入

    private func importFromDNA(_ dna: AgentDNA) async {
        isCreating = true
        defer { isCreating = false }

        let id = effectiveDNAAgentId
        let workspace = "~/.openclaw/workspace-\(id)"

        do {
            // 1. 以 ASCII id 作为 name 创建 agent（服务端从 name 派生 agentId）
            //    中文名通过后续 agents.update 设置，避免 normalize 冲突
            var profile = try await gatewayHub.agentsCreate(
                username: username,
                name: id,
                workspace: workspace,
                emoji: dna.emoji.isEmpty ? nil : dna.emoji
            )

            // 2. 设置真实的中文显示名
            if !dna.name.isEmpty && dna.name != id {
                try await gatewayHub.agentsUpdate(
                    username: username,
                    agentId: profile.id,
                    name: dna.name
                )
                profile.name = dna.name
            }

            // 3. 通过 RPC 写入 persona 文件（覆盖 bootstrap 默认内容）
            if let soul = dna.fileSoul, !soul.isEmpty {
                try? await gatewayHub.agentsFileSet(username: username, agentId: profile.id, fileName: "SOUL.md", content: soul)
            }
            if let identity = dna.fileIdentity, !identity.isEmpty {
                try? await gatewayHub.agentsFileSet(username: username, agentId: profile.id, fileName: "IDENTITY.md", content: identity)
            }
            if let user = dna.fileUser, !user.isEmpty {
                try? await gatewayHub.agentsFileSet(username: username, agentId: profile.id, fileName: "USER.md", content: user)
            }

            // 无需 restart — RPC 写完 config 后 gateway 自动感知
            onCreated?(profile)
            dismiss()
        } catch {
            self.error = Self.humanizeServerError(error)
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
