// ClawdHome/Services/PrivacyFilterEngine.swift
// 本地内容脱敏核心逻辑引擎

import Foundation
import NaturalLanguage
import AppKit
import SwiftUI

// MARK: - 过滤器检测引擎类型

public enum FilterEngineType: String, Codable, CaseIterable, Identifiable {
    case native = "NATIVE"
    case semanticLocal = "LOCAL_SEMANTIC"
    case openAI = "OPENAI"

    public static var allCases: [FilterEngineType] {
        [.native, .semanticLocal]
    }

    public var id: String { rawValue }

    var usesSemanticRuntime: Bool {
        self == .semanticLocal || self == .openAI
    }

    public var label: String {
        switch self {
        case .native:
            return L10n.k("auto.privacy_filter.native_engine", fallback: "Apple")
        case .semanticLocal, .openAI:
            return L10n.k("auto.privacy_filter.openai_engine", fallback: "OpenAI q4")
        }
    }
}

public enum PrivacySemanticModel: String, Codable, CaseIterable, Identifiable {
    case openAIPrivacyFilterQ4 = "openai-privacy-filter-q4"

    public static var allCases: [PrivacySemanticModel] {
        [.openAIPrivacyFilterQ4]
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openAIPrivacyFilterQ4:
            return L10n.k("auto.privacy_filter.model_openai_q4", fallback: "OpenAI q4")
        }
    }

    public var isUserVisible: Bool {
        self == .openAIPrivacyFilterQ4
    }

    public var detail: String {
        switch self {
        case .openAIPrivacyFilterQ4:
            return L10n.k("auto.privacy_filter.model_openai_q4_detail", fallback: "约 945 MB，本地下载并使用 ONNX 模型检测 PII。")
        }
    }

    var installCommand: String {
        switch self {
        case .openAIPrivacyFilterQ4:
            return "prepare-onnx-model"
        }
    }
}

// MARK: - 敏感信息实体类别

public enum PrivacyEntityType: String, Codable, CaseIterable, Identifiable {
    case name = "PERSON"
    case phone = "PHONE"
    case email = "EMAIL"
    case address = "ADDRESS"
    case idCard = "ID_CARD"
    case bankCard = "BANK_CARD"
    case secret = "SECRET"
    case organization = "ORG"
    case username = "USER"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: return L10n.k("auto.privacy_filter.entity_name", fallback: "姓名")
        case .phone: return L10n.k("auto.privacy_filter.entity_phone", fallback: "电话")
        case .email: return L10n.k("auto.privacy_filter.entity_email", fallback: "邮箱")
        case .address: return L10n.k("auto.privacy_filter.entity_address", fallback: "地址")
        case .idCard: return L10n.k("auto.privacy_filter.entity_idcard", fallback: "身份证")
        case .bankCard: return L10n.k("auto.privacy_filter.entity_bankcard", fallback: "银行卡")
        case .secret: return L10n.k("auto.privacy_filter.entity_secret", fallback: "密钥")
        case .organization: return L10n.k("auto.privacy_filter.entity_org", fallback: "机构")
        case .username: return L10n.k("auto.privacy_filter.entity_username", fallback: "账户")
        }
    }

    public var color: Color {
        switch self {
        case .name: return .blue
        case .phone: return .green
        case .email: return .orange
        case .address: return .teal
        case .idCard: return .purple
        case .bankCard: return .indigo
        case .secret: return .red
        case .organization: return .pink
        case .username: return .gray
        }
    }
}

// MARK: - 命中的敏感词 Span

public struct PrivacySpan: Identifiable, Hashable, Codable {
    public let id: UUID
    public let text: String
    public let type: PrivacyEntityType
    public let startOffset: Int
    public let endOffset: Int
    public let confidence: Double
    public var placeholder: String
    public var isIgnored: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        type: PrivacyEntityType,
        startOffset: Int,
        endOffset: Int,
        confidence: Double,
        placeholder: String = "",
        isIgnored: Bool = false
    ) {
        self.id = id
        self.text = text
        self.type = type
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.confidence = confidence
        self.placeholder = placeholder
        self.isIgnored = isIgnored
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: PrivacySpan, rhs: PrivacySpan) -> Bool {
        lhs.id == rhs.id
    }
}

public struct PrivacyRedactionMapping: Identifiable, Hashable, Codable {
    public var id: String { placeholder }
    public let placeholder: String
    public let originalText: String
    public let type: PrivacyEntityType

    public init(placeholder: String, originalText: String, type: PrivacyEntityType) {
        self.placeholder = placeholder
        self.originalText = originalText
        self.type = type
    }
}

// MARK: - OpenAI q4 模型运行时

public enum PrivacySemanticRuntime: Equatable {
    case bundledTool
    case tool(URL)
    case nodeScript(nodePath: String, scriptPath: String, timeoutSeconds: TimeInterval = 15)
    case disabledForTests

    var isAvailable: Bool {
        switch self {
        case .disabledForTests:
            return false
        case .bundledTool:
            return PrivacySemanticRuntime.bundledToolURL()?.isFileURL == true
        case let .tool(url):
            return FileManager.default.isExecutableFile(atPath: url.path)
        case let .nodeScript(nodePath, scriptPath, _):
            let fm = FileManager.default
            return fm.isExecutableFile(atPath: nodePath) && fm.fileExists(atPath: scriptPath)
        }
    }

    fileprivate var executableURL: URL? {
        switch self {
        case .bundledTool:
            return Self.bundledToolURL()
        case let .tool(url):
            return url
        case let .nodeScript(nodePath, _, _):
            return URL(fileURLWithPath: nodePath)
        case .disabledForTests:
            return nil
        }
    }

    fileprivate static func bundledToolURL() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Executables/ClawdHomePrivacyFilter")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}

public struct PrivacyModelDownloadProgress: Decodable, Equatable {
    public let modelID: String
    public let status: String
    public let currentFile: String?
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public let fileDownloadedBytes: Int64
    public let fileTotalBytes: Int64
    public let bytesPerSecond: Double
    public let error: String?

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

// MARK: - 脱敏分析引擎

@Observable
public final class PrivacyFilterEngine {
    public static let openAIPrivacyFilterQ4ModelID = "openai-privacy-filter-q4"

    public private(set) var isSemanticModelReady = false
    public private(set) var isPreparingSemanticModel = false
    public private(set) var semanticModelErrorMessage: String?
    public private(set) var semanticModelProgress: PrivacyModelDownloadProgress?
    public var selectedSemanticModel: PrivacySemanticModel = .openAIPrivacyFilterQ4 {
        didSet {
            semanticModelProgress = nil
            refreshSemanticModelReadyState()
        }
    }

    public var isRealModelReady: Bool {
        get { isSemanticModelReady }
        set { isSemanticModelReady = newValue }
    }

    private let semanticRuntime: PrivacySemanticRuntime
    public let semanticModelDirectory: URL
    public var selectedSemanticModelDirectory: URL {
        directory(for: selectedSemanticModel)
    }
    private let fileManager: FileManager

    public init(
        semanticRuntime: PrivacySemanticRuntime = .bundledTool,
        modelBaseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.semanticRuntime = semanticRuntime
        self.fileManager = fileManager
        self.semanticModelDirectory = modelBaseDirectory ?? Self.defaultSemanticModelDirectory(fileManager: fileManager)
        self.isSemanticModelReady = semanticRuntime.isAvailable && Self.hasPreparedSemanticModel(selectedSemanticModel, in: selectedSemanticModelDirectory, fileManager: fileManager)
    }

    /// 分析文本并标记敏感实体 Span 列表。Apple 与 OpenAI q4 独立运行，便于对比检测效果。
    public func analyze(text: String, engineType: FilterEngineType = .native) async -> [PrivacySpan] {
        guard !text.isEmpty else { return [] }

        switch engineType {
        case .native:
            var spans: [PrivacySpan] = []
            spans.append(contentsOf: runNativeEntityInference(text: text))
            spans.append(contentsOf: runRegexInference(text: text))
            return Self.finalize(spans: spans, in: text)
        case .semanticLocal, .openAI:
            guard isSemanticModelReady else { return [] }
            return Self.finalize(spans: await runSemanticInference(text: text), in: text)
        }
    }

    public func prepareSemanticModel(force: Bool = false) async {
        guard !isPreparingSemanticModel else { return }
        guard semanticRuntime.isAvailable else {
            semanticModelErrorMessage = L10n.k("auto.privacy_filter.tool_unavailable", fallback: "OpenAI q4 工具不可用。")
            isSemanticModelReady = false
            return
        }

        isPreparingSemanticModel = true
        semanticModelErrorMessage = nil
        semanticModelProgress = nil
        var progressPollingTask: Task<Void, Never>?
        defer {
            progressPollingTask?.cancel()
            isPreparingSemanticModel = false
        }

        do {
            let model = selectedSemanticModel
            let directory = directory(for: model)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var arguments = [model.installCommand, "--model-id", model.rawValue, "--cache-dir", directory.path]
            if model == .openAIPrivacyFilterQ4 {
                let progressFileURL = semanticModelProgressFileURL(for: directory)
                arguments.append(contentsOf: ["--progress-file", progressFileURL.path])
                progressPollingTask = startSemanticModelProgressPolling(progressFileURL)
            }
            if force {
                arguments.append("--force")
            }
            let response: PrepareModelResponse = try await runToolJSON(
                arguments: arguments,
                input: nil,
                timeoutSeconds: model == .openAIPrivacyFilterQ4 ? 3_600 : 120
            )
            if response.ok {
                isSemanticModelReady = Self.hasPreparedSemanticModel(model, in: directory, fileManager: fileManager)
            } else {
                isSemanticModelReady = false
                semanticModelErrorMessage = response.error
            }
        } catch {
            isSemanticModelReady = false
            semanticModelErrorMessage = error.localizedDescription
        }
    }

    private func semanticModelProgressFileURL(for directory: URL) -> URL {
        directory.appendingPathComponent(".clawdhome-download-progress.json")
    }

    private func startSemanticModelProgressPolling(_ progressFileURL: URL) -> Task<Void, Never> {
        Task { [weak self] in
            guard let engine = self else { return }
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progressFileURL),
                   let progress = try? JSONDecoder().decode(PrivacyModelDownloadProgress.self, from: data) {
                    await MainActor.run {
                        engine.semanticModelProgress = progress
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    public func openSemanticModelDirectory() {
        let directory = selectedSemanticModelDirectory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// 执行脱敏替换，只针对没有被人工忽略的 Span 进行，从后往前替换以避免 offset 失效。
    public func redact(text: String, spans: [PrivacySpan]) -> String {
        let activeSpans = spans.filter { !$0.isIgnored }
        guard !activeSpans.isEmpty else { return text }

        var redactedText = text
        let sortedSpans = activeSpans.sorted { $0.startOffset > $1.startOffset }

        for span in sortedSpans {
            guard let startIdx = redactedText.index(
                redactedText.startIndex,
                offsetBy: span.startOffset,
                limitedBy: redactedText.endIndex
            ),
                let endIdx = redactedText.index(
                    redactedText.startIndex,
                    offsetBy: span.endOffset,
                    limitedBy: redactedText.endIndex
                ),
                startIdx <= endIdx
            else { continue }

            redactedText.replaceSubrange(startIdx..<endIdx, with: span.placeholder)
        }

        return redactedText
    }

    public func redactionMapping(from spans: [PrivacySpan]) -> [PrivacyRedactionMapping] {
        var seen: Set<String> = []
        return spans.compactMap { span in
            guard !span.isIgnored, !span.placeholder.isEmpty, !seen.contains(span.placeholder) else { return nil }
            seen.insert(span.placeholder)
            return PrivacyRedactionMapping(
                placeholder: span.placeholder,
                originalText: span.text,
                type: span.type
            )
        }
    }

    public func restore(text: String, mappings: [PrivacyRedactionMapping]) -> String {
        mappings
            .sorted { $0.placeholder.count > $1.placeholder.count }
            .reduce(text) { result, mapping in
                result.replacingOccurrences(of: mapping.placeholder, with: mapping.originalText)
            }
    }

    private func runNativeEntityInference(text: String) -> [PrivacySpan] {
        var spans: [PrivacySpan] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            guard let tag else { return true }
            let matchedText = String(text[tokenRange])

            switch tag {
            case .personalName:
                spans.append(Self.makeSpan(text: text, range: tokenRange, type: .name, confidence: 0.9))
            case .placeName where matchedText.count >= 2:
                spans.append(Self.makeSpan(text: text, range: tokenRange, type: .address, confidence: 0.8))
            default:
                break
            }

            return true
        }

        return spans
    }

    private func runRegexInference(text: String) -> [PrivacySpan] {
        let rules: [PrivacyRegexRule] = [
            PrivacyRegexRule(type: .email, pattern: #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}"#, confidence: 0.95),
            PrivacyRegexRule(type: .phone, pattern: #"(?:1[3-9]\d{9})|(?:\d{3,4}-\d{7,8})"#, confidence: 0.9),
            PrivacyRegexRule(type: .idCard, pattern: #"[1-9]\d{5}(?:18|19|20)\d{2}(?:(?:0[1-9])|(?:1[0-2]))(?:(?:[0-2][1-9])|10|20|30|31)\d{3}[0-9Xx]"#, confidence: 0.98),
            PrivacyRegexRule(type: .bankCard, pattern: #"[1-9]\d{12,18}"#, confidence: 0.85),
            PrivacyRegexRule(type: .secret, pattern: #"sk-(?:proj-)?[A-Za-z0-9\-_]{32,}"#, confidence: 0.99),
            PrivacyRegexRule(type: .secret, pattern: #"(?i)\b(?:api[_-]?key|apikey|appkey|secret|private[_-]?key|client[_-]?secret|db[_-]?password|password|token)\b\s*[:=]\s*["']?([A-Za-z0-9._~+/\-=]{12,})["']?"#, captureGroup: 1, confidence: 0.9),
            PrivacyRegexRule(type: .secret, pattern: #"(?i)\bBearer\s+([A-Za-z0-9._~+/\-=]{20,})"#, captureGroup: 1, confidence: 0.92),
            PrivacyRegexRule(type: .secret, pattern: #"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}\b"#, confidence: 0.93)
        ]

        var spans: [PrivacySpan] = []
        let nsString = text as NSString
        let textRange = NSRange(location: 0, length: nsString.length)

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else { continue }

            regex.enumerateMatches(in: text, options: [], range: textRange) { match, _, _ in
                guard let match else { return }
                let targetRange = rule.captureGroup < match.numberOfRanges ? match.range(at: rule.captureGroup) : match.range
                guard targetRange.location != NSNotFound,
                      let swiftRange = Range(targetRange, in: text)
                else { return }

                spans.append(Self.makeSpan(text: text, range: swiftRange, type: rule.type, confidence: rule.confidence))
            }
        }

        return spans
    }

    private func runSemanticInference(text: String) async -> [PrivacySpan] {
        switch semanticRuntime {
        case .disabledForTests:
            return []
        case .bundledTool:
            return await runPrivacyFilterTool(text: text)
        case .tool:
            return await runPrivacyFilterTool(text: text)
        case let .nodeScript(nodePath, scriptPath, timeoutSeconds):
            return await runSemanticProcess(
                executableURL: URL(fileURLWithPath: nodePath),
                arguments: [scriptPath],
                text: text,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private func runPrivacyFilterTool(text: String) async -> [PrivacySpan] {
        do {
            let response: AnalyzeResponse = try await runToolJSON(
                arguments: ["analyze", "--model-id", selectedSemanticModel.rawValue, "--cache-dir", selectedSemanticModelDirectory.path],
                input: text.data(using: .utf8),
                timeoutSeconds: selectedSemanticModel == .openAIPrivacyFilterQ4 ? 120 : 30
            )
            guard response.ok else {
                isSemanticModelReady = false
                semanticModelErrorMessage = response.error
                return []
            }
            return response.spans.compactMap { Self.makeSpan(from: $0, in: text) }
        } catch {
            isSemanticModelReady = false
            semanticModelErrorMessage = error.localizedDescription
            return []
        }
    }

    private func runSemanticProcess(
        executableURL: URL,
        arguments: [String],
        text: String,
        timeoutSeconds: TimeInterval
    ) async -> [PrivacySpan] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                var didResume = false
                let lock = NSLock()

                func finish(_ spans: [PrivacySpan]) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: spans)
                }

                process.terminationHandler = { process in
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    guard process.terminationStatus == 0,
                          let dtos = try? JSONDecoder().decode([SemanticSpanDTO].self, from: outputData)
                    else {
                        finish([])
                        return
                    }

                    finish(dtos.compactMap { Self.makeSpan(from: $0, in: text) })
                }

                do {
                    try process.run()
                    if let data = text.data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(data)
                    }
                    try? inputPipe.fileHandleForWriting.close()

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                        if process.isRunning {
                            process.terminate()
                        }
                        finish([])
                    }
                } catch {
                    finish([])
                }
            }
        }
    }

    private func runToolJSON<T: Decodable>(
        arguments: [String],
        input: Data?,
        timeoutSeconds: TimeInterval
    ) async throws -> T {
        guard let executableURL = semanticRuntime.executableURL else {
            throw NSError(
                domain: "ai.clawdhome.privacy-filter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Privacy filter tool is unavailable."]
            )
        }

        let data = try await runProcess(executableURL: executableURL, arguments: arguments, input: input, timeoutSeconds: timeoutSeconds)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        input: Data?,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let stdoutBuffer = LockedDataBuffer()
                let stderrBuffer = LockedDataBuffer()

                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let resumeLock = NSLock()
                var didResume = false

                func finish(_ result: Result<Data, Error>) {
                    resumeLock.lock()
                    defer { resumeLock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(with: result)
                }

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutBuffer.append(handle.availableData)
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrBuffer.append(handle.availableData)
                }

                process.terminationHandler = { process in
                    let stdout = stdoutBuffer.appendAndSnapshot(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    let stderr = stderrBuffer.appendAndSnapshot(errorPipe.fileHandleForReading.readDataToEndOfFile())

                    if process.terminationStatus == 0 {
                        finish(.success(stdout))
                    } else {
                        let message = String(data: stderr, encoding: .utf8) ?? "Privacy filter tool failed."
                        finish(.failure(NSError(
                            domain: "ai.clawdhome.privacy-filter",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )))
                    }
                }

                do {
                    try process.run()
                    if let input {
                        inputPipe.fileHandleForWriting.write(input)
                    }
                    try? inputPipe.fileHandleForWriting.close()

                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private static func makeSpan(text: String, range: Range<String.Index>, type: PrivacyEntityType, confidence: Double) -> PrivacySpan {
        PrivacySpan(
            text: String(text[range]),
            type: type,
            startOffset: text.distance(from: text.startIndex, to: range.lowerBound),
            endOffset: text.distance(from: text.startIndex, to: range.upperBound),
            confidence: confidence
        )
    }

    private static func makeSpan(from dto: SemanticSpanDTO, in text: String) -> PrivacySpan? {
        guard let type = dto.privacyType else { return nil }

        if dto.start >= 0,
           dto.end >= dto.start,
           let startIndex = text.index(text.startIndex, offsetBy: dto.start, limitedBy: text.endIndex),
           let endIndex = text.index(text.startIndex, offsetBy: dto.end, limitedBy: text.endIndex) {
            let range = startIndex..<endIndex
            return makeSpan(text: text, range: range, type: type, confidence: dto.score)
        }

        if let word = dto.word, let range = text.range(of: word) {
            return makeSpan(text: text, range: range, type: type, confidence: dto.score)
        }

        return nil
    }

    private static func finalize(spans: [PrivacySpan], in text: String) -> [PrivacySpan] {
        var filteredSpans = spans.filter { span in
            guard span.startOffset >= 0, span.endOffset <= text.count, span.startOffset < span.endOffset else { return false }
            if (span.type == .name || span.type == .address) && span.text.count < 2 {
                return false
            }
            return true
        }

        filteredSpans.sort {
            if $0.startOffset == $1.startOffset {
                if $0.confidence == $1.confidence {
                    return $0.text.count > $1.text.count
                }
                return $0.confidence > $1.confidence
            }
            return $0.startOffset < $1.startOffset
        }

        var deconflictedSpans: [PrivacySpan] = []
        for span in filteredSpans {
            guard let last = deconflictedSpans.last else {
                deconflictedSpans.append(span)
                continue
            }

            if span.startOffset < last.endOffset {
                if shouldReplace(existing: last, with: span) {
                    deconflictedSpans.removeLast()
                    deconflictedSpans.append(span)
                }
            } else {
                deconflictedSpans.append(span)
            }
        }

        return assignPlaceholders(to: deconflictedSpans)
    }

    private static func shouldReplace(existing: PrivacySpan, with candidate: PrivacySpan) -> Bool {
        if candidate.confidence != existing.confidence {
            return candidate.confidence > existing.confidence
        }
        return candidate.text.count > existing.text.count
    }

    private static func assignPlaceholders(to spans: [PrivacySpan]) -> [PrivacySpan] {
        var typeCounters: [PrivacyEntityType: Int] = [:]
        var textToPlaceholder: [PlaceholderKey: String] = [:]

        return spans.map { span in
            var updated = span
            let key = PlaceholderKey(type: span.type, text: span.text)

            if let existingPlaceholder = textToPlaceholder[key] {
                updated.placeholder = existingPlaceholder
            } else {
                let currentCount = typeCounters[span.type, default: 0] + 1
                typeCounters[span.type] = currentCount
                let placeholder = "{{\(span.type.rawValue)_\(currentCount)}}"
                textToPlaceholder[key] = placeholder
                updated.placeholder = placeholder
                updated.isIgnored = false
            }

            return updated
        }
    }

    private func refreshSemanticModelReadyState() {
        isSemanticModelReady = semanticRuntime.isAvailable && Self.hasPreparedSemanticModel(
            selectedSemanticModel,
            in: selectedSemanticModelDirectory,
            fileManager: fileManager
        )
    }

    private func directory(for model: PrivacySemanticModel) -> URL {
        switch model {
        case .openAIPrivacyFilterQ4:
            return semanticModelRootDirectory().appendingPathComponent(Self.openAIPrivacyFilterQ4ModelID, isDirectory: true)
        }
    }

    private func semanticModelRootDirectory() -> URL {
        if semanticModelDirectory.lastPathComponent == "local-semantic" {
            return semanticModelDirectory.deletingLastPathComponent()
        }
        return semanticModelDirectory
    }

    private static func defaultSemanticModelDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("PrivacyFilterModels", isDirectory: true)
    }

    private static func hasPreparedSemanticModel(_ model: PrivacySemanticModel, in directory: URL, fileManager: FileManager) -> Bool {
        switch model {
        case .openAIPrivacyFilterQ4:
            return [
                ("config.json", Int64(1_500)),
                ("tokenizer.json", Int64(13_000_000)),
                ("tokenizer_config.json", Int64(100)),
                ("viterbi_calibration.json", Int64(100)),
                ("onnx/model_q4.onnx", Int64(80_000)),
                ("onnx/model_q4.onnx_data", Int64(450_000_000)),
            ].allSatisfy { relativePath, minimumBytes in
                let fileURL = directory.appendingPathComponent(relativePath)
                guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                      let size = attributes[.size] as? NSNumber
                else { return false }
                return size.int64Value >= minimumBytes
            }
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func appendAndSnapshot(_ tail: Data) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if !tail.isEmpty {
            data.append(tail)
        }
        return data
    }
}

private struct PrivacyRegexRule {
    let type: PrivacyEntityType
    let pattern: String
    var captureGroup = 0
    let confidence: Double
}

private struct PlaceholderKey: Hashable {
    let type: PrivacyEntityType
    let normalizedText: String

    init(type: PrivacyEntityType, text: String) {
        self.type = type
        self.normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct SemanticSpanDTO: Decodable {
    let entity: String
    let score: Double
    let word: String?
    let start: Int
    let end: Int

    var privacyType: PrivacyEntityType? {
        switch entity.lowercased() {
        case "label_1", "person", "per", "private_person": return .name
        case "label_2", "address", "loc", "location", "private_address": return .address
        case "label_3", "email", "private_email": return .email
        case "label_4", "phone", "tel", "private_phone": return .phone
        case "label_5", "org", "organization": return .organization
        case "label_6", "user", "username": return .username
        case "label_7", "bank_card", "account_number": return .bankCard
        case "label_8", "secret", "token", "api_key", "private_url", "private_date": return .secret
        default: return nil
        }
    }
}

private struct PrepareModelResponse: Decodable {
    let ok: Bool
    let command: String
    let modelDirectory: String?
    let error: String?
}

private struct AnalyzeResponse: Decodable {
    let ok: Bool
    let command: String
    let spans: [SemanticSpanDTO]
    let error: String?
}
