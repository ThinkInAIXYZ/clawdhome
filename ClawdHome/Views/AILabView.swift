// ClawdHome/Views/AILabView.swift
// AI 实验室视图 - 适配 ClawdHome 统一设计语言约束规范

import SwiftUI

// MARK: - AI Lab 工具模型

private struct AITool: Identifiable {
    enum Route {
        case speech
        case chat
        case unavailable
    }

    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let theme: DesignSystem.GradientTheme
    let status: DesignSystem.BadgeStyle
    let route: Route
}

private let aiTools: [AITool] = [
    AITool(
        name: L10n.k("auto.ailab_view.speech_to_text", fallback: "语音转文字"),
        description: L10n.k("auto.ailab_view.file_language", fallback: "将音频或录音转为文字，支持多语言识别与 AI 智能总结，一键生成会议纪要"),
        icon: "waveform.and.mic",
        theme: .blue,
        status: .ready,
        route: .speech
    ),
    AITool(
        name: L10n.k("auto.ailab_view.voice_cloning", fallback: "语音克隆"),
        description: L10n.k("auto.ailab_view.tts", fallback: "录制少量语音样本，克隆出自然流畅的 TTS 音色"),
        icon: "person.wave.2.fill",
        theme: .purple,
        status: .inDevelopment,
        route: .unavailable
    ),
    AITool(
        name: L10n.k("auto.ailab_view.chat_box", fallback: "智能对话"),
        description: L10n.k("auto.ailab_view.chat_box_desc", fallback: "与本地内置的精选大模型进行多轮对话，支持图片多模态分析"),
        icon: "bubble.left.and.bubble.right.fill",
        theme: .emerald,
        status: .demo,
        route: .chat
    ),
    AITool(
        name: L10n.k("auto.ailab_view.description", fallback: "图像描述"),
        description: L10n.k("auto.ailab_view.modelsdescription", fallback: "使用多模态模型为图片生成文字描述或回答视觉问题"),
        icon: "photo.on.rectangle.angled",
        theme: .orange,
        status: .planned,
        route: .unavailable
    ),
    AITool(
        name: L10n.k("auto.ailab_view.document_summary", fallback: "文档摘要"),
        description: L10n.k("auto.ailab_view.pdf", fallback: "自动提取 PDF、文档的核心要点，生成结构化摘要"),
        icon: "doc.text.magnifyingglass",
        theme: .teal,
        status: .planned,
        route: .unavailable
    ),
]

// MARK: - AI 实验室主视图

struct AILabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeRoute: AITool.Route? = nil

    // 采用自适应紧凑网格规划，使卡片比例更加均衡，充分适配不同视窗宽度
    let columns = [GridItem(.adaptive(minimum: 240, maximum: 290), spacing: 16)]

    var body: some View {
        Group {
            if activeRoute == .speech {
                SpeechTranscriptionView {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeRoute = nil
                    }
                }
                .transition(.opacity)
            } else if activeRoute == .chat {
                AIChatView {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        activeRoute = nil
                    }
                }
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        
                        // 顶部优雅的副标题区，带精致的渐变小指示线
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "cpu.fill")
                                    .foregroundStyle(DesignSystem.GradientTheme.blue.gradient)
                                    .font(.system(size: 14, weight: .bold))
                                
                                Text(L10n.k("auto.ailab_view.ai_tools_running_locally_data_stays_on_device", fallback: "AI 辅助工具集合，运行在本地，数据不离机"))
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            
                            // 极细的装饰渐变分割线
                            RoundedRectangle(cornerRadius: 1)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.1), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 1.5)
                                .frame(maxWidth: 400)
                        }
                        .padding(.horizontal, 4)

                        // 瀑布流自适应卡片网格
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(aiTools) { tool in
                                switch tool.route {
                                case .speech:
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            activeRoute = .speech
                                        }
                                    } label: {
                                        AIToolCard(tool: tool)
                                    }
                                    .buttonStyle(.plain)
                                case .chat:
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            activeRoute = .chat
                                        }
                                    } label: {
                                        AIToolCard(tool: tool)
                                    }
                                    .buttonStyle(.plain)
                                case .unavailable:
                                    AIToolCard(tool: tool)
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(colorScheme == .dark ? Color.clear : Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.k("auto.content_view.ai_lab", fallback: "AI 实验室"))
    }
}

// MARK: - 重构后的工具卡片组件

private struct AIToolCard: View {
    let tool: AITool

    var body: some View {
        let isAvailable = tool.status == .ready || tool.status == .demo
        
        ZStack(alignment: .bottomTrailing) {
            // 仿照仪表盘聚合卡片的极高品位设计：右下角倾斜 80pt 的主题渐变水印大图标
            Image(systemName: tool.icon)
                .font(.system(size: 80, weight: .bold))
                .foregroundStyle(
                    tool.theme.gradient.opacity(isAvailable ? 0.05 : 0.025)
                )
                .rotationEffect(.degrees(-12))
                .offset(x: 16, y: 16)
                .clipped()
            
            VStack(alignment: .leading, spacing: 14) {
                // 头部：圆形高光渐变图标 + 标题与状态徽章
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                tool.theme.mainColor.opacity(isAvailable ? 0.12 : 0.06)
                            )
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: tool.icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(tool.theme.gradient)
                            .opacity(isAvailable ? 1.0 : 0.5)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                            .opacity(isAvailable ? 1.0 : 0.8)
                        
                        PremiumStatusBadge(style: tool.status)
                    }
                    Spacer()
                }

                // 功能介绍：带特定行高 and 截断限制，视觉规整统一
                Text(tool.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .lineLimit(3)
                    .frame(minHeight: 52, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isAvailable ? 1.0 : 0.65)

                // 底部操作或规划引导区
                if isAvailable {
                    HStack(spacing: 4) {
                        Spacer()
                        Text(L10n.k("auto.ailab_view.open", fallback: "立即体验"))
                            .font(.system(size: 12, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(tool.theme.mainColor)
                } else {
                    HStack {
                        Spacer()
                        Text(tool.status == .inDevelopment ? "研发阶段" : "规划蓝图")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        // 绑定统一设计语言中的高级玻璃拟态卡片，即使不可点击也保持微光边框与动态渐变以提高视觉连贯性
        .premiumCard(theme: tool.theme, isAvailable: true)
    }
}
