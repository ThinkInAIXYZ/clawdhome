// ClawdHome/Views/RoleMarketView.swift
// 角色中心：本地 HTML 市场 + JS Bridge + 唤醒向导

import SwiftUI
import WebKit

// MARK: - DNA 数据模型

struct AgentDNA: Codable, Identifiable {
    let id: String
    let name: String
    let emoji: String
    let soul: String
    let skills: [String]
    let category: String
    let version: String
    // 三个可编辑文件（由 roles.html 模板预填充）
    let fileSoul: String?       // 核心价值观 (SOUL)
    let fileIdentity: String?   // 身份设定 (IDENTITY)
    let fileUser: String?       // 我的画像 (USER)
    // OS 用户名建议值（由模板预填充，用户可修改）
    let suggestedAgentID: String?
}

/// 团队 DNA：由 roles.html 通过 adoptTeam bridge 消息发送过来
struct TeamDNA: Codable, Identifiable {
    let id: String
    let teamName: String
    let teamEmoji: String
    let suggestedInstanceID: String
    let members: [AgentDNA]
}

// MARK: - Shimmer 骨架屏动画修饰器

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear,                                          location: 0.0),
                            .init(color: Color.white.opacity(0.25),                       location: 0.4),
                            .init(color: Color.white.opacity(0.45),                       location: 0.5),
                            .init(color: Color.white.opacity(0.25),                       location: 0.6),
                            .init(color: .clear,                                          location: 1.0),
                        ]),
                        startPoint: UnitPoint(x: phase, y: 0.5),
                        endPoint:   UnitPoint(x: phase + 1, y: 0.5)
                    )
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - 骨架屏占位 View

private struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 30)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 14)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 11)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.10))
                        .frame(width: 44, height: 18)
                }
            }
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.13))
                .frame(height: 28)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .modifier(ShimmerModifier())
    }
}

private struct RoleMarketSkeletonView: View {
    let columns = [GridItem(.adaptive(minimum: 200), spacing: 10)]

    var body: some View {
        // 搜索栏 + 标签占位
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 30)
                .modifier(ShimmerModifier())

            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 48, height: 24)
                        .modifier(ShimmerModifier())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

        // 卡片网格占位
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                SkeletonCard()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

// MARK: - WebView Coordinator（处理 JS Bridge + 加载回调）

final class RoleMarketCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onAdoptAgent: ((AgentDNA) -> Void)?
    var onAdoptTeam: ((TeamDNA) -> Void)?
    var onPageLoaded: (() -> Void)?

    // MARK: JS Bridge
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "ClawdHomeBridge" else { return }
        guard let body = message.body as? [String: Any] else {
            appLog("[Bridge] Failed to parse message: \(message.body)", level: .warn)
            return
        }

        // 区分团队领养 vs 单角色领养
        if let msgType = body["type"] as? String, msgType == "adoptTeam" {
            guard let teamId = body["teamId"] as? String,
                  let teamName = body["teamName"] as? String,
                  let teamEmoji = body["teamEmoji"] as? String,
                  let membersRaw = body["members"] as? [[String: Any]]
            else {
                appLog("[Bridge] Failed to parse TeamDNA: \(body)", level: .warn)
                return
            }
            let teamID = (body["suggestedInstanceID"] as? String)
                ?? (body["suggestedTeamID"] as? String)
                ?? teamName
            let members: [AgentDNA] = membersRaw.compactMap { dict in
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let dna = try? JSONDecoder().decode(AgentDNA.self, from: data)
                else { return nil }
                return dna
            }
            let teamDNA = TeamDNA(
                id: teamId,
                teamName: teamName,
                teamEmoji: teamEmoji,
                suggestedInstanceID: teamID,
                members: members
            )
            appLog("[Bridge] Received TeamDNA: \(teamName) (\(members.count) members)")
            DispatchQueue.main.async { self.onAdoptTeam?(teamDNA) }
            return
        }

        // 普通单角色 DNA
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let dna = try? JSONDecoder().decode(AgentDNA.self, from: data)
        else {
            appLog("[Bridge] Failed to parse DNA: \(message.body)", level: .warn)
            return
        }
        appLog("[Bridge] Received DNA: \(dna.name) (\(dna.id))")
        DispatchQueue.main.async { self.onAdoptAgent?(dna) }
    }

    // MARK: WKNavigationDelegate — 加载完成通知
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.onPageLoaded?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 失败时同样隐藏骨架屏，避免永久卡住
        DispatchQueue.main.async {
            self.onPageLoaded?()
        }
    }
}

private func resolvedRoleMarketLocaleIdentifier() -> String {
    let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
    guard let appLanguage = AppLanguage(rawValue: selected) else { return "en" }

    switch appLanguage {
    case .english:
        return "en"
    case .chineseSimplified:
        return "zh-CN"
    case .system:
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? "zh-CN" : "en"
    }
}

private func javaScriptStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
    guard let data,
          let encoded = String(data: data, encoding: .utf8),
          encoded.count >= 2 else {
        return "\"en\""
    }
    return String(encoded.dropFirst().dropLast())
}

func makeRoleMarketConfiguration(coordinator: RoleMarketCoordinator, localeIdentifier: String) -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    let localeLiteral = javaScriptStringLiteral(localeIdentifier)
    let bootstrap = "window.__clawdhomeLocale = \(localeLiteral);"
    let script = WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    config.userContentController.addUserScript(script)
    config.userContentController.add(coordinator, name: "ClawdHomeBridge")
    return config
}

private func applyRoleMarketLocale(_ localeIdentifier: String, to webView: WKWebView) {
    let localeLiteral = javaScriptStringLiteral(localeIdentifier)
    let script = "window.__clawdhomeLocale = \(localeLiteral); window.setAppLocale && window.setAppLocale(\(localeLiteral));"
    webView.evaluateJavaScript(script, completionHandler: nil)
}

// MARK: - WebView 预热单例缓存

/// App 启动后可提前预热，角色中心打开时直接复用，消除冷启动延迟。
final class RoleMarketWebViewCache {
    static let shared = RoleMarketWebViewCache()
    private init() {}

    private(set) var webView: WKWebView?
    private(set) var coordinator: RoleMarketCoordinator?

    /// 预热：创建 WebView 并加载页面（在已预热时幂等，安全多次调用）。
    @MainActor
    func preloadIfNeeded() {
        guard webView == nil else { return }

        let c = RoleMarketCoordinator()
        let config = makeRoleMarketConfiguration(
            coordinator: c,
            localeIdentifier: resolvedRoleMarketLocaleIdentifier()
        )

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = c
        wv.setValue(false, forKey: "drawsBackground")  // 透明背景，防止白屏闪烁

        // 加载本地 HTML（未来改线上只需替换为 wv.load(URLRequest(url:...))）
        if let url = Bundle.main.url(forResource: "roles", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            appLog("[RoleMarketWebViewCache] roles.html not found in Bundle!", level: .error)
        }

        self.coordinator = c
        self.webView = wv
        appLog("[RoleMarketWebViewCache] WebView preloaded")
    }
}

// MARK: - WKWebView NSViewRepresentable（macOS）

struct RoleMarketWebView: NSViewRepresentable {
    // coordinator 由外部传入（来自缓存单例或当场新建）
    let coordinator: RoleMarketCoordinator
    let localeIdentifier: String

    func makeCoordinator() -> RoleMarketCoordinator { coordinator }

    func makeNSView(context: Context) -> WKWebView {
        // 优先复用预热好的缓存，命中时直接返回，零延迟
        if let cached = RoleMarketWebViewCache.shared.webView {
            appLog("[RoleMarketWebView] Using prewarmed WebView")
            applyRoleMarketLocale(localeIdentifier, to: cached)
            return cached
        }

        // 缓存未命中（未预热或首次）：降级为当场创建
        appLog("[RoleMarketWebView] Cache miss — creating WebView on demand")
        let config = makeRoleMarketConfiguration(
            coordinator: context.coordinator,
            localeIdentifier: localeIdentifier
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        if let url = Bundle.main.url(forResource: "roles", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            appLog("[RoleMarketWebView] roles.html not found in Bundle!", level: .error)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        applyRoleMarketLocale(localeIdentifier, to: nsView)
    }
}

// MARK: - RoleMarketView（主 View）

struct RoleMarketView: View {
    @State private var adoptedDNA: AgentDNA? = nil
    @State private var adoptedTeam: TeamDNA? = nil
    @State private var awakeningError: String? = nil
    /// 缓存已加载完毕时直接为 true，第二次进入跳过骨架屏，无闪烁
    @State private var isPageLoaded: Bool = {
        if let wv = RoleMarketWebViewCache.shared.webView,
           !wv.isLoading, wv.url != nil { return true }
        return false
    }()

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(\.openWindow) private var openWindow

    private struct AwakeningValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 优先取缓存中已初始化好的 coordinator，避免重复注册 JS Handler 崩溃
    private var coordinator: RoleMarketCoordinator {
        RoleMarketWebViewCache.shared.coordinator ?? RoleMarketCoordinator()
    }

    private var localeIdentifier: String {
        resolvedRoleMarketLocaleIdentifier()
    }

    var body: some View {
        ZStack {
            // WebView 层：加载完成前透明（opacity=0），避免白屏
            RoleMarketWebView(coordinator: coordinator, localeIdentifier: localeIdentifier)
                .opacity(isPageLoaded ? 1 : 0)
                .animation(.easeIn(duration: 0.25), value: isPageLoaded)

            // 骨架屏层：加载完成后淡出消失
            if !isPageLoaded {
                ScrollView {
                    RoleMarketSkeletonView()
                }
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        }
        .onAppear {
            coordinator.onAdoptAgent = { dna in
                self.adoptedDNA = dna
            }
            coordinator.onAdoptTeam = { teamDNA in
                self.adoptedTeam = teamDNA
            }
            coordinator.onPageLoaded = {
                withAnimation {
                    self.isPageLoaded = true
                }
            }
        }
        .sheet(item: $adoptedDNA) { dna in
            AwakeningWizardView(
                dna: dna,
                isPresented: .constant(true),
                existingUsers: pool.users.map { AwakeningExistingUser(username: $0.username, fullName: $0.fullName) },
                onDismiss: { adoptedDNA = nil },
                onAwaken: { username, fullName, description, soul, identity, userProfile in
                    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)

                    try validateAwakeningInput(
                        username: normalizedUsername,
                        fullName: normalizedFullName
                    )

                    let password = try UserPasswordStore.generateAndSave(for: normalizedUsername)
                    do {
                        try await helperClient.createUser(
                            username: normalizedUsername,
                            fullName: normalizedFullName,
                            password: password
                        )
                    } catch {
                        throw mapAwakeningCreateError(error, username: normalizedUsername, fullName: normalizedFullName)
                    }

                    // 新建同名账号时，清理可能遗留的初始化进度，避免向导误跳步骤。
                    try? await helperClient.saveInitState(username: normalizedUsername, json: "{}")

                    // 把在市场配置的 DNA 提前落盘
                    let workspaceDir = ".openclaw/workspace"
                    try? await helperClient.createDirectory(username: normalizedUsername, relativePath: workspaceDir)
                    try? await helperClient.applySavedProxySettingsIfAny(username: normalizedUsername)
                    if !soul.isEmpty {
                        try? await helperClient.writeFile(username: normalizedUsername, relativePath: "\(workspaceDir)/SOUL.md", data: soul.data(using: .utf8) ?? Data())
                    }
                    if !identity.isEmpty {
                        try? await helperClient.writeFile(username: normalizedUsername, relativePath: "\(workspaceDir)/IDENTITY.md", data: identity.data(using: .utf8) ?? Data())
                    }
                    if !userProfile.isEmpty {
                        try? await helperClient.writeFile(username: normalizedUsername, relativePath: "\(workspaceDir)/USER.md", data: userProfile.data(using: .utf8) ?? Data())
                    }

                    // 注入 TOOLS.md（共享文件夹指引）
                    let toolsPath = "\(workspaceDir)/TOOLS.md"
                    let toolsExists = (try? await helperClient.readFile(username: normalizedUsername, relativePath: toolsPath)) != nil
                    if !toolsExists {
                        try? await helperClient.writeFile(username: normalizedUsername, relativePath: toolsPath, data: defaultToolsContent.data(using: .utf8) ?? Data())
                    }

                    // workspace 已创建，触发 setupVault 在 workspace 中建立 shared/ 符号链接
                    try? await helperClient.setupVault(username: normalizedUsername)

                    pool.loadUsers()
                    pool.setDescription(description, for: normalizedUsername)
                    pool.markNeedsOnboarding(username: normalizedUsername)
                    NotificationCenter.default.post(name: .roleMarketAdoptionStarted, object: nil)
                    openWindow(id: "user-init-wizard", value: normalizedUsername)
                }
            )
            .frame(minWidth: 460, minHeight: 560)
        }
        .sheet(item: $adoptedTeam) { teamDNA in
            AdoptTeamSheet(
                teamDNA: teamDNA,
                existingUsers: pool.users.map { AwakeningExistingUser(username: $0.username, fullName: $0.fullName) }
            ) { adoptedTeam = nil }
            .frame(minWidth: 460, minHeight: 420)
        }
        .overlay(alignment: .bottom) {
            if let err = awakeningError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .onTapGesture { awakeningError = nil }
            }
        }
        .navigationTitle(L10n.k("role_market.title", fallback: "角色中心"))
    }

    private func validateAwakeningInput(username: String, fullName: String) throws {
        guard !username.isEmpty else {
            throw AwakeningValidationError(message: L10n.k("views.role_market.error_username_empty", fallback: "系统用户名不能为空"))
        }
        guard !fullName.isEmpty else {
            throw AwakeningValidationError(message: L10n.k("views.role_market.error_display_name_empty", fallback: "显示名不能为空"))
        }
        if pool.users.contains(where: { $0.username.caseInsensitiveCompare(username) == .orderedSame }) {
            throw AwakeningValidationError(message: L10n.f("views.role_market.error_username_exists", fallback: "用户名 @%@ 已存在，请换一个再试", username))
        }
        if pool.users.contains(where: { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame }) {
            throw AwakeningValidationError(message: L10n.f("views.role_market.error_display_name_taken", fallback: "显示名「%@」已被使用，请换一个名字", fullName))
        }
    }

    private func mapAwakeningCreateError(_ error: Error, username: String, fullName: String) -> Error {
        let rawMessage = error.localizedDescription
        let lowercased = rawMessage.lowercased()
        let hasDirectoryConflict = lowercased.contains("edspermissionerror")
            || lowercased.contains("ds error: -14120")
            || lowercased.contains("/users/\(username.lowercased())")
        if hasDirectoryConflict {
            return AwakeningValidationError(
                message: L10n.f("views.role_market.error_create_conflict", fallback: "创建失败：检测到用户名或显示名冲突（@%@ / %@）。请修改后重试。", username, fullName)
            )
        }
        return error
    }
}

extension Notification.Name {
    static let roleMarketAdoptionStarted = Notification.Name("RoleMarketAdoptionStarted")
}
