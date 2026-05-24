import AppKit
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

    private var runningProcess: Process?
    private var cancellationRequested = false
    private var downloadMonitorTask: Task<Void, Never>?

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
        selectedFileURL = url
        lastErrorMessage = nil
    }

    func clearSelection() {
        selectedFileURL = nil
        currentTranscript = ""
        lastErrorMessage = nil
    }

    func transcribeSelectedFile() async {
        guard !isTranscribing else { return }
        guard let fileURL = selectedFileURL else {
            lastErrorMessage = "No audio file selected."
            return
        }
        guard availability.isAvailable else {
            lastErrorMessage = availability.detail
            return
        }

        isTranscribing = true
        cancellationRequested = false
        lastErrorMessage = nil

        do {
            let response = try await runTranscription(for: fileURL, modelID: selectedModelID)
            currentTranscript = response.transcript ?? ""
            if let record = makeHistoryRecord(
                for: fileURL,
                modelID: selectedModelID,
                transcript: currentTranscript,
                elapsedSeconds: response.elapsedSeconds ?? 0,
                status: .completed,
                errorSummary: nil
            ) {
                historyStore.save(record)
            }
            history = historyStore.load()
        } catch {
            if cancellationRequested {
                if let record = makeHistoryRecord(
                    for: fileURL,
                    modelID: selectedModelID,
                    transcript: "",
                    elapsedSeconds: 0,
                    status: .cancelled,
                    errorSummary: nil
                ) {
                    historyStore.save(record)
                }
                history = historyStore.load()
            } else {
                lastErrorMessage = error.localizedDescription
                if let record = makeHistoryRecord(
                    for: fileURL,
                    modelID: selectedModelID,
                    transcript: "",
                    elapsedSeconds: 0,
                    status: .failed,
                    errorSummary: error.localizedDescription
                ) {
                    historyStore.save(record)
                }
                history = historyStore.load()
            }
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
        return contents.contains { $0.pathExtension == "safetensors" || $0.lastPathComponent == "vocab.json" }
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
        let data = try await runTool(arguments: arguments)
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
                    continuation.resume(returning: stdoutData)
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
}
