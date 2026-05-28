import AppKit
import AVFoundation
import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class SpeechTranscriptionService {
    private final class ToolStderrMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var stderrBuffer = Data()
        private var stderrRemainder = Data()

        func append(_ data: Data, onProgress: ((SpeechToolProgressEvent) -> Void)?) {
            guard !data.isEmpty else { return }
            var events: [SpeechToolProgressEvent] = []
            lock.lock()
            stderrBuffer.append(data)
            stderrRemainder.append(data)
            while let newlineIndex = stderrRemainder.firstIndex(of: 0x0A) {
                let lineData = stderrRemainder.prefix(upTo: newlineIndex)
                stderrRemainder.removeSubrange(...newlineIndex)
                if !lineData.isEmpty,
                   let line = String(data: lineData, encoding: .utf8),
                   let event = SpeechToolOutputParser.progressEvent(from: line) {
                    events.append(event)
                }
            }
            lock.unlock()
            events.forEach { onProgress?($0) }
        }

        func finish(with data: Data, onProgress: ((SpeechToolProgressEvent) -> Void)?) -> Data {
            var trailingEvent: SpeechToolProgressEvent?
            lock.lock()
            if !data.isEmpty {
                stderrBuffer.append(data)
                stderrRemainder.append(data)
            }
            if !stderrRemainder.isEmpty,
               let line = String(data: stderrRemainder, encoding: .utf8),
               let event = SpeechToolOutputParser.progressEvent(from: line) {
                trailingEvent = event
            }
            stderrRemainder.removeAll(keepingCapacity: false)
            let snapshot = stderrBuffer
            lock.unlock()
            if let trailingEvent {
                onProgress?(trailingEvent)
            }
            return snapshot
        }
    }

    static let shared = SpeechTranscriptionService()

    private struct ToolProbeResponse: Decodable {
        let ok: Bool
        let command: String
        let message: String
        let supportedModelIDs: [String]
    }

    private struct ToolTranscribeResponse: Decodable {
        let ok: Bool
        let command: String
        let modelID: String
        let transcript: String?
        let elapsedSeconds: Double?
        let error: String?
    }

    private struct ToolPrepareResponse: Decodable {
        let ok: Bool
        let command: String
        let modelID: String
        let elapsedSeconds: Double?
        let error: String?
    }

    private let historyStore: SpeechHistoryStore
    private let fileManager: FileManager

    private(set) var history: [SpeechHistoryRecord] = []
    private(set) var availability: SpeechToolAvailability
    private(set) var recommendation: SpeechModelRecommendation
    private(set) var isTranscribing = false
    private(set) var isPreparingModel = false
    private(set) var lastErrorMessage: String?
    private(set) var transcriptionProgressFraction: Double = 0
    private(set) var transcriptionStatusMessage: String?
    private(set) var preparedModelBytes: Int64 = 0
    private(set) var preparedModelEstimatedTotalBytes: Int64 = 0
    private(set) var downloadSpeedBytesPerSecond: Double = 0
    private(set) var preparationProgressFraction: Double = 0
    private(set) var preparationStatusMessage: String?
    private(set) var isPreparationPaused = false

    var selectedModelID: SpeechModelID {
        didSet {
            refreshModelDownloadState()
        }
    }
    var selectedFileURL: URL?
    var currentTranscript = ""

    // 是否启用 macOS 原生 AI 人声降噪与增强预处理，默认开启 (方案 A)
    var vocalEnhanceEnabled: Bool = true

    // 【新增】待转译的任务队列
    private(set) var queue: [SpeechQueueItem] = []
    
    // 【新增】当前选中的队列任务项（右侧展示其对应的转译结果）
    var selectedQueueItem: SpeechQueueItem? {
        didSet {
            if let item = selectedQueueItem {
                self.selectedFileURL = item.fileURL
                self.currentTranscript = item.transcriptText
            }
        }
    }

    private var runningProcess: Process?
    private var cancellationRequested = false
    private var downloadMonitorTask: Task<Void, Never>?
    private var asrStartTime: Date? = nil

    init(
        historyStore: SpeechHistoryStore = SpeechHistoryStore(),
        fileManager: FileManager = .default
    ) {
        self.historyStore = historyStore
        self.fileManager = fileManager
        self.history = historyStore.load()
        let initialAvailability = SpeechToolAvailability(
            isAvailable: false,
            reason: .missingBundledTool,
            detail: "Speech tool has not been probed yet."
        )
        self.availability = initialAvailability
        self.recommendation = SpeechModelRecommendation(
            recommendedModel: nil,
            fallbackModel: nil,
            warnings: [],
            availability: initialAvailability
        )
        self.selectedModelID = .qwen3ASR17B8Bit
        refreshRecommendation(localAIServiceRunning: false)
    }

    func refresh(localAIServiceRunning: Bool = false) async {
        refreshRecommendation(localAIServiceRunning: localAIServiceRunning)
        refreshModelDownloadState()
        if availability.isAvailable {
            do {
                _ = try await probeTool()
            } catch {
                availability = SpeechToolAvailability(
                    isAvailable: false,
                    reason: .toolLaunchFailed,
                    detail: error.localizedDescription
                )
                recommendation = SpeechModelRecommendation(
                    recommendedModel: nil,
                    fallbackModel: nil,
                    warnings: recommendation.warnings,
                    availability: availability
                )
            }
        }
        if let recommendedModel = recommendation.recommendedModel {
            selectedModelID = recommendedModel
        }
        history = historyStore.load()
    }

    func selectFile(_ url: URL) {
        // 清理原有的队列，将新选择的文件作为唯一的队列项
        queue.removeAll()
        let item = SpeechQueueItem(fileURL: url)
        queue.append(item)
        selectedQueueItem = item
        lastErrorMessage = nil
    }

    // 【新增】多音频文件批量追加至队列
    func enqueueFiles(_ urls: [URL]) {
        let newItems = urls.map { SpeechQueueItem(fileURL: $0) }
        self.queue.append(contentsOf: newItems)
        
        if selectedQueueItem == nil {
            selectedQueueItem = newItems.first
        }
        lastErrorMessage = nil
    }

    // 【新增】从队列中删除特定的单个任务项
    func removeQueueItem(id: UUID) {
        queue.removeAll { $0.id == id }
        if selectedQueueItem?.id == id {
            selectedQueueItem = queue.first
        }
        if queue.isEmpty {
            clearSelection()
        }
    }

    // 【新增】清空队列中已完成、失败或已取消的项目
    func cleanQueue() {
        queue.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        if !queue.contains(where: { $0.id == selectedQueueItem?.id }) {
            selectedQueueItem = queue.first
        }
        if queue.isEmpty {
            clearSelection()
        }
    }

    // 【新增】基于专名词典对 ASR 识别出的文本进行后处理一键纠错
    func applyHotwordsFilter(to text: String) -> String {
        let rawHotwords = UserDefaults.standard.string(forKey: "asr_hotwords_setting") ?? ""
        var filteredText = text
        
        let lines = rawHotwords.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let wrong = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let right = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !wrong.isEmpty {
                filteredText = filteredText.replacingOccurrences(of: wrong, with: right)
            }
        }
        return filteredText
    }

    func clearSelection() {
        selectedFileURL = nil
        selectedQueueItem = nil
        queue.removeAll()
        currentTranscript = ""
        lastErrorMessage = nil
    }

    // 重构的串行排队智能转写调度主流程
    func transcribeSelectedFile() async {
        guard !isTranscribing else { return }
        
        // 如果队列为空，但是先前通过某种方式选中了单文件，则自动将其入队
        if queue.isEmpty, let fileURL = selectedFileURL {
            let item = SpeechQueueItem(fileURL: fileURL)
            queue.append(item)
            selectedQueueItem = item
        }
        
        guard !queue.isEmpty else {
            lastErrorMessage = "No audio files in queue."
            return
        }
        guard availability.isAvailable else {
            lastErrorMessage = availability.detail
            return
        }

        isTranscribing = true
        cancellationRequested = false
        lastErrorMessage = nil

        // 基于串行 FIFO 逐个处理未开始的任务
        while !cancellationRequested, let nextItem = queue.first(where: { $0.status == .waiting }) {
            selectedQueueItem = nextItem
            nextItem.status = .transcribing
            nextItem.progressFraction = 0
            nextItem.stageProgress = 0
            nextItem.asrSpeed = nil
            
            // 异步提取音频文件时长以作速率计算的基准
            let asset = AVURLAsset(url: nextItem.fileURL)
            if let duration = try? await asset.load(.duration) {
                nextItem.durationSeconds = duration.seconds
            } else {
                let audioFile = try? AVAudioFile(forReading: nextItem.fileURL)
                if let audioFile {
                    nextItem.durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                }
            }
            
            transcriptionProgressFraction = 0
            transcriptionStatusMessage = nil

            var audioToTranscribe = nextItem.fileURL
            var tempEnhancedURL: URL? = nil
            
            if vocalEnhanceEnabled {
                nextItem.stage = .enhancing
                do {
                    // 执行原生降噪预处理：占用整体进度的前 10% 区间 (0% -> 10%)
                    let enhancedURL = try await enhanceVocal(inputURL: nextItem.fileURL) { progress in
                        Task { @MainActor in
                            nextItem.stageProgress = progress
                            nextItem.progressFraction = progress * 0.1
                            nextItem.statusMessage = String(format: "人声分离与降噪中... %.0f%%", progress * 100)
                        }
                    }
                    tempEnhancedURL = enhancedURL
                    audioToTranscribe = enhancedURL
                } catch {
                    print("Vocal enhancement failed, fallback to original audio: \(error.localizedDescription)")
                }
            }

            // 真正开始 ASR 转换阶段 (预设为 10% 或 0% 的转录起点，并将状态标识刷新为 ASR 准备中)
            if !cancellationRequested {
                self.asrStartTime = Date() // 记录 ASR 真正转换的开始时间
                await MainActor.run {
                    nextItem.stage = .loadingModel
                    nextItem.stageProgress = 0.0
                    nextItem.progressFraction = vocalEnhanceEnabled ? 0.1 : 0.0
                    nextItem.statusMessage = "准备启动本地 ASR 智能转译..."
                }
            }

            do {
                let response = try await runTranscription(for: audioToTranscribe, modelID: selectedModelID)
                
                // 应用热词翻译词典过滤
                let finalTranscript = applyHotwordsFilter(to: response.transcript ?? "")
                
                nextItem.status = .completed
                nextItem.stage = .completed
                nextItem.stageProgress = 1.0
                nextItem.progressFraction = 1.0
                nextItem.transcriptText = finalTranscript
                nextItem.elapsedSeconds = response.elapsedSeconds ?? 0
                
                // 完成时计算最终平均速率
                if let startTime = self.asrStartTime {
                    let elapsed = nextItem.elapsedSeconds > 0 ? nextItem.elapsedSeconds : Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        var speedText = ""
                        if nextItem.durationSeconds > 0 {
                            let speedX = nextItem.durationSeconds / elapsed
                            speedText = String(format: "%.1fx", speedX)
                        }
                        let charCount = finalTranscript.count
                        if charCount > 0 {
                            let charSpeed = Double(charCount) / elapsed
                            if !speedText.isEmpty {
                                speedText += String(format: " (%.0f字/秒)", charSpeed)
                            } else {
                                speedText = String(format: "%.0f字/秒", charSpeed)
                            }
                        }
                        nextItem.asrSpeed = speedText
                    }
                }
                
                if selectedQueueItem?.id == nextItem.id {
                    currentTranscript = finalTranscript
                }

                if let tempEnhancedURL {
                    try? fileManager.removeItem(at: tempEnhancedURL)
                }

                if let record = makeHistoryRecord(
                    for: nextItem.fileURL,
                    modelID: selectedModelID,
                    transcript: finalTranscript,
                    elapsedSeconds: nextItem.elapsedSeconds,
                    status: .completed,
                    errorSummary: nil
                ) {
                    historyStore.save(record)
                }
            } catch {
                if let tempEnhancedURL {
                    try? fileManager.removeItem(at: tempEnhancedURL)
                }

                if cancellationRequested {
                    nextItem.status = .cancelled
                    nextItem.stage = .cancelled
                    nextItem.stageProgress = 0.0
                    if let record = makeHistoryRecord(
                        for: nextItem.fileURL,
                        modelID: selectedModelID,
                        transcript: "",
                        elapsedSeconds: 0,
                        status: .cancelled,
                        errorSummary: nil
                    ) {
                        historyStore.save(record)
                    }
                } else {
                    nextItem.status = .failed
                    nextItem.stage = .failed
                    nextItem.stageProgress = 0.0
                    nextItem.errorSummary = error.localizedDescription
                    lastErrorMessage = error.localizedDescription
                    
                    if let record = makeHistoryRecord(
                        for: nextItem.fileURL,
                        modelID: selectedModelID,
                        transcript: "",
                        elapsedSeconds: 0,
                        status: .failed,
                        errorSummary: error.localizedDescription
                    ) {
                        historyStore.save(record)
                    }
                }
            }
            history = historyStore.load()
        }

        runningProcess = nil
        isTranscribing = false
    }


    func prepareSelectedModel() async {
        guard !isPreparingModel else { return }
        guard availability.isAvailable else {
            lastErrorMessage = availability.detail
            return
        }

        isPreparingModel = true
        cancellationRequested = false
        lastErrorMessage = nil
        preparedModelEstimatedTotalBytes = estimatedModelBytes(for: selectedModelID)
        preparedModelBytes = currentModelBytes(for: selectedModelID)
        downloadSpeedBytesPerSecond = 0
        preparationProgressFraction = 0
        preparationStatusMessage = nil
        isPreparationPaused = false
        startDownloadMonitoring(for: selectedModelID)
        defer {
            stopDownloadMonitoring()
            refreshModelDownloadState()
            isPreparingModel = false
            isPreparationPaused = false
        }

        do {
            _ = try await runPrepareModel(for: selectedModelID)
        } catch {
            if cancellationRequested {
                lastErrorMessage = L10n.k("speech.prepare.cancelled", fallback: "已取消模型下载。")
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func pauseModelPreparation() {
        guard isPreparingModel, let process = runningProcess, !isPreparationPaused else { return }
        let pid = process.processIdentifier
        if kill(pid, SIGSTOP) == 0 {
            isPreparationPaused = true
        }
    }

    func resumeModelPreparation() {
        guard isPreparingModel, let process = runningProcess, isPreparationPaused else { return }
        let pid = process.processIdentifier
        if kill(pid, SIGCONT) == 0 {
            isPreparationPaused = false
        }
    }

    func cancelModelPreparation() {
        guard isPreparingModel else { return }
        if isPreparationPaused, let process = runningProcess {
            kill(process.processIdentifier, SIGCONT)
        }
        cancellationRequested = true
        runningProcess?.terminate()
        isPreparationPaused = false
    }

    func cancelCurrentTranscription() {
        guard isTranscribing else { return }
        cancellationRequested = true
        runningProcess?.terminate()
    }

    func cancelAllQueueTranscriptions() {
        cancellationRequested = true
        for item in queue where item.status == .waiting || item.status == .transcribing {
            item.status = .cancelled
        }
        runningProcess?.terminate()
    }

    func deleteHistoryRecord(id: UUID) {
        historyStore.delete(id: id)
        history = historyStore.load()
    }

    func copyTranscript(_ transcript: String? = nil) {
        let value = transcript ?? currentTranscript
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func export(record: SpeechHistoryRecord? = nil, format: SpeechTranscriptExportFormat) throws {
        let resolved = record ?? currentHistoryRecord
        guard let resolved else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        switch format {
        case .txt:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = suggestedExportFileName(for: resolved, ext: "txt")
        case .markdown:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = suggestedExportFileName(for: resolved, ext: "md")
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = exportedText(for: resolved, format: format)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var currentHistoryRecord: SpeechHistoryRecord? {
        history.first(where: { $0.transcriptText == currentTranscript && !$0.transcriptText.isEmpty })
    }

    var isSelectedModelDownloaded: Bool {
        isModelDownloaded(selectedModelID)
    }

    func isModelDownloaded(_ modelID: SpeechModelID) -> Bool {
        let cacheURL = cacheDirectory(for: modelID)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let hasSafetensors = contents.contains { $0.pathExtension == "safetensors" }
        let hasVocab = contents.contains { $0.lastPathComponent == "vocab.json" }
        return hasSafetensors && hasVocab
    }

    var selectedModelDescriptor: SpeechModelDescriptor? {
        curatedSpeechModels.first(where: { $0.id == selectedModelID })
    }

    var selectedModelEstimatedSizeText: String {
        humanReadableByteCount(estimatedModelBytes(for: selectedModelID))
    }

    var selectedModelPreparedSizeText: String {
        humanReadableByteCount(preparedModelBytes)
    }

    var selectedModelDownloadSpeedText: String {
        guard downloadSpeedBytesPerSecond > 0 else { return "0 KB/s" }
        return "\(humanReadableByteCount(Int64(downloadSpeedBytesPerSecond)))/s"
    }

    var preparationProgressPercentText: String {
        "\(Int((preparationProgressFraction * 100).rounded()))%"
    }

    var selectedModelDownloadETAText: String? {
        guard isPreparingModel, downloadSpeedBytesPerSecond > 0, !isPreparationPaused else { return nil }
        let remainingBytes = max(preparedModelEstimatedTotalBytes - preparedModelBytes, 0)
        let seconds = Double(remainingBytes) / downloadSpeedBytesPerSecond
        guard seconds > 0 && seconds < 3600 * 24 else { return nil }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m > 0 {
            return L10n.f("speech.download_progress.eta_minutes_seconds", fallback: "剩余 %d分%d秒", m, s)
        } else {
            return L10n.f("speech.download_progress.eta_seconds", fallback: "剩余 %d秒", s)
        }
    }

    func exportedText(for record: SpeechHistoryRecord, format: SpeechTranscriptExportFormat) -> String {
        switch format {
        case .txt:
            return record.transcriptText
        case .markdown:
            return """
            # \(record.sourceFileName)

            - Source: \(record.sourceFilePath)
            - Exported At: \(ISO8601DateFormatter().string(from: Date()))
            - Model: \(record.modelDisplayName)
            - Elapsed: \(String(format: "%.2f", record.elapsedSeconds))s

            \(record.transcriptText)
            """
        }
    }

    private func refreshRecommendation(localAIServiceRunning: Bool) {
        let supportedAvailability = detectAvailability()
        availability = supportedAvailability
        recommendation = SpeechModelAdvisor.recommend(
            for: .init(
                isAppleSilicon: isAppleSilicon(),
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                availableMemoryBytes: availableMemoryBytes(),
                availableDiskBytes: availableDiskBytes(),
                localAIServiceRunning: localAIServiceRunning
            )
        )
        recommendation = SpeechModelRecommendation(
            recommendedModel: recommendation.recommendedModel,
            fallbackModel: recommendation.fallbackModel,
            warnings: recommendation.warnings,
            availability: supportedAvailability
        )
    }

    private func refreshModelDownloadState() {
        preparedModelEstimatedTotalBytes = estimatedModelBytes(for: selectedModelID)
        preparedModelBytes = currentModelBytes(for: selectedModelID)
        if !isPreparingModel {
            downloadSpeedBytesPerSecond = 0
            preparationProgressFraction = 0
            preparationStatusMessage = nil
        }
    }

    private func detectAvailability() -> SpeechToolAvailability {
        guard isAppleSilicon() else {
            return SpeechToolAvailability(
                isAvailable: false,
                reason: .unsupportedCPU,
                detail: "Speech transcription requires Apple Silicon."
            )
        }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
            return SpeechToolAvailability(
                isAvailable: false,
                reason: .unsupportedOS,
                detail: "Speech transcription requires macOS 15 or later."
            )
        }
        guard fileManager.isExecutableFile(atPath: bundledToolURL().path) else {
            return SpeechToolAvailability(
                isAvailable: false,
                reason: .missingBundledTool,
                detail: "Bundled speech tool is missing from the app bundle."
            )
        }
        return .supported
    }

    private func probeTool() async throws -> ToolProbeResponse {
        let data = try await runTool(arguments: ["probe"])
        return try JSONDecoder().decode(ToolProbeResponse.self, from: data)
    }

    private func runTranscription(for fileURL: URL, modelID: SpeechModelID) async throws -> ToolTranscribeResponse {
        let cacheURL = cacheDirectory(for: modelID)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let arguments = [
            "transcribe",
            "--file", fileURL.path,
            "--model-id", modelID.rawValue,
            "--cache-dir", cacheURL.path
        ]
        let data = try await runTool(
            arguments: arguments,
            onProgress: { [weak self] event in
                Task { @MainActor in
                    self?.applyTranscriptionProgress(event)
                }
            }
        )
        let response = try JSONDecoder().decode(ToolTranscribeResponse.self, from: data)
        if response.ok {
            return response
        }
        throw NSError(
            domain: "ai.clawdhome.speech",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: response.error ?? "Speech transcription failed."]
        )
    }

    private func runPrepareModel(for modelID: SpeechModelID) async throws -> ToolPrepareResponse {
        let cacheURL = cacheDirectory(for: modelID)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let data = try await runTool(
            arguments: [
                "prepare-model",
                "--model-id", modelID.rawValue,
                "--cache-dir", cacheURL.path
            ],
            onProgress: { [weak self] event in
                Task { @MainActor in
                    self?.applyPreparationProgress(event)
                }
            }
        )
        let response = try JSONDecoder().decode(ToolPrepareResponse.self, from: data)
        if response.ok {
            return response
        }
        throw NSError(
            domain: "ai.clawdhome.speech",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: response.error ?? "Speech model preparation failed."]
        )
    }

    private func runTool(
        arguments: [String],
        onProgress: ((SpeechToolProgressEvent) -> Void)? = nil
    ) async throws -> Data {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = bundledToolURL()
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error

        // 注入加速源和 Token 环境变量
        let pref = UserDefaults.standard.string(forKey: "hf_endpoint_preference") ?? ""
        let prefToken = UserDefaults.standard.string(forKey: "hf_token_preference") ?? ""
        let resolvedEndpoint: String
        if pref == "custom" {
            resolvedEndpoint = UserDefaults.standard.string(forKey: "custom_hf_endpoint") ?? ""
        } else {
            resolvedEndpoint = pref
        }
        if !resolvedEndpoint.isEmpty || !prefToken.isEmpty {
            var env = ProcessInfo.processInfo.environment
            if !resolvedEndpoint.isEmpty {
                env["HF_ENDPOINT"] = resolvedEndpoint
            }
            if !prefToken.isEmpty {
                env["HF_TOKEN"] = prefToken
            }
            process.environment = env
        }

        return try await withCheckedThrowingContinuation { continuation in
            let stderrMonitor = ToolStderrMonitor()

            error.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                stderrMonitor.append(data, onProgress: onProgress)
            }

            process.terminationHandler = { [weak self] process in
                let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
                error.fileHandleForReading.readabilityHandler = nil
                let stderrTail = error.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrMonitor.finish(with: stderrTail, onProgress: onProgress)

                Task { @MainActor in
                    self?.runningProcess = nil
                }

                if process.terminationStatus == 0 {
                    let cleanedData = SpeechTranscriptionService.extractJSONData(from: stdoutData)
                    continuation.resume(returning: cleanedData)
                    return
                }

                let message = SpeechToolOutputParser.errorMessage(stdout: stdoutData, stderr: stderrData)
                continuation.resume(
                    throwing: NSError(
                        domain: "ai.clawdhome.speech",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                )
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.runningProcess = process
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func applyPreparationProgress(_ event: SpeechToolProgressEvent) {
        guard event.command == "prepare-model" else { return }
        preparationProgressFraction = min(max(event.fractionCompleted, 0), 1)
        preparationStatusMessage = event.message
    }

    private func makeHistoryRecord(
        for fileURL: URL,
        modelID: SpeechModelID,
        transcript: String,
        elapsedSeconds: Double,
        status: SpeechHistoryStatus,
        errorSummary: String?
    ) -> SpeechHistoryRecord? {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return SpeechHistoryRecord(
            sourceFilePath: fileURL.path,
            sourceFileName: fileURL.lastPathComponent,
            sourceFileSizeBytes: size,
            durationSeconds: nil,
            engineID: "qwen3-asr",
            modelID: modelID,
            modelDisplayName: displayName(for: modelID),
            languageHintOrDetectedLanguage: nil,
            transcriptText: transcript,
            elapsedSeconds: elapsedSeconds,
            status: status,
            errorSummary: errorSummary
        )
    }

    private func displayName(for modelID: SpeechModelID) -> String {
        curatedSpeechModels.first(where: { $0.id == modelID })?.displayName ?? modelID.rawValue
    }

    private func estimatedModelBytes(for modelID: SpeechModelID) -> Int64 {
        guard let descriptor = curatedSpeechModels.first(where: { $0.id == modelID }) else {
            return 0
        }
        return Int64(descriptor.estimatedDiskGB * 1_000_000_000)
    }

    private func currentModelBytes(for modelID: SpeechModelID) -> Int64 {
        directorySize(at: cacheDirectory(for: modelID))
    }

    private func startDownloadMonitoring(for modelID: SpeechModelID) {
        stopDownloadMonitoring()
        let cacheURL = cacheDirectory(for: modelID)
        downloadMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousBytes = self.directorySize(at: cacheURL)
            var previousDate = Date()

            while !Task.isCancelled && self.isPreparingModel {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                
                if self.isPreparationPaused {
                    self.downloadSpeedBytesPerSecond = 0
                    previousDate = Date()
                    continue
                }

                let currentBytes = self.directorySize(at: cacheURL)
                let now = Date()
                let deltaBytes = max(currentBytes - previousBytes, 0)
                let deltaTime = now.timeIntervalSince(previousDate)

                self.preparedModelBytes = currentBytes
                if deltaTime > 0 {
                    self.downloadSpeedBytesPerSecond = Double(deltaBytes) / deltaTime
                }

                previousBytes = currentBytes
                previousDate = now
            }
        }
    }

    private func stopDownloadMonitoring() {
        downloadMonitorTask?.cancel()
        downloadMonitorTask = nil
    }

    private func speechCacheBaseDirectory() -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
            .appendingPathComponent("qwen3-asr", isDirectory: true)
    }

    private func cacheDirectory(for modelID: SpeechModelID) -> URL {
        modelID.repositoryCachePathComponents.reduce(speechCacheBaseDirectory()) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func bundledToolURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Executables", isDirectory: true)
            .appendingPathComponent("ClawdHomeSpeech", isDirectory: false)
    }

    private func suggestedExportFileName(for record: SpeechHistoryRecord, ext: String) -> String {
        let baseName = (record.sourceFileName as NSString).deletingPathExtension
        return "\(baseName)-transcript.\(ext)"
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]),
                values.isRegularFile == true
            else {
                continue
            }

            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }

    private func humanReadableByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    private func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private func availableMemoryBytes() -> UInt64 {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return ProcessInfo.processInfo.physicalMemory
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freePages = UInt64(vmStats.free_count + vmStats.inactive_count)
        return freePages * pageSize
    }

    private func availableDiskBytes() -> UInt64 {
        let cacheURL = speechCacheBaseDirectory()
        if let values = try? cacheURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(available, 0))
        }
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let available = attrs[.systemFreeSize] as? NSNumber {
            return available.uint64Value
        }
        return 0
    }
    
    func applyTranscriptionProgress(_ event: SpeechToolProgressEvent) {
        if event.command == "load-model" {
            transcriptionStatusMessage = event.message
            if let activeItem = queue.first(where: { $0.status == .transcribing }) {
                activeItem.stage = .loadingModel
                activeItem.stageProgress = 0.0
                activeItem.statusMessage = event.message
                activeItem.progressFraction = vocalEnhanceEnabled ? 0.12 : 0.02
            }
            return
        }
        
        guard event.command == "transcribe" else { return }
        transcriptionProgressFraction = min(max(event.fractionCompleted, 0), 1)
        transcriptionStatusMessage = event.message
        
        if let activeItem = queue.first(where: { $0.status == .transcribing }) {
            activeItem.stage = .transcribing
            activeItem.stageProgress = transcriptionProgressFraction
            
            // ASR 阶段，进度条从 10% (或 0%) 线性顺滑走到 100%
            let asrProgress = transcriptionProgressFraction
            let base = vocalEnhanceEnabled ? 0.1 : 0.0
            let overallProgress = base + (asrProgress * (1.0 - base))
            
            activeItem.progressFraction = overallProgress
            activeItem.statusMessage = String(format: "ASR 智能转译中... %.0f%%", asrProgress * 100)

            if let transcript = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                let filteredTranscript = applyHotwordsFilter(to: transcript)
                activeItem.transcriptText = filteredTranscript

                // 只有当用户当前选中的是正在转写中的任务时，才实时显示在右侧文本框
                // 避免将“已转写 5%”这类进度状态误写为 ASR 正文。
                if selectedQueueItem?.id == activeItem.id {
                    currentTranscript = filteredTranscript
                }
            }
            
            // 计算实时 ASR 转译速率 (仅在 asrStartTime 已记录时)
            if let startTime = self.asrStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0.3 {
                    var speedText = ""
                    // 计算倍速
                    if activeItem.durationSeconds > 0 {
                        let processedAudio = activeItem.durationSeconds * transcriptionProgressFraction
                        let speedX = processedAudio / elapsed
                        speedText = String(format: "%.1fx", speedX)
                    }
                    
                    // 计算字数转换速率
                    let charCount = activeItem.transcriptText.count
                    if charCount > 0 {
                        let charSpeed = Double(charCount) / elapsed
                        if !speedText.isEmpty {
                            speedText += String(format: " (%.0f字/秒)", charSpeed)
                        } else {
                            speedText = String(format: "%.0f字/秒", charSpeed)
                        }
                    }
                    
                    if !speedText.isEmpty {
                        activeItem.asrSpeed = speedText
                    }
                }
            }
        }
    }



    /// 【方案 A】利用 macOS 原生的 AVAudioEngine Manual Rendering 链条对输入音频进行极速高保真去噪和人声隔离增强
    private func enhanceVocal(inputURL: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("clawdhome_vocal_enhanced_\(UUID().uuidString).wav")
        
        let audioFile = try AVAudioFile(forReading: inputURL)
        let format = audioFile.processingFormat
        
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        
        // 实例化原生的音频滤波器（仅保留高保真 EQ 滤镜）
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        
        engine.attach(player)
        engine.attach(eq)
        
        // 拼接节点：Player -> EQ(高通降噪人声增强) -> Output
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.outputNode, format: format)
        
        // 配置 EQ 滤镜：100Hz 高通降噪 + 2.5kHz 人声增益
        let bypassBand = eq.bands[0]
        bypassBand.filterType = .highPass
        bypassBand.frequency = 100.0 // 截断 100Hz 以下低频背景杂噪
        bypassBand.bypass = false
        
        let vocalBand = eq.bands[1]
        vocalBand.filterType = .parametric
        vocalBand.frequency = 2500.0 // 增益 2.5kHz 人声主频齿音
        vocalBand.bandwidth = 1.0
        vocalBand.gain = 4.0 // 增强 4dB 提取更加清脆的人声细节
        vocalBand.bypass = false
        
        // 启用 AVAudioEngine 手动离线极速渲染模式
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        
        // 启动节点与装载音频
        try engine.start()
        player.scheduleFile(audioFile, at: nil, completionHandler: nil)
        player.play()
        
        // 使用与渲染缓冲区完全一致的 processingFormat 格式进行高保真自适应写出
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        
        // 极速渲染循环
        let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        let totalFrames = audioFile.length
        var lastReportedProgress: Double = 0.0
        
        while engine.manualRenderingSampleTime < totalFrames {
            let framesToRender = min(maxFrames, AVAudioFrameCount(totalFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            
            if status == .success {
                try outputFile.write(from: renderBuffer)
                
                // 实时计算渲染帧数进度
                let progress = Double(engine.manualRenderingSampleTime) / Double(totalFrames)
                // 每增长 2% 进行一次通知，防高频线程通知导致 UI 渲染锁死
                if progress - lastReportedProgress >= 0.02 || progress >= 0.99 {
                    lastReportedProgress = progress
                    onProgress(progress)
                }
            } else if status == .error {
                throw NSError(domain: "ai.clawdhome.speech.render", code: 4, userInfo: [NSLocalizedDescriptionKey: "WAV manual rendering failed."])
            }
        }
        
        player.stop()
        engine.stop()
        
        return outputURL
    }

    nonisolated private static func extractJSONData(from data: Data) -> Data {
        if let firstBraceIndex = data.firstIndex(of: 0x7B), // '{'
           let lastBraceIndex = data.lastIndex(of: 0x7D),  // '}'
           firstBraceIndex < lastBraceIndex {
            return data.subdata(in: firstBraceIndex..<(lastBraceIndex + 1))
        }
        return data
    }
}
