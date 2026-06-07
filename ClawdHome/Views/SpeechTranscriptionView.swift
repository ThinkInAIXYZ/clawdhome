import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

enum SpeechTranscriptionSaveButtonPolicy {
    static func shouldShow(isTranscribing: Bool, isContentModified: Bool, didSaved: Bool) -> Bool {
        guard !isTranscribing else { return false }
        return isContentModified || didSaved
    }
}

struct SpeechTranscriptionView: View {
    var onBack: (() -> Void)? = nil
    @Environment(HelperClient.self) private var helperClient
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var service = SpeechTranscriptionService.shared

    private var markdownPreviewBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.05, green: 0.07, blue: 0.10)
            : Color(NSColor.textBackgroundColor)
    }

    @State private var isImportHovered = false
    @State private var importWaveScale = 1.0
    @State private var importWaveOpacity = 0.15
    @State private var importBorderOpacity = 0.08






    // 是否正在拖拽文件悬停于导入区
    @State private var isDragTargeted = false
    // ASR 配置弹出面板是否显示
    @State private var showSettingsPopover = false
    // AI 精整 Sheet 弹出状态
    @State private var showRefineSheet = false
    // 复制成功短暂提示状态
    @State private var didCopied = false

    // 【新增】内容展现维度与预览格式切换定义
    enum ContentDimension: String, CaseIterable, Identifiable {
        case raw = "粗稿原文"
        case refined = "AI 智能总结"
        case srt = "实时字幕"

        var id: String { rawValue }
    }

    enum PreviewFormat: String, CaseIterable, Identifiable {
        case txt = "TXT"
        case md = "MD"

        var id: String { rawValue }
    }

    @State private var selectedContentTab: ContentDimension = .raw
    @State private var previewFormat: PreviewFormat = .txt
    @State private var editedRefinedText = ""
    @State private var editedRawText = ""
    @State private var isSaving = false
    @State private var didSaved = false

    @State private var didSyncObsidian = false
    @State private var syncObsidianError: String? = nil
    @State private var isSyncingObsidian = false

    @AppStorage("hf_endpoint_preference") private var hfEndpointPreference = ""
    @AppStorage("custom_hf_endpoint") private var customHFEndpoint = ""
    @AppStorage("hf_token_preference") private var hfTokenPreference = ""

    // 状态就绪检测标记，防止在进入界面的一瞬间闪烁不可用提示
    @State private var isChecking = true

    var body: some View {
        VStack(spacing: 0) {
            // 顶层统一的奢华导航条与 UI 主题切换器
            headerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))

            Divider()

            if isChecking {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.0)
                    Text(L10n.k("speech.checking_availability", fallback: "正在检测语音识别引擎可用性..."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.availability.isAvailable {
                GeometryReader { proxy in
                    v1WorkspaceLayout
                        .padding(20)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            } else {
                unavailablePlaceholderView
            }
        }
        .navigationTitle(L10n.k("speech.title", fallback: "语音转文字"))
        .task {
            isChecking = true
            editedRawText = service.currentTranscript
            await refreshService()
            isChecking = false
        }
        .onChange(of: service.currentTranscript) { _, newValue in
            editedRawText = newValue
        }
        .sheet(isPresented: $showRefineSheet) {
            AISpeechRefineSheet()
                .environment(modelStore)
                .environment(helperClient)
        }
    }

    // MARK: - 顶层统一 Header
    private var headerBar: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.k("auto.model_config_wizard.back", fallback: "返回"))
            }
            // 左侧：当前引擎就绪指示器
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(service.availability.isAvailable ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(service.availability.isAvailable ? Color.green.opacity(0.18) : Color.orange.opacity(0.18), lineWidth: 0.5)
                        )

                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(service.availability.isAvailable ? Color.green : Color.orange)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Qwen3-ASR")
                        .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(service.availability.isAvailable ? Color.green : Color.orange)
                            .frame(width: 5, height: 5)
                            .shadow(color: service.availability.isAvailable ? Color.green.opacity(0.6) : Color.orange.opacity(0.6), radius: 2)
                        Text(service.availability.isAvailable ? L10n.k("speech.available", fallback: "就绪") : L10n.k("speech.unavailable", fallback: "不可用"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // 右侧：模型目录与引擎配置
            HStack(spacing: 10) {
                Button {
                    service.openModelsDirectory()
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.k("speech.models.open_cache_help", fallback: "在 Finder 中打开模型缓存目录"))


                Button {
                    showSettingsPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text(L10n.k("speech.engine_settings", fallback: "引擎配置"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(showSettingsPopover ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(showSettingsPopover ? Color.blue.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .foregroundColor(showSettingsPopover ? .blue : .primary)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showSettingsPopover) {
                    v1SettingsSheetContent
                }
            }
        }
    }

    // MARK: - =========================================================================
    // MARK: - [版本 1] 侧边工作流分栏版 (Workspace Split Layout)
    // MARK: - =========================================================================

    private var v1WorkspaceLayout: some View {
        VStack(spacing: 0) {
            // 核心转写工作流（左：导入与队列控制，右：结果展示）
            HStack(alignment: .top, spacing: 20) {
                // 左侧：导入区 + 队列控制 + 历史记录
                VStack(spacing: 16) {
                    v1QueueDropZoneCard

                    if !service.queue.isEmpty {
                        v1QueueControlBar
                    }

                    v1HistoryCard
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: 360, maxHeight: .infinity)

                // 右侧：结果展示工作区
                v1ResultWorkspaceCard
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }



    // V1 批量音频队列导入区 (整合模型选择与状态下载条的一体化设计)
    private var v1QueueDropZoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ASR 引擎模型选择微卡片 (局部芯片样式)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(L10n.k("speech.model", fallback: "模型选择"), systemImage: "cpu")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // 精美紧凑的就绪与不可用状态标志
                    if service.availability.isAvailable {
                        if !service.isPreparingModel && service.isSelectedModelDownloaded {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.green)
                                    .shadow(color: Color.green.opacity(0.15), radius: 2)
                                Text(L10n.k("speech.download_progress.ready_title", fallback: "模型就绪"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(L10n.k("speech.unavailable", fallback: "不可用"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Picker("", selection: $service.selectedModelID) {
                        ForEach(curatedSpeechModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(service.isPreparingModel || service.isTranscribing)

                    // 未下载状态迷你下载按钮
                    if !service.isPreparingModel && !service.isSelectedModelDownloaded {
                        Button {
                            Task { await service.prepareSelectedModel() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle")
                                Text(L10n.k("speech.download", fallback: "下载"))
                            }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(service.availability.isAvailable ? Color.blue.opacity(0.12) : Color.primary.opacity(0.04))
                            .foregroundColor(service.availability.isAvailable ? .blue : .secondary)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .disabled(!service.availability.isAvailable || service.isPreparingModel || service.isTranscribing)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                // 正在准备模型时的微型进度条与百分比
                if service.isPreparingModel {
                    HStack(spacing: 8) {
                        ProgressView(value: service.preparationProgressFraction)
                            .progressViewStyle(.linear)

                        Text(service.preparationProgressPercentText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)

                        Button {
                            service.cancelModelPreparation()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                // 如果不可用，显示具体原因提示，帮助排查
                if !service.availability.isAvailable {
                    Text(service.availability.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(service.availability.isAvailable ? Color.primary.opacity(0.04) : Color.orange.opacity(0.15), lineWidth: 1)
            )

            Divider()
                .opacity(0.4)

            // 标题栏
            HStack {
                Label(L10n.k("speech.import", fallback: "音频导入队列"), systemImage: "list.number")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !service.queue.isEmpty && !service.isTranscribing {
                    Button {
                        withAnimation { service.clearSelection() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.k("speech.queue.clear_help", fallback: "清空队列"))
                }
            }
            .frame(height: 28)

            // 拖拽投放区（始终显示，可追加文件）
            let borderStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [5, 4])
            ZStack {
                // 1. 高级极光渐变背景
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isDragTargeted
                            ? LinearGradient(colors: [Color.blue.opacity(0.08), Color.purple.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : (isImportHovered
                               ? LinearGradient(colors: [Color.blue.opacity(0.04), Color.purple.opacity(0.01)], startPoint: .topLeading, endPoint: .bottomTrailing)
                               : LinearGradient(colors: [Color.primary.opacity(0.015), Color.primary.opacity(0.005)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .animation(.easeInOut(duration: 0.3), value: isDragTargeted || isImportHovered)

                // 2. 悬浮微弱阴影（Hover/Drag 产生发光和立体悬浮感）
                if isImportHovered || isDragTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.clear)
                        .shadow(color: Color.blue.opacity(isDragTargeted ? 0.12 : 0.04), radius: 8, x: 0, y: 4)
                }

                // 3. 动态呼吸虚线边框
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDragTargeted
                            ? Color.blue.opacity(0.8)
                            : (isImportHovered ? Color.blue.opacity(0.35) : Color.blue.opacity(importBorderOpacity)),
                        style: borderStroke
                    )
                    .animation(.easeInOut(duration: 0.3), value: isDragTargeted || isImportHovered)

                // 4. 左侧图标与文本内容排版
                HStack(spacing: 12) {
                    ZStack {
                        // 【新增】常态声纳雷达水波纹涟漪 (只有在常态且队列为空时，静谧扩散)
                        if service.queue.isEmpty && !isImportHovered && !isDragTargeted {
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                                .frame(width: 36, height: 36)
                                .scaleEffect(importWaveScale)
                                .opacity(importWaveOpacity)
                        }

                        // 动态微光光晕圆形底色
                        Circle()
                            .fill(
                                isDragTargeted
                                    ? Color.blue.opacity(0.16)
                                    : (isImportHovered ? Color.blue.opacity(0.10) : Color.blue.opacity(0.05))
                            )
                            .frame(width: 36, height: 36)
                            .scaleEffect(isImportHovered ? 1.08 : 1.0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.65), value: isImportHovered)

                        Image(systemName: isDragTargeted ? "arrow.down.circle.fill" : "plus.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: isImportHovered || isDragTargeted ? [.blue, .purple] : [.blue, .blue.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .offset(y: isDragTargeted ? 2 : 0)
                            .scaleEffect(isImportHovered ? 1.06 : 1.0)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isDragTargeted || isImportHovered)
                            .animation(isDragTargeted ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true) : .default, value: isDragTargeted)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.queue.isEmpty ? L10n.k("speech.drag_hint", fallback: "将音频文件拖拽至此，或点击选择") : "继续添加更多文件…")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isImportHovered ? Color.primary : Color.primary.opacity(0.85))

                        Text("MP3 · WAV · M4A · FLAC · AAC")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(isImportHovered ? Color.secondary : Color.secondary.opacity(0.6))
                    }
                    .animation(.easeInOut(duration: 0.25), value: isImportHovered)

                    Spacer()
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 64)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hover in
                withAnimation(.easeInOut(duration: 0.25)) {
                    isImportHovered = hover
                }
            }
            .onTapGesture { chooseAudioFile() }
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                let urls = providers.compactMap { provider -> URL? in
                    var result: URL?
                    let semaphore = DispatchSemaphore(value: 0)
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        result = url
                        semaphore.signal()
                    }
                    semaphore.wait()
                    return result
                }.filter { url in
                    let ext = url.pathExtension.lowercased()
                    return ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "wma"].contains(ext)
                }
                guard !urls.isEmpty else { return false }
                DispatchQueue.main.async {
                    withAnimation { service.enqueueFiles(urls) }
                }
                return true
            }
            .onAppear {
                // 将无限循环动画的触发强行延迟到下一个 RunLoop 渲染周期，确保 100% 顺利激活
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 3.2).repeatForever(autoreverses: false)) {
                        importWaveScale = 1.7
                        importWaveOpacity = 0.0
                    }
                    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                        importBorderOpacity = 0.22
                    }
                }
            }

            // 队列任务列表
            if !service.queue.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(service.queue) { item in
                            v1QueueItemRow(item: item)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: min(CGFloat(service.queue.count) * 48, 240))
            }
        }
    }

    // V1 队列单行任务卡片
    @ViewBuilder
    private func v1QueueItemRow(item: SpeechQueueItem) -> some View {
        let isSelected = service.selectedQueueItem?.id == item.id

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                service.selectedQueueItem = item
            }
        } label: {
            HStack(spacing: 10) {
                // 状态图标
                ZStack {
                    Circle()
                        .fill(queueItemStatusColor(item.status).opacity(0.12))
                        .frame(width: 28, height: 28)

                    if item.status == .transcribing {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(queueItemStatusColor(item.status))
                    } else {
                        Image(systemName: queueItemStatusIcon(item.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(queueItemStatusColor(item.status))
                    }
                }

                // 文件名与进度/状态
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .blue : .primary)

                    if item.status == .transcribing {
                        HStack(spacing: 6) {
                            Text(item.statusMessage ?? queueItemStatusLabel(item.status))

                            // 真正开始 ASR 转换阶段时，才开始显示速率
                            if item.stage == .transcribing, let speed = item.asrSpeed {
                                Text("⚡️ \(speed)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.purple)
                            }
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else if item.status == .completed {
                        HStack(spacing: 6) {
                            Text(L10n.f("speech.queue.completed_meta", fallback: "✓ 完成 · %.1fs · %d 字", item.elapsedSeconds, item.transcriptText.count))
                            if let speed = item.asrSpeed {
                                Text("⚡️ \(speed)")
                                    .foregroundStyle(.purple.opacity(0.8))
                            }
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else if item.status == .failed {
                        Text(item.errorSummary ?? L10n.k("speech.queue.failed", fallback: "转写失败"))
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.8))
                            .lineLimit(1)
                    } else if item.status == .cancelled {
                        Text(L10n.k("speech.queue.cancelled", fallback: "已取消"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(queueItemStatusLabel(item.status))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 真正开始 ASR 转换时，才在右侧显示 ASR 进度的百分比
                if item.status == .transcribing && item.stage == .transcribing {
                    Text("\(Int((item.stageProgress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                        .frame(width: 34, alignment: .trailing)
                }

                // 删除按钮（非转写中才可删除）
                if item.status != .transcribing {
                    Button {
                        withAnimation { service.removeQueueItem(id: item.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? Color.blue.opacity(0.06) : Color(NSColor.controlBackgroundColor).opacity(0.25))

                    if item.status == .transcribing {
                        if item.stage == .transcribing {
                            // 真正 ASR 转换阶段时，才开始显示专属进度条
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue.opacity(0.18), Color.purple.opacity(0.12)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, proxy.size.width * CGFloat(min(max(item.stageProgress, 0), 1))))
                            }
                        } else if item.stage == .enhancing {
                            // 人声增强降噪预处理阶段显示极其柔和的青色底色，没有进度条，代表预处理中
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.cyan.opacity(isSelected ? 0.08 : 0.04))
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? Color.blue.opacity(0.22) : Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func queueItemStatusIcon(_ status: SpeechQueueItemStatus) -> String {
        switch status {
        case .waiting:     return "clock"
        case .transcribing: return "waveform"
        case .completed:   return "checkmark"
        case .failed:      return "exclamationmark"
        case .cancelled:   return "xmark"
        }
    }

    private func queueItemStatusColor(_ status: SpeechQueueItemStatus) -> Color {
        switch status {
        case .waiting:     return .secondary
        case .transcribing: return .blue
        case .completed:   return .green
        case .failed:      return .red
        case .cancelled:   return .secondary
        }
    }

    private func queueItemStatusLabel(_ status: SpeechQueueItemStatus) -> String {
        switch status {
        case .waiting:     return "等待中"
        case .transcribing: return "转写中…"
        case .completed:   return "完成"
        case .failed:      return "失败"
        case .cancelled:   return "已取消"
        }
    }

    // V1 批量队列控制条（替代原单文件控制面板）
    private var v1QueueControlBar: some View {
        VStack(spacing: 10) {
            // 转写中状态
            if service.isTranscribing {
                // 中止整个队列
                Button {
                    service.cancelAllQueueTranscriptions()
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 12))
                        Text(L10n.k("speech.queue.cancel_all", fallback: "中止全部转写"))
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .frame(height: 34)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.27, blue: 0.23), Color(red: 1.0, green: 0.18, blue: 0.14)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(10)
                    .shadow(color: Color.red.opacity(0.18), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
            } else {
                // 等待启动状态
                let waitingCount = service.queue.filter { $0.status == .waiting }.count
                let completedCount = service.queue.filter { $0.status == .completed }.count

                HStack(spacing: 8) {
                    // 开始批量转写
                    Button {
                        Task { await service.transcribeSelectedFile() }
                    } label: {
                        HStack(spacing: 6) {
                            Spacer()
                            Image(systemName: waitingCount > 1 ? "play.circle.fill" : "play.fill")
                                .font(.system(size: 13))
                            Text(waitingCount > 1 ? L10n.f("speech.queue.start_batch", fallback: "批量转写（%d 个）", waitingCount) : L10n.k("speech.queue.start_one", fallback: "开始转写"))
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .frame(height: 36)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(10)
                        .shadow(color: Color.blue.opacity(0.2), radius: 6, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!service.availability.isAvailable || waitingCount == 0 || service.isPreparingModel)

                    // 清理已完成/失败/取消的任务
                    if completedCount > 0 {
                        Button {
                            withAnimation { service.cleanQueue() }
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Color.primary.opacity(0.04))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(L10n.k("speech.queue.clean_completed_help", fallback: "清理已完成的任务"))
                    }
                }
            }

            if let error = service.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }

    // V1 结果展示工作区
    private var v1ResultWorkspaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                // 1. 首选长布局（行内完整版，适合超大屏幕 >= 650pt）
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Label(L10n.k("speech.content.title", fallback: "内容整理"), systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        wordCountBadge
                    }

                    Spacer(minLength: 16)

                    Picker("", selection: $selectedContentTab) {
                        Text(L10n.k("speech.content.tab.raw", fallback: "📝 粗稿原文")).tag(ContentDimension.raw)
                        Text(L10n.k("speech.content.tab.refined", fallback: "✨ AI 精装稿")).tag(ContentDimension.refined)
                        Text(L10n.k("speech.content.tab.srt", fallback: "🎬 实时字幕")).tag(ContentDimension.srt)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)

                    Spacer(minLength: 16)

                    HStack(spacing: 6) {
                        if selectedContentTab != .srt {
                            Picker("", selection: $previewFormat) {
                                Text(L10n.k("speech.preview.source", fallback: "📄 源码")).tag(PreviewFormat.txt)
                                Text(L10n.k("speech.preview.rendered", fallback: "👁️ 预览")).tag(PreviewFormat.md)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 135) // 增大到 135 彻底修复“预览”与“AI润色”重叠问题
                            .padding(.trailing, 4)
                        }
                        refineButton
                        copyButton
                        obsidianSyncButton
                        if shouldShowSaveButton {
                            saveButton
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 28)

                // 2. 宽屏行内精简版（省略“内容整理”文字标题以节省水平空间，适合 >= 520pt）
                HStack(spacing: 8) {
                    wordCountBadge

                    Spacer(minLength: 12)

                    Picker("", selection: $selectedContentTab) {
                        Text(L10n.k("speech.content.tab.raw", fallback: "📝 粗稿原文")).tag(ContentDimension.raw)
                        Text(L10n.k("speech.content.tab.refined", fallback: "✨ AI 精装稿")).tag(ContentDimension.refined)
                        Text(L10n.k("speech.content.tab.srt", fallback: "🎬 实时字幕")).tag(ContentDimension.srt)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)

                    Spacer(minLength: 12)

                    HStack(spacing: 6) {
                        if selectedContentTab != .srt {
                            Button {
                                withAnimation {
                                    previewFormat = previewFormat == .txt ? .md : .txt
                                }
                            } label: {
                                Image(systemName: previewFormat == .txt ? "eye" : "doc.text")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help(previewFormat == .txt ? L10n.k("speech.preview.switch_rendered_help", fallback: "切换到预览模式") : L10n.k("speech.preview.switch_source_help", fallback: "切换到编辑模式"))
                        }
                        refineButton
                        copyButton
                        obsidianSyncButton
                        if shouldShowSaveButton {
                            saveButton
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 28)

                // 3. 窄屏极致图标版（精简三态 Picker 宽度至 200pt，且操作按钮全图标化，适合 >= 340pt）
                HStack(spacing: 4) {
                    wordCountBadge

                    Spacer(minLength: 6)

                    Picker("", selection: $selectedContentTab) {
                        Text(L10n.k("speech.content.tab.raw", fallback: "📝 粗稿原文")).tag(ContentDimension.raw)
                        Text(L10n.k("speech.content.tab.refined", fallback: "✨ AI 精装稿")).tag(ContentDimension.refined)
                        Text(L10n.k("speech.content.tab.srt", fallback: "🎬 实时字幕")).tag(ContentDimension.srt)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)

                    Spacer(minLength: 6)

                    HStack(spacing: 4) {
                        if selectedContentTab != .srt {
                            Button {
                                withAnimation {
                                    previewFormat = previewFormat == .txt ? .md : .txt
                                }
                            } label: {
                                Image(systemName: previewFormat == .txt ? "eye" : "doc.text")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help(previewFormat == .txt ? L10n.k("speech.preview.switch_rendered_help", fallback: "切换到预览模式") : L10n.k("speech.preview.switch_source_help", fallback: "切换到编辑模式"))
                        }
                        refineIconButton
                        copyIconButton
                        obsidianSyncIconButton
                        if shouldShowSaveButton {
                            saveButton
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 28)

                // 4. 极窄双行自适应版（双行物理排列，100% 确保窄窗口下所有控制元素完美外露不被切断遮挡，适合 < 340pt）
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Picker("", selection: $selectedContentTab) {
                            Text(L10n.k("speech.content.tab.raw", fallback: "📝 粗稿原文")).tag(ContentDimension.raw)
                            Text(L10n.k("speech.content.tab.refined", fallback: "✨ AI 精装稿")).tag(ContentDimension.refined)
                            Text(L10n.k("speech.content.tab.srt", fallback: "🎬 实时字幕")).tag(ContentDimension.srt)
                        }
                        .pickerStyle(.segmented)

                        if selectedContentTab != .srt {
                            Button {
                                withAnimation {
                                    previewFormat = previewFormat == .txt ? .md : .txt
                                }
                            } label: {
                                Image(systemName: previewFormat == .txt ? "eye" : "doc.text")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help(previewFormat == .txt ? L10n.k("speech.preview.switch_rendered_help", fallback: "切换到预览模式") : L10n.k("speech.preview.switch_source_help", fallback: "切换到编辑模式"))
                        }
                    }

                    HStack(spacing: 6) {
                        wordCountBadge

                        Spacer()

                        refineIconButton
                        copyIconButton
                        obsidianSyncIconButton
                        if shouldShowSaveButton {
                            saveButton
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: shouldShowSaveButton)

            // 3. 底层编辑与预览核心视窗
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(markdownPreviewBackground)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.01), radius: 8, x: 0, y: 4)

                switch selectedContentTab {
                case .raw:
                    rawContentEditor
                case .refined:
                    refinedContentEditor
                case .srt:
                    srtContentEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: service.selectedRecordID) { _, newID in
            if let record = service.selectedHistoryRecord {
                editedRefinedText = record.refinedText ?? ""
                editedRawText = record.transcriptText
                // 始终默认显示原稿，不自动跳转到精装稿
                selectedContentTab = .raw
            } else {
                editedRefinedText = ""
                editedRawText = service.currentTranscript
                selectedContentTab = .raw
            }
        }
        .onChange(of: service.selectedHistoryRecord?.refinedText) { _, newRefined in
            if let newRefined {
                if editedRefinedText != newRefined {
                    editedRefinedText = newRefined
                }
            } else {
                if !editedRefinedText.isEmpty {
                    editedRefinedText = ""
                }
            }
        }
    }

    // A. 粗稿原文内容渲染区
    @ViewBuilder
    private var rawContentEditor: some View {
        if service.currentTranscript.isEmpty {
            waitingPlaceholderView
        } else if previewFormat == .txt {
            // 源码可编辑模式
            TextEditor(text: $editedRawText)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(6)
                .padding(12)
                .scrollContentBackground(.hidden)
        } else {
            // Markdown 渲染预览模式（升级为 MarkdownUI 经典 GFM GitHub 主题渲染）
            ScrollView {
                Markdown(service.currentTranscript)
                    .markdownTheme(.gitHub)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // B. AI 智能精装稿渲染区
    @ViewBuilder
    private var refinedContentEditor: some View {
        if service.selectedHistoryRecord?.refinedText == nil && editedRefinedText.isEmpty {
            // 尚未润色的占位魔法按钮区
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(1.1)

                Text(L10n.k("speech.refine.empty_title", fallback: "✨ 尚未进行 AI 智能精整与专名润色"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.k("speech.refine.empty_desc", fallback: "一键消除口癖语气词，智能理顺断句，提取会议纪要、随记便签，保留原笔记的同时保留精装润色版。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)

                Button {
                    showRefineSheet = true
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text(L10n.k("speech.refine.empty_action", fallback: "立即开启智能精整魔法"))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                    .shadow(color: Color.purple.opacity(0.18), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(service.currentTranscript.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if previewFormat == .txt {
            // 源码可编辑模式
            TextEditor(text: $editedRefinedText)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(6)
                .padding(12)
                .scrollContentBackground(.hidden)
        } else {
            // Markdown 渲染预览模式（升级为 MarkdownUI 经典 GFM GitHub 主题渲染，追加 AI 精修元数据 Header 卡片）
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let record = service.selectedHistoryRecord,
                       ((record.refinedTitle?.isEmpty == false) || (record.refinedSummary?.isEmpty == false) || (record.refinedTags?.isEmpty == false)) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let title = record.refinedTitle, !title.isEmpty {
                                Text(title)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.primary)
                            }

                            if let summary = record.refinedSummary, !summary.isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "quote.opening")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.purple)
                                        .padding(.top, 2)
                                    Text(summary)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(3)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.04))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.purple.opacity(0.12), lineWidth: 0.5)
                                )
                            }

                            if let tags = record.refinedTags, !tags.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(tags, id: \.self) { tag in
                                        Text("#\(tag)")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.blue.opacity(0.08))
                                            .foregroundColor(.blue)
                                            .cornerRadius(6)
                                    }
                                }
                                .padding(.top, 2)
                            }

                            Divider()
                                .padding(.vertical, 8)
                        }
                    }

                    Markdown(editedRefinedText)
                        .markdownTheme(.gitHub)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // C. 实时字幕渲染区
    @ViewBuilder
    private var srtContentEditor: some View {
        if service.currentTranscript.isEmpty {
            waitingPlaceholderView
        } else {
            // 只读字幕编辑器，方便划选及复制
            TextEditor(text: .constant(currentSRTContent))
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(6)
                .padding(12)
                .scrollContentBackground(.hidden)
        }
    }


    private var currentWordCount: Int {
        switch selectedContentTab {
        case .raw: return service.currentTranscript.count
        case .refined: return editedRefinedText.count
        case .srt: return currentSRTContent.count
        }
    }

    private var isContentModified: Bool {
        switch selectedContentTab {
        case .raw:
            let originalText = service.selectedHistoryRecord?.transcriptText ?? service.currentTranscript
            return !editedRawText.isEmpty && editedRawText != originalText
        case .refined:
            let originalText = service.selectedHistoryRecord?.refinedText ?? ""
            return !editedRefinedText.isEmpty && editedRefinedText != originalText
        case .srt:
            return false
        }
    }

    private var shouldShowSaveButton: Bool {
        SpeechTranscriptionSaveButtonPolicy.shouldShow(
            isTranscribing: service.isTranscribing,
            isContentModified: isContentModified,
            didSaved: didSaved
        )
    }

    private var saveButton: some View {
        Button {
            triggerSaveAction()
        } label: {
            HStack(spacing: 4) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: didSaved ? "checkmark" : "checkmark.circle.fill")
                        .foregroundStyle(didSaved ? .green : .white)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(didSaved ? "已保存" : "保存")
                    .foregroundStyle(didSaved ? .green : .white)
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(didSaved ? Color.green.opacity(0.12) : Color.blue.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(didSaved ? Color.green.opacity(0.3) : Color.blue.opacity(0.9), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func triggerSaveAction() {
        guard !isSaving else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isSaving = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if selectedContentTab == .raw {
                if service.selectedRecordID != nil {
                    service.updateSelectedRecordTranscript(editedRawText)
                } else {
                    service.currentTranscript = editedRawText
                }
            } else if selectedContentTab == .refined {
                service.updateSelectedRecordRefinedText(editedRefinedText)
            }

            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isSaving = false
                didSaved = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    didSaved = false
                }
            }
        }
    }

    // 智能字幕的物理文件路径读取（支持转译过程中的实时生成与展示）
    private var currentSRTContent: String {
        if let record = service.selectedHistoryRecord {
            let baseDir = SpeechHistoryStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("speech_transcription").appendingPathComponent("records")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = formatter.string(from: record.createdAt)
            let srtURL = baseDir.appendingPathComponent("\(dateString)_\(record.id.uuidString).srt")
            if let srt = try? String(contentsOf: srtURL, encoding: .utf8) {
                return srt
            }
            return SpeechHistoryStore.generateSRT(from: record.transcriptText, duration: record.durationSeconds ?? 0)
        } else {
            // 没有选中的历史记录，说明可能是当前正在转译的队列项
            let text = service.currentTranscript
            guard !text.isEmpty else { return "" }

            var duration: Double = 0
            if let activeItem = service.selectedQueueItem {
                if activeItem.durationSeconds > 0 {
                    // 转译过程中，估计当前已转译文本对应的音频时长
                    // 比如音频共100秒，转译进度为30%，则当前文本对应前30秒
                    let progress = activeItem.stageProgress > 0 ? activeItem.stageProgress : 0.01
                    duration = activeItem.durationSeconds * progress
                } else {
                    // 兜底：字数估算，中文字符 ≈ 0.25秒
                    duration = Double(text.count) * 0.25
                }
            } else {
                duration = Double(text.count) * 0.25
            }

            // 确保 duration 大于 0 才能正确生成字幕时间戳
            if duration <= 0 {
                duration = Double(text.count) * 0.25
            }
            if duration <= 0 {
                duration = 1.0
            }

            return SpeechHistoryStore.generateSRT(from: text, duration: duration)
        }
    }

    private var waitingPlaceholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 24))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(L10n.k("speech.ui.waiting_placeholder", fallback: "等待开启智能识别任务，提取的离线文本会即时在此处流式展现，并支持高自由度二次编辑。"))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var wordCountBadge: some View {
        Group {
            let currentWordCount: Int = {
                switch selectedContentTab {
                case .raw: return service.currentTranscript.count
                case .refined: return editedRefinedText.count
                case .srt: return currentSRTContent.count
                }
            }()
            if currentWordCount > 0 {
                Text(L10n.f("speech.word_count", fallback: "%d 字", currentWordCount))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
            }
        }
    }

    private var refineButton: some View {
        Button {
            showRefineSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text(service.selectedHistoryRecord?.refinedText != nil ? "重新总结" : "AI 总结")
            }
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.12), Color.blue.opacity(0.08)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.3), Color.blue.opacity(0.2)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(service.currentTranscript.isEmpty)
    }

    private var refineIconButton: some View {
        let isDisabled = service.currentTranscript.isEmpty
        return Button {
            showRefineSheet = true
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(isDisabled ? Color.secondary : .purple)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(isDisabled ? Color.primary.opacity(0.03) : Color.purple.opacity(0.08))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isDisabled ? Color.primary.opacity(0.04) : Color.purple.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(service.selectedHistoryRecord?.refinedText != nil ? "重新总结" : "AI 智能总结")
    }

    private var copyButton: some View {
        Button {
            let textToCopy: String
            switch selectedContentTab {
            case .raw: textToCopy = service.currentTranscript
            case .refined: textToCopy = editedRefinedText
            case .srt: textToCopy = currentSRTContent
            }
            service.copyTranscript(textToCopy)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { didCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { didCopied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: didCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(didCopied ? .green : .primary)
                Text(didCopied ? "已复制" : "复制")
                    .foregroundStyle(didCopied ? .green : .primary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(didCopied ? Color.green.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(didCopied ? Color.green.opacity(0.2) : Color.primary.opacity(0.04), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(currentWordCount == 0)
    }

    private var copyIconButton: some View {
        Button {
            let textToCopy: String
            switch selectedContentTab {
            case .raw: textToCopy = service.currentTranscript
            case .refined: textToCopy = editedRefinedText
            case .srt: textToCopy = currentSRTContent
            }
            service.copyTranscript(textToCopy)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { didCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { didCopied = false }
            }
        } label: {
            Image(systemName: didCopied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(didCopied ? .green : .primary)
                .font(.system(size: 10))
                .frame(width: 24, height: 24)
                .background(didCopied ? Color.green.opacity(0.08) : Color.primary.opacity(0.03))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(didCopied ? Color.green.opacity(0.2) : Color.primary.opacity(0.04), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(currentWordCount == 0)
        .help(didCopied ? "已复制" : "复制当前内容")
    }

    private var obsidianSyncTooltip: String {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "obsidian_enabled") else {
            return L10n.k("speech.obsidian.sync_tooltip.disabled", fallback: "未启用 Obsidian 同步，请前往设置开启")
        }
        guard let vaultPath = defaults.string(forKey: "obsidian_vault_path"), !vaultPath.isEmpty else {
            return L10n.k("speech.obsidian.sync_tooltip.path_empty", fallback: "未配置 Obsidian Vault 路径，请前往设置配置")
        }
        let inbox = defaults.string(forKey: "obsidian_inbox") ?? "Inbox"
        let syncPath = URL(fileURLWithPath: vaultPath).appendingPathComponent(inbox).path
        return L10n.f("speech.obsidian.sync_tooltip.path", fallback: "同步至目录：%@\n点击将当前记录手动同步至此目录", syncPath)
    }

    private var obsidianSyncButton: some View {
        Button {
            triggerObsidianSync()
        } label: {
            HStack(spacing: 4) {
                if isSyncingObsidian {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: didSyncObsidian ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.doc.on.doc")
                        .foregroundStyle(didSyncObsidian ? .green : .purple)
                }
                Text(didSyncObsidian ? L10n.k("speech.obsidian.synced", fallback: "已同步") : L10n.k("speech.obsidian.sync", fallback: "同步至 Obsidian"))
                    .foregroundStyle(didSyncObsidian ? .green : .primary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(didSyncObsidian ? Color.green.opacity(0.08) : Color.purple.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(didSyncObsidian ? Color.green.opacity(0.2) : Color.purple.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(currentWordCount == 0 || isSyncingObsidian)
        .help(obsidianSyncTooltip)
    }

    private var obsidianSyncIconButton: some View {
        let isDisabled = currentWordCount == 0 || isSyncingObsidian
        return Button {
            triggerObsidianSync()
        } label: {
            if isSyncingObsidian {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: didSyncObsidian ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.doc.on.doc")
                    .foregroundStyle(isDisabled ? Color.secondary : (didSyncObsidian ? .green : .purple))
                    .font(.system(size: 10))
                    .frame(width: 24, height: 24)
                    .background(isDisabled ? Color.primary.opacity(0.03) : (didSyncObsidian ? Color.green.opacity(0.08) : Color.purple.opacity(0.05)))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isDisabled ? Color.primary.opacity(0.04) : (didSyncObsidian ? Color.green.opacity(0.2) : Color.purple.opacity(0.12)), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(obsidianSyncTooltip)
    }

    private func triggerObsidianSync() {
        guard !isSyncingObsidian else { return }
        guard let record = service.currentHistoryRecord else { return }

        withAnimation {
            isSyncingObsidian = true
            syncObsidianError = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                let success = try service.manualSyncToObsidian(record: record)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isSyncingObsidian = false
                    if success {
                        didSyncObsidian = true
                    }
                }

                if success {
                    let defaults = UserDefaults.standard
                    let vaultPath = defaults.string(forKey: "obsidian_vault_path") ?? ""
                    let inbox = defaults.string(forKey: "obsidian_inbox") ?? "Inbox"
                    let syncPath = URL(fileURLWithPath: vaultPath).appendingPathComponent(inbox).path
                    let noteFileName = SpeechTranscriptionService.obsidianASRNoteFileName(for: record)
                    let fileURL = URL(fileURLWithPath: syncPath).appendingPathComponent(noteFileName)

                    let alert = NSAlert()
                    alert.messageText = L10n.k("speech.obsidian.sync_success", fallback: "同步成功")
                    alert.informativeText = L10n.f("speech.obsidian.sync_success_detail", fallback: "已成功同步至 Obsidian Vault 目录：\n%@\n\n文件名称：\n%@", syncPath, noteFileName)
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: L10n.k("speech.obsidian.sync_success.ok", fallback: "确定"))
                    alert.addButton(withTitle: L10n.k("speech.obsidian.sync_success.reveal_in_finder", fallback: "在 Finder 中显示"))
                    
                    let response = alert.runModal()
                    if response == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        didSyncObsidian = false
                    }
                }
            } catch {
                withAnimation {
                    isSyncingObsidian = false
                    syncObsidianError = error.localizedDescription
                }

                let alert = NSAlert()
                alert.messageText = L10n.k("speech.obsidian.sync_failed", fallback: "Obsidian 同步失败")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: L10n.k("auto.model_config_wizard.ok", fallback: "确定"))
                alert.runModal()
            }
        }
    }

    // V1 历史记录区域
    private var v1HistoryCard: some View {
        SpeechHistoryCard(selectedContentTab: $selectedContentTab)
    }

    // V1 引擎设置 Sheet 内容
    private var v1SettingsSheetContent: some View {
        ASRSettingsSheet(
            hfEndpointPreference: $hfEndpointPreference,
            customHFEndpoint: $customHFEndpoint,
            hfTokenPreference: $hfTokenPreference,
            service: service,
            isPresented: $showSettingsPopover
        )
    }

    // MARK: - =========================================================================
    // MARK: - 通用辅助处理逻辑
    // MARK: - =========================================================================

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true  // 支持多选
        panel.allowedContentTypes = [
            .audio,
            UTType(filenameExtension: "wav"),
            UTType(filenameExtension: "mp3"),
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "aac"),
            UTType(filenameExtension: "flac"),
            UTType(filenameExtension: "opus"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        withAnimation { service.enqueueFiles(urls) }
    }

    private func fileMetadata(for fileURL: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.1f MB", size / 1_048_576)
    }



    private func refreshService() async {
        let llmStatus = await helperClient.getLocalLLMStatus()
        await service.refresh(localAIServiceRunning: llmStatus.isRunning)
    }

    private var unavailablePlaceholderView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.08))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            
            VStack(spacing: 8) {
                Text(L10n.k("speech.unsupported.title", fallback: "当前设备暂不支持语音转文字"))
                    .font(.title3)
                    .fontWeight(.bold)
                
                Text(service.availability.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            // 系统要求配置说明
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.k("speech.unsupported.requirements", fallback: "硬件与系统要求："))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .frame(width: 16)
                        Text(L10n.k("speech.unsupported.cpu_req", fallback: "需要 Apple Silicon (M1/M2/M3/M4 等) 芯片设备"))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "macbook")
                            .frame(width: 16)
                        Text(L10n.k("speech.unsupported.os_req", fallback: "需要 macOS 15 Sequoia 或更高版本操作系统"))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .frame(width: 16)
                        Text(L10n.k("speech.unsupported.bundle_req", fallback: "需要 App 内建 ASR 组件就绪"))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
            )
            
            Button {
                if let onBack {
                    onBack()
                }
            } label: {
                Text(L10n.k("speech.unsupported.btn_back", fallback: "返回 AI 实验室"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 智能实时声波模拟组件
struct ASRWaveformVisualizer: View {
    let isAnimating: Bool
    @State private var heights: [CGFloat] = Array(repeating: 4, count: 18)
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<heights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: isAnimating
                                ? [Color.blue, Color.purple, Color.pink]
                                : [Color.secondary.opacity(0.4), Color.secondary.opacity(0.2)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: heights[index])
            }
        }
        .frame(height: 24)
        .onReceive(timer) { _ in
            guard isAnimating else {
                withAnimation(.easeOut(duration: 0.2)) {
                    // 闲置状态下呈现轻微呼吸波
                    heights = (0..<18).map { _ in CGFloat.random(in: 4...8) }
                }
                return
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                // 运行状态下呈现激烈且动感的波频
                heights = (0..<18).map { _ in CGFloat.random(in: 4...24) }
            }
        }
        .onAppear {
            heights = (0..<18).map { _ in CGFloat.random(in: 4...10) }
        }
    }
}



// 极致微扫光进度条
struct ShimmeringProgressBar: View {
    var progress: Double
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 99)
                    .fill(Color.primary.opacity(0.05))

                RoundedRectangle(cornerRadius: 99)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color(red: 0.0, green: 0.78, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(progress))
                    .overlay(
                        GeometryReader { innerGeo in
                            RoundedRectangle(cornerRadius: 99)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0), Color.white.opacity(0.45), Color.white.opacity(0)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 40)
                                .offset(x: (innerGeo.size.width + 40) * phase - 20)
                        }
                        .clipped()
                    )
                    .shadow(color: Color.blue.opacity(0.2), radius: 2, x: 0, y: 1)
            }
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

// MARK: - AI 智能精整与专名润色面板
struct AISpeechRefineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(HelperClient.self) private var helperClient

    @State private var service = SpeechTranscriptionService.shared

    struct SelectedModelConfig: Hashable, Equatable {
        let provider: ProviderTemplate
        let modelId: String

        var displayName: String {
            "\(provider.providerDisplayName)-\(provider.name) (\(modelId.components(separatedBy: "/").last ?? modelId))"
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(provider.id)
            hasher.combine(modelId)
        }

        static func == (lhs: SelectedModelConfig, rhs: SelectedModelConfig) -> Bool {
            return lhs.provider.id == rhs.provider.id && lhs.modelId == rhs.modelId
        }
    }

    @State private var selectedModel: SelectedModelConfig?
    @State private var glossary = ""
    @State private var refineMode = "原稿智能净化"

    @State private var isRefining = false
    @State private var refinedText = ""
    @State private var refineDuration: Double = 0
    @State private var errorMessage: String? = nil
    @State private var showCompareView = false

    @State private var copiedSuccess = false

    // 用于控制流式生成和打断生命周期的异步任务变量
    @State private var refineTask: Task<Void, Never>? = nil

    // 平铺可用模型，完全遵循全局配置的排序顺序
    private var availableModels: [SelectedModelConfig] {
        modelStore.sortedActiveModels.map { item in
            SelectedModelConfig(provider: item.provider, modelId: item.modelId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部标题栏
            HStack {
                Label(showCompareView ? "AI 智能总结结果对比" : "AI 智能总结与提炼", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Spacer()

                // 只有在非流式精整阶段才允许通过 Esc 或点击叉号关闭，防止中途退出
                if !isRefining {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if showCompareView {
                // A. 双栏流式对比视图 (直接平滑呈现，带打字机输出)
                VStack(spacing: 0) {
                    if let error = errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.06))
                        .cornerRadius(6)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        // 左栏：原文粗稿
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.secondary)
                                Text(L10n.k("speech.compare.raw_title", fallback: "转写粗稿原文"))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .frame(height: 24)
                            .padding(.leading, 4)

                            ZStack(alignment: .topLeading) {
                                TextEditor(text: .constant(service.currentTranscript))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineSpacing(4)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.02))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        // 右栏：精装流式润色稿
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text(L10n.k("speech.compare.refined_title", fallback: "AI 智能精装版"))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.purple)
                                Spacer()

                                if isRefining {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.45)
                                        Text(L10n.k("speech.refine.streaming", fallback: "正在流式生成中..."))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.purple)
                                    }
                                } else if !refinedText.isEmpty {
                                    Group {
                                        if refineDuration > 0 {
                                            Text(L10n.f("speech.refine.count_duration", fallback: "%d 字 · ⚡️ %.1fs", refinedText.count, refineDuration))
                                        } else {
                                            Text(L10n.f("speech.word_count", fallback: "%d 字", refinedText.count))
                                        }
                                    }
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.04))
                                    .cornerRadius(4)
                                }
                            }
                            .frame(height: 24)
                            .padding(.leading, 4)

                            ZStack(alignment: .topLeading) {
                                TextEditor(text: $refinedText)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineSpacing(4)
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.4))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isRefining ? Color.purple.opacity(0.45) : Color.purple.opacity(0.18), lineWidth: 1)
                                    .animation(.easeInOut(duration: 0.5), value: isRefining)
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(20)

                    Divider()

                    // 底部控制
                    HStack(spacing: 12) {
                        Button {
                            refineTask?.cancel()
                            showCompareView = false
                            errorMessage = nil
                        } label: {
                            HStack {
                                Image(systemName: "arrow.left")
                                Text(L10n.k("speech.refine.back_to_config", fallback: "返回配置"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isRefining) // 生成中禁用返回

                        Spacer()

                        Button {
                            service.copyTranscript(refinedText)
                            withAnimation { copiedSuccess = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { copiedSuccess = false }
                            }
                        } label: {
                            HStack {
                                Image(systemName: copiedSuccess ? "checkmark" : "doc.on.doc")
                                Text(copiedSuccess ? L10n.k("common.status.copied", fallback: "已复制") : L10n.k("speech.refine.copy_refined_only", fallback: "仅复制精装版"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(refinedText.isEmpty || isRefining)

                        if isRefining {
                            // 正在流式生成时，提供红色的强力“停止生成”按钮
                            Button {
                                refineTask?.cancel()
                                isRefining = false
                            } label: {
                                HStack {
                                    Image(systemName: "stop.circle.fill")
                                    Text(L10n.k("speech.refine.stop_generation", fallback: "停止生成"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .tint(.red)
                        } else {
                            // 生成完毕或已打断时，只写入 AI 精装版，避免覆盖原稿。
                            Button {
                                if service.applyRefinedTextToCurrentRecord(refinedText) {
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text(L10n.k("speech.refine.save_to_refined", fallback: "保存到 AI 精装版"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .tint(.purple)
                            .disabled(refinedText.isEmpty || service.currentHistoryRecord == nil)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                // B. 精整配置表单
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = errorMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.06))
                            .cornerRadius(6)
                        }

                        // 1. 润色模式
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("speech.refine.mode_label", fallback: "润色重塑模式"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)

                            Picker("", selection: $refineMode) {
                                Text(L10n.k("speech.refine.mode.clean", fallback: "✨ 智能净化")).tag("原稿智能净化")
                                Text(L10n.k("speech.refine.mode.note", fallback: "📓 灵感随记")).tag("灵感随记整理")
                                Text(L10n.k("speech.refine.mode.meeting", fallback: "📋 会议纪要")).tag("提炼会议纪要")
                                Text(L10n.k("speech.refine.mode.rewrite", fallback: "✍️ 专业重塑")).tag("专业文稿重塑")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        // 2. 选择 AI 智能引擎
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("speech.refine.engine_label", fallback: "选择 AI 精整引擎"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)

                            if availableModels.isEmpty {
                                HStack {
                                    Text(L10n.k("speech.refine.no_models", fallback: "⚠️ 还没有在「全局模型池」中配置模型，请先去配置账户。"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.05))
                                .cornerRadius(6)
                            } else {
                                Picker("", selection: $selectedModel) {
                                    ForEach(availableModels, id: \.self) { model in
                                        Text(model.displayName).tag(Optional(model))
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }
                        }

                        // 3. 上下文正确专名词表
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.k("speech.refine.glossary_label", fallback: "本段音频的背景与正确热词"))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "info.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .help(L10n.k("speech.refine.glossary_help", fallback: "输入此录音里提到的正确人名、产品名或背景，AI 会根据它们来智能纠正所有同音错别字。"))
                                Spacer()
                            }

                            TextField(L10n.k("speech.refine.glossary_placeholder", fallback: "例如：ClawdHome, OpenClaw, 隔离沙箱"), text: $glossary)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                        }

                        Spacer()
                            .frame(height: 10)

                        // 开始按钮
                        Button {
                            startRefinement()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "sparkles")
                                Text(L10n.k("speech.refine.start", fallback: "开始智能精整与专名润色"))
                                    .fontWeight(.bold)
                                Spacer()
                            }
                            .foregroundColor(.white)
                            .frame(height: 36)
                            .background(
                                LinearGradient(
                                    colors: availableModels.isEmpty ? [.gray] : [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(8)
                            .shadow(color: Color.purple.opacity(availableModels.isEmpty ? 0 : 0.15), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                        .disabled(availableModels.isEmpty)
                    }
                    .padding(20)
                }
                .onAppear {
                    // 默认优先加载全局配置的系统默认模型，否则 fallback 加载第一个模型
                    if selectedModel == nil {
                        if let defaultKey = modelStore.defaultModelKey,
                           let matched = findDefaultModel(defaultKey: defaultKey) {
                            selectedModel = matched
                        } else if let first = availableModels.first {
                            selectedModel = first
                        }
                    }

                    // 2. 加载个性化与全局的 Glossary 记忆
                    if let recordID = service.selectedRecordID {
                        let savedGlossary = UserDefaults.standard.string(forKey: "speech_refine_glossary_\(recordID.uuidString)")
                            ?? UserDefaults.standard.string(forKey: "speech_refine_glossary_global")
                            ?? ""
                        self.glossary = savedGlossary

                        // 3. 加载个性化与全局的 Mode 记忆，若不存在则使用已有文本特征启发式猜测
                        let savedMode = UserDefaults.standard.string(forKey: "speech_refine_mode_\(recordID.uuidString)")
                            ?? UserDefaults.standard.string(forKey: "speech_refine_mode_global")

                        if let savedMode, ["原稿智能净化", "灵感随记整理", "提炼会议纪要", "专业文稿重塑"].contains(savedMode) {
                            self.refineMode = savedMode
                        } else if let refined = service.selectedHistoryRecord?.refinedText {
                            // 通过特征词进行启发式推导
                            if refined.contains("# 📓 灵感随记") || refined.contains("📌 快速摘要") {
                                self.refineMode = "灵感随记整理"
                            } else if refined.contains("### 核心结论") || refined.contains("会议纪要") {
                                self.refineMode = "提炼会议纪要"
                            } else if refined.contains("### 📝 精整正文") {
                                self.refineMode = "灵感随记整理"
                            }
                        }
                    }
                }
            }
        }
        .frame(width: showCompareView ? 820 : 460, height: showCompareView ? 580 : 380)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showCompareView)
    }

    private func findDefaultModel(defaultKey: String) -> SelectedModelConfig? {
        availableModels.first { model in
            let key = "\(model.modelId)_\(model.provider.id.uuidString)"
            return key == defaultKey
        }
    }

    // 执行流式 AI 专名精整与即时吐字渲染
    private func startRefinement() {
        guard let config = selectedModel else {
            errorMessage = "请先选择一个可用的 AI 引擎。"
            return
        }

        // 写入配置与词汇表持久化记忆
        if let recordID = service.selectedRecordID {
            UserDefaults.standard.set(glossary, forKey: "speech_refine_glossary_\(recordID.uuidString)")
            UserDefaults.standard.set(refineMode, forKey: "speech_refine_mode_\(recordID.uuidString)")
        }
        UserDefaults.standard.set(glossary, forKey: "speech_refine_glossary_global")
        UserDefaults.standard.set(refineMode, forKey: "speech_refine_mode_global")

        isRefining = true
        refineDuration = 0
        errorMessage = nil
        refinedText = ""
        showCompareView = true // 直接、优雅地平滑展开为双栏预览状态！

        refineTask = Task {
            let startTime = Date()
            var rawRefinedBuffer = ""
            do {
                let stream = service.refineTranscriptStream(
                    text: service.currentTranscript,
                    provider: config.provider,
                    modelId: config.modelId,
                    glossary: glossary,
                    mode: refineMode
                )

                for try await chunk in stream {
                    // 随时检测任务取消，支持秒级强力打断
                    try Task.checkCancellation()

                    rawRefinedBuffer += chunk
                    let displayText = SpeechTranscriptionService.refinementDisplayText(
                        from: rawRefinedBuffer,
                        isFinal: false
                    )

                    await MainActor.run {
                        self.refinedText = displayText
                    }
                }

                let finalText = SpeechTranscriptionService.refinementDisplayText(from: rawRefinedBuffer)
                await MainActor.run {
                    self.refineDuration = Date().timeIntervalSince(startTime)
                    self.refinedText = finalText
                    self.isRefining = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isRefining = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRefining = false
                }
            }
        }
    }
}

// MARK: - 历史记录单行卡片组件
struct SpeechHistoryRecordRow: View {
    let record: SpeechHistoryRecord
    let isSelected: Bool
    @Binding var selectedContentTab: SpeechTranscriptionView.ContentDimension
    let subtitle: String
    let onReveal: () -> Void

    @State private var isHovered = false
    fileprivate var service = SpeechTranscriptionService.shared

    private var cardBackground: Color {
        if isSelected {
            return Color(NSColor.controlBackgroundColor).opacity(0.8)
        } else if isHovered {
            return Color.primary.opacity(0.04)
        } else {
            return Color(NSColor.controlBackgroundColor).opacity(0.2)
        }
    }

    private var cardStrokeColor: Color {
        if isSelected {
            return Color.blue.opacity(0.2)
        } else if isHovered {
            return Color.blue.opacity(0.1)
        } else {
            return Color.primary.opacity(0.04)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // 优先展示 Topic 标题，无则 fallback 到原始文件名
                    let displayTitle = (record.refinedTitle?.isEmpty == false) ? record.refinedTitle! : record.sourceFileName
                    Text(displayTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .blue : .primary)

                    if record.vocalEnhanceEnabled == true {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.purple)
                            .help(L10n.k("speech.vocal_enhance.enabled_help", fallback: "已启用智能人声增强与去噪"))
                    }
                }

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                // 【新增】微型彩色胶囊标签气泡
                if let tags = record.refinedTags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(isSelected ? Color.blue.opacity(0.15) : Color.primary.opacity(0.05))
                                .foregroundColor(isSelected ? .blue : .secondary)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            Button {
                onReveal()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.k("speech.history.reveal_source_help", fallback: "在 Finder 中显示原始文件"))

            Button {
                service.deleteHistoryRecord(id: record.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(L10n.k("speech.history.delete_help", fallback: "删除该历史记录"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cardStrokeColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hover in
            isHovered = hover
        }
        .onTapGesture {
            withAnimation {
                service.selectedRecordID = record.id
                if record.refinedText == nil && selectedContentTab == .refined {
                    selectedContentTab = .raw
                }
            }
        }
        .contextMenu {
            Button {
                retranscribe()
            } label: {
                Label(L10n.k("speech.history.retranscribe", fallback: "重新转译音频"), systemImage: "arrow.counterclockwise")
            }
            .disabled(!FileManager.default.fileExists(atPath: record.sourceFilePath))

            Button {
                onReveal()
            } label: {
                Label(L10n.k("common.reveal_in_finder", fallback: "在 Finder 中显示"), systemImage: "folder")
            }

            Divider()

            Button {
                service.copyTranscript(record.transcriptText)
            } label: {
                Label(L10n.k("speech.history.copy_raw", fallback: "复制转写粗稿原文"), systemImage: "doc.on.doc")
            }

            if let refined = record.refinedText, !refined.isEmpty {
                Button {
                    service.copyTranscript(refined)
                } label: {
                    Label(L10n.k("speech.history.copy_refined", fallback: "复制 AI 智能精装版"), systemImage: "sparkles")
                }
            }

            Divider()

            Button(role: .destructive) {
                service.deleteHistoryRecord(id: record.id)
            } label: {
                Label(L10n.k("speech.history.delete", fallback: "删除历史记录"), systemImage: "trash")
            }
        }
    }

    private func retranscribe() {
        let fileURL = URL(fileURLWithPath: record.sourceFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        // 1. 如果队列中没有，则入队
        if !service.queue.contains(where: { $0.fileURL.path == fileURL.path }) {
            service.enqueueFiles([fileURL])
        }

        // 2. 选中并重置状态，将主面板切回 ASR 队列渲染
        service.selectedFileURL = fileURL
        if let matched = service.queue.first(where: { $0.fileURL.path == fileURL.path }) {
            service.selectedQueueItem = matched
        }

        // 3. 将选中历史记录清空，退回队列转写视图
        withAnimation {
            service.selectedRecordID = nil
            selectedContentTab = .raw
        }
    }
}

// MARK: - 历史记录卡片及列表主组件
struct SpeechHistoryCard: View {
    @State private var service = SpeechTranscriptionService.shared
    @Binding var selectedContentTab: SpeechTranscriptionView.ContentDimension

    private var headerSection: some View {
        HStack {
            Label(L10n.k("speech.history_records", fallback: "历史转写"), systemImage: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                service.openHistoryDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(L10n.k("speech.open_directory", fallback: "打开目录"))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Open ASR history directory in Finder")
        }
        .frame(height: 28)
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(L10n.k("speech.history_empty", fallback: "暂无历史记录"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var historyListView: some View {
        ScrollView {
            VStack(spacing: 8) {
                if service.history.isEmpty {
                    emptyStateView
                } else {
                    ForEach(service.history) { record in
                        let isSelected = service.selectedRecordID == record.id
                        SpeechHistoryRecordRow(
                            record: record,
                            isSelected: isSelected,
                            selectedContentTab: $selectedContentTab,
                            subtitle: historySubtitle(for: record),
                            onReveal: { revealRecordSource(record) }
                        )
                    }
                }
            }
            .padding(8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.01))

                historyListView
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .padding(12)
        .background(Color.primary.opacity(0.01))
        .cornerRadius(12)
    }

    private func historySubtitle(for record: SpeechHistoryRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let dateStr = formatter.string(from: record.createdAt)
        let elapsedStr = String(format: "%.1fs", record.elapsedSeconds)

        // 音频文件大小智能格式化
        let bytes = record.sourceFileSizeBytes
        let sizeStr: String
        if bytes >= 1_048_576 {
            sizeStr = String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            sizeStr = String(format: "%.0f KB", Double(bytes) / 1024)
        } else {
            sizeStr = "\(bytes) B"
        }

        // 音频物理时长格式化
        var durationStr = ""
        if let duration = record.durationSeconds, duration > 0 {
            let totalSeconds = Int(duration.rounded())
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            if minutes > 0 {
                durationStr = "\(minutes)分\(seconds)秒"
            } else {
                durationStr = "\(totalSeconds)秒"
            }
        }

        var parts: [String] = [dateStr]
        if !durationStr.isEmpty {
            parts.append(durationStr)
        }
        parts.append(sizeStr)
        parts.append("耗时 \(elapsedStr)")

        return parts.joined(separator: " · ")
    }

    private func revealRecordSource(_ record: SpeechHistoryRecord) {
        let url = URL(fileURLWithPath: record.sourceFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct ASRSettingsSheet: View {
    @Binding var hfEndpointPreference: String
    @Binding var customHFEndpoint: String
    @Binding var hfTokenPreference: String
    var service: SpeechTranscriptionService
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶层标题栏
            HStack {
                Label(L10n.k("speech.engine_settings", fallback: "ASR 引擎设置"), systemImage: "waveform.and.mic")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button(L10n.k("auto.model_config_wizard.done", fallback: "完成")) {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 主体可滚动区域
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.k("settings.speech_transcription.hf_endpoint", fallback: "模型下载源"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $hfEndpointPreference) {
                            Text(L10n.k("settings.speech_transcription.hf_endpoint.default", fallback: "默认 (Hugging Face)")).tag("")
                            Text(L10n.k("settings.speech_transcription.hf_endpoint.mirror", fallback: "HF 镜像站 (hf-mirror.com)")).tag("https://hf-mirror.com")
                            Text(L10n.k("settings.speech_transcription.hf_endpoint.custom", fallback: "自定义…")).tag("custom")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    if hfEndpointPreference == "custom" {
                        TextField(L10n.k("settings.speech_transcription.hf_endpoint.custom_url", fallback: "自定义端点 URL"), text: $customHFEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hugging Face Token")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            if let tokenURL = URL(string: "https://huggingface.co/settings/tokens") {
                                Link(destination: tokenURL) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 11))
                                }
                            }
                        }

                        SecureField(L10n.k("settings.speech_transcription.hf_token.placeholder", fallback: "可选，用于提速或下载受限模型"), text: $hfTokenPreference)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }

                    Text(L10n.k("settings.speech_transcription.hf_endpoint.hint", fallback: "提示：若镜像站因元数据校验失败报错，请尝试切回默认源。"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let recommended = service.recommendation.recommendedModel {
                        Text(L10n.f("speech.recommended", fallback: "当前设备推荐配置：%@ ASR", curatedSpeechModels.first(where: { $0.id == recommended })?.displayName ?? recommended.rawValue))
                            .font(.system(size: 10))
                            .foregroundStyle(.blue)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Bindable(service).vocalEnhanceEnabled) {
                            HStack(spacing: 4) {
                                Text(L10n.k("speech.vocal_enhance.title", fallback: "AI 智能人声增强"))
                                    .font(.system(size: 11, weight: .semibold))
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.purple)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Text(L10n.k("speech.vocal_enhance.desc", fallback: "利用 macOS 原生的核心音频降噪与动态范围均化，消除低频噪音，极大提升嘈杂音频的识别精度。"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 380, height: 360)
    }
}
