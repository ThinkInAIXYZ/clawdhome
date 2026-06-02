// ClawdHome/Views/ModelManager/ModelDetailView.swift
// 模型详情与连通性测试面板 - 采用 ClawdHome 统一设计语言与 UI 规范重构

import SwiftUI

struct ModelDetailView: View {
    let model: ModelEntry
    @Environment(ProviderKeychainStore.self) private var keychainStore
    @Environment(\.colorScheme) private var colorScheme

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
            VStack(alignment: .leading, spacing: 24) {
                
                // 1. 模型基本信息卡片 (自适应海洋蓝主题)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(DesignSystem.GradientTheme.blue.gradient)
                        Text(L10n.k("auto.model_detail_view.models", fallback: "模型信息"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow(label: L10n.k("auto.model_detail_view.name", fallback: "名称"), value: model.label)
                        Divider().opacity(0.4)
                        infoRow(label: L10n.k("auto.model_detail_view.models_id", fallback: "模型 ID"), value: model.id, isMonospaced: true)
                        Divider().opacity(0.4)
                        
                        HStack {
                            Text("Provider")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                if let p = provider {
                                    let hasKey = keychainStore.hasKey(for: p)
                                    Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(hasKey ? .green : .orange)
                                    Text(p.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                } else {
                                    Text(L10n.k("auto.model_detail_view.unknown", fallback: "未知"))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .premiumCard(theme: .blue, isAvailable: true)

                // 2. 连通性测试卡片 (自适应翡翠绿主题)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(DesignSystem.GradientTheme.emerald.gradient)
                        Text(L10n.k("auto.model_detail_view.connectivity_test", fallback: "连通性测试"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                Task { await runPing() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isPinging {
                                        ProgressView().controlSize(.small)
                                        Text(L10n.k("auto.model_detail_view.text_49562bf14c", fallback: "测试中…"))
                                    } else {
                                        Image(systemName: "bolt.fill")
                                        Text("⚡ Ping")
                                    }
                                }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(isPinging || apiKey == nil ? Color.secondary.opacity(0.15) : Color.accentColor)
                                .foregroundStyle(isPinging || apiKey == nil ? Color.secondary : Color.white)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isPinging || apiKey == nil)
                            
                            if apiKey == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11))
                                    Text(L10n.k("auto.model_detail_view.configuration_api_key", fallback: "需先配置 API Key"))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                            }
                        }
                        
                        if let r = pingResult {
                            HStack(spacing: 8) {
                                Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(r.success ? .green : .red)
                                
                                if r.success {
                                    Text(String(format: "延迟: %.0f ms", r.latencyMs))
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.green)
                                } else {
                                    Text(r.errorMessage ?? L10n.k("auto.model_detail_view.failed", fallback: "连接失败"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.top, 4)
                }
                .premiumCard(theme: .emerald, isAvailable: true)

                // 3. 对话测试卡片 (自适应科技粉紫主题)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(DesignSystem.GradientTheme.purple.gradient)
                        Text(L10n.k("auto.model_detail_view.conversation_test", fallback: "对话测试"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        if chatMessages.isEmpty {
                            HStack {
                                Spacer()
                                Text(L10n.k("auto.model_detail_view.models", fallback: "发送消息与模型对话，验证功能是否正常"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(chatMessages.indices, id: \.self) { i in
                                            let msg = chatMessages[i]
                                            let isUser = msg.role == "user"
                                            
                                            HStack {
                                                if isUser { Spacer() }
                                                
                                                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                                                    Text(isUser ? L10n.k("views.model_detail_view.chat_role_you", fallback: "你") : model.label)
                                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                                        .foregroundStyle(.tertiary)
                                                    
                                                    Text(msg.text)
                                                        .font(.system(size: 12))
                                                        .textSelection(.enabled)
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 8)
                                                        .background(
                                                            isUser
                                                                ? Color.accentColor.opacity(0.14)
                                                                : Color.secondary.opacity(colorScheme == .dark ? 0.08 : 0.04)
                                                        )
                                                        .foregroundStyle(.primary)
                                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                                }
                                                .id(i)
                                                
                                                if !isUser { Spacer() }
                                            }
                                        }
                                    }
                                    .padding(10)
                                }
                                .frame(maxHeight: 220)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                                )
                                .onChange(of: chatMessages.count) { _, count in
                                    if count > 0 {
                                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                                    }
                                }
                            }
                        }
                        
                        if let err = chatError {
                            Text(err)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                        }
                        
                        // 输入区域 - 高亮精致边框
                        HStack(spacing: 8) {
                            TextField(L10n.k("auto.model_detail_view.input", fallback: "输入消息…"), text: $chatInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                )
                                .disabled(isChatting || apiKey == nil)
                                .onSubmit { Task { await sendChat() } }
                            
                            Button {
                                Task { await sendChat() }
                            } label: {
                                Text(isChatting ? L10n.k("auto.model_detail_view.text_c1b894480d", fallback: "发送中") : L10n.k("auto.model_detail_view.send", fallback: "发送"))
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isChatting || chatInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKey == nil ? Color.secondary.opacity(0.15) : Color.accentColor)
                                    .foregroundStyle(isChatting || chatInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKey == nil ? Color.secondary : Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isChatting || chatInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKey == nil)
                            
                            if !chatMessages.isEmpty {
                                Button {
                                    chatMessages = []
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.k("auto.model_detail_view.clear", fallback: "清空对话"))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .premiumCard(theme: .purple, isAvailable: true)

                // 4. 用量统计卡片 (自适应冷灰石板主题)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(DesignSystem.GradientTheme.slate.gradient)
                        Text(L10n.k("auto.model_detail_view.usage_statistics", fallback: "用量统计"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    
                    Text(L10n.k("auto.model_detail_view.no_data_yet_feature_pending", fallback: "暂无数据（功能待实现）"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .premiumCard(theme: .slate, isAvailable: false)
            }
            .padding(24)
        }
        .onChange(of: model.id) { _, _ in
            pingResult = nil
            chatMessages = []
            chatError = nil
        }
    }

    // MARK: - 辅助私有布局组件

    private func infoRow(label: String, value: String, isMonospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: isMonospaced ? .medium : .regular, design: isMonospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
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
