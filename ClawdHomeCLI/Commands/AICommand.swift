// ClawdHomeCLI/Commands/AICommand.swift
// clawdhome ai <capability> — ClawdHome 本地 AI 能力入口

import Foundation
import Darwin

enum AICommand {
    static func run(_ args: [String], client: CLIHelperClient) throws {
        _ = client
        guard let capability = args.first else {
            printUsage()
            exit(1)
        }

        let rest = Array(args.dropFirst())
        switch capability {
        case "asr":
            try ASRCommand.run(rest)
        case "-h", "--help":
            printUsage()
        default:
            Output.printError("未知 AI 能力: \(capability)")
            printUsage()
            exit(1)
        }
    }

    private static func printUsage() {
        Output.printErr("""
        ClawdHome AI — 本地 AI 能力

        用法: clawdhome ai <capability> <command> [args]

        Capabilities:
          asr                         离线语音识别

        示例:
          clawdhome ai asr transcribe meeting.m4a
          clawdhome ai asr pull qwen3-asr-1.7b-8bit
        """)
    }
}

private enum ASRCommand {
    private struct Model {
        let id: String
        let displayName: String
        let repositoryModelID: String
        let estimatedDiskGB: Double
    }

    private struct ProbeResponse: Decodable {
        let ok: Bool
        let message: String
        let supportedModelIDs: [String]
    }

    private struct PrepareModelResponse: Decodable {
        let ok: Bool
        let modelID: String
        let elapsedSeconds: Double?
        let error: String?
    }

    private struct TranscribeResponse: Decodable {
        let ok: Bool
        let transcript: String?
        let elapsedSeconds: Double?
        let error: String?
    }

    private static let defaultModelID = "qwen3-asr-1.7b-8bit"
    private static let models = [
        Model(
            id: "qwen3-asr-0.6b",
            displayName: "Qwen3-ASR 0.6B",
            repositoryModelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
            estimatedDiskGB: 1.1
        ),
        Model(
            id: "qwen3-asr-1.7b-8bit",
            displayName: "Qwen3-ASR 1.7B 8-bit",
            repositoryModelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
            estimatedDiskGB: 2.6
        ),
    ]

    static func run(_ args: [String]) throws {
        guard let subcommand = args.first else {
            printUsage()
            exit(1)
        }

        let rest = Array(args.dropFirst())
        switch subcommand {
        case "doctor", "probe":
            try requireSupportedPlatform()
            try doctor()
        case "models":
            try requireSupportedPlatform()
            try listModels()
        case "pull", "prepare-model":
            try requireSupportedPlatform()
            try pull(rest)
        case "transcribe":
            try requireSupportedPlatform()
            try transcribe(rest)
        case "-h", "--help":
            printUsage()
        default:
            Output.printError("未知 ASR 子命令: \(subcommand)")
            printUsage()
            exit(1)
        }
    }

    private static func printUsage() {
        Output.printErr("""
        ClawdHome AI ASR — 离线语音识别

        用法: clawdhome ai asr <command> [args]

        Commands:
          doctor                      检查 ASR 工具可用性
          models                      列出 ASR 模型
          pull <model-id>             下载并准备模型
          transcribe <audio-file>     转写音频文件

        Options:
          --model <id>                ASR 模型（默认 qwen3-asr-1.7b-8bit）
          --language <code>           语言提示，例如 zh 或 en

        示例:
          clawdhome ai asr pull qwen3-asr-1.7b-8bit
          clawdhome ai asr transcribe meeting.m4a --model qwen3-asr-1.7b-8bit
        """)
    }

    private static func doctor() throws {
        let output = try runSpeechTool(["probe"])
        if Output.jsonMode {
            writeStdout(output.stdout)
            return
        }

        let response = try decode(ProbeResponse.self, from: output.stdout)
        guard response.ok else {
            throw CLIError.operationFailed(response.message)
        }
        Output.printSuccess(response.message)
        print("Supported models: \(response.supportedModelIDs.joined(separator: ", "))")
    }

    private static func listModels() throws {
        let rows = models.map { model -> [String] in
            let installed = isModelDownloaded(model) ? "installed" : "not installed"
            return [model.id, model.displayName, "\(model.estimatedDiskGB) GB", installed]
        }
        if Output.jsonMode {
            Output.printJSON(models.map { model in
                [
                    "id": model.id,
                    "displayName": model.displayName,
                    "estimatedDiskGB": model.estimatedDiskGB,
                    "installed": isModelDownloaded(model),
                ] as [String: Any]
            })
        } else {
            Output.printTable(headers: ["MODEL", "NAME", "SIZE", "STATUS"], rows: rows)
        }
    }

    private static func pull(_ args: [String]) throws {
        guard let modelID = args.first else {
            Output.printError("用法: clawdhome ai asr pull <model-id>")
            exit(1)
        }
        let model = try requireModel(modelID)
        try FileManager.default.createDirectory(at: cacheDirectory(for: model), withIntermediateDirectories: true)

        let output = try runSpeechTool([
            "prepare-model",
            "--model-id", model.id,
            "--cache-dir", cacheDirectory(for: model).path,
        ])

        if Output.jsonMode {
            writeStdout(output.stdout)
            return
        }

        let response = try decode(PrepareModelResponse.self, from: output.stdout)
        guard response.ok else {
            throw CLIError.operationFailed(response.error ?? "ASR 模型准备失败")
        }
        let elapsed = response.elapsedSeconds.map { String(format: "%.1fs", $0) } ?? "-"
        Output.printSuccess("\(model.displayName) 已准备完成（\(elapsed)）")
    }

    private static func transcribe(_ args: [String]) throws {
        guard let filePath = args.first else {
            Output.printError("用法: clawdhome ai asr transcribe <audio-file> [--model <id>]")
            exit(1)
        }

        var modelID = defaultModelID
        var language: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--model", "--model-id" where i + 1 < args.count:
                modelID = args[i + 1]
                i += 2
            case "--language" where i + 1 < args.count:
                language = args[i + 1]
                i += 2
            default:
                i += 1
            }
        }

        let model = try requireModel(modelID)
        try FileManager.default.createDirectory(at: cacheDirectory(for: model), withIntermediateDirectories: true)

        var toolArgs = [
            "transcribe",
            "--file", URL(fileURLWithPath: filePath).path,
            "--model-id", model.id,
            "--cache-dir", cacheDirectory(for: model).path,
        ]
        if let language, !language.isEmpty {
            toolArgs.append(contentsOf: ["--language", language])
        }

        let output = try runSpeechTool(toolArgs)
        if Output.jsonMode {
            writeStdout(output.stdout)
            return
        }

        let response = try decode(TranscribeResponse.self, from: output.stdout)
        guard response.ok else {
            throw CLIError.operationFailed(response.error ?? "ASR 转写失败")
        }
        if let transcript = response.transcript, !transcript.isEmpty {
            print(transcript)
        }
    }

    private static func requireModel(_ id: String) throws -> Model {
        guard let model = models.first(where: { $0.id == id }) else {
            throw CLIError.operationFailed("未知 ASR 模型: \(id)")
        }
        return model
    }

    private static func requireSupportedPlatform() throws {
        guard isAppleSilicon() else {
            throw CLIError.operationFailed("ASR requires Apple Silicon. Intel Macs are not supported.")
        }
    }

    private static func isAppleSilicon() -> Bool {
        if let override = ProcessInfo.processInfo.environment["CLAWDHOME_CPU_ARCH_OVERRIDE"], !override.isEmpty {
            return override == "arm64"
        }

        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    private static func cacheBaseDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
            .appendingPathComponent("qwen3-asr", isDirectory: true)
    }

    private static func cacheDirectory(for model: Model) -> URL {
        let parts = model.repositoryModelID.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return cacheBaseDirectory()
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(parts[0], isDirectory: true)
                .appendingPathComponent(parts[1], isDirectory: true)
        }
        return cacheBaseDirectory()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repositoryModelID, isDirectory: true)
    }

    private static func isModelDownloaded(_ model: Model) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory(for: model),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let hasSafetensors = contents.contains { $0.pathExtension == "safetensors" }
        let hasVocab = contents.contains { $0.lastPathComponent == "vocab.json" }
        return hasSafetensors && hasVocab
    }

    private struct ToolOutput {
        let stdout: Data
    }

    private static func runSpeechTool(_ arguments: [String]) throws -> ToolOutput {
        let toolURL = try speechToolURL()
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var stderrData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrData.append(data)
            FileHandle.standardError.write(data)
        }

        try process.run()
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
        if !trailingStderr.isEmpty {
            stderrData.append(trailingStderr)
            FileHandle.standardError.write(trailingStderr)
        }

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.operationFailed(message?.isEmpty == false ? message! : "ASR 工具执行失败")
        }

        return ToolOutput(stdout: stdoutData)
    }

    private static func speechToolURL() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CLAWDHOME_SPEECH_TOOL"], !override.isEmpty {
            guard fileManager.isExecutableFile(atPath: override) else {
                throw CLIError.operationFailed("CLAWDHOME_SPEECH_TOOL 不可执行: \(override)")
            }
            return URL(fileURLWithPath: override)
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("ClawdHomeSpeech"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/Executables/ClawdHomeSpeech"),
            URL(fileURLWithPath: "/Applications/ClawdHome.app/Contents/Library/Executables/ClawdHomeSpeech"),
        ]

        if let url = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return url
        }

        throw CLIError.operationFailed("未找到 ClawdHomeSpeech。请先安装 ClawdHome.app 或运行 make build-speech。")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CLIError.operationFailed("ASR 工具输出不是有效 JSON: \(text)")
        }
    }

    private static func writeStdout(_ data: Data) {
        FileHandle.standardOutput.write(data)
        if !data.isEmpty, data.last != 10 {
            print("")
        }
    }
}
