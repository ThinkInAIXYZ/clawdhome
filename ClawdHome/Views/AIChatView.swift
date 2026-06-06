// ClawdHome/Views/AIChatView.swift
// 智能对话助手模块 - 与全局「模型模块」深度互通版

import SwiftUI
import AppKit

// MARK: - 消息模型
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let sender: MessageSender
    let timestamp: Date
    let text: String
    var imageData: Data? // 多模态支持：图像 JPEG 序列化数据

    enum MessageSender: String, Codable {
        case user
        case assistant
    }
}

// MARK: - 互通型模型可选项定义 (支持 Hashable 绑定 Picker)
struct ModelOption: Identifiable, Hashable {
    var id: String {
        let templateId = template?.id.uuidString ?? "local"
        return "\(modelId)_\(templateId)"
    }
    
    let modelId: String                // 全局模型 ID，如 "bailian/qwen3.6-plus" 或 "mlx-community/Qwen2.5-7B-Instruct-4bit"
    let displayName: String            // 漂亮的展示名称，如 "Qwen3.6 Plus (百炼-主账号)"
    let template: ProviderTemplate?    // 关联的账户模板，用于读取密钥与自定义 BaseURL
    
    static func == (lhs: ModelOption, rhs: ModelOption) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 智能对话状态管理 (Observation 框架)
@Observable
final class AIChatViewModel {
    // 持久化上次选择的模型 ID
    static let lastModelKey = "ai.clawdhome.ailab.chat.lastSelectedModelId"
    
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var selectedImage: NSImage? = nil
    var isSending: Bool = false
    var selectedOption: ModelOption? = nil {
        didSet {
            // 选择变更时自动持久化
            if let option = selectedOption {
                UserDefaults.standard.set(option.id, forKey: Self.lastModelKey)
            }
        }
    }
    
    /// 从 UserDefaults 恢复上次选择的模型
    static var lastSelectedModelId: String? {
        UserDefaults.standard.string(forKey: lastModelKey)
    }

    // 初始化：messages 默认为空数组，由 WelcomeEmptyState 展示欢迎页
    init() {}

    /// 清空当前会话，恢复到欢迎空状态
    func clearChat() {
        messages = []
        inputText = ""
        selectedImage = nil
    }

    /// 复制消息文本到系统剪贴板
    func copyMessageToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 重新生成最后一条 AI 回复：找到最后一条用户消息，删除最后的 AI 回复，重新发送
    func regenerateLastResponse(option: ModelOption) async {
        // 找到最后一条用户消息
        guard let lastUserIndex = messages.lastIndex(where: { $0.sender == .user }) else { return }
        
        // 保留该用户消息的文本与图像数据
        let userMessage = messages[lastUserIndex]
        
        // 删除该用户消息之后的所有消息（包含用户消息本身，sendMessage 会重新将其 append 入 messages）
        messages = Array(messages.prefix(upTo: lastUserIndex))
        
        // 恢复之前的文字与图片并调用 sendMessage
        await MainActor.run {
            self.inputText = userMessage.text
            if let imgData = userMessage.imageData {
                self.selectedImage = NSImage(data: imgData)
            } else {
                self.selectedImage = nil
            }
        }
        await sendMessage(option: option)
    }

    // MARK: - 选择本地图片
    func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L10n.k("auto.ailab_view.choose_image", fallback: "选择本地图片进行分析")

        if panel.runModal() == .OK, let url = panel.url {
            if let nsImage = NSImage(contentsOf: url) {
                self.selectedImage = nsImage
            }
        }
    }

    func clearSelectedImage() {
        self.selectedImage = nil
    }

    // MARK: - 发送消息并调用底层模型服务
    func sendMessage(option: ModelOption) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || selectedImage != nil else { return }

        await MainActor.run {
            self.isSending = true
        }

        // 处理多模态图像 JPEG 压缩暂存
        var imgData: Data? = nil
        if let selectedImage {
            if let tiff = selectedImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
                imgData = jpeg
            }
        }

        let userMsg = ChatMessage(
            id: UUID(),
            sender: .user,
            timestamp: Date(),
            text: trimmed,
            imageData: imgData
        )

        await MainActor.run {
            self.messages.append(userMsg)
            self.inputText = ""
            self.selectedImage = nil
        }

        do {
            let reply: String
            
            if let template = option.template {
                // 1. 云端账户或自定义账户模型互通：自动定位 Secrets 秘钥库
                let secretKey = "\(template.providerGroupId):\(template.name)"
                let apiKey = GlobalSecretsStore.shared.value(for: secretKey, fallbackProvider: template.providerGroupId) ?? ""
                
                // 完美调用 ClawdHome 核心多协议调度器 ModelPingService
                reply = try await ModelPingService.shared.chat(
                    modelId: option.modelId,
                    apiKey: apiKey,
                    message: trimmed,
                    imageData: imgData,
                    maxTokens: 4096,
                    baseURL: template.customBaseURL,
                    apiType: template.customAPIType,
                    authHeader: template.providerGroupId == "minimax"
                )
            } else {
                // 2. 本地离线默认模型
                reply = try await ModelPingService.shared.chat(
                    modelId: option.modelId,
                    apiKey: "local",
                    message: trimmed,
                    imageData: imgData,
                    maxTokens: 4096,
                    baseURL: "http://localhost:18800",
                    apiType: "openai-completions"
                )
            }

            // 流式打字机视觉输出
            await typeOutReply(reply)

        } catch {
            await MainActor.run {
                // 出错时，流式吐出人性化的错误卡片和故障排查指引
                let displayError = error.localizedDescription
                let isCloudModel = option.template != nil
                let modelShort = option.modelId.components(separatedBy: "/").last ?? option.modelId
                
                let fallbackText: String
                if isCloudModel {
                    fallbackText = L10n.k("auto.ailab_view.cloud_chat_error", fallback: "⚠️ 呼叫云端大模型失败。\n\n**详细诊断：**\n*   **模型**：`\(option.modelId)`\n*   **账户**：`\(option.template?.displayNameWithAlias ?? "未知")`\n*   **异常详情**：\(displayError)\n\n请前往「全局模型池」检查该账户配置的 API Key 凭证是否过期或有效。")
                } else {
                    fallbackText = L10n.k("auto.ailab_view.local_chat_error", fallback: "⚠️ 呼叫本地离线大模型失败。\n\n**详细诊断：**\n*   **模型**：`\(modelShort)`\n*   **异常详情**：\(displayError)\n\n所有对话数据已严格保存在 Shrimp 目录，安全不离机。请前往「全局模型池」确认本地内置大模型服务是否已一键启动并完成模型装载。")
                }
                
                Task {
                    await typeOutReply(fallbackText)
                }
            }
        }
    }

    // 流式打字机动效呈现
    private func typeOutReply(_ text: String) async {
        let aiMsgId = UUID()
        
        await MainActor.run {
            self.messages.append(ChatMessage(id: aiMsgId, sender: .assistant, timestamp: Date(), text: ""))
            self.isSending = false
        }

        var tempStr = ""
        for char in text {
            tempStr.append(char)
            try? await Task.sleep(nanoseconds: 10_000_000) // 10毫秒流式吐字速率
            
            await MainActor.run {
                if let idx = self.messages.firstIndex(where: { $0.id == aiMsgId }) {
                    self.messages[idx] = ChatMessage(id: aiMsgId, sender: .assistant, timestamp: Date(), text: tempStr)
                }
            }
        }
    }
}

// MARK: - SwiftUI 智能对话视图 (互通版)
struct AIChatView: View {
    @Environment(HelperClient.self) private var helperClient
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = AIChatViewModel()
    
    // 返回 AI 实验室回调
    let onBack: () -> Void

    // 动态从模型池组装可选项列表
    private var allOptions: [ModelOption] {
        let active = modelStore.sortedActiveModels
        
        // 1. 如果模型账户为空，优雅地回退并展示三个离线内置精选模型
        if active.isEmpty {
            return [
                ModelOption(modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: L10n.k("auto.ailab_view.qwen25_7b", fallback: "Qwen2.5 7B (推荐)"), template: nil),
                ModelOption(modelId: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: L10n.k("auto.ailab_view.qwen25_3b", fallback: "Qwen2.5 3B (轻量)"), template: nil),
                ModelOption(modelId: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B", template: nil)
            ]
        }
        
        // 2. 提取用户在模型模块中配置并排序后的所有可用模型项
        return active.map { item in
            ModelOption(modelId: item.modelId, displayName: item.displayName, template: item.provider)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
                .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
            messageArea
            composerView
        }
        .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // 初始化默认选中项：优先恢复上次选择的模型，其次定位全局默认模型
            if viewModel.selectedOption == nil {
                let options = allOptions
                if let savedId = AIChatViewModel.lastSelectedModelId,
                   let matched = options.first(where: { $0.id == savedId }) {
                    viewModel.selectedOption = matched
                } else if let defaultKey = modelStore.defaultModelKey,
                          let matched = options.first(where: { option in
                              if let template = option.template {
                                  return "\(option.modelId)_\(template.id.uuidString)" == defaultKey
                              }
                              return false
                          }) {
                    viewModel.selectedOption = matched
                } else if let first = options.first {
                    viewModel.selectedOption = first
                }
                viewModel.clearChat()
            }
        }
    }

    private var headerView: some View {
        ZStack {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text(L10n.k("auto.ailab_view.back", fallback: "返回实验室"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.clearChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help(L10n.k("auto.ailab_view.new_chat", fallback: "新建会话"))

                Spacer()
            }

            Text(L10n.k("auto.ailab_view.pure_chat", fallback: "智能对话助手"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(colorScheme == .dark ? Color.black.opacity(0.12) : Color(nsColor: .windowBackgroundColor).opacity(0.9))
    }

    @ViewBuilder
    private var messageArea: some View {
        if viewModel.messages.isEmpty && !viewModel.isSending {
            WelcomeEmptyState { prompt in
                viewModel.inputText = prompt
            }
        } else {
            messageScrollView
        }
    }

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(
                            message: message,
                            onCopy: copyAction(for: message),
                            onRegenerate: regenerateAction(for: message)
                        )
                    }

                    if viewModel.isSending {
                        ThinkingBubble()
                            .id("thinking-indicator")
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .padding(24)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.isSending) { _, newValue in
                withAnimation(.easeOut(duration: 0.25)) {
                    if newValue {
                        proxy.scrollTo("thinking-indicator", anchor: .bottom)
                    } else if let lastId = viewModel.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func copyAction(for message: ChatMessage) -> (() -> Void)? {
        guard message.sender == .assistant else { return nil }
        return { viewModel.copyMessageToClipboard(message.text) }
    }

    private func regenerateAction(for message: ChatMessage) -> (() -> Void)? {
        guard message.sender == .assistant else { return nil }
        return {
            if let option = viewModel.selectedOption {
                Task { await viewModel.regenerateLastResponse(option: option) }
            }
        }
    }

    private var composerView: some View {
        VStack(spacing: 0) {
            selectedImagePreview

            Divider()
                .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))

            modelSwitcher
            inputBar
        }
        .background(
            colorScheme == .dark
                ? Color.black.opacity(0.08)
                : Color(nsColor: .windowBackgroundColor).opacity(0.85)
        )
    }

    @ViewBuilder
    private var selectedImagePreview: some View {
        if let selectedImage = viewModel.selectedImage {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: selectedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .cornerRadius(8)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                        )

                    Button(action: viewModel.clearSelectedImage) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.red)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
                .padding(.vertical, 10)

                Spacer()
            }
            .padding(.horizontal, 24)
            .background(colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.015))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var modelSwitcher: some View {
        HStack {
            Menu {
                ForEach(allOptions, id: \.self) { option in
                    Button(action: {
                        viewModel.selectedOption = option
                    }) {
                        HStack {
                            Text(option.displayName)
                            if viewModel.selectedOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                modelSwitcherLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: viewModel.selectedOption) { _, _ in
                viewModel.clearChat()
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var modelSwitcherLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundColor(.blue)
            Text(viewModel.selectedOption?.displayName ?? L10n.k("auto.ailab_view.choose_model", fallback: "选择模型"))
                .font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
        .cornerRadius(6)
        .contentShape(Rectangle())
    }

    private var inputBar: some View {
        HStack(spacing: 14) {
            Button(action: viewModel.selectImage) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 17))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.k("auto.ailab_view.add_photo", fallback: "添加本地图片进行分析"))

            TextField(L10n.k("auto.ailab_view.chat_placeholder", fallback: "给 AI 助手发送消息... (回车发送)"), text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(sendCurrentMessage)
                .disabled(viewModel.isSending)

            Button(action: {
                viewModel.inputText = L10n.k("auto.ailab_view.voice_demo", fallback: "帮我看看这张代码截图有什么性能隐患？")
            }) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.k("auto.ailab_view.voice_input", fallback: "语音输入转译"))

            sendControl
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(colorScheme == .dark ? Color.white.opacity(0.03) : Color(nsColor: .textBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: colorScheme == .dark ? Color.clear : Color.black.opacity(0.015), radius: 4, x: 0, y: 1.5)
        .padding(20)
    }

    @ViewBuilder
    private var sendControl: some View {
        if viewModel.isSending {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(action: sendCurrentMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.blue.gradient)
            }
            .buttonStyle(.plain)
        }
    }

    private func sendCurrentMessage() {
        if let option = viewModel.selectedOption {
            Task {
                await viewModel.sendMessage(option: option)
            }
        }
    }
}

// MARK: - 快捷操作数据结构 (ChatQuickAction)
private struct ChatQuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
}

// MARK: - 欢迎空状态 (WelcomeEmptyState)
private struct WelcomeEmptyState: View {
    let onSelectPrompt: (String) -> Void
    
    private let quickActions: [ChatQuickAction] = [
        ChatQuickAction(
            icon: "💡",
            title: L10n.k("auto.ailab_view.quick_explain", fallback: "解释一个概念"),
            prompt: L10n.k("auto.ailab_view.prompt_explain", fallback: "请帮我用简洁易懂的方式解释一下：")
        ),
        ChatQuickAction(
            icon: "📄",
            title: L10n.k("auto.ailab_view.quick_summarize", fallback: "总结文本"),
            prompt: L10n.k("auto.ailab_view.prompt_summarize", fallback: "请帮我总结以下文本的核心要点：\n\n")
        ),
        ChatQuickAction(
            icon: "</>",
            title: L10n.k("auto.ailab_view.quick_code", fallback: "编写代码"),
            prompt: L10n.k("auto.ailab_view.prompt_code", fallback: "请帮我编写以下功能的代码：")
        ),
        ChatQuickAction(
            icon: "✏️",
            title: L10n.k("auto.ailab_view.quick_write", fallback: "帮我写"),
            prompt: L10n.k("auto.ailab_view.prompt_write", fallback: "请帮我撰写一段关于")
        )
    ]
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 16) {
                // 顶部图标
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.bottom, 4)
                
                // 大号标题
                Text(L10n.k("auto.ailab_view.welcome_title", fallback: "你好"))
                    .font(.system(size: 28, weight: .bold))
                
                // 副标题
                Text(L10n.k("auto.ailab_view.welcome_subtitle", fallback: "今天我能为您提供什么帮助？"))
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                
                Spacer().frame(height: 24)
                
                // 2×2 快捷操作卡片网格
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(quickActions) { action in
                        QuickActionCard(action: action, onTap: {
                            onSelectPrompt(action.prompt)
                        })
                    }
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 快捷操作卡片 (QuickActionCard)
private struct QuickActionCard: View {
    let action: ChatQuickAction
    let onTap: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(action.icon)
                    .font(.system(size: 18))
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(isHovered ? 0.08 : 0.04)
                    : Color(nsColor: .textBackgroundColor).opacity(isHovered ? 0.95 : 0.8)
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(isHovered ? 0.12 : 0.06)
                            : Color.black.opacity(isHovered ? 0.08 : 0.04),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: colorScheme == .dark ? Color.clear : Color.black.opacity(isHovered ? 0.03 : 0.015),
                radius: isHovered ? 6 : 3,
                x: 0,
                y: isHovered ? 3 : 1
            )
            .scaleEffect(isHovered ? 1.025 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 聊天消息气泡 (ChatBubble)
private struct ChatBubble: View {
    let message: ChatMessage
    var onCopy: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.sender == .assistant {
                // AI 气泡
                ZStack {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045))
                        .frame(width: 30, height: 30)
                    Text("🤖")
                        .font(.system(size: 15))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 8) {
                        // 利用 AttributedString 原生轻量渲染 Markdown 和代码高亮
                        if let formatted = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(formatted)
                                .font(.system(size: 13.5))
                                .lineSpacing(4)
                        } else {
                            Text(message.text)
                                .font(.system(size: 13.5))
                                .lineSpacing(4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(colorScheme == .dark ? Color.white.opacity(0.04) : Color(nsColor: .textBackgroundColor))
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06), lineWidth: 1)
                    )
                    .shadow(color: colorScheme == .dark ? Color.clear : Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
                    
                    // 时间戳 + 操作按钮
                    HStack(spacing: 10) {
                        Text(message.timestamp, format: .dateTime.hour().minute())
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        if onCopy != nil || onRegenerate != nil {
                            Spacer().frame(width: 2)
                            
                            // 复制按钮
                            if let onCopy {
                                MessageActionButton(
                                    icon: "doc.on.doc",
                                    action: onCopy
                                )
                            }
                            
                            // 重新生成按钮
                            if let onRegenerate {
                                MessageActionButton(
                                    icon: "arrow.counterclockwise",
                                    action: onRegenerate
                                )
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
                Spacer(minLength: 40)
            } else {
                // 用户气泡
                Spacer(minLength: 40)
                
                VStack(alignment: .trailing, spacing: 8) {
                    // 若用户消息中带图片，进行高质感卡片展示
                    if let imgData = message.imageData, let nsImage = NSImage(data: imgData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 240, maxHeight: 180)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.3), radius: 8, y: 3)
                    }

                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.65)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .cornerRadius(14)
                    }
                    
                    // 时间戳
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.trailing, 4)
                }
                
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 30, height: 30)
                    Text("U")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
    }
}

// MARK: - 消息操作按钮 (MessageActionButton)
private struct MessageActionButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(isHovered ? 0.9 : 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 思考中动画气泡 (ThinkingBubble)
private struct ThinkingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // AI 头像
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 30, height: 30)
                Text("🤖")
                    .font(.system(size: 15))
            }

            VStack(alignment: .leading, spacing: 6) {
                // 跳动圆点指示器
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan.opacity(0.7), Color.blue.opacity(0.5)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 7, height: 7)
                            .offset(y: animating ? -5 : 3)
                            .animation(
                                .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                                value: animating
                            )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.04))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

                // 提示文字
                Text(L10n.k("auto.ailab_view.thinking", fallback: "正在思考..."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.leading, 4)
            }

            Spacer(minLength: 40)
        }
        .onAppear {
            animating = true
        }
    }
}
