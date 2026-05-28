import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpeechTranscriptionView: View {
    var onBack: (() -> Void)? = nil
    @Environment(HelperClient.self) private var helperClient
    @State private var service = SpeechTranscriptionService.shared


    
    // 是否正在拖拽文件悬停于导入区
    @State private var isDragTargeted = false
    // ASR 配置弹出面板是否显示
    @State private var showSettingsPopover = false
    // 复制成功短暂提示状态
    @State private var didCopied = false
    
    @AppStorage("hf_endpoint_preference") private var hfEndpointPreference = ""
    @AppStorage("custom_hf_endpoint") private var customHFEndpoint = ""
    @AppStorage("hf_token_preference") private var hfTokenPreference = ""
    @AppStorage("asr_hotwords_setting") private var asrHotwordsSetting = ""

    var body: some View {
        VStack(spacing: 0) {
            // 顶层统一的奢华导航条与 UI 主题切换器
            headerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
                
            Divider()

            GeometryReader { proxy in
                v1WorkspaceLayout
                    .padding(20)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .navigationTitle(L10n.k("speech.title", fallback: "语音转文字"))
        .task {
            await refreshService()
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
            
            // 右侧：刷新与引擎配置
            HStack(spacing: 10) {
                Button {
                    Task { await refreshService() }
                } label: {
                    Image(systemName: "arrow.clockwise")
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
                .help(L10n.k("speech.refresh", fallback: "刷新"))

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
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    v1SettingsPopoverContent
                }
            }
        }
    }

    // MARK: - =========================================================================
    // MARK: - [版本 1] 侧边工作流分栏版 (Workspace Split Layout)
    // MARK: - =========================================================================
    
    private var v1WorkspaceLayout: some View {
        VStack(spacing: 20) {
            // ASR 模型快速选择与下载状态栏
            if service.availability.isAvailable {
                v1ModelBarCard
            }
            
            // 核心转写工作流（左：导入与队列控制，右：结果展示）
            HStack(alignment: .top, spacing: 20) {
                // 左侧：导入区 + 队列控制 + 历史记录
                VStack(spacing: 16) {
                    v1QueueDropZoneCard
                    
                    if !service.queue.isEmpty {
                        v1QueueControlBar
                    }
                    
                    v1HistoryCard
                }
                .frame(maxWidth: 360)
                
                // 右侧：结果展示工作区
                v1ResultWorkspaceCard
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // V1 极简模型选择与下载区
    private var v1ModelBarCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.k("speech.model", fallback: "模型选择"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                
                Picker("", selection: $service.selectedModelID) {
                    ForEach(curatedSpeechModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
            
            Spacer()
            
            // 模型就绪/准备卡片
            VStack(alignment: .trailing, spacing: 4) {
                if service.isPreparingModel {
                    HStack(spacing: 8) {
                        ProgressView(value: service.preparationProgressFraction)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        
                        Text(service.preparationProgressPercentText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                        
                        Button {
                            service.cancelModelPreparation()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else if service.isSelectedModelDownloaded {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .shadow(color: Color.green.opacity(0.3), radius: 3)
                        Text(L10n.k("speech.download_progress.ready_title", fallback: "模型就绪"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await service.prepareSelectedModel() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text(L10n.k("speech.download", fallback: "下载模型"))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isPreparingModel || service.isTranscribing)
                }
            }
        }
        .padding(14)
        .premiumCard(theme: .blue)
    }
    
    // V1 批量音频队列导入区
    private var v1QueueDropZoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .help("清空队列")
                }
            }
            .frame(height: 28)
            
            // 拖拽投放区（始终显示，可追加文件）
            let borderStroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [5, 4])
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isDragTargeted
                            ? LinearGradient(colors: [Color.blue.opacity(0.08), Color.purple.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color.primary.opacity(0.01), Color.primary.opacity(0.005)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isDragTargeted ? Color.blue.opacity(0.7) : Color.primary.opacity(0.07), style: borderStroke)
                
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(isDragTargeted ? Color.blue.opacity(0.12) : Color.blue.opacity(0.06))
                            .frame(width: 34, height: 34)
                        Image(systemName: isDragTargeted ? "arrow.down.circle.fill" : "plus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                            .offset(y: isDragTargeted ? 2 : 0)
                            .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: isDragTargeted)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.queue.isEmpty ? L10n.k("speech.drag_hint", fallback: "拖拽音频至此，或点击选择") : "继续添加更多文件…")
                            .font(.system(size: 12, weight: .medium))
                        Text("MP3 · WAV · M4A · FLAC · AAC")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 64)
            .contentShape(RoundedRectangle(cornerRadius: 12))
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
            
            // 队列任务列表
            if !service.queue.isEmpty {
                VStack(spacing: 6) {
                    ForEach(service.queue) { item in
                        v1QueueItemRow(item: item)
                    }
                }
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
                        Text(item.statusMessage ?? queueItemStatusLabel(item.status))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if item.status == .completed {
                        Text("✓ 完成 · \(String(format: "%.1fs", item.elapsedSeconds)) · \(item.transcriptText.count)字")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else if item.status == .failed {
                        Text(item.errorSummary ?? "转写失败")
                            .font(.system(size: 9))
                            .foregroundStyle(.red.opacity(0.8))
                            .lineLimit(1)
                    } else if item.status == .cancelled {
                        Text("已取消")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(queueItemStatusLabel(item.status))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if item.status == .transcribing {
                    Text("\(Int((item.progressFraction * 100).rounded()))%")
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
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.blue.opacity(isSelected ? 0.18 : 0.12))
                                .frame(width: max(0, proxy.size.width * CGFloat(min(max(item.progressFraction, 0), 1))))
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
                        Text("中止全部转写")
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
                            Text(waitingCount > 1 ? "批量转写 (\(waitingCount)个)" : "开始转写")
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
                        .help("清理已完成的任务")
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
            HStack {
                HStack(spacing: 6) {
                    Label(L10n.k("speech.result", fallback: "转写结果"), systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                    
                    if !service.currentTranscript.isEmpty {
                        Text(L10n.f("speech.word_count", fallback: "%d 字", service.currentTranscript.count))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
                
                // 结果操作水晶按钮栏
                HStack(spacing: 8) {
                    Button {
                        service.copyTranscript()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { didCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { didCopied = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: didCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(didCopied ? .green : .primary)
                                .scaleEffect(didCopied ? 1.15 : 1.0)
                            Text(didCopied ? "已复制" : L10n.k("speech.copy", fallback: "复制"))
                                .foregroundStyle(didCopied ? .green : .primary)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
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
                    .disabled(service.currentTranscript.isEmpty)
                    
                    Button {
                        try? service.export(format: .txt)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc")
                            Text("TXT")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.currentTranscript.isEmpty)
                    
                    Button {
                        try? service.export(format: .markdown)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text("MD")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.currentTranscript.isEmpty)
                }
            }
            .frame(height: 28)
            
            ZStack(alignment: .topLeading) {
                TextEditor(text: $service.currentTranscript)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(6)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(NSColor.textBackgroundColor).opacity(0.22))
                    )
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.01), radius: 8, x: 0, y: 4)
                
                if service.currentTranscript.isEmpty {
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
            }
        }
    }
    
    // V1 历史记录区域
    private var v1HistoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.k("speech.history_records", fallback: "历史转写"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 28)
                
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.01))
                
                ScrollView {
                    VStack(spacing: 8) {
                        if service.history.isEmpty {
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
                        } else {
                            ForEach(service.history) { record in
                                let isSelected = service.currentTranscript == record.transcriptText && !record.transcriptText.isEmpty
                                
                                HStack(spacing: 8) {
                                    Button {
                                        withAnimation {
                                            service.selectedQueueItem = nil
                                            service.currentTranscript = record.transcriptText
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(record.sourceFileName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(1)
                                                .foregroundColor(isSelected ? .blue : .primary)
                                            
                                            Text(historySubtitle(for: record))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Spacer()
                                    
                                    Button {
                                        revealRecordSource(record)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Button {
                                        service.deleteHistoryRecord(id: record.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor).opacity(isSelected ? 0.8 : 0.2))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Color.blue.opacity(0.2) : Color.primary.opacity(0.04), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxHeight: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
        }
        .padding(12)
        .background(Color.primary.opacity(0.01))
        .cornerRadius(12)
    }

    // V1 引擎设置悬浮窗内容
    private var v1SettingsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.k("speech.engine_settings", fallback: "ASR 引擎设置"))
                .font(.system(size: 13, weight: .bold))
            
            Divider()
            
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
            
            // 热词纠错词典
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("专名热词纠错", systemImage: "character.magnify")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                
                Text("每行一条规则，格式：错误识别 -> 正确词汇")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                
                TextEditor(text: $asrHotwordsSetting)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 80)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.3))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .scrollContentBackground(.hidden)
                
                Text("示例：ClowdHome -> ClawdHome")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
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

    private func historySubtitle(for record: SpeechHistoryRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let elapsed = String(format: "%.1fs", record.elapsedSeconds)
        return "\(formatter.string(from: record.createdAt)) · \(record.modelDisplayName) · \(elapsed)"
    }

    private func revealRecordSource(_ record: SpeechHistoryRecord) {
        let url = URL(fileURLWithPath: record.sourceFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func refreshService() async {
        let llmStatus = await helperClient.getLocalLLMStatus()
        await service.refresh(localAIServiceRunning: llmStatus.isRunning)
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
