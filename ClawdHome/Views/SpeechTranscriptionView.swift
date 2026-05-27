import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpeechTranscriptionView: View {
    @Environment(HelperClient.self) private var helperClient
    @State private var service = SpeechTranscriptionService.shared

    // ASR UI 主题版本切换：1 = 侧边分栏工作台, 2 = 沉浸式卡片流看板
    @AppStorage("speech_ui_version") private var selectedUIVersion = 1
    
    // 是否正在拖拽文件悬停于导入区
    @State private var isDragTargeted = false
    // ASR 配置弹出面板是否显示 (Version 1)
    @State private var showSettingsPopover = false
    
    @AppStorage("hf_endpoint_preference") private var hfEndpointPreference = ""
    @AppStorage("custom_hf_endpoint") private var customHFEndpoint = ""
    @AppStorage("hf_token_preference") private var hfTokenPreference = ""

    var body: some View {
        VStack(spacing: 0) {
            // 顶层统一的奢华导航条与 UI 主题切换器
            headerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
                
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedUIVersion == 1 {
                        // 版本 1：侧边工作流分栏版 (Workspace Split Layout)
                        v1WorkspaceLayout
                    } else {
                        // 版本 2：沉浸式卡片流看板 (Immersive Floating Deck Layout)
                        v2ImmersiveLayout
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(L10n.k("speech.title", fallback: "语音转文字"))
        .task {
            await refreshService()
        }
    }

    // MARK: - 顶层统一 Header
    private var headerBar: some View {
        HStack {
            // 左侧：当前引擎就绪指示器
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(service.availability.isAvailable ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 28, height: 28)
                    
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
                        Text(service.availability.isAvailable ? L10n.k("speech.available", fallback: "就绪") : L10n.k("speech.unavailable", fallback: "不可用"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 中间：炫酷的主题切换器
            Picker("", selection: $selectedUIVersion) {
                Text(L10n.k("speech.ui_style.classic_split", fallback: "侧边分栏")).tag(1)
                Text(L10n.k("speech.ui_style.immersive_deck", fallback: "沉浸看板")).tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
            
            Spacer()
            
            // 右侧：刷新与配置 (Version 1 配置收纳在此)
            HStack(spacing: 10) {
                Button {
                    Task { await refreshService() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.k("speech.refresh", fallback: "刷新"))

                if selectedUIVersion == 1 {
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
                        .background(showSettingsPopover ? Color.blue.opacity(0.12) : Color.primary.opacity(0.05))
                        .foregroundColor(showSettingsPopover ? .blue : .primary)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                        v1SettingsPopoverContent
                    }
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
            
            // 核心转写工作流（上：音频导入 + 下：转录区）
            HStack(alignment: .top, spacing: 20) {
                // 左侧/上半部分：导入与控制
                VStack(spacing: 16) {
                    v1ImportDropZoneCard
                    
                    if service.isTranscribing || service.selectedFileURL != nil {
                        v1ControlActionBar
                    }
                    
                    v1HistoryCard
                }
                .frame(maxWidth: 360)
                
                // 右侧：结果展示工作区
                v1ResultWorkspaceCard
            }
        }
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
    
    // V1 支持拖拽的音频导入区
    private var v1ImportDropZoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.k("speech.import", fallback: "音频导入"), systemImage: "arrow.down.doc")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 28)
                
            ZStack(alignment: .topTrailing) {
                ZStack {
                    let borderStroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
                    
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: isDragTargeted 
                                    ? [Color.blue.opacity(0.08), Color.purple.opacity(0.04)]
                                    : [Color.primary.opacity(0.02), Color.primary.opacity(0.01)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isDragTargeted ? Color.blue : Color.primary.opacity(0.12), style: borderStroke)
                    
                    if let fileURL = service.selectedFileURL {
                        // 已选定文件状态
                        VStack(spacing: 12) {
                            // 顶部大唱片磁贴效果
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [Color.gray.opacity(0.12), Color.gray.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 54, height: 54)
                                
                                Image(systemName: "doc.richtext.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                            
                            VStack(spacing: 4) {
                                Text(fileURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                
                                Text(fileMetadata(for: fileURL))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            
                            // 动态律动音轨
                            ASRWaveformVisualizer(isAnimating: service.isTranscribing)
                                .padding(.top, 4)
                        }
                        .padding(.vertical, 20)
                        .padding(.horizontal, 16)
                    } else {
                        // 尚未选择文件状态
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 48)
                                
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color.blue)
                                    .offset(y: isDragTargeted ? 3 : 0)
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isDragTargeted)
                            }
                            
                            VStack(spacing: 4) {
                                Text(L10n.k("speech.drag_hint", fallback: "拖拽音频至此，或点击浏览"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.primary)
                                
                                Text("MP3, WAV, M4A, FLAC, AAC")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 28)
                    }
                }
                .frame(height: service.selectedFileURL == nil ? 180 : nil)
                .frame(minHeight: 180)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture {
                    if service.selectedFileURL == nil {
                        chooseAudioFile()
                    }
                }
                
                // 右上角精致关闭小按钮
                if service.selectedFileURL != nil && !service.isTranscribing {
                    Button {
                        withAnimation { service.clearSelection() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            withAnimation { service.selectFile(url) }
                        }
                    }
                }
                return true
            }
        }
    }
    
    // V1 控制面板与按钮
    private var v1ControlActionBar: some View {
        VStack(spacing: 10) {
            if service.isTranscribing {
                VStack(spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(service.transcriptionStatusMessage ?? L10n.k("speech.running", fallback: "正在深度转写音频…"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    
                    if service.transcriptionProgressFraction > 0 && service.transcriptionProgressFraction < 1 {
                        HStack(spacing: 8) {
                            ProgressView(value: service.transcriptionProgressFraction)
                                .progressViewStyle(.linear)
                            Text("\(Int((service.transcriptionProgressFraction * 100).rounded()))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                    }
                    
                    Button {
                        service.cancelCurrentTranscription()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "stop.fill")
                            Text(L10n.k("speech.cancel", fallback: "中止转写"))
                            Spacer()
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(height: 34)
                        .background(Color.red.opacity(0.85))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await service.transcribeSelectedFile() }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "play.fill")
                        Text(L10n.k("speech.start", fallback: "开始智能转写"))
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .frame(height: 38)
                    .background(
                        LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(8)
                    .shadow(color: Color.blue.opacity(0.2), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(!service.availability.isAvailable || service.selectedFileURL == nil || service.isPreparingModel)
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
                Label(L10n.k("speech.result", fallback: "转写结果"), systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // 结果操作水晶按钮栏
                HStack(spacing: 8) {
                    Button {
                        service.copyTranscript()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text(L10n.k("speech.copy", fallback: "复制"))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
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
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
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
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(6)
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
                    .frame(minHeight: 380, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.2))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                
                if service.currentTranscript.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary.opacity(0.4))
                        
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
                                        withAnimation { service.currentTranscript = record.transcriptText }
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
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - =========================================================================
    // MARK: - [版本 2] 沉浸式卡片流看板 (Immersive Floating Deck Layout)
    // MARK: - =========================================================================
    
    private var v2ImmersiveLayout: some View {
        VStack(spacing: 24) {
            // 卡片一：微缩 ASR 配置胶囊控制仓
            v2SmartConsoleCard
            
            // 卡片二：沉浸式霓虹拖拽识别面板
            v2NeonVisualTranscriberCard
            
            // 卡片三：大格局左右分栏双视窗（历史 + 结果）
            HStack(alignment: .top, spacing: 20) {
                // 左视窗：高对比度历史名片列表
                v2HistoryColumn
                    .frame(width: 260)
                
                // 右视窗：沉浸式磨砂文本转写台
                v2ResultColumn
            }
        }
    }
    
    // V2 极简控制仓
    private var v2SmartConsoleCard: some View {
        HStack(spacing: 12) {
            // 模型选择标签
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(.blue)
                Text(L10n.k("speech.model", fallback: "引擎模型"))
                    .font(.system(size: 11, weight: .bold))
                
                Picker("", selection: $service.selectedModelID) {
                    ForEach(curatedSpeechModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(14)
            
            // 下载源配置
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundStyle(.purple)
                Text(L10n.k("settings.speech_transcription.hf_endpoint", fallback: "下载源"))
                    .font(.system(size: 11, weight: .bold))
                
                Picker("", selection: $hfEndpointPreference) {
                    Text(L10n.k("settings.speech_transcription.hf_endpoint.default", fallback: "默认 (HF)")).tag("")
                    Text(L10n.k("speech.ui.hf_mirror", fallback: "HF 镜像")).tag("https://hf-mirror.com")
                    Text(L10n.k("settings.speech_transcription.hf_endpoint.custom", fallback: "自定义…")).tag("custom")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(14)
            
            Spacer()
            
            // 模型状态指示
            HStack(spacing: 8) {
                if service.isPreparingModel {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(L10n.k("speech.preparing", fallback: "模型就绪中…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                } else if service.isSelectedModelDownloaded {
                    Capsule()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 80, height: 20)
                        .overlay(
                            Text(L10n.k("speech.download_progress.ready_title", fallback: "就绪 (离线)"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        )
                } else {
                    Button {
                        Task { await service.prepareSelectedModel() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(L10n.k("speech.download", fallback: "下载模型准备离线转写"))
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 12)
                        .frame(height: 20)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
    
    // V2 沉浸式霓虹面板 (带炫彩特效)
    private var v2NeonVisualTranscriberCard: some View {
        ZStack {
            // 背景霓虹发光环 (转录时发光更加明显)
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: service.isTranscribing
                            ? [Color.blue.opacity(0.2), Color.purple.opacity(0.2), Color.pink.opacity(0.1)]
                            : [Color.primary.opacity(0.03), Color.primary.opacity(0.01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            // 霓虹描边
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: service.isTranscribing 
                            ? [Color.blue, Color.purple, Color.pink] 
                            : [Color.primary.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: service.isTranscribing ? 2.5 : 1
                )
                .blur(radius: service.isTranscribing ? 1 : 0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: service.isTranscribing)
            
            VStack(spacing: 20) {
                if let fileURL = service.selectedFileURL {
                    // 文件已选择
                    HStack(spacing: 24) {
                        // 左边：旋转科技感声波呼吸灯圈 / 磁带轮廓
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "music.mic")
                                .font(.system(size: 32))
                                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .scaleEffect(service.isTranscribing ? 1.15 : 1.0)
                                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: service.isTranscribing)
                        }
                        
                        // 中间：文件元数据
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.k("speech.selected_file", fallback: "当前选中音频"))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            Text(fileURL.lastPathComponent)
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(1)
                            
                            HStack(spacing: 12) {
                                Text(fileMetadata(for: fileURL))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                
                                Circle()
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 4, height: 4)
                                
                                Text(service.selectedModelDescriptor?.displayName ?? service.selectedModelID.rawValue)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                            }
                            
                            if service.isTranscribing {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(service.transcriptionStatusMessage ?? L10n.k("speech.running", fallback: "正在深度转写音频…"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.blue)
                                        .lineLimit(1)
                                    
                                    if service.transcriptionProgressFraction > 0 && service.transcriptionProgressFraction < 1 {
                                        HStack(spacing: 6) {
                                            ProgressView(value: service.transcriptionProgressFraction)
                                                .progressViewStyle(.linear)
                                                .frame(width: 120)
                                            Text("\(Int((service.transcriptionProgressFraction * 100).rounded()))%")
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                                .frame(width: 200, alignment: .leading)
                            } else {
                                // 动态音律轨道波形
                                ASRWaveformVisualizer(isAnimating: service.isTranscribing)
                                    .frame(width: 200)
                                    .padding(.top, 4)
                            }
                        }
                        
                        Spacer()
                        
                        // 右边：一键控制大按钮与状态
                        VStack(spacing: 10) {
                            if service.isTranscribing {
                                Button {
                                    service.cancelCurrentTranscription()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "stop.fill")
                                        Text(L10n.k("speech.cancel", fallback: "强行中止"))
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 38)
                                    .background(Color.red.opacity(0.85))
                                    .cornerRadius(19)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    Task { await service.transcribeSelectedFile() }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "bolt.fill")
                                        Text(L10n.k("speech.start", fallback: "一键离线识别"))
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .frame(height: 38)
                                    .background(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(19)
                                }
                                .buttonStyle(.plain)
                                .disabled(!service.availability.isAvailable || service.selectedFileURL == nil || service.isPreparingModel)
                            }
                            
                            Button {
                                withAnimation { service.clearSelection() }
                            } label: {
                                Text(L10n.k("speech.ui.clear_selection", fallback: "清除所选"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(service.isTranscribing)
                        }
                    }
                    .padding(24)
                } else {
                    // 未选择文件：超拟物拖拽呼吸大空盘
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [Color.blue.opacity(0.06), Color.purple.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                                .scaleEffect(isDragTargeted ? 1.15 : 1.0)
                                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isDragTargeted)
                        }
                        
                        VStack(spacing: 6) {
                            Text(L10n.k("speech.drag_hint", fallback: "拖拽音频文件至此，或点击本地上传"))
                                .font(.system(size: 14, weight: .bold))
                            
                            Text(L10n.k("speech.ui.privacy_badge", fallback: "本地极速离线转写 · 绝不泄漏您的隐私数据"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 40)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        chooseAudioFile()
                    }
                }
            }
        }
        .frame(height: 180)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    DispatchQueue.main.async {
                        withAnimation { service.selectFile(url) }
                    }
                }
            }
            return true
        }
    }
    
    // V2 左右分栏左视窗：名片小投影历史列表
    private var v2HistoryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.k("speech.history_records", fallback: "历史工作台"), systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            
            ScrollView {
                VStack(spacing: 12) {
                    if service.history.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text(L10n.k("speech.history_empty", fallback: "暂无历史记录"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 40)
                    } else {
                        ForEach(service.history) { record in
                            let isSelected = service.currentTranscript == record.transcriptText && !record.transcriptText.isEmpty
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Button {
                                        withAnimation { service.currentTranscript = record.transcriptText }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.sourceFileName)
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(isSelected ? .blue : .primary)
                                                .lineLimit(1)
                                            
                                            HStack {
                                                Image(systemName: "bolt.horizontal.circle")
                                                Text(historySubtitle(for: record))
                                            }
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    
                                    Spacer()
                                    
                                    // 历史操作小气泡
                                    Menu {
                                        Button {
                                            service.copyTranscript(record.transcriptText)
                                        } label: {
                                            Label(L10n.k("speech.copy", fallback: "复制文本"), systemImage: "doc.on.doc")
                                        }
                                        
                                        Button {
                                            revealRecordSource(record)
                                        } label: {
                                            Label(L10n.k("speech.ui.reveal_in_finder", fallback: "在 Finder 中定位"), systemImage: "folder")
                                        }
                                        
                                        Divider()
                                        
                                        Button(role: .destructive) {
                                            service.deleteHistoryRecord(id: record.id)
                                        } label: {
                                            Label(L10n.k("speech.ui.delete_record", fallback: "删除记录"), systemImage: "trash")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20, height: 20)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(isSelected ? 0.8 : 0.3))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                            .shadow(color: isSelected ? Color.blue.opacity(0.05) : Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
                        }
                    }
                }
            }
        }
    }
    
    // V2 左右分栏右视窗：沉浸式磨砂文本转写台
    private var v2ResultColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                    Text(L10n.k("speech.ui.analysis_result", fallback: "智能分析结果"))
                        .font(.system(size: 12, weight: .bold))
                }
                
                Spacer()
                
                // 一键复制与多格式一键导出（水晶面板）
                if !service.currentTranscript.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            service.copyTranscript()
                        } label: {
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 11))
                            Text(L10n.k("speech.copy", fallback: "复制"))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(12)
                        
                        Button {
                            try? service.export(format: .txt)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                            Text("TXT")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.04))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                        
                        Button {
                            try? service.export(format: .markdown)
                        } label: {
                            Image(systemName: "chevron.left.right")
                                .font(.system(size: 11))
                            Text("Markdown")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.04))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                }
            }
            
            ZStack(alignment: .topLeading) {
                TextEditor(text: $service.currentTranscript)
                    .font(.system(size: 14, design: .monospaced))
                    .lineSpacing(6)
                    .padding(16)
                    .frame(minHeight: 420, maxHeight: .infinity)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.15))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                
                if service.currentTranscript.isEmpty {
                    VStack(alignment: .center, spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.5))
                        
                        Text(L10n.k("speech.ui.waiting_placeholder", fallback: "等待开启智能识别任务，提取的离线文本会即时在此处流式展现，并支持高自由度二次编辑。"))
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 80)
                }
            }
        }
    }

    // MARK: - =========================================================================
    // MARK: - 通用辅助处理逻辑
    // MARK: - =========================================================================
    
    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            UTType(filenameExtension: "wav"),
            UTType(filenameExtension: "mp3"),
            UTType(filenameExtension: "m4a"),
            UTType(filenameExtension: "aac"),
            UTType(filenameExtension: "flac"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        withAnimation { service.selectFile(url) }
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
