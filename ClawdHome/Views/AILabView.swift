// ClawdHome/Views/AILabView.swift

import SwiftUI

// MARK: - AI Lab 工具列表

private struct AITool: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let color: Color
    let available: Bool
}

private let aiTools: [AITool] = [
    AITool(name: L10n.k("auto.ailab_view.speech_to_text", fallback: "语音转文字"), description: L10n.k("auto.ailab_view.file_language", fallback: "将音频文件或实时录音转录为文字，支持多语言识别"),
           icon: "waveform.and.mic", color: .blue, available: false),
    AITool(name: L10n.k("auto.ailab_view.voice_cloning", fallback: "语音克隆"), description: L10n.k("auto.ailab_view.tts", fallback: "录制少量语音样本，克隆出自然流畅的 TTS 音色"),
           icon: "person.wave.2.fill", color: .purple, available: false),
    AITool(name: L10n.k("auto.ailab_view.text_translation", fallback: "文本翻译"), description: L10n.k("auto.ailab_view.localmodels_language", fallback: "基于本地大模型的离线翻译，支持主流语言互译"),
           icon: "globe", color: .green, available: false),
    AITool(name: L10n.k("auto.ailab_view.description", fallback: "图像描述"), description: L10n.k("auto.ailab_view.modelsdescription", fallback: "使用多模态模型为图片生成文字描述或回答视觉问题"),
           icon: "photo.on.rectangle.angled", color: .orange, available: false),
    AITool(name: L10n.k("auto.ailab_view.document_summary", fallback: "文档摘要"), description: L10n.k("auto.ailab_view.pdf", fallback: "自动提取 PDF、文档的核心要点，生成结构化摘要"),
           icon: "doc.text.magnifyingglass", color: .teal, available: false),
]

// MARK: - 视图

struct AILabView: View {
    let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 顶部描述
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("auto.ailab_view.ai_tools_running_locally_data_stays_on_device", fallback: "AI 辅助工具集合，运行在本地，数据不离机"))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.horizontal, 4)

                // 工具卡片网格
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(aiTools) { tool in
                        AIToolCard(tool: tool)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(L10n.k("auto.content_view.ai_lab", fallback: "AI 实验室"))
    }
}

// MARK: - 工具卡片

private struct AIToolCard: View {
    let tool: AITool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: tool.icon)
                        .font(.title2)
                        .foregroundStyle(tool.available ? tool.color : .secondary)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.headline)
                        Text(tool.available ? L10n.k("auto.ailab_view.available", fallback: "可用") : L10n.k("auto.ailab_view.coming_soon", fallback: "即将推出"))
                            .font(.caption)
                            .foregroundStyle(tool.available ? .green : .secondary)
                    }
                    Spacer()
                }

                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if tool.available {
                    Button(L10n.k("auto.ailab_view.open", fallback: "打开")) {}
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(tool.color)
                } else {
                    Text(L10n.k("auto.ailab_view.coming_soon", fallback: "敬请期待"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(4)
        }
        .opacity(tool.available ? 1.0 : 0.75)
    }
}
