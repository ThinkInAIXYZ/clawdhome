import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpeechTranscriptionView: View {
    @Environment(HelperClient.self) private var helperClient

    @State private var service = SpeechTranscriptionService.shared

    @AppStorage("hf_endpoint_preference") private var hfEndpointPreference = ""
    @AppStorage("custom_hf_endpoint") private var customHFEndpoint = ""
    @AppStorage("hf_token_preference") private var hfTokenPreference = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusSection
                importSection
                resultSection
                historySection
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("speech.title", fallback: "语音转文字"))
        .task {
            await refreshService()
        }
    }

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Qwen3-ASR", systemImage: "waveform.and.mic")
                        .font(.headline)
                    Spacer()
                    if service.availability.isAvailable {
                        Label(L10n.k("speech.available", fallback: "可用"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label(L10n.k("speech.unavailable", fallback: "不可用"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                Text(service.availability.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if service.availability.isAvailable {
                    Text(L10n.k("speech.model", fallback: "模型"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $service.selectedModelID) {
                        ForEach(curatedSpeechModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    SpeechModelDownloadCard(service: service)
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(L10n.k("settings.speech_transcription.hf_endpoint", fallback: "模型下载源"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $hfEndpointPreference) {
                                Text(L10n.k("settings.speech_transcription.hf_endpoint.default", fallback: "默认 (Hugging Face)")).tag("")
                                Text(L10n.k("settings.speech_transcription.hf_endpoint.mirror", fallback: "HF 镜像站 (hf-mirror.com)")).tag("https://hf-mirror.com")
                                Text(L10n.k("settings.speech_transcription.hf_endpoint.custom", fallback: "自定义…")).tag("custom")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 240)
                        }

                        if hfEndpointPreference == "custom" {
                            TextField(
                                L10n.k("settings.speech_transcription.hf_endpoint.custom_url", fallback: "自定义端点 URL"),
                                text: $customHFEndpoint
                            )
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .font(.caption)
                            .frame(maxWidth: 320)
                        }

                        HStack(spacing: 8) {
                            Text(L10n.k("settings.speech_transcription.hf_token", fallback: "Hugging Face Token"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SecureField(
                                L10n.k("settings.speech_transcription.hf_token.placeholder", fallback: "可选，用于提速或下载受限模型"),
                                text: $hfTokenPreference
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(maxWidth: 240)
                            
                            if let tokenURL = URL(string: "https://huggingface.co/settings/tokens") {
                                Link(destination: tokenURL) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .help(L10n.k("settings.speech_transcription.hf_token.get_link", fallback: "获取 Token (https://huggingface.co/settings/tokens)"))
                            }
                        }

                        Text(L10n.k("settings.speech_transcription.hf_endpoint.hint", fallback: "提示：若镜像站因元数据校验失败报错，请尝试切回默认源。"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    if let recommended = service.recommendation.recommendedModel {
                        Text(
                            L10n.f(
                                "speech.recommended",
                                fallback: "推荐：%@",
                                curatedSpeechModels.first(where: { $0.id == recommended })?.displayName ?? recommended.rawValue
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(service.recommendation.warnings) { warning in
                        Text(warning.message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button(
                            service.isSelectedModelDownloaded
                                ? L10n.k("speech.redownload", fallback: "重新准备模型")
                                : L10n.k("speech.download", fallback: "下载模型")
                        ) {
                            Task { await service.prepareSelectedModel() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isPreparingModel || service.isTranscribing)

                        Button(L10n.k("speech.refresh", fallback: "刷新")) {
                            Task { await refreshService() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(4)
        }
    }

    private var importSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.k("speech.import", fallback: "导入音频"))
                    .font(.headline)

                if let fileURL = service.selectedFileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.callout)
                    Text(fileMetadata(for: fileURL))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.k("speech.no_file", fallback: "尚未选择音频文件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(L10n.k("speech.choose_file", fallback: "选择文件")) {
                        chooseAudioFile()
                    }
                    .buttonStyle(.bordered)

                    Button(service.isTranscribing ? L10n.k("speech.running", fallback: "转写中…") : L10n.k("speech.start", fallback: "开始转写")) {
                        Task { await service.transcribeSelectedFile() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!service.availability.isAvailable || service.selectedFileURL == nil || service.isPreparingModel || service.isTranscribing)

                    if service.isTranscribing {
                        Button(L10n.k("speech.cancel", fallback: "取消")) {
                            service.cancelCurrentTranscription()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let error = service.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(4)
        }
    }

    private var resultSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.k("speech.result", fallback: "转写结果"))
                    .font(.headline)

                TextEditor(text: $service.currentTranscript)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                HStack {
                    Button(L10n.k("speech.copy", fallback: "复制")) {
                        service.copyTranscript()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.currentTranscript.isEmpty)

                    Button(L10n.k("speech.export_txt", fallback: "导出 TXT")) {
                        try? service.export(format: .txt)
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.currentTranscript.isEmpty)

                    Button(L10n.k("speech.export_md", fallback: "导出 Markdown")) {
                        try? service.export(format: .markdown)
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.currentTranscript.isEmpty)
                }
            }
            .padding(4)
        }
    }

    private var historySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.k("speech.history", fallback: "历史记录"))
                    .font(.headline)

                if service.history.isEmpty {
                    Text(L10n.k("speech.history_empty", fallback: "暂无历史记录"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.history) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    service.currentTranscript = record.transcriptText
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.sourceFileName)
                                            .font(.callout)
                                        Text(historySubtitle(for: record))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    service.copyTranscript(record.transcriptText)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    try? service.export(record: record, format: .txt)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    revealRecordSource(record)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    service.deleteHistoryRecord(id: record.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }

                            Divider()
                        }
                    }
                }
            }
            .padding(4)
        }
    }

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
        service.selectFile(url)
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
        return "\(formatter.string(from: record.createdAt)) · \(record.modelDisplayName) · \(record.status.rawValue)"
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

struct SpeechModelDownloadCard: View {
    @State private var isHoveringPause = false
    @State private var isHoveringCancel = false
    let service: SpeechTranscriptionService

    var body: some View {
        if service.isPreparingModel {
            // 下载中或已暂停状态的卡片
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    // 左侧：圆形双色柔和渐变背景 + 图标
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: service.isPreparationPaused
                                        ? [Color.gray.opacity(0.18), Color.gray.opacity(0.12)]
                                        : [Color.blue.opacity(0.18), Color.purple.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 38, height: 38)
                        
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: service.isPreparationPaused
                                        ? [Color.secondary, Color.secondary.opacity(0.8)]
                                        : [Color.blue, Color.purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    // 中间：标题与进度信息
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(headlineText)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            if service.isPreparationPaused {
                                Text(L10n.k("speech.download_progress.paused_pill", fallback: "已暂停"))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule().fill(Color.orange.opacity(0.12))
                                    )
                            }
                        }
                        
                        Text(progressDetailText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 12)

                    // 右侧：圆形控制按钮
                    HStack(spacing: 8) {
                        // 暂停/播放按钮
                        Button {
                            if service.isPreparationPaused {
                                service.resumeModelPreparation()
                            } else {
                                service.pauseModelPreparation()
                            }
                        } label: {
                            Image(systemName: service.isPreparationPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(service.isPreparationPaused ? .blue : .secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle().fill(isHoveringPause ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(service.isPreparationPaused 
                              ? L10n.k("speech.download_progress.resume_help", fallback: "继续下载") 
                              : L10n.k("speech.download_progress.pause_help", fallback: "暂停下载"))
                        .onHover { hovering in
                            isHoveringPause = hovering
                        }

                        // 取消按钮
                        Button {
                            service.cancelModelPreparation()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    Circle().fill(isHoveringCancel ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.k("speech.download_progress.cancel_help", fallback: "取消下载"))
                        .onHover { hovering in
                            isHoveringCancel = hovering
                        }
                    }
                }

                // 底部：高保真进度条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: service.isPreparationPaused
                                        ? [Color.gray.opacity(0.6), Color.gray.opacity(0.4)]
                                        : [Color.blue, Color.purple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(service.preparationProgressFraction))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: service.preparationProgressFraction)
                    }
                }
                .frame(height: 5)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 3)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            ))
        } else if service.isSelectedModelDownloaded {
            // 已下载完成就绪的绿盾卡片
            HStack(spacing: 12) {
                // 左侧：绿色圆形柔和渐变背景 + 绿盾图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.18), Color.green.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.green)
                }

                // 中间：就绪文字排版
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.k("speech.download_progress.ready_title", fallback: "模型已就绪"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Text(L10n.k("speech.download_progress.ready_desc", fallback: "所选模型已完整下载并准备好进行离线转写。"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.green.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 3)
            .transition(.opacity)
        }
    }

    private var headlineText: String {
        let modelName = service.selectedModelDescriptor?.displayName ?? service.selectedModelID.rawValue
        if service.isPreparationPaused {
            return L10n.f("speech.download_progress.paused_headline", fallback: "已暂停 — %@", modelName)
        }
        return L10n.f("speech.download_progress.headline", fallback: "正在下载 %@", modelName)
    }

    private var progressDetailText: String {
        var parts: [String] = []
        
        // 已下载 / 总大小
        let preparedText = service.selectedModelPreparedSizeText
        let estimatedText = service.selectedModelEstimatedSizeText
        parts.append("\(preparedText) / \(estimatedText)")

        // 速度（仅在非暂停时展示）
        if !service.isPreparationPaused && service.downloadSpeedBytesPerSecond > 0 {
            parts.append(service.selectedModelDownloadSpeedText)
        }
        
        // 剩余时间（ETA）
        if let eta = service.selectedModelDownloadETAText {
            parts.append(eta)
        }
        
        return parts.joined(separator: " · ")
    }
}
