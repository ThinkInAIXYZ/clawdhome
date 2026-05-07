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
    let suggestedUsername: String?
}

// MARK: - WebView Coordinator（处理 JS Bridge）

final class RoleMarketCoordinator: NSObject, WKScriptMessageHandler {
    var onAdoptAgent: ((AgentDNA) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "ClawdHomeBridge" else { return }

        // message.body 是 JS postMessage 发来的字典
        guard let body = message.body as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: body),
              let dna = try? JSONDecoder().decode(AgentDNA.self, from: data)
        else {
            print("[Bridge] Failed to parse DNA:", message.body)
            return
        }

        print("[Bridge] Received DNA: \(dna.name) (\(dna.id))")
        DispatchQueue.main.async {
            self.onAdoptAgent?(dna)
        }
    }
}

// MARK: - WKWebView NSViewRepresentable（macOS）

struct RoleMarketWebView: NSViewRepresentable {
    let coordinator: RoleMarketCoordinator

    func makeCoordinator() -> RoleMarketCoordinator { coordinator }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "ClawdHomeBridge")

        let webView = WKWebView(frame: .zero, configuration: config)

        // 加载本地 HTML
        if let url = Bundle.main.url(forResource: "roles", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            print("[RoleMarketWebView] roles.html not found in Bundle!")
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - RoleMarketView（主 View）

struct RoleMarketView: View {
    @State private var adoptedDNA: AgentDNA? = nil
    @State private var awakeningError: String? = nil

    @Environment(HelperClient.self) private var helperClient
    @Environment(ShrimpPool.self) private var pool
    @Environment(\.openWindow) private var openWindow

    private let coordinator = RoleMarketCoordinator()

    var body: some View {
        RoleMarketWebView(coordinator: coordinator)
            .onAppear {
                coordinator.onAdoptAgent = { dna in
                    self.adoptedDNA = dna
                }
            }
            .sheet(item: $adoptedDNA) { dna in
                AwakeningWizardView(
                    dna: dna,
                    isPresented: .constant(true),
                    onDismiss: { adoptedDNA = nil },
                    onAwaken: { username, fullName, description, soul, identity, userProfile in
                        Task {
                            do {
                                let password = try UserPasswordStore.generateAndSave(for: username)
                                try await helperClient.createUser(
                                    username: username,
                                    fullName: fullName,
                                    password: password
                                )
                                
                                // 把在市场配置的 DNA 提前落盘
                                let workspaceDir = ".openclaw/workspace"
                                try? await helperClient.createDirectory(username: username, relativePath: workspaceDir)
                                if !soul.isEmpty {
                                    try? await helperClient.writeFile(username: username, relativePath: "\(workspaceDir)/SOUL.md", data: soul.data(using: .utf8) ?? Data())
                                }
                                if !identity.isEmpty {
                                    try? await helperClient.writeFile(username: username, relativePath: "\(workspaceDir)/IDENTITY.md", data: identity.data(using: .utf8) ?? Data())
                                }
                                if !userProfile.isEmpty {
                                    try? await helperClient.writeFile(username: username, relativePath: "\(workspaceDir)/USER.md", data: userProfile.data(using: .utf8) ?? Data())
                                }

                                pool.loadUsers()
                                pool.setDescription(description, for: username)
                                openWindow(id: "claw-detail", value: username)
                            } catch {
                                awakeningError = error.localizedDescription
                            }
                        }
                    }
                )
                .frame(minWidth: 460, minHeight: 560)
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
}
