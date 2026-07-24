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
          clawdhome ai asr transcribe meeting.m4a --format srt
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
        let segments: [Segment]?

        // 块级时间戳分段（由 ClawdHomeSpeech 滑动窗口分块边界推导，非词级时间戳）
        struct Segment: Decodable {
            let index: Int
            let start: Double
            let end: Double
            let text: String
        }
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

        Transcribe options:
          --model <id>                ASR 模型（默认 qwen3-asr-1.7b-8bit）
          --language <code>           语言提示，例如 zh 或 en
          --format <text|json|srt>    输出格式（默认 text 纯文本，无时间戳）
                                      json: 完整 JSON，segments 数组含每块 start/end（秒）与文本
                                      srt:  标准 SRT 字幕，含时间戳，可直接用于剪辑/字幕
          --chunk <seconds>           转写分块长度，5-30，默认 30。
                                      时间戳粒度=块长：需要更细的时间定位时调小（如 20），
                                      块越小转写总耗时略增

        时间戳说明:
          模型（Qwen3-ASR）不输出词级时间戳。json/srt 中的时间戳为“块级粗时间戳”，
          由转写分块边界推导，精度约等于 --chunk 块长；内部含 2 秒块间重叠以防止
          边界截断，相邻块时间可能有约 2 秒重叠。

        示例:
          clawdhome ai asr transcribe meeting.m4a                        # 纯文本
          clawdhome ai asr transcribe meeting.m4a --format srt           # SRT 字幕（带时间戳）
          clawdhome ai asr transcribe talk.mp3 --format json --chunk 20  # 20 秒粒度，JSON 含 segments
          clawdhome ai asr pull qwen3-asr-1.7b-8bit
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
            Output.printError("用法: clawdhome ai asr transcribe <audio-file> [--model <id>] [--format <text|json|srt>] [--chunk <seconds>]")
            exit(1)
        }

        var modelID = defaultModelID
        var language: String?
        var format = "text"
        var chunkSeconds: Int?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--model", "--model-id":
                // 注意：不要用 "case a, b where cond" 写法——where 只约束逗号列表里最后一个
                // pattern，另一个在末尾缺值时会导致 args[i + 1] 越界崩溃。这里显式判断边界。
                if i + 1 < args.count {
                    modelID = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--language":
                if i + 1 < args.count {
                    language = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--format":
                if i + 1 < args.count {
                    format = args[i + 1]
                    i += 2
                } else {
                    Output.printError("--format 需要一个值（合法值：text, json, srt）")
                    exit(1)
                }
            case "--chunk":
                if i + 1 < args.count {
                    let raw = args[i + 1]
                    guard let parsed = Int(raw), (5...30).contains(parsed) else {
                        Output.printError("非法 --chunk 值: \(raw)（必须是 5-30 范围内的整数）")
                        exit(1)
                    }
                    chunkSeconds = parsed
                    i += 2
                } else {
                    Output.printError("--chunk 需要一个值（5-30 范围内的整数）")
                    exit(1)
                }
            default:
                i += 1
            }
        }

        guard ["text", "json", "srt"].contains(format) else {
            Output.printError("非法 --format 值: \(format)（合法值：text, json, srt）")
            exit(1)
        }

        // 前置检查音频可读性，把"文件不存在/无权限"在 CLI 侧就报清楚，
        // 不让它变成工具侧难以理解的底层错误
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            Output.printError("无法读取音频文件: \(filePath)（文件不存在或无读取权限）。若文件位于 ~/Downloads 等受保护目录，请为调用进程授予文件访问权限或将文件移至可访问目录；跨用户调用（Shrimp 引擎）请将文件放入 /Users/Shared/ClawdHome/ 共享目录。")
            exit(1)
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
        if let chunkSeconds {
            toolArgs.append(contentsOf: ["--chunk-seconds", String(chunkSeconds)])
        }

        let output = try runSpeechTool(toolArgs)
        if Output.jsonMode || format == "json" {
            writeStdout(output.stdout)
            return
        }

        let response = try decode(TranscribeResponse.self, from: output.stdout)
        guard response.ok else {
            throw CLIError.operationFailed(response.error ?? "ASR 转写失败")
        }

        if format == "srt" {
            if let segments = response.segments, !segments.isEmpty {
                print(renderSRT(segments))
                return
            }
            Output.printErr("工具未返回分段时间戳，已回退纯文本输出")
        }

        if let transcript = response.transcript, !transcript.isEmpty {
            print(transcript)
        }
    }

    // 将块级时间戳分段渲染为标准 SRT 字幕文本
    private static func renderSRT(_ segments: [TranscribeResponse.Segment]) -> String {
        segments.enumerated().map { offset, segment in
            """
            \(offset + 1)
            \(formatSRTTime(segment.start)) --> \(formatSRTTime(segment.end))
            \(segment.text)
            """
        }.joined(separator: "\n\n")
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60000) % 60
        let h = totalMs / 3600000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func requireModel(_ id: String) throws -> Model {
        guard let model = models.first(where: { $0.id == id }) else {
            throw CLIError.operationFailed("未知 ASR 模型: \(id)")
        }
        return model
    }

    private static func requireSupportedPlatform() throws {
        switch ASRPlatformDetector.current() {
        case .appleSilicon:
            return
        case .intel:
            throw CLIError.operationFailed("ASR requires Apple Silicon. Intel Macs are not supported.")
        case .unknown:
            throw CLIError.operationFailed("无法确认当前环境的 CPU 架构。ASR requires Apple Silicon.")
        }
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

    // 工具失败时 stdout 上的 JSON 错误信封：ClawdHomeSpeech 失败时把
    // {"ok":false,"error":"..."} 写到 stdout 并以非零退出，真实错误在这里而不在 stderr
    private struct ToolErrorEnvelope: Decodable {
        let ok: Bool
        let error: String?
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

        // 启动失败（工具路径无效、非可执行文件等）与工具运行失败分开报错，
        // 避免只透传裸 POSIX 文本让调用方无从分辨
        do {
            try process.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CLIError.operationFailed("无法启动 ASR 工具 \(toolURL.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let trailingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
        if !trailingStderr.isEmpty {
            stderrData.append(trailingStderr)
            FileHandle.standardError.write(trailingStderr)
        }

        guard process.terminationStatus == 0 else {
            // 三级错误提取：优先取 stdout JSON 信封里的真实错误，其次 stderr 文本，最后通用文案
            if let envelope = try? JSONDecoder().decode(ToolErrorEnvelope.self, from: stdoutData),
               let innerError = envelope.error, !innerError.isEmpty {
                throw CLIError.operationFailed("ASR 工具执行失败: \(innerError)")
            }
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.operationFailed(message?.isEmpty == false ? message! : "ASR 工具执行失败")
        }

        return ToolOutput(stdout: stdoutData)
    }

    // 判断路径是"可执行的常规文件"：目录的 x 位是搜索权限，isExecutableFile 对目录也返回 true；
    // 若不排除目录，Process.run() 会尝试执行目录并抛出 EACCES（Permission denied）。
    private static func isExecutableRegularFile(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func speechToolURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAWDHOME_SPEECH_TOOL"], !override.isEmpty {
            guard isExecutableRegularFile(override) else {
                throw CLIError.operationFailed("CLAWDHOME_SPEECH_TOOL 不是可执行的常规文件: \(override)")
            }
            return URL(fileURLWithPath: override)
        }

        var candidates: [URL] = []

        // 同目录候选：仅当 argv[0] 带路径分隔符时才有意义。以 PATH 裸名（如 "clawdhome"）
        // 调用时 argv[0] 不含 "/"，deletingLastPathComponent 会解析成当前目录——在仓库根目录
        // 下会命中 ClawdHomeSpeech 源码目录，必须跳过。带路径时先解析符号链接
        // （/usr/local/bin/clawdhome 可能软链到 app bundle 内的真实二进制），
        // 同目录候选才指向真实安装位置。
        if CommandLine.arguments[0].contains("/") {
            let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            candidates.append(executableDirectory.appendingPathComponent("ClawdHomeSpeech"))
            // app-bundle 布局候选：Contents/MacOS/../Library/Executables/ClawdHomeSpeech，
            // 使安装版 CLI 不依赖写死的 /Applications 路径也能找到工具
            candidates.append(
                executableDirectory
                    .appendingPathComponent("../Library/Executables/ClawdHomeSpeech")
                    .standardized
            )
        }

        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/Executables/ClawdHomeSpeech")
        )
        candidates.append(
            URL(fileURLWithPath: "/Applications/ClawdHome.app/Contents/Library/Executables/ClawdHomeSpeech")
        )

        if let url = candidates.first(where: { isExecutableRegularFile($0.path) }) {
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
