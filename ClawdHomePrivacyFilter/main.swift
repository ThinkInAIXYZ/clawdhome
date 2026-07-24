import CryptoKit
import Darwin
import Foundation
import HuggingFace
import Tokenizers
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

private enum BuildInfo {
    static let version = kPrivacyFilterVersion
    static let buildTime = kPrivacyFilterBuildTime
}

private let defaultModelID = "clawdhome-privacy-ner-v1"
private let openAIPrivacyFilterQ4ModelID = "openai-privacy-filter-q4"

private final class ChildProcessRegistry: @unchecked Sendable {
    static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var activeProcess: Process?

    func setActive(_ process: Process) {
        lock.lock()
        activeProcess = process
        lock.unlock()
    }

    func clearActive(_ process: Process) {
        lock.lock()
        if activeProcess === process {
            activeProcess = nil
        }
        lock.unlock()
    }

    func terminateActive() {
        lock.lock()
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

private final class ToolSignalHandlers: @unchecked Sendable {
    static let shared = ToolSignalHandlers()

    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard sources.isEmpty else { return }
        install(signalNumber: SIGINT, exitCode: 130)
        install(signalNumber: SIGTERM, exitCode: 143)
    }

    private func install(signalNumber: Int32, exitCode: Int32) {
        Darwin.signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
        source.setEventHandler {
            ChildProcessRegistry.shared.terminateActive()
            usleep(200_000)
            exit(exitCode)
        }
        source.resume()
        sources.append(source)
    }
}

private enum PrivacyToolError: LocalizedError {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case invalidCacheDirectory(String)
    case unsupportedModel(String)
    case modelNotInstalled(String)
    case modelChecksumMismatch
    case invalidModel(String)
    case missingMapFile
    case missingONNXModelFile(String)
    case downloadFailed(String)
    case onnxRuntimeUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "missing command"
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .invalidCacheDirectory(let path):
            return "invalid cache directory: \(path)"
        case .unsupportedModel(let modelID):
            return "unsupported model: \(modelID)"
        case .modelNotInstalled(let modelID):
            return "model is not installed: \(modelID)"
        case .modelChecksumMismatch:
            return "model checksum mismatch"
        case .invalidModel(let reason):
            return "invalid model: \(reason)"
        case .missingMapFile:
            return "missing value for --map-file"
        case .missingONNXModelFile(let path):
            return "missing ONNX model file: \(path)"
        case .downloadFailed(let message):
            return "download failed: \(message)"
        case .onnxRuntimeUnavailable:
            return "ONNX Runtime support is not enabled in this build"
        }
    }
}

private struct ProbeResponse: Codable {
    let ok: Bool
    let command: String
    let message: String
    let version: String
    let buildTime: String
    let supportedModelIDs: [String]
}

private struct PrepareModelResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let modelDirectory: String
    let source: String
    let error: String?
}

private struct AnalyzeResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let spans: [SemanticSpanDTO]
    let error: String?
}

private struct RedactResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let redactedText: String
    let mappings: [RedactionMappingEntry]
    let mapFile: String?
    let error: String?
}

private struct RestoreResponse: Codable {
    let ok: Bool
    let command: String
    let restoredText: String
    let restoredCount: Int
    let error: String?
}

private struct StatusResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let installed: Bool
    let modelDirectory: String
    let version: String?
    let error: String?
}

private struct PrepareONNXModelResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let modelDirectory: String
    let dryRun: Bool
    let requiredFiles: [ONNXModelFileDTO]
    let totalBytes: Int64
    let error: String?
}

private struct ONNXDownloadProgressSnapshot: Codable {
    let modelID: String
    let status: String
    let currentFile: String?
    let downloadedBytes: Int64
    let totalBytes: Int64
    let fileDownloadedBytes: Int64
    let fileTotalBytes: Int64
    let bytesPerSecond: Double
    let error: String?
}

private struct InspectONNXModelResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let modelPath: String
    let ortVersion: String
    let inputNames: [String]
    let outputNames: [String]
    let error: String?
}

private struct ONNXModelFileDTO: Codable {
    let path: String
    let url: String
    let bytes: Int64
    let installed: Bool
}

private struct ErrorResponse: Codable {
    let ok: Bool
    let command: String
    let error: String
}

private struct SemanticSpanDTO: Codable {
    let entity: String
    let score: Double
    let word: String
    let start: Int
    let end: Int
}

private struct RedactionMappingEntry: Codable {
    let placeholder: String
    let entity: String
    let value: String
}

private struct RedactionMapDocument: Codable {
    let schemaVersion: Int
    let tool: String
    let createdAt: String
    let redactedText: String
    let mappings: [RedactionMappingEntry]
}

private struct CLIOptions {
    var modelID = defaultModelID
    var cacheDirectory: URL?
    var modelURL: URL?
    var mapFileURL: URL?
    var progressFileURL: URL?
    var force = false
    var dryRun = false
}

private struct ONNXModelSpec {
    let modelID: String
    let onnxRelativePath: String
    let files: [ONNXModelFile]
}

private struct OpenAIPrivacyFilterConfig: Codable {
    let id2label: [String: String]
}

private struct TokenRange {
    let tokenIndex: Int
    let tokenID: Int
    let start: Int
    let end: Int
}

private struct ONNXModelFile {
    let relativePath: String
    let url: URL
    let bytes: Int64

    var minimumInstalledBytes: Int64 {
        max(1, bytes / 2)
    }
}

private struct PrivacyNERModel: Codable {
    let schemaVersion: Int
    let modelID: String
    let version: String
    let engine: String
    let rules: [PrivacyModelRule]
    let dictionaries: [PrivacyDictionary]
}

private struct PrivacyModelRule: Codable {
    let id: String
    let entity: String
    let score: Double
    let pattern: String
    let captureGroup: Int?
}

private struct PrivacyDictionary: Codable {
    let id: String
    let entity: String
    let score: Double
    let terms: [String]
}

private struct ModelManifest: Codable {
    let tool: String
    let schemaVersion: Int
    let modelID: String
    let modelVersion: String
    let engine: String
    let source: String
    let sha256: String
    let installedAt: String
}

struct ClawdHomePrivacyFilterMain {
    static func main() async {
        ToolSignalHandlers.shared.install()

        if shouldPrintHelp(CommandLine.arguments) {
            printHelp()
            return
        }

        do {
            let response = try await run(arguments: CommandLine.arguments)
            try writeJSON(response)
        } catch {
            let fallback = ErrorResponse(
                ok: false,
                command: commandName(from: CommandLine.arguments),
                error: error.localizedDescription
            )
            try? writeJSON(fallback)
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws -> any Encodable {
        guard arguments.count >= 2 else { throw PrivacyToolError.missingCommand }

        switch arguments[1] {
        case "probe":
            return ProbeResponse(
                ok: true,
                command: "probe",
                message: "ClawdHomePrivacyFilter ready",
                version: BuildInfo.version,
                buildTime: BuildInfo.buildTime,
                supportedModelIDs: [defaultModelID, openAIPrivacyFilterQ4ModelID]
            )
        case "status":
            return try status(arguments: Array(arguments.dropFirst(2)))
        case "prepare-model":
            return try prepareModel(arguments: Array(arguments.dropFirst(2)))
        case "prepare-onnx-model":
            return try await prepareONNXModel(arguments: Array(arguments.dropFirst(2)))
        case "inspect-onnx-model":
            return try inspectONNXModel(arguments: Array(arguments.dropFirst(2)))
        case "analyze":
            return try await analyze(arguments: Array(arguments.dropFirst(2)))
        case "redact":
            return try await redact(arguments: Array(arguments.dropFirst(2)))
        case "restore":
            return try restore(arguments: Array(arguments.dropFirst(2)))
        default:
            throw PrivacyToolError.unknownCommand(arguments[1])
        }
    }

    private static func status(arguments: [String]) throws -> StatusResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        if options.modelID == openAIPrivacyFilterQ4ModelID {
            let spec = try onnxModelSpec(for: options.modelID)
            let installed = spec.files.allSatisfy { file in
                isONNXModelFileInstalled(file, in: directory)
            }
            return StatusResponse(
                ok: true,
                command: "status",
                modelID: options.modelID,
                installed: installed,
                modelDirectory: directory.path,
                version: installed ? "main" : nil,
                error: nil
            )
        }

        let manifest = try? loadManifest(modelID: options.modelID, cacheDirectory: directory)
        return StatusResponse(
            ok: true,
            command: "status",
            modelID: options.modelID,
            installed: manifest != nil,
            modelDirectory: directory.path,
            version: manifest?.modelVersion,
            error: nil
        )
    }

    private static func prepareModel(arguments: [String]) throws -> PrepareModelResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        try ensureDirectory(directory)

        let modelData: Data
        let source: String
        if let modelURL = options.modelURL {
            modelData = try Data(contentsOf: modelURL)
            source = modelURL.absoluteString
        } else {
            modelData = try bundledModelData(modelID: options.modelID)
            source = "embedded"
        }

        let model = try decodeAndValidateModel(modelData, expectedModelID: options.modelID)
        let modelURL = directory.appendingPathComponent("model.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")

        if FileManager.default.fileExists(atPath: manifestURL.path), !options.force {
            _ = try loadModel(modelID: options.modelID, cacheDirectory: directory)
            return PrepareModelResponse(
                ok: true,
                command: "prepare-model",
                modelID: options.modelID,
                modelDirectory: directory.path,
                source: "existing",
                error: nil
            )
        }

        try modelData.write(to: modelURL, options: [.atomic])
        let manifest = ModelManifest(
            tool: "ClawdHomePrivacyFilter",
            schemaVersion: 1,
            modelID: model.modelID,
            modelVersion: model.version,
            engine: model.engine,
            source: source,
            sha256: sha256Hex(modelData),
            installedAt: ISO8601DateFormatter().string(from: Date())
        )
        try JSONEncoder.sorted.encode(manifest).write(to: manifestURL, options: [.atomic])

        return PrepareModelResponse(
            ok: true,
            command: "prepare-model",
            modelID: options.modelID,
            modelDirectory: directory.path,
            source: source,
            error: nil
        )
    }

    private static func prepareONNXModel(arguments: [String]) async throws -> PrepareONNXModelResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        try ensureDirectory(directory)
        let spec = try onnxModelSpec(for: options.modelID)

        if let progressFileURL = options.progressFileURL {
            try writeONNXProgress(
                spec: spec,
                directory: directory,
                progressFileURL: progressFileURL,
                status: "preparing",
                currentFile: nil,
                bytesPerSecond: 0,
                error: nil
            )
        }

        do {
            if !options.dryRun {
                let hasMissingFile = spec.files.contains { file in
                    !isONNXModelFileInstalled(file, in: directory)
                }
                if hasMissingFile || options.force {
                    try await downloadONNXModelFiles(
                        spec: spec,
                        to: directory,
                        force: options.force,
                        progressFileURL: options.progressFileURL
                    )
                }
            }
        } catch {
            if let progressFileURL = options.progressFileURL {
                try? writeONNXProgress(
                    spec: spec,
                    directory: directory,
                    progressFileURL: progressFileURL,
                    status: "failed",
                    currentFile: nil,
                    bytesPerSecond: 0,
                    error: error.localizedDescription
                )
            }
            throw error
        }

        if let progressFileURL = options.progressFileURL {
            try writeONNXProgress(
                spec: spec,
                directory: directory,
                progressFileURL: progressFileURL,
                status: "done",
                currentFile: nil,
                bytesPerSecond: 0,
                error: nil
            )
        }

        return PrepareONNXModelResponse(
            ok: true,
            command: "prepare-onnx-model",
            modelID: spec.modelID,
            modelDirectory: directory.path,
            dryRun: options.dryRun,
            requiredFiles: spec.files.map { file in
                ONNXModelFileDTO(
                    path: file.relativePath,
                    url: file.url.absoluteString,
                    bytes: file.bytes,
                    installed: isONNXModelFileInstalled(file, in: directory)
                )
            },
            totalBytes: spec.files.reduce(Int64(0)) { $0 + $1.bytes },
            error: nil
        )
    }

    private static func downloadONNXModelFiles(spec: ONNXModelSpec, to directory: URL, force: Bool, progressFileURL: URL?) async throws {
        guard Repo.ID(rawValue: "openai/privacy-filter") != nil else {
            throw PrivacyToolError.downloadFailed("invalid Hugging Face repository ID")
        }

        do {
            for file in spec.files {
                let destinationURL = directory.appendingPathComponent(file.relativePath)
                if isONNXModelFileInstalled(file, in: directory), !force {
                    continue
                }
                try ensureDirectory(destinationURL.deletingLastPathComponent())
                if force, FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try downloadFileWithResumableCurl(
                    from: file.url,
                    to: destinationURL,
                    file: file,
                    spec: spec,
                    directory: directory,
                    progressFileURL: progressFileURL
                )
                guard isONNXModelFileInstalled(file, in: directory) else {
                    throw PrivacyToolError.downloadFailed("downloaded file is incomplete: \(file.relativePath)")
                }
            }
        } catch {
            throw PrivacyToolError.downloadFailed(error.localizedDescription)
        }
    }

    private static func downloadFileWithResumableCurl(
        from sourceURL: URL,
        to destinationURL: URL,
        file: ONNXModelFile,
        spec: ONNXModelSpec,
        directory: URL,
        progressFileURL: URL?
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--fail",
            "--location",
            "--connect-timeout", "30",
            "--retry", "5",
            "--retry-delay", "2",
            "--retry-all-errors",
            "--continue-at", "-",
            "--silent",
            "--show-error",
            "--output", destinationURL.path,
            sourceURL.absoluteString,
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        ChildProcessRegistry.shared.setActive(process)
        defer {
            ChildProcessRegistry.shared.clearActive(process)
        }

        var lastBytes = installedBytes(for: spec, in: directory)
        var lastDate = Date()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.5)
            let now = Date()
            let currentBytes = installedBytes(for: spec, in: directory)
            let elapsed = max(now.timeIntervalSince(lastDate), 0.001)
            let bytesPerSecond = Double(max(0, currentBytes - lastBytes)) / elapsed
            try writeONNXProgress(
                spec: spec,
                directory: directory,
                progressFileURL: progressFileURL,
                status: "downloading",
                currentFile: file.relativePath,
                bytesPerSecond: bytesPerSecond,
                error: nil
            )
            lastBytes = currentBytes
            lastDate = now
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrivacyToolError.downloadFailed(message?.isEmpty == false ? message! : "curl exited with \(process.terminationStatus)")
        }
        try writeONNXProgress(
            spec: spec,
            directory: directory,
            progressFileURL: progressFileURL,
            status: "downloading",
            currentFile: file.relativePath,
            bytesPerSecond: 0,
            error: nil
        )
    }

    private static func writeONNXProgress(
        spec: ONNXModelSpec,
        directory: URL,
        progressFileURL: URL?,
        status: String,
        currentFile: String?,
        bytesPerSecond: Double,
        error: String?
    ) throws {
        guard let progressFileURL else { return }
        try ensureDirectory(progressFileURL.deletingLastPathComponent())

        let currentSpecFile = currentFile.flatMap { relativePath in
            spec.files.first { $0.relativePath == relativePath }
        }
        let fileDownloadedBytes = currentSpecFile.map { installedBytes(for: $0, in: directory) } ?? 0
        let fileTotalBytes = currentSpecFile?.bytes ?? 0
        let snapshot = ONNXDownloadProgressSnapshot(
            modelID: spec.modelID,
            status: status,
            currentFile: currentFile,
            downloadedBytes: installedBytes(for: spec, in: directory),
            totalBytes: spec.files.reduce(Int64(0)) { $0 + $1.bytes },
            fileDownloadedBytes: fileDownloadedBytes,
            fileTotalBytes: fileTotalBytes,
            bytesPerSecond: bytesPerSecond,
            error: error
        )
        try JSONEncoder.sorted.encode(snapshot).write(to: progressFileURL, options: [.atomic])
    }

    private static func installedBytes(for spec: ONNXModelSpec, in directory: URL) -> Int64 {
        spec.files.reduce(Int64(0)) { total, file in
            total + installedBytes(for: file, in: directory)
        }
    }

    private static func installedBytes(for file: ONNXModelFile, in directory: URL) -> Int64 {
        let fileURL = directory.appendingPathComponent(file.relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return min(size.int64Value, file.bytes)
    }

    private static func isONNXModelFileInstalled(_ file: ONNXModelFile, in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(file.relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.int64Value >= file.minimumInstalledBytes
    }

    private static func inspectONNXModel(arguments: [String]) throws -> InspectONNXModelResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        let spec = try onnxModelSpec(for: options.modelID)
        let modelURL = directory.appendingPathComponent(spec.onnxRelativePath)
        guard let onnxModel = spec.files.first(where: { $0.relativePath == spec.onnxRelativePath }),
              isONNXModelFileInstalled(onnxModel, in: directory)
        else {
            throw PrivacyToolError.missingONNXModelFile(modelURL.path)
        }
        for file in spec.files where file.relativePath.hasPrefix("onnx/") {
            let fileURL = directory.appendingPathComponent(file.relativePath)
            guard isONNXModelFileInstalled(file, in: directory) else {
                throw PrivacyToolError.missingONNXModelFile(fileURL.path)
            }
        }

        #if canImport(OnnxRuntimeBindings)
            let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let sessionOptions = try ORTSessionOptions()
            try sessionOptions.setLogSeverityLevel(ORTLoggingLevel.warning)
            try sessionOptions.setIntraOpNumThreads(1)
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: sessionOptions)

            return InspectONNXModelResponse(
                ok: true,
                command: "inspect-onnx-model",
                modelID: spec.modelID,
                modelPath: modelURL.path,
                ortVersion: ORTVersion() ?? "unknown",
                inputNames: try session.inputNames(),
                outputNames: try session.outputNames(),
                error: nil
            )
        #else
            throw PrivacyToolError.onnxRuntimeUnavailable
        #endif
    }

    private static func analyzeWithOpenAIPrivacyFilterQ4(text: String, cacheDirectory: URL) async throws -> [SemanticSpanDTO] {
        guard !text.isEmpty else { return [] }
        let spec = try onnxModelSpec(for: openAIPrivacyFilterQ4ModelID)
        try validateONNXModelFiles(spec: spec, in: cacheDirectory)

        #if canImport(OnnxRuntimeBindings)
            let tokenizer = try await AutoTokenizer.from(modelFolder: cacheDirectory)
            let tokenIDs = tokenizer.encode(text: text, addSpecialTokens: false)
            guard !tokenIDs.isEmpty else { return [] }
            let tokenRanges = tokenRanges(for: tokenIDs, tokenizer: tokenizer, text: text)
            guard !tokenRanges.isEmpty else { return [] }

            let configURL = cacheDirectory.appendingPathComponent("config.json")
            let config = try JSONDecoder().decode(OpenAIPrivacyFilterConfig.self, from: Data(contentsOf: configURL))
            let labelsByID = Dictionary(uniqueKeysWithValues: config.id2label.compactMap { key, value in
                Int(key).map { ($0, value) }
            })

            let modelURL = cacheDirectory.appendingPathComponent(spec.onnxRelativePath)
            let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let sessionOptions = try ORTSessionOptions()
            try sessionOptions.setLogSeverityLevel(ORTLoggingLevel.warning)
            try sessionOptions.setIntraOpNumThreads(1)
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: sessionOptions)
            let outputNames = try session.outputNames()
            guard let outputName = outputNames.first else {
                throw PrivacyToolError.invalidModel("ONNX model has no outputs")
            }

            let inputIDValues = tokenIDs.map(Int64.init)
            let attentionMaskValues = Array(repeating: Int64(1), count: tokenIDs.count)
            let shape = [NSNumber(value: 1), NSNumber(value: tokenIDs.count)]
            let inputIDs = try makeInt64Tensor(inputIDValues, shape: shape)
            let attentionMask = try makeInt64Tensor(attentionMaskValues, shape: shape)
            let outputs = try session.run(
                withInputs: [
                    "input_ids": inputIDs,
                    "attention_mask": attentionMask,
                ],
                outputNames: Set([outputName]),
                runOptions: nil
            )
            guard let logitsValue = outputs[outputName] else {
                throw PrivacyToolError.invalidModel("ONNX model did not return \(outputName)")
            }
            let tensorInfo = try logitsValue.tensorTypeAndShapeInfo()
            guard tensorInfo.elementType == ORTTensorElementDataType.float else {
                throw PrivacyToolError.invalidModel("expected float logits")
            }
            let shapeValues = tensorInfo.shape.map(\.intValue)
            guard shapeValues.count >= 3 else {
                throw PrivacyToolError.invalidModel("unexpected logits shape: \(shapeValues)")
            }
            let classCount = shapeValues[shapeValues.count - 1]
            let sequenceLength = min(tokenRanges.count, shapeValues[shapeValues.count - 2])
            let logitsData = try logitsValue.tensorData() as Data
            let labelIDs = logitsData.withUnsafeBytes { rawBuffer in
                let logits = rawBuffer.bindMemory(to: Float.self)
                return (0..<sequenceLength).map { tokenIndex in
                    let rowOffset = tokenIndex * classCount
                    var bestID = 0
                    var bestScore = -Float.greatestFiniteMagnitude
                    var expSum = 0.0
                    for classID in 0..<classCount {
                        let score = logits[rowOffset + classID]
                        if score > bestScore {
                            bestScore = score
                            bestID = classID
                        }
                    }
                    for classID in 0..<classCount {
                        expSum += exp(Double(logits[rowOffset + classID] - bestScore))
                    }
                    return (bestID, expSum > 0 ? 1.0 / expSum : 0.0)
                }
            }

            return decodeBIOES(labelIDs: labelIDs, tokenRanges: tokenRanges, labelsByID: labelsByID, text: text)
        #else
            throw PrivacyToolError.onnxRuntimeUnavailable
        #endif
    }

    private static func validateONNXModelFiles(spec: ONNXModelSpec, in directory: URL) throws {
        for file in spec.files {
            let fileURL = directory.appendingPathComponent(file.relativePath)
            guard isONNXModelFileInstalled(file, in: directory) else {
                throw PrivacyToolError.missingONNXModelFile(fileURL.path)
            }
        }
    }

    #if canImport(OnnxRuntimeBindings)
        private static func makeInt64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
            let data = values.withUnsafeBufferPointer { buffer in
                NSMutableData(bytes: buffer.baseAddress, length: values.count * MemoryLayout<Int64>.stride)
            }
            return try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.int64, shape: shape)
        }
    #endif

    private static func tokenRanges(for tokenIDs: [Int], tokenizer: any Tokenizer, text: String) -> [TokenRange] {
        var ranges: [TokenRange] = []
        var searchStart = text.startIndex

        for (index, tokenID) in tokenIDs.enumerated() {
            let decoded = tokenizer.decode(tokens: [tokenID], skipSpecialTokens: true)
            guard !decoded.isEmpty else { continue }

            let candidates = [decoded, decoded.trimmingCharacters(in: .whitespacesAndNewlines)]
                .filter { !$0.isEmpty }
            guard let match = candidates.compactMap({ candidate in
                text.range(of: candidate, range: searchStart..<text.endIndex)
            }).first else {
                continue
            }

            let start = text.distance(from: text.startIndex, to: match.lowerBound)
            let end = text.distance(from: text.startIndex, to: match.upperBound)
            ranges.append(TokenRange(tokenIndex: index, tokenID: tokenID, start: start, end: end))
            searchStart = match.upperBound
        }

        return ranges
    }

    private static func decodeBIOES(
        labelIDs: [(id: Int, score: Double)],
        tokenRanges: [TokenRange],
        labelsByID: [Int: String],
        text: String
    ) -> [SemanticSpanDTO] {
        var spans: [SemanticSpanDTO] = []
        var activeType: String?
        var activeStart: Int?
        var activeEnd: Int?
        var activeScore = 0.0
        var activeCount = 0

        func finishActive() {
            guard let type = activeType, let start = activeStart, let end = activeEnd, start < end else {
                activeType = nil
                activeStart = nil
                activeEnd = nil
                activeScore = 0
                activeCount = 0
                return
            }
            let trimmed = trimmedSpan(in: text, start: start, end: end)
            guard trimmed.start < trimmed.end else {
                activeType = nil
                activeStart = nil
                activeEnd = nil
                activeScore = 0
                activeCount = 0
                return
            }
            let word = substring(text, start: trimmed.start, end: trimmed.end)
            spans.append(SemanticSpanDTO(
                entity: type,
                score: activeCount > 0 ? activeScore / Double(activeCount) : 0.0,
                word: word,
                start: trimmed.start,
                end: trimmed.end
            ))
            activeType = nil
            activeStart = nil
            activeEnd = nil
            activeScore = 0
            activeCount = 0
        }

        for (index, prediction) in labelIDs.enumerated() {
            guard index < tokenRanges.count else { break }
            let range = tokenRanges[index]
            let rawLabel = labelsByID[prediction.id] ?? "O"
            if rawLabel == "O" {
                finishActive()
                continue
            }

            let parts = rawLabel.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                finishActive()
                continue
            }
            let prefix = parts[0]
            let entity = parts[1]

            switch prefix {
            case "S":
                finishActive()
                let trimmed = trimmedSpan(in: text, start: range.start, end: range.end)
                let word = substring(text, start: trimmed.start, end: trimmed.end)
                if !word.isEmpty {
                    spans.append(SemanticSpanDTO(entity: entity, score: prediction.score, word: word, start: trimmed.start, end: trimmed.end))
                }
            case "B":
                finishActive()
                activeType = entity
                activeStart = range.start
                activeEnd = range.end
                activeScore = prediction.score
                activeCount = 1
            case "I":
                if activeType == entity {
                    activeEnd = range.end
                    activeScore += prediction.score
                    activeCount += 1
                } else {
                    finishActive()
                    activeType = entity
                    activeStart = range.start
                    activeEnd = range.end
                    activeScore = prediction.score
                    activeCount = 1
                }
            case "E":
                if activeType == entity {
                    activeEnd = range.end
                    activeScore += prediction.score
                    activeCount += 1
                    finishActive()
                } else {
                    finishActive()
                    let trimmed = trimmedSpan(in: text, start: range.start, end: range.end)
                    let word = substring(text, start: trimmed.start, end: trimmed.end)
                    if !word.isEmpty {
                        spans.append(SemanticSpanDTO(entity: entity, score: prediction.score, word: word, start: trimmed.start, end: trimmed.end))
                    }
                }
            default:
                finishActive()
            }
        }
        finishActive()
        return spans
    }

    private static func substring(_ text: String, start: Int, end: Int) -> String {
        guard let startIndex = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex),
              let endIndex = text.index(text.startIndex, offsetBy: end, limitedBy: text.endIndex),
              startIndex <= endIndex
        else { return "" }
        return String(text[startIndex..<endIndex])
    }

    private static func trimmedSpan(in text: String, start: Int, end: Int) -> (start: Int, end: Int) {
        guard var startIndex = text.index(text.startIndex, offsetBy: start, limitedBy: text.endIndex),
              var endIndex = text.index(text.startIndex, offsetBy: end, limitedBy: text.endIndex),
              startIndex <= endIndex
        else { return (start, end) }
        while startIndex < endIndex, text[startIndex].isWhitespace {
            startIndex = text.index(after: startIndex)
        }
        while endIndex > startIndex {
            let previous = text.index(before: endIndex)
            if !text[previous].isWhitespace { break }
            endIndex = previous
        }
        return (
            text.distance(from: text.startIndex, to: startIndex),
            text.distance(from: text.startIndex, to: endIndex)
        )
    }

    private static func analyze(arguments: [String]) async throws -> AnalyzeResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        if options.modelID == openAIPrivacyFilterQ4ModelID {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return AnalyzeResponse(
                ok: true,
                command: "analyze",
                modelID: options.modelID,
                spans: try await analyzeWithOpenAIPrivacyFilterQ4(text: text, cacheDirectory: directory),
                error: nil
            )
        }

        let model = try loadModel(modelID: options.modelID, cacheDirectory: directory)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        return AnalyzeResponse(
            ok: true,
            command: "analyze",
            modelID: options.modelID,
            spans: analyze(text: text, with: model),
            error: nil
        )
    }

    private static func redact(arguments: [String]) async throws -> RedactResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: true)
        let directory = try resolvedCacheDirectory(options)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let spans: [SemanticSpanDTO]
        if options.modelID == openAIPrivacyFilterQ4ModelID {
            spans = try await analyzeWithOpenAIPrivacyFilterQ4(text: text, cacheDirectory: directory)
        } else {
            let model = try loadModel(modelID: options.modelID, cacheDirectory: directory)
            spans = analyze(text: text, with: model)
        }
        let redactedText = redact(text: text, spans: spans)
        let mappings = redactionMappings(from: spans)

        if let mapFileURL = options.mapFileURL {
            let document = RedactionMapDocument(
                schemaVersion: 1,
                tool: "ClawdHomePrivacyFilter",
                createdAt: ISO8601DateFormatter().string(from: Date()),
                redactedText: redactedText,
                mappings: mappings
            )
            try JSONEncoder.sorted.encode(document).write(to: mapFileURL, options: [.atomic])
        }

        return RedactResponse(
            ok: true,
            command: "redact",
            modelID: options.modelID,
            redactedText: redactedText,
            mappings: mappings,
            mapFile: options.mapFileURL?.path,
            error: nil
        )
    }

    private static func restore(arguments: [String]) throws -> RestoreResponse {
        let options = try parseOptions(arguments, requireCacheDirectory: false)
        guard let mapFileURL = options.mapFileURL else {
            throw PrivacyToolError.missingMapFile
        }

        let document = try JSONDecoder().decode(RedactionMapDocument.self, from: Data(contentsOf: mapFileURL))
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let restoredText = restore(text: text, mappings: document.mappings)
        let restoredCount = document.mappings.filter { text.contains($0.placeholder) }.count

        return RestoreResponse(
            ok: true,
            command: "restore",
            restoredText: restoredText,
            restoredCount: restoredCount,
            error: nil
        )
    }

    private static func parseOptions(_ args: [String], requireCacheDirectory: Bool) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--model-id":
                let value = try value(after: arg, at: index, in: args)
                options.modelID = value
                index += 2
            case "--cache-dir":
                let value = try value(after: arg, at: index, in: args)
                options.cacheDirectory = URL(fileURLWithPath: value, isDirectory: true)
                index += 2
            case "--model-url":
                let value = try value(after: arg, at: index, in: args)
                guard let url = URL(string: value) else {
                    throw PrivacyToolError.invalidModel("invalid --model-url")
                }
                options.modelURL = url
                index += 2
            case "--map-file":
                let value = try value(after: arg, at: index, in: args)
                options.mapFileURL = URL(fileURLWithPath: value)
                index += 2
            case "--progress-file":
                let value = try value(after: arg, at: index, in: args)
                options.progressFileURL = URL(fileURLWithPath: value)
                index += 2
            case "--dry-run":
                options.dryRun = true
                index += 1
            case "--force":
                options.force = true
                index += 1
            default:
                index += 1
            }
        }

        if requireCacheDirectory, options.cacheDirectory == nil {
            throw PrivacyToolError.missingValue("--cache-dir")
        }
        guard !options.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrivacyToolError.missingValue("--model-id")
        }
        return options
    }

    private static func value(after flag: String, at index: Int, in args: [String]) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < args.count else { throw PrivacyToolError.missingValue(flag) }
        return args[valueIndex]
    }

    private static func resolvedCacheDirectory(_ options: CLIOptions) throws -> URL {
        guard let directory = options.cacheDirectory else {
            throw PrivacyToolError.missingValue("--cache-dir")
        }
        return directory
    }

    private static func ensureDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PrivacyToolError.invalidCacheDirectory(directory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func loadManifest(modelID: String, cacheDirectory: URL) throws -> ModelManifest {
        let manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PrivacyToolError.modelNotInstalled(modelID)
        }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.modelID == modelID else {
            throw PrivacyToolError.invalidModel("manifest model id mismatch")
        }
        return manifest
    }

    private static func loadModel(modelID: String, cacheDirectory: URL) throws -> PrivacyNERModel {
        let manifest = try loadManifest(modelID: modelID, cacheDirectory: cacheDirectory)
        let modelURL = cacheDirectory.appendingPathComponent("model.json")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw PrivacyToolError.modelNotInstalled(modelID)
        }
        let data = try Data(contentsOf: modelURL)
        guard sha256Hex(data) == manifest.sha256 else {
            throw PrivacyToolError.modelChecksumMismatch
        }
        return try decodeAndValidateModel(data, expectedModelID: modelID)
    }

    private static func decodeAndValidateModel(_ data: Data, expectedModelID: String) throws -> PrivacyNERModel {
        let model = try JSONDecoder().decode(PrivacyNERModel.self, from: data)
        guard model.schemaVersion == 1 else {
            throw PrivacyToolError.invalidModel("unsupported schema \(model.schemaVersion)")
        }
        guard model.modelID == expectedModelID else {
            throw PrivacyToolError.invalidModel("model id mismatch")
        }
        guard model.engine == "lexical-context-ner" else {
            throw PrivacyToolError.invalidModel("unsupported engine \(model.engine)")
        }
        guard !model.rules.isEmpty || !model.dictionaries.isEmpty else {
            throw PrivacyToolError.invalidModel("empty model")
        }
        return model
    }

    private static func analyze(text: String, with model: PrivacyNERModel) -> [SemanticSpanDTO] {
        guard !text.isEmpty else { return [] }
        var spans: [SemanticSpanDTO] = []

        for rule in model.rules {
            spans.append(contentsOf: regexSpans(in: text, rule: rule))
        }
        for dictionary in model.dictionaries {
            spans.append(contentsOf: dictionarySpans(in: text, dictionary: dictionary))
        }

        return deconflict(spans)
    }

    private static func regexSpans(in text: String, rule: PrivacyModelRule) -> [SemanticSpanDTO] {
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        var spans: [SemanticSpanDTO] = []

        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match else { return }
            let captureGroup = rule.captureGroup ?? 0
            let targetRange = captureGroup < match.numberOfRanges && match.range(at: captureGroup).location != NSNotFound
                ? match.range(at: captureGroup)
                : match.range
            guard let range = Range(targetRange, in: text) else { return }
            spans.append(makeSpan(text: text, range: range, entity: rule.entity, score: rule.score))
        }

        return spans
    }

    private static func dictionarySpans(in text: String, dictionary: PrivacyDictionary) -> [SemanticSpanDTO] {
        dictionary.terms.flatMap { term in
            guard !term.isEmpty else { return [SemanticSpanDTO]() }
            var spans: [SemanticSpanDTO] = []
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
                spans.append(makeSpan(text: text, range: range, entity: dictionary.entity, score: dictionary.score))
                searchStart = range.upperBound
            }
            return spans
        }
    }

    private static func makeSpan(text: String, range: Range<String.Index>, entity: String, score: Double) -> SemanticSpanDTO {
        SemanticSpanDTO(
            entity: entity,
            score: score,
            word: String(text[range]),
            start: text.distance(from: text.startIndex, to: range.lowerBound),
            end: text.distance(from: text.startIndex, to: range.upperBound)
        )
    }

    private static func deconflict(_ spans: [SemanticSpanDTO]) -> [SemanticSpanDTO] {
        spans.sorted {
            if $0.start == $1.start {
                return ($0.end - $0.start) > ($1.end - $1.start)
            }
            return $0.start < $1.start
        }.reduce(into: [SemanticSpanDTO]()) { result, span in
            guard let last = result.last else {
                result.append(span)
                return
            }
            if span.start < last.end {
                if span.score > last.score || (span.score == last.score && (span.end - span.start) > (last.end - last.start)) {
                    result.removeLast()
                    result.append(span)
                }
            } else {
                result.append(span)
            }
        }
    }

    private static func redact(text: String, spans: [SemanticSpanDTO]) -> String {
        guard !spans.isEmpty else { return text }
        let spansWithPlaceholders = assignPlaceholders(to: spans)
        return spansWithPlaceholders
            .sorted { $0.span.start > $1.span.start }
            .reduce(text) { result, item in
                guard let startIndex = result.index(result.startIndex, offsetBy: item.span.start, limitedBy: result.endIndex),
                      let endIndex = result.index(result.startIndex, offsetBy: item.span.end, limitedBy: result.endIndex),
                      startIndex <= endIndex
                else { return result }
                var updated = result
                updated.replaceSubrange(startIndex..<endIndex, with: item.placeholder)
                return updated
            }
    }

    private static func redactionMappings(from spans: [SemanticSpanDTO]) -> [RedactionMappingEntry] {
        assignPlaceholders(to: spans).map {
            RedactionMappingEntry(
                placeholder: $0.placeholder,
                entity: $0.span.entity,
                value: $0.span.word
            )
        }
    }

    private static func assignPlaceholders(to spans: [SemanticSpanDTO]) -> [(span: SemanticSpanDTO, placeholder: String)] {
        var counters: [String: Int] = [:]
        var existing: [String: String] = [:]

        return spans.map { span in
            let key = "\(span.entity)\u{1F}\(span.word.lowercased())"
            if let placeholder = existing[key] {
                return (span, placeholder)
            }

            let count = counters[span.entity, default: 0] + 1
            counters[span.entity] = count
            let placeholder = "{{\(span.entity)_\(count)}}"
            existing[key] = placeholder
            return (span, placeholder)
        }
    }

    private static func restore(text: String, mappings: [RedactionMappingEntry]) -> String {
        mappings
            .sorted { $0.placeholder.count > $1.placeholder.count }
            .reduce(text) { result, mapping in
                result.replacingOccurrences(of: mapping.placeholder, with: mapping.value)
            }
    }

    private static func bundledModelData(modelID: String) throws -> Data {
        guard modelID == defaultModelID else {
            throw PrivacyToolError.unsupportedModel(modelID)
        }
        return Data(defaultModelJSON.utf8)
    }

    private static func onnxModelSpec(for modelID: String) throws -> ONNXModelSpec {
        guard modelID == openAIPrivacyFilterQ4ModelID else {
            throw PrivacyToolError.unsupportedModel(modelID)
        }

        func hf(_ relativePath: String) -> URL {
            URL(string: "https://huggingface.co/openai/privacy-filter/resolve/main/\(relativePath)")!
        }

        let files = [
            ONNXModelFile(relativePath: "config.json", url: hf("config.json"), bytes: 3_039),
            ONNXModelFile(relativePath: "tokenizer.json", url: hf("tokenizer.json"), bytes: 27_868_174),
            ONNXModelFile(relativePath: "tokenizer_config.json", url: hf("tokenizer_config.json"), bytes: 234),
            ONNXModelFile(relativePath: "viterbi_calibration.json", url: hf("viterbi_calibration.json"), bytes: 372),
            ONNXModelFile(relativePath: "onnx/model_q4.onnx", url: hf("onnx/model_q4.onnx"), bytes: 160_219),
            ONNXModelFile(relativePath: "onnx/model_q4.onnx_data", url: hf("onnx/model_q4.onnx_data"), bytes: 917_120_144),
        ]

        return ONNXModelSpec(
            modelID: openAIPrivacyFilterQ4ModelID,
            onnxRelativePath: "onnx/model_q4.onnx",
            files: files
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func shouldPrintHelp(_ arguments: [String]) -> Bool {
        arguments.count < 2 || ["help", "--help", "-h"].contains(arguments[1])
    }

    private static func printHelp() {
        print("""
        ClawdHomePrivacyFilter \(BuildInfo.version)

        Usage:
          ClawdHomePrivacyFilter help
          ClawdHomePrivacyFilter probe
          ClawdHomePrivacyFilter status --model-id <id> --cache-dir <dir>
          ClawdHomePrivacyFilter prepare-model --model-id <id> --cache-dir <dir> [--model-url <url>] [--force]
          ClawdHomePrivacyFilter prepare-onnx-model --model-id openai-privacy-filter-q4 --cache-dir <dir> [--progress-file <file>] [--dry-run] [--force]
          ClawdHomePrivacyFilter inspect-onnx-model --model-id openai-privacy-filter-q4 --cache-dir <dir>
          ClawdHomePrivacyFilter analyze --model-id <id> --cache-dir <dir> < input.txt
          ClawdHomePrivacyFilter redact --model-id <id> --cache-dir <dir> --map-file <file> < input.txt
          ClawdHomePrivacyFilter restore --map-file <file> < llm-output.txt

        Models:
          \(defaultModelID)  Local lexical-context NER model for privacy filtering.
          \(openAIPrivacyFilterQ4ModelID)  OpenAI Privacy Filter q4 ONNX model.

        Commands:
          help           Print this help text.
          probe          Print tool version and supported model IDs as JSON.
          status         Check whether a model is installed and valid.
          prepare-model  Install the embedded model or download a JSON model from --model-url.
          prepare-onnx-model  Download the q4 ONNX model files from Hugging Face.
          inspect-onnx-model  Create an ONNX Runtime session and print model metadata.
          analyze        Load the installed model and emit semantic spans as JSON.
          redact         Emit redacted text and store a local reversible placeholder map.
          restore        Rehydrate LLM output with a local map created by redact.

        Options:
          --model-id     Model identifier. Default supported model: \(defaultModelID).
          --cache-dir    Directory containing manifest.json and model.json.
          --model-url    Optional file:// or https:// JSON model URL used by prepare-model.
          --map-file     Local JSON placeholder map for redact/restore.
          --progress-file Write ONNX download progress JSON for UI polling.
          --dry-run      Print required ONNX files without downloading.
          --force        Reinstall model even when a valid manifest already exists.
        """)
    }

    private static func writeJSON(_ value: any Encodable) throws {
        let data = try JSONEncoder.sorted.encode(AnyEncodable(value))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func commandName(from arguments: [String]) -> String {
        arguments.count > 1 ? arguments[1] : "unknown"
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

private let defaultModelJSON = """
{
  "schemaVersion": 1,
  "modelID": "clawdhome-privacy-ner-v1",
  "version": "2026.06.16",
  "engine": "lexical-context-ner",
  "rules": [
    {
      "id": "project-codename-cn",
      "entity": "ORG",
      "score": 0.93,
      "pattern": "(?:项目代号|内部项目|架构|计划|项目)\\\\s*[:：]?\\\\s*([A-Za-z][A-Za-z0-9_]*(?:-[A-Za-z0-9_]+)+)",
      "captureGroup": 1
    },
    {
      "id": "project-codename-en",
      "entity": "ORG",
      "score": 0.9,
      "pattern": "\\\\b(?:project|codename|initiative|program)\\\\s*[:：]?\\\\s*([A-Za-z][A-Za-z0-9_]*(?:-[A-Za-z0-9_]+)+)\\\\b",
      "captureGroup": 1
    },
    {
      "id": "hyphenated-internal-name",
      "entity": "ORG",
      "score": 0.84,
      "pattern": "\\\\b([A-Z][A-Za-z0-9]+(?:-[A-Z0-9][A-Za-z0-9]+)+)\\\\b",
      "captureGroup": 1
    },
    {
      "id": "account-cn",
      "entity": "USER",
      "score": 0.9,
      "pattern": "(?:账号|账户|用户|用户名|负责人账号)\\\\s*[:：为是]?\\\\s*([A-Za-z][A-Za-z0-9._-]{2,})",
      "captureGroup": 1
    },
    {
      "id": "account-en",
      "entity": "USER",
      "score": 0.88,
      "pattern": "\\\\b(?:user|username|account|login)\\\\s*[:=]?\\\\s*([A-Za-z][A-Za-z0-9._-]{2,})\\\\b",
      "captureGroup": 1
    },
    {
      "id": "private-repository",
      "entity": "SECRET",
      "score": 0.82,
      "pattern": "https://github\\\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\\\\.git)?",
      "captureGroup": 0
    }
  ],
  "dictionaries": [
    {
      "id": "sensitive-program-terms",
      "entity": "ORG",
      "score": 0.78,
      "terms": ["Lobster-AI", "Hermes Agent", "OpenClaw"]
    }
  ]
}
"""

await ClawdHomePrivacyFilterMain.main()
