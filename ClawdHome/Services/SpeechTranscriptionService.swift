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

    // 【新增】当前选中的历史记录 ID
    var selectedRecordID: UUID? {
        didSet {
            if let record = selectedHistoryRecord {
                self.selectedQueueItem = nil
                self.selectedFileURL = URL(fileURLWithPath: record.sourceFilePath)
                self.currentTranscript = record.transcriptText
            }
        }
    }

    var selectedHistoryRecord: SpeechHistoryRecord? {
        history.first(where: { $0.id == selectedRecordID })
    }

    // 更新选中历史记录的原笔记内容并持久化
    func updateSelectedRecordTranscript(_ text: String) {
        guard let record = selectedHistoryRecord else { return }
        var updated = record
        updated.transcriptText = text
        historyStore.save(updated)
        self.syncToObsidian(record: updated)
        // 重新从磁盘加载，同步内存列表状态，但保留选中状态
        let prevSelected = selectedRecordID
        history = historyStore.load()
        selectedRecordID = prevSelected
    }

    // 更新选中历史记录的 AI 润色精装内容并持久化
    func updateSelectedRecordRefinedText(_ text: String) {
        guard let record = selectedHistoryRecord else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = record
        updated.refinedText = trimmedText
        updated.refinedTitle = Self.refinedTitleFromFirstLine(trimmedText)
        updated.refinedSummary = nil
        updated.refinedTags = nil
        historyStore.save(updated)
        self.syncToObsidian(record: updated)
        let prevSelected = selectedRecordID
        history = historyStore.load()
        selectedRecordID = prevSelected
    }

    @discardableResult
    func applyRefinedTextToCurrentRecord(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, var updated = currentHistoryRecord else { return false }
        updated.refinedText = trimmedText
        updated.refinedTitle = Self.refinedTitleFromFirstLine(trimmedText)
        updated.refinedSummary = nil
        updated.refinedTags = nil
        historyStore.save(updated)
        self.syncToObsidian(record: updated)
        history = historyStore.load()
        selectedRecordID = updated.id
        return true
    }

    // 是否启用 macOS 原生 AI 人声降噪与增强预处理，默认开启 (方案 A)
    var vocalEnhanceEnabled: Bool = true

    // 【新增】待转译的任务队列
    private(set) var queue: [SpeechQueueItem] = []

    // 【新增】当前选中的队列任务项（右侧展示其对应的转译结果）
    var selectedQueueItem: SpeechQueueItem? {
        didSet {
            if let item = selectedQueueItem {
                self.selectedRecordID = nil // 清空历史记录选中
                self.selectedFileURL = item.fileURL
                self.currentTranscript = item.transcriptText
            }
        }
    }

    private var runningProcess: Process?
    private var cancellationRequested = false
    private var downloadMonitorTask: Task<Void, Never>?
    private var asrStartTime: Date? = nil

    private var obsidianWatcherTimer: Timer?

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

        // 启动后台 Obsidian 共享音频捕获监控
        self.startObsidianWatcher()
    }

    /// 开启监控 Obsidian Vault 文件夹，自动捕获手机 DeepJerry 录入的新音频并接力 ASR
    func startObsidianWatcher() {
        obsidianWatcherTimer?.invalidate()

        // 启动每 8 秒一次的静默轮询监控
        obsidianWatcherTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.scanAndProcessObsidianAudios()
            }
        }
    }

    /// 停止监控
    func stopObsidianWatcher() {
        obsidianWatcherTimer?.invalidate()
        obsidianWatcherTimer = nil
    }

    /// 扫描 Obsidian attachments 目录并自动处理新捕获的音频
    private func scanAndProcessObsidianAudios() async {
        let defaults = UserDefaults.standard
        // 必须开启了 Obsidian 同步，且设置了有效的 Vault 路径
        guard defaults.bool(forKey: "obsidian_enabled") else { return }
        guard let vaultPath = defaults.string(forKey: "obsidian_vault_path"), !vaultPath.isEmpty else { return }

        let attachmentsSubdir = defaults.string(forKey: "obsidian_attachments") ?? "Inbox/attachments"
        let attachmentsURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(attachmentsSubdir)

        let fm = FileManager.default
        guard fm.fileExists(atPath: attachmentsURL.path) else { return }

        do {
            let files = try fm.contentsOfDirectory(at: attachmentsURL, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)

            // 筛选出音频文件 (.m4a, .wav, .mp3, .caf, .aac)
            let audioExtensions = ["m4a", "wav", "mp3", "caf", "aac"]
            let audioFiles = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }

            var newAudiosToEnqueue: [URL] = []
            for fileURL in audioFiles {
                let fileName = fileURL.lastPathComponent

                // 检查是否已经存在于 ClawdHome 的 ASR 历史记录中（或者正在队列中处理）
                let alreadyProcessed = history.contains { record in
                    record.sourceFileName == fileName ||
                    fileName.hasSuffix(record.sourceFileName) ||
                    record.sourceFileName.hasSuffix(fileName)
                }

                let alreadyInQueue = queue.contains { $0.fileURL.lastPathComponent == fileName }

                if !alreadyProcessed && !alreadyInQueue {
                    newAudiosToEnqueue.append(fileURL)
                }
            }

            guard !newAudiosToEnqueue.isEmpty else { return }

            print("[ObsidianWatcher] Detected \(newAudiosToEnqueue.count) new raw audios from DeepJerryApp!")

            // 自动批量入队并设置降噪等偏好
            self.enqueueFiles(newAudiosToEnqueue)

            // 如果当前不在转译中，立即启动接力转译
            if !isTranscribing {
                Task {
                    await self.transcribeSelectedFile()
                }
            }
        } catch {
            print("[ObsidianWatcher] Error scanning Obsidian vault: \(error.localizedDescription)")
        }
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
        let item = SpeechQueueItem(fileURL: url, isVocalEnhanced: vocalEnhanceEnabled)
        queue.append(item)
        selectedQueueItem = item
        lastErrorMessage = nil
    }

    // 【新增】多音频文件批量追加至队列
    func enqueueFiles(_ urls: [URL]) {
        let newItems = urls.map { SpeechQueueItem(fileURL: $0, isVocalEnhanced: vocalEnhanceEnabled) }
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

                let finalTranscript = response.transcript ?? ""

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
                    durationSeconds: nextItem.durationSeconds,
                    modelID: selectedModelID,
                    transcript: finalTranscript,
                    elapsedSeconds: nextItem.elapsedSeconds,
                    status: .completed,
                    errorSummary: nil,
                    vocalEnhanceEnabled: nextItem.isVocalEnhanced
                ) {
                    historyStore.save(record)
                    self.syncToObsidian(record: record)
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
                        durationSeconds: nextItem.durationSeconds,
                        modelID: selectedModelID,
                        transcript: "",
                        elapsedSeconds: 0,
                        status: .cancelled,
                        errorSummary: nil,
                        vocalEnhanceEnabled: nextItem.isVocalEnhanced
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
                        durationSeconds: nextItem.durationSeconds,
                        modelID: selectedModelID,
                        transcript: "",
                        elapsedSeconds: 0,
                        status: .failed,
                        errorSummary: error.localizedDescription,
                        vocalEnhanceEnabled: nextItem.isVocalEnhanced
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

    func openHistoryDirectory() {
        let baseDir = SpeechHistoryStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("speech_transcription")
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(baseDir)
    }

    /// 在 Finder 中打开 ASR 模型缓存目录（~/Library/Caches/ClawdHome/SpeechModels/）
    func openModelsDirectory() {
        let dir = speechCacheBaseDirectory()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
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

    nonisolated static func obsidianASRNoteFileName(for record: SpeechHistoryRecord) -> String {
        "\(obsidianASRNoteTitle(for: record)) clawdhome_asr.md"
    }

    private nonisolated static func obsidianASRNoteTitle(for record: SpeechHistoryRecord) -> String {
        let rawBaseName = (record.sourceFileName as NSString).deletingPathExtension
        let refinedTitle = normalizedRefinedTitleForFileName(record.refinedTitle)
        if let timestamp = leadingObsidianTimestamp(in: rawBaseName) {
            let remainder = String(rawBaseName.dropFirst(timestamp.count))
            let title = refinedTitle ?? normalizedObsidianSourceTitle(remainder)
            return "\(timestamp) \(title)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = formatter.string(from: record.createdAt)
        let title = refinedTitle ?? normalizedObsidianSourceTitle(rawBaseName)
        return "\(timestamp) \(title)"
    }

    private nonisolated static func leadingObsidianTimestamp(in value: String) -> String? {
        let timestampLength = 19
        guard value.count >= timestampLength else { return nil }

        let candidate = String(value.prefix(timestampLength))
        let scalars = Array(candidate.unicodeScalars)
        guard scalars.count == timestampLength else { return nil }

        let separators: [Int: UnicodeScalar] = [
            4: "-",
            7: "-",
            10: " ",
            13: "-",
            16: "-"
        ]

        for index in 0..<timestampLength {
            if let separator = separators[index] {
                guard scalars[index] == separator else { return nil }
            } else {
                guard CharacterSet.decimalDigits.contains(scalars[index]) else { return nil }
            }
        }
        return candidate
    }

    private nonisolated static func normalizedObsidianSourceTitle(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.caseInsensitiveCompare("Audio") == .orderedSame {
            return "Flash"
        }
        return title
    }

    nonisolated static func refinedTitleFromFirstLine(_ text: String) -> String? {
        guard let firstLine = text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }

        var title = firstLine
        while title.hasPrefix("#") {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」『』《》[]()（）【】"))
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }
        return String(title.prefix(24))
    }

    private nonisolated static func normalizedRefinedTitleForFileName(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let illegalScalars = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleanedScalars = value.unicodeScalars.map { scalar -> Character in
            illegalScalars.contains(scalar) ? "-" : Character(scalar)
        }
        let cleaned = String(cleanedScalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))

        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(48))
    }

    private nonisolated static func sourceAudioIsAlreadyInAttachments(_ sourceAudioURL: URL, attachmentsURL: URL) -> Bool {
        let sourcePath = sourceAudioURL.standardizedFileURL.path
        let attachmentsPath = attachmentsURL.standardizedFileURL.path
        let directoryPrefix = attachmentsPath.hasSuffix("/") ? attachmentsPath : "\(attachmentsPath)/"
        return sourcePath.hasPrefix(directoryPrefix)
    }

    /// 【新增】将特定语音记录及其音频同步到 Obsidian Vault（自动同步，不报错不阻塞）
    func syncToObsidian(record: SpeechHistoryRecord) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "obsidian_enabled") else { return }
        guard let vaultPath = defaults.string(forKey: "obsidian_vault_path"), !vaultPath.isEmpty else { return }

        let inbox = defaults.string(forKey: "obsidian_inbox") ?? "Inbox"
        let attachments = defaults.string(forKey: "obsidian_attachments") ?? "Inbox/attachments"

        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let inboxURL = vaultURL.appendingPathComponent(inbox)
        let attachmentsURL = vaultURL.appendingPathComponent(attachments)

        do {
            try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        } catch {
            print("Failed to create Obsidian vault subdirectories: \(error.localizedDescription)")
            return
        }

        let sourceAudioURL = URL(fileURLWithPath: record.sourceFilePath)
        guard fileManager.fileExists(atPath: sourceAudioURL.path) else {
            print("Source audio file does not exist: \(record.sourceFilePath)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let datePrefix = formatter.string(from: record.createdAt)
        let (targetAudioFileName, targetAudioURL, shouldCopyAudio): (String, URL, Bool)
        if Self.sourceAudioIsAlreadyInAttachments(sourceAudioURL, attachmentsURL: attachmentsURL) {
            targetAudioFileName = sourceAudioURL.lastPathComponent
            targetAudioURL = sourceAudioURL
            shouldCopyAudio = false
        } else {
            targetAudioFileName = "\(datePrefix)_\(record.sourceFileName)"
            targetAudioURL = attachmentsURL.appendingPathComponent(targetAudioFileName)
            shouldCopyAudio = true
        }

        if shouldCopyAudio {
            do {
                if fileManager.fileExists(atPath: targetAudioURL.path) {
                    try fileManager.removeItem(at: targetAudioURL)
                }
                try fileManager.copyItem(at: sourceAudioURL, to: targetAudioURL)
            } catch {
                print("Failed to copy audio to Obsidian attachments: \(error.localizedDescription)")
                return
            }
        }

        let noteTitle = Self.obsidianASRNoteTitle(for: record)
        let noteFileName = Self.obsidianASRNoteFileName(for: record)
        let noteURL = inboxURL.appendingPathComponent(noteFileName)

        let dateStringFormatter = DateFormatter()
        dateStringFormatter.dateStyle = .medium
        dateStringFormatter.timeStyle = .medium
        let dateString = dateStringFormatter.string(from: record.createdAt)

        let obsidianAudioLink = "![[\(attachments)/\(targetAudioFileName)]]"

        var mdContent = """
        # 语音记录: \(noteTitle)

        - **录音时间**: \(dateString)
        - **识别模型**: \(record.modelDisplayName)
        - **音频长度**: \(record.durationSeconds != nil ? String(format: "%.1fs", record.durationSeconds!) : "未知")

        ## 🎧 音频回放
        \(obsidianAudioLink)

        """

        if let refined = record.refinedText, !refined.isEmpty {
            mdContent += """

            ## ✨ AI 智能精装版
            \(refined)

            """
        }

        mdContent += """

        ## 📝 转写原稿
        \(record.transcriptText)

        """

        do {
            try mdContent.write(to: noteURL, atomically: true, encoding: .utf8)
            print("Successfully synced recording and note to Obsidian Vault!")
        } catch {
            print("Failed to write Obsidian markdown note: \(error.localizedDescription)")
        }
    }

    /// 【新增】手动强制将语音记录同步到 Obsidian Vault（若报错则向外抛出）
    @discardableResult
    func manualSyncToObsidian(record: SpeechHistoryRecord) throws -> Bool {
        let defaults = UserDefaults.standard
        guard let vaultPath = defaults.string(forKey: "obsidian_vault_path"), !vaultPath.isEmpty else {
            throw NSError(
                domain: "ai.clawdhome.obsidian",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.k("settings.obsidian.error.vault_not_set", fallback: "未配置 Obsidian Vault 路径，请前往设置配置")]
            )
        }

        let inbox = defaults.string(forKey: "obsidian_inbox") ?? "Inbox"
        let attachments = defaults.string(forKey: "obsidian_attachments") ?? "Inbox/attachments"

        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let inboxURL = vaultURL.appendingPathComponent(inbox)
        let attachmentsURL = vaultURL.appendingPathComponent(attachments)

        try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        let sourceAudioURL = URL(fileURLWithPath: record.sourceFilePath)
        guard fileManager.fileExists(atPath: sourceAudioURL.path) else {
            throw NSError(
                domain: "ai.clawdhome.obsidian",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L10n.k("settings.obsidian.error.audio_missing", fallback: "找不到源音频文件")]
            )
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let datePrefix = formatter.string(from: record.createdAt)
        let (targetAudioFileName, targetAudioURL, shouldCopyAudio): (String, URL, Bool)
        if Self.sourceAudioIsAlreadyInAttachments(sourceAudioURL, attachmentsURL: attachmentsURL) {
            targetAudioFileName = sourceAudioURL.lastPathComponent
            targetAudioURL = sourceAudioURL
            shouldCopyAudio = false
        } else {
            targetAudioFileName = "\(datePrefix)_\(record.sourceFileName)"
            targetAudioURL = attachmentsURL.appendingPathComponent(targetAudioFileName)
            shouldCopyAudio = true
        }

        if shouldCopyAudio {
            if fileManager.fileExists(atPath: targetAudioURL.path) {
                try fileManager.removeItem(at: targetAudioURL)
            }
            try fileManager.copyItem(at: sourceAudioURL, to: targetAudioURL)
        }

        let noteTitle = Self.obsidianASRNoteTitle(for: record)
        let noteFileName = Self.obsidianASRNoteFileName(for: record)
        let noteURL = inboxURL.appendingPathComponent(noteFileName)

        let dateStringFormatter = DateFormatter()
        dateStringFormatter.dateStyle = .medium
        dateStringFormatter.timeStyle = .medium
        let dateString = dateStringFormatter.string(from: record.createdAt)

        let obsidianAudioLink = "![[\(attachments)/\(targetAudioFileName)]]"

        var mdContent = """
        # 语音记录: \(noteTitle)

        - **录音时间**: \(dateString)
        - **识别模型**: \(record.modelDisplayName)
        - **音频长度**: \(record.durationSeconds != nil ? String(format: "%.1fs", record.durationSeconds!) : "未知")

        ## 🎧 音频回放
        \(obsidianAudioLink)

        """

        if let refined = record.refinedText, !refined.isEmpty {
            mdContent += """

            ## ✨ AI 智能精装版
            \(refined)

            """
        }

        mdContent += """

        ## 📝 转写原稿
        \(record.transcriptText)

        """

        try mdContent.write(to: noteURL, atomically: true, encoding: .utf8)
        return true
    }

    var currentHistoryRecord: SpeechHistoryRecord? {
        if let selectedRecordID {
            return history.first(where: { $0.id == selectedRecordID })
        }
        return history.first(where: { $0.transcriptText == currentTranscript && !$0.transcriptText.isEmpty })
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

            var stdoutAccumulated = Data()
            let stdoutLock = NSLock()

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                stdoutLock.lock()
                stdoutAccumulated.append(data)
                stdoutLock.unlock()
            }

            error.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                stderrMonitor.append(data, onProgress: onProgress)
            }

            process.terminationHandler = { [weak self] process in
                // 首先关闭 readabilityHandler 以免再次派发或读写冲突
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil

                // 收尾读取管道中残留的所有剩余数据
                let stdoutTail = output.fileHandleForReading.readDataToEndOfFile()
                let stderrTail = error.fileHandleForReading.readDataToEndOfFile()

                stdoutLock.lock()
                stdoutAccumulated.append(stdoutTail)
                let finalStdout = stdoutAccumulated
                stdoutLock.unlock()

                let stderrData = stderrMonitor.finish(with: stderrTail, onProgress: onProgress)

                Task { @MainActor in
                    self?.runningProcess = nil
                }

                if process.terminationStatus == 0 {
                    let cleanedData = SpeechTranscriptionService.extractJSONData(from: finalStdout)
                    continuation.resume(returning: cleanedData)
                    return
                }

                let message = SpeechToolOutputParser.errorMessage(stdout: finalStdout, stderr: stderrData)
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
        durationSeconds: Double?,
        modelID: SpeechModelID,
        transcript: String,
        elapsedSeconds: Double,
        status: SpeechHistoryStatus,
        errorSummary: String?,
        vocalEnhanceEnabled: Bool? = nil
    ) -> SpeechHistoryRecord? {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return SpeechHistoryRecord(
            sourceFilePath: fileURL.path,
            sourceFileName: fileURL.lastPathComponent,
            sourceFileSizeBytes: size,
            durationSeconds: durationSeconds,
            engineID: "qwen3-asr",
            modelID: modelID,
            modelDisplayName: displayName(for: modelID),
            languageHintOrDetectedLanguage: nil,
            transcriptText: transcript,
            elapsedSeconds: elapsedSeconds,
            status: status,
            errorSummary: errorSummary,
            vocalEnhanceEnabled: vocalEnhanceEnabled
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
            let displayProgress = min(transcriptionProgressFraction, 0.995)
            activeItem.stage = .transcribing
            activeItem.stageProgress = displayProgress

            // ASR 阶段，进度条从 10% (或 0%) 线性顺滑走到 100%
            let asrProgress = displayProgress
            let base = vocalEnhanceEnabled ? 0.1 : 0.0
            let overallProgress = base + (asrProgress * (1.0 - base))

            activeItem.progressFraction = overallProgress
            let progressMessage = event.message.trimmingCharacters(in: .whitespacesAndNewlines)
            activeItem.statusMessage = transcriptionProgressFraction >= 1.0
                ? "正在整理最终文本..."
                : progressMessage.isEmpty
                ? String(format: "ASR 智能转译中... %.0f%%", asrProgress * 100)
                : progressMessage

            if let transcript = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                let filteredTranscript = transcript
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

    // 【新增】ASR 系统 Prompt 生成器
    private static func buildSystemPrompt(glossary: String, mode: String) -> String {
        return """
        你是一个极其专业的语音转写文本（ASR）智能精整与专名纠错专家。

        # 上下文提示（专有名词字典）
        以下是用户提供的正确背景主题与专名热词列表：
        <glossary>
        \(glossary)
        </glossary>

        # 任务目标
        请根据所选模式 [\(mode)]，在不捏造事实的前提下完成处理：
        1. 【专名纠错】：根据 <glossary> 中提供的正确热词列表，在上下文中寻找发音相近的误识别词，并智能纠正（例如如果 glossary 有 ClawdHome，遇到 ClowdHome / CloudHome / Clawd Home 须全部自动纠正为 ClawdHome）。
        2. 【口语消解】：彻底剔除“嗯”、“啊”、“那啥”、“就是说”、“然后”等无意义的语气词 and 口癖，恢复文稿的清爽度。
        3. 【标点与断句】：智能修正断句，增添合适的标点符号。
        4. 【标题协议】：输出第一行必须是一个 Markdown 一级标题，格式为 `# 主题标题`；标题需直接概括音频核心主题，严格控制在 12 个汉字以内，不要使用“语音记录”“灵感随记”“会议纪要”等泛泛标题。第一行之后空一行，再输出正文。
        5. 【格式转换】：
           - 若模式为“原稿智能净化”：必须保留原始的口吻与第一人称，不要重写句式，仅纠正错别字和净化口癖。
           - 若模式为“提炼会议纪要”：提取主要议题、核心结论和后续待办行动项（Markdown 列表形式）。
           - 若模式为“专业文稿重塑”：将其重塑改写为排版优雅、逻辑顺畅、专业流畅的书面语报告或博客。
           - 若模式为“灵感随记整理”：将零散碎碎念、心境日记或突发灵感音频文本整理为排版精美、层次清晰的 Markdown 便签。其输出必须严格遵循以下结构：
             1. 首行输出 `# 主题标题`，标题必须来自内容本身，严格控制在 12 个汉字以内。
             2. 增加引言块输出 `> **📌 快速摘要**：[一句话提炼音频核心主题，精炼在 30 字内]`。
             3. 增加引言块输出 `> **🏷️ 关键词**：[根据内容提炼出 3-5 个核心标签，以 # 形式列出，例如 #灵感 #规划，标签之间空格隔开]`。
             4. 增加分割线 `---`。
             5. 增加 `### 📝 精整正文` 部分：将大段杂乱的口语消除口癖后理顺段落，排版得当、逻辑清晰，保留第一人称和原本的情感细节。
             6. 增加 `### ✅ 待办行动` 部分：智能捕捉内容中提及的所有未来待办任务、计划或建议行动，以 Markdown 任务列表（如 `- [ ] 任务 1`）形式列出。如果音频内容中确实没有任何未来待办项，则输出「无待办事项」。

        请直接输出处理后的纯文本，不要带有任何多余的开场白或解释。
        """
    }

    // 【同步向下兼容接口】智能精整入口（同步一次性返回）
    func refineTranscript(
        text: String,
        provider: ProviderTemplate,
        modelId: String,
        glossary: String,
        mode: String
    ) async throws -> String {
        let stream = refineTranscriptStream(
            text: text,
            provider: provider,
            modelId: modelId,
            glossary: glossary,
            mode: mode
        )
        var result = ""
        for try await chunk in stream {
            result += chunk
        }
        return result
    }

    // 【新增】智能精整流式入口（流式返回）
    func refineTranscriptStream(
        text: String,
        provider: ProviderTemplate,
        modelId: String,
        glossary: String,
        mode: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let secretKey = "\(provider.providerGroupId):\(provider.name)"
                    guard let apiKey = GlobalSecretsStore.shared.value(for: secretKey) else {
                        throw NSError(domain: "ai.clawdhome.speech", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法加载选中模型的 API 凭证，请前往「全局模型池」配置。"])
                    }

                    let systemPrompt = SpeechTranscriptionService.buildSystemPrompt(glossary: glossary, mode: mode)

                    try await callLLMForRefineStream(
                        modelId: modelId,
                        apiKey: apiKey,
                        systemPrompt: systemPrompt,
                        userMessage: text,
                        baseURL: provider.customBaseURL,
                        apiType: provider.customAPIType,
                        providerPrefix: provider.providerGroupId,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // 【新增】核心流式 SSE 抓取与 SSE 行文本解析引擎
    private func callLLMForRefineStream(
        modelId: String,
        apiKey: String,
        systemPrompt: String,
        userMessage: String,
        baseURL: String?,
        apiType: String?,
        providerPrefix: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let effectiveBaseURL: String
        let apiMode: String
        let normalizedModel: String

        let prefix = providerPrefix

        if let baseURL = baseURL, !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveBaseURL = baseURL
            apiMode = apiType ?? "openai-completions"
            normalizedModel = modelId.dropProviderPrefix()
        } else {
            switch prefix {
            case "anthropic":
                effectiveBaseURL = "https://api.anthropic.com"
                apiMode = "anthropic-messages"
                normalizedModel = modelId.dropPrefix("anthropic/")
            case "openai":
                effectiveBaseURL = "https://api.openai.com"
                apiMode = "openai-completions"
                normalizedModel = modelId.dropPrefix("openai/")
            case "openrouter":
                effectiveBaseURL = "https://openrouter.ai"
                apiMode = "openai-completions"
                normalizedModel = modelId.dropPrefix("openrouter/")
            case "google":
                effectiveBaseURL = "https://generativelanguage.googleapis.com"
                apiMode = "google-gemini"
                normalizedModel = modelId.dropPrefix("google/")
            case "bailian":
                effectiveBaseURL = "https://coding.dashscope.aliyuncs.com/v1"
                apiMode = "openai-completions"
                normalizedModel = modelId.dropPrefix("bailian/")
            case "qiniu":
                effectiveBaseURL = "https://api.qnaigc.com/v1"
                apiMode = "openai-completions"
                normalizedModel = modelId.dropPrefix("qiniu/")
            case "zai":
                effectiveBaseURL = "https://open.bigmodel.cn/api/paas/v4"
                apiMode = "openai-completions"
                normalizedModel = modelId.dropPrefix("zai/")
            case "minimax":
                effectiveBaseURL = "https://api.minimaxi.com/anthropic"
                apiMode = "anthropic-messages"
                normalizedModel = modelId.dropPrefix("minimax/")
            case "kimi-coding":
                effectiveBaseURL = "https://api.kimi.com/coding"
                apiMode = "anthropic-messages"
                normalizedModel = modelId.dropPrefix("kimi-coding/")
            default:
                effectiveBaseURL = "http://localhost:18800"
                apiMode = "openai-completions"
                normalizedModel = modelId
            }
        }

        let trimmedBase = effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
            ? String(effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).dropLast())
            : effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if apiMode.contains("anthropic") {
            let endpoint = trimmedBase.hasSuffix("/v1/messages") ? trimmedBase : (trimmedBase.hasSuffix("/v1") ? "\(trimmedBase)/messages" : "\(trimmedBase)/v1/messages")
            var req = URLRequest(url: URL(string: endpoint)!)
            req.httpMethod = "POST"
            if prefix == "minimax" {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": normalizedModel,
                "system": systemPrompt,
                "messages": [["role": "user", "content": userMessage]],
                "max_tokens": 4096,
                "stream": true
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "ai.clawdhome.speech.refine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Anthropic Stream API 响应非 200 错误。"])
            }
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        continuation.yield(text)
                    }
                }
            }

        } else if apiMode == "google-gemini" {
            let urlStr = "\(trimmedBase)/v1beta/models/\(normalizedModel):streamGenerateContent"
            var req = URLRequest(url: URL(string: urlStr)!)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["role": "user", "parts": [["text": userMessage]]]],
                "generationConfig": ["maxOutputTokens": 4096]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "ai.clawdhome.speech.refine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemini Stream API 响应非 200 错误。"])
            }
            for try await line in bytes.lines {
                var cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanLine.hasPrefix("data: ") {
                    cleanLine = String(cleanLine.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cleanLine.hasPrefix(",") {
                    cleanLine = String(cleanLine.dropFirst(1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cleanLine == "[" || cleanLine == "]" || cleanLine.isEmpty { continue }

                if let jsonData = cleanLine.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let first = candidates.first,
                   let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String {
                    continuation.yield(text)
                }
            }

        } else {
            // OpenAI 兼容
            let endpoint = trimmedBase.hasSuffix("/chat/completions") ? trimmedBase : (trimmedBase.hasSuffix("/v1") ? "\(trimmedBase)/chat/completions" : "\(trimmedBase)/v1/chat/completions")
            var req = URLRequest(url: URL(string: endpoint)!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": normalizedModel,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ],
                "max_tokens": 4096,
                "stream": true
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "ai.clawdhome.speech.refine", code: 3, userInfo: [NSLocalizedDescriptionKey: "OpenAI Stream API 响应非 200 错误。"])
            }
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if jsonString == "[DONE]" { continue }
                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        continuation.yield(content)
                    }
                }
            }
        }
    }

}

fileprivate extension String {
    func dropPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func dropProviderPrefix() -> String {
        let parts = split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return self }
        return parts[1]
    }
}
