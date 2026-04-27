// ClawdHome/Views/ConfigTabView.swift

import SwiftUI

// MARK: - 配置 Tab (openclaw.json)

struct ConfigTabView: View {
    let username: String
    @Environment(HelperClient.self) private var helperClient
    @Environment(GatewayHub.self) private var gatewayHub
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isRestartingGateway = false
    @State private var errorMessage: String?
    @State private var jsonError: String?

    private let relPath = ".openclaw/openclaw.json"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("openclaw.json")
                    .font(.headline)
                Spacer()
                if isSaving || isRestartingGateway {
                    ProgressView().controlSize(.small)
                }
                Button { Task { await load() } } label: {
                    Label(L10n.k("user.detail.auto.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isLoading || isSaving || isRestartingGateway)
                Button(
                    isRestartingGateway
                        ? L10n.k("views.user_detail_view.restarting_gateway", fallback: "重启中…")
                        : (isSaving
                            ? L10n.k("views.config_tab_view.saving", fallback: "保存中…")
                            : L10n.k("views.config_tab_view.save_and_restart", fallback: "保存并重启 Gateway"))
                ) { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isLoading || isSaving || isRestartingGateway || jsonError != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let jsonError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(jsonError).font(.caption).foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
            }

            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
            }

            if isLoading {
                ProgressView(L10n.k("user.detail.auto.loading", fallback: "加载中…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .onChange(of: content) { _, newVal in validateJSON(newVal) }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
                Text(L10n.k("views.config_tab_view.footer_hint", fallback: "编辑 .openclaw/openclaw.json 主配置。保存后将自动重启 Gateway 使配置生效。JSON 校验错误时保存按钮将禁用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await helperClient.readFile(username: username, relativePath: relPath)
            let raw = String(data: data, encoding: .utf8) ?? ""
            // 格式化 JSON 便于阅读
            if let jsonData = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let formatted = String(data: pretty, encoding: .utf8) {
                content = formatted
            } else {
                content = raw
            }
            validateJSON(content)
        } catch {
            errorMessage = L10n.f("views.user_detail_view.text_bc49b91a", fallback: "读取失败：%@", String(describing: error.localizedDescription))
        }
    }

    private func save() async {
        guard jsonError == nil else { return }
        isSaving = true
        isRestartingGateway = false
        errorMessage = nil
        defer {
            isSaving = false
            isRestartingGateway = false
        }
        guard let data = content.data(using: .utf8) else { return }
        do {
            try await helperClient.writeFile(username: username, relativePath: relPath, data: data)
            isSaving = false
            isRestartingGateway = true
            gatewayHub.markPendingStart(username: username)
            try await helperClient.restartGateway(username: username)
        } catch {
            errorMessage = L10n.f("views.user_detail_view.text_1eacd4c6", fallback: "保存失败：%@", String(describing: error.localizedDescription))
        }
    }

    private func validateJSON(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            jsonError = nil; return
        }
        guard let data = text.data(using: .utf8) else { jsonError = L10n.k("user.detail.auto.encoding_error", fallback: "编码错误"); return }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            jsonError = nil
        } catch {
            let desc = error.localizedDescription
            if let r = desc.range(of: "line ") {
                jsonError = L10n.f("views.user_detail_view.json", fallback: "JSON 语法错误：%@", String(describing: desc[r.lowerBound...]))
            } else {
                jsonError = L10n.k("user.detail.auto.json", fallback: "JSON 语法错误")
            }
        }
    }
}
