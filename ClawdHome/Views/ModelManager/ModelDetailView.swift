// ClawdHome/Views/ModelManager/ModelDetailView.swift
import SwiftUI

struct ModelDetailView: View {
    let model: ModelEntry
    @Environment(ProviderKeychainStore.self) private var keychainStore

    @State private var pingResult: PingResult? = nil
    @State private var isPinging = false
    @State private var chatMessages: [(role: String, text: String)] = []
    @State private var chatInput = ""
    @State private var isChatting = false
    @State private var chatError: String? = nil

    private var provider: KnownProvider? { KnownProvider.from(modelId: model.id) }
    private var apiKey: String? { provider.flatMap { keychainStore.read(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(L10n.k("auto.model_detail_view.models", fallback: "模型信息")) {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(L10n.k("auto.model_detail_view.name", fallback: "名称"), value: model.label)
                        LabeledContent(L10n.k("auto.model_detail_view.models_id", fallback: "模型 ID")) {
                            Text(model.id)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("Provider") {
                            HStack(spacing: 6) {
                                if let p = provider {
                                    Image(systemName: keychainStore.hasKey(for: p) ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundStyle(keychainStore.hasKey(for: p) ? .green : .secondary)
                                    Text(p.displayName)
                                } else {
                                    Text(L10n.k("auto.model_detail_view.unknown", fallback: "未知")).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox(L10n.k("auto.model_detail_view.connectivity_test", fallback: "连通性测试")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button(isPinging ? L10n.k("auto.model_detail_view.text_49562bf14c", fallback: "测试中…") : "⚡ Ping") {
                                Task { await runPing() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isPinging || apiKey == nil)
                            if apiKey == nil {
                                Text(L10n.k("auto.model_detail_view.configuration_api_key", fallback: "需先配置 API Key")).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let r = pingResult {
                            HStack(spacing: 6) {
                                Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r.success ? .green : .red)
                                if r.success {
                                    Text(String(format: "%.0f ms", r.latencyMs))
                                        .monospacedDigit().foregroundStyle(.green)
                                } else {
                                    Text(r.errorMessage ?? L10n.k("auto.model_detail_view.failed", fallback: "失败"))
                                        .font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox(L10n.k("auto.model_detail_view.conversation_test", fallback: "对话测试")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if chatMessages.isEmpty {
                            Text(L10n.k("auto.model_detail_view.models", fallback: "发送消息与模型对话，验证功能是否正常"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(chatMessages.indices, id: \.self) { i in
                                        let msg = chatMessages[i]
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(
                                                msg.role == "user"
                                                    ? L10n.k("views.model_detail_view.chat_role_you", fallback: "你")
                                                    : L10n.k("views.model_detail_view.chat_role_model", fallback: "模型")
                                            )
                                                .font(.caption).foregroundStyle(.secondary)
                                                .frame(width: 36, alignment: .trailing)
                                            Text(msg.text)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(8)
                            }
                            .frame(maxHeight: 200)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let err = chatError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            TextField(L10n.k("auto.model_detail_view.input", fallback: "输入消息…"), text: $chatInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isChatting || apiKey == nil)
                                .onSubmit { Task { await sendChat() } }
                            Button(isChatting ? L10n.k("auto.model_detail_view.text_c1b894480d", fallback: "发送中…") : L10n.k("auto.model_detail_view.send", fallback: "发送")) { Task { await sendChat() } }
                                .buttonStyle(.bordered)
                                .disabled(isChatting || chatInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKey == nil)
                            if !chatMessages.isEmpty {
                                Button(L10n.k("auto.model_detail_view.clear", fallback: "清空")) { chatMessages = [] }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox(L10n.k("auto.model_detail_view.usage_statistics", fallback: "用量统计")) {
                    Text(L10n.k("auto.model_detail_view.no_data_yet_feature_pending", fallback: "暂无数据（功能待实现）"))
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
            .padding(20)
        }
        .onChange(of: model.id) { _, _ in
            pingResult = nil
            chatMessages = []
            chatError = nil
        }
    }

    @MainActor
    private func runPing() async {
        guard let key = apiKey else { return }
        isPinging = true
        pingResult = await ModelPingService.shared.ping(modelId: model.id, apiKey: key)
        isPinging = false
    }

    @MainActor
    private func sendChat() async {
        let msg = chatInput.trimmingCharacters(in: .whitespaces)
        guard !msg.isEmpty, let key = apiKey else { return }
        chatInput = ""
        chatMessages.append((role: "user", text: msg))
        isChatting = true
        chatError = nil
        do {
            let reply = try await ModelPingService.shared.chat(modelId: model.id, apiKey: key, message: msg)
            chatMessages.append((role: "model", text: reply))
        } catch {
            chatError = error.localizedDescription
        }
        isChatting = false
    }
}
