import ClawdHomeSpeechCore
import ClawdHomeSpeechRuntime
import Foundation
import Qwen3ASR
import Darwin // 引入 POSIX 系统级 setenv 等操作

// ANSI 多彩终端格式定义
private enum ANSI {
    static let green = "\u{001B}[1;32m"
    static let purple = "\u{001B}[1;35m"
    static let cyan = "\u{001B}[1;36m"
    static let yellow = "\u{001B}[1;33m"
    static let red = "\u{001B}[1;31m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let reset = "\u{001B}[0m"
    static let clearLine = "\r\u{001B}[K"
}

private enum BuildInfo {
    static let version = kSpeechVersion
    static let buildTime = kSpeechBuildTime
}

private enum SpeechToolError: LocalizedError {
    case missingCommand
    case missingValue(String)
    case missingAudioFile(String)
    case unreadableAudioFile(String)
    case invalidCacheDirectory(String)
    case invalidChunkSeconds(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "missing command"
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .missingAudioFile(let path):
            return "audio file not found: \(path)"
        case .unreadableAudioFile(let path):
            // 区分"文件不存在"与"存在但无读取权限"，方便上层定位跨用户/受保护目录问题
            return "audio file not readable (permission denied): \(path)"
        case .invalidCacheDirectory(let path):
            return "invalid cache directory: \(path)"
        case .invalidChunkSeconds(let raw):
            // --chunk-seconds 必须是 5...30 范围内的整数（模型训练窗口上限 30 秒）
            return "invalid --chunk-seconds value: \(raw) (must be an integer in 5...30)"
        }
    }
}

private struct ProbeResponse: Codable {
    let ok: Bool
    let command: String
    let message: String
    let version: String
    let supportedModelIDs: [String]
}

private struct PrepareModelResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let elapsedSeconds: Double?
    let error: String?
}

private struct TranscribeResponse: Codable {
    let ok: Bool
    let command: String
    let modelID: String
    let transcript: String?
    let elapsedSeconds: Double?
    let error: String?
    let segments: [TranscribeSegmentPayload]?
    let chunkSeconds: Int?
}

// 无头 transcribe 命令输出的块级时间戳分段（滑动窗口分块边界推导，非词级时间戳）
private struct TranscribeSegmentPayload: Codable {
    let index: Int
    let start: Double   // 秒
    let end: Double     // 秒
    let text: String
}

// 线程安全高频插值下载进度状态监控类，保障高并发刷新下无 Data Race 且绝对原子安全
private final class DownloadProgressState: @unchecked Sendable {
    private let lock = NSLock()
    let totalBytes: Int64
    
    private var _physicalBytes: Int64 = 0
    private var _physicalProgress: Double = 0.0
    private var _speedBytesPerSec: Double = 0.0
    private var _lastPhysicalUpdateTime = Date()
    private var _isFinished = false
    
    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }
    
    var physicalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }; return _physicalBytes
    }
    var physicalProgress: Double {
        lock.lock(); defer { lock.unlock() }; return _physicalProgress
    }
    var speedBytesPerSec: Double {
        lock.lock(); defer { lock.unlock() }; return _speedBytesPerSec
    }
    var lastPhysicalUpdateTime: Date {
        lock.lock(); defer { lock.unlock() }; return _lastPhysicalUpdateTime
    }
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }; return _isFinished
    }
    
    func update(progress: Double, speed: Double) {
        lock.lock()
        defer { lock.unlock() }
        _physicalProgress = progress
        _physicalBytes = Int64(Double(totalBytes) * progress)
        _speedBytesPerSec = speed
        _lastPhysicalUpdateTime = Date()
    }
    
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        _isFinished = true
    }
}

struct ClawdHomeSpeechMain {
    // CLI 每个进程只串行执行一条命令路径，控制器不会被并发访问。
    nonisolated(unsafe) private static let memoryController = SpeechMLXMemoryController(
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )

    static func main() async {
        // 双模判定：若无参数，或参数非静默机器对接指令，则完美滑入极客终端控制台
        if CommandLine.arguments.count < 2 || !["probe", "prepare-model", "transcribe"].contains(CommandLine.arguments[1]) {
            await runInteractiveMode()
            return
        }

        do {
            let response = try await run(arguments: CommandLine.arguments)
            try writeJSON(response)
        } catch {
            let fallback = TranscribeResponse(
                ok: false,
                command: commandName(from: CommandLine.arguments),
                modelID: "",
                transcript: nil,
                elapsedSeconds: nil,
                error: error.localizedDescription,
                segments: nil,
                chunkSeconds: nil
            )
            try? writeJSON(fallback)
            exit(1)
        }
    }

    // MARK: - 交互式极客终端控制台 (Interactive Mode)

    private static func printMascot() {
        print("""
\(ANSI.green)        .---.
       /     \\
       \\  o o /   \(ANSI.purple)🦖 ~[ ASR Brain ]\(ANSI.green)
       /  ==  \\
      /        \\
     /  ||  ||  \\
    (_ _||__||_ _)
\(ANSI.reset)
""")
    }

    private static func runInteractiveMode() async {
        applyHFConfigEnv()
        
        while true {
            print("\u{001B}[2J\u{001B}[H") // 终端清屏并将光标置顶
            printMascot()
            print("\(ANSI.bold)=== ClawdHomeSpeech 语音转译独立控制台 ===\(ANSI.reset)")
            print("\(ANSI.dim)当前版本：\(BuildInfo.version) · 编译时间：\(BuildInfo.buildTime)\(ANSI.reset)\n")
            
            let config = loadHFConfig()
            if !config.endpoint.isEmpty {
                print("\(ANSI.dim)当前加速源：\(config.endpoint)\(ANSI.reset)")
            }
            if !config.token.isEmpty {
                print("\(ANSI.dim)当前 Token ：已遮罩保护 (长度：\(config.token.count))\(ANSI.reset)")
            }
            print("")
            print("1. 浏览模型仓库与下载状态 (List models)")
            print("2. 下载并安装 ASR 模型 (Download model)")
            print("3. 离线音频转译 (ASR Transcription)")
            print("4. 自定义 Hugging Face 加速端点 (Configure Accelerators)")
            print("5. 退出程序 (Exit)")
            print("")
            print("\(ANSI.bold)请输入选项 (1-5)：\(ANSI.reset)", terminator: "")
            fflush(stdout)
            
            guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }
            
            switch choice {
            case "1":
                await showModelList()
            case "2":
                await interactiveDownload()
            case "3":
                await interactiveTranscribe()
            case "4":
                await interactiveConfigure()
            case "5":
                print("\n\(ANSI.bold)感谢使用，再见！\(ANSI.reset)\n")
                exit(0)
            default:
                print("\(ANSI.red)无效选项，请重新输入。\(ANSI.reset)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func showModelList() async {
        print("\n\(ANSI.bold)--- ASR 离线模型仓库列表 ---\(ANSI.reset)\n")
        
        let models = [
            ("qwen3-asr-0.6b", "Qwen3-ASR 0.6B (超轻量 · 极速下载与转译测试推荐 🌟)", 0.36),
            ("qwen3-asr-1.7b-8bit", "Qwen3-ASR 1.7B 8-bit (高准确率中等负载)", 1.72)
        ]
        
        for (idx, model) in models.enumerated() {
            let downloaded = isModelDownloaded(modelID: model.0)
            let statusText = downloaded 
                ? "\(ANSI.green)[已下载 / Installed]\(ANSI.reset)" 
                : "\(ANSI.dim)[未下载 / Available]\(ANSI.reset)"
            
            print("\(idx + 1). \(ANSI.bold)\(model.1)\(ANSI.reset)")
            print("   标识符：\(model.0)  物理体积：\(model.2) GB  状态：\(statusText)")
            print("")
        }
        
        print("按回车键返回主菜单...", terminator: "")
        fflush(stdout)
        _ = readLine()
    }

    private static func interactiveDownload() async {
        print("\n\(ANSI.bold)--- 下载并安装 ASR 大模型 ---\(ANSI.reset)\n")
        print("1. Qwen3-ASR 0.6B (仅 360 MB 🌟 极速测试首选)")
        print("2. Qwen3-ASR 1.7B 8-bit (1.72 GB 高清大包)")
        print("3. 返回主菜单")
        print("")
        print("\(ANSI.bold)请输入下载模型编号 (1-3)：\(ANSI.reset)", terminator: "")
        fflush(stdout)
        
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        let modelID: String
        let modelName: String
        let estimatedGB: Double
        
        if choice == "1" {
            modelID = "qwen3-asr-0.6b"
            modelName = "Qwen3-ASR 0.6B"
            estimatedGB = 0.36
        } else if choice == "2" {
            modelID = "qwen3-asr-1.7b-8bit"
            modelName = "Qwen3-ASR 1.7B 8-bit"
            estimatedGB = 1.72
        } else {
            return
        }
        
        let resolved = resolveModelID(from: modelID)
        let cacheDir = cacheDirectory(for: modelID)
        
        // 物理创建目录
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        print("\n\(ANSI.cyan)正在拉取并下载 \(modelName) 模型文件...\(ANSI.reset)")
        print("\(ANSI.dim)模型大小估算：\(estimatedGB) GB，物理缓存位置：\(cacheDir.path)\(ANSI.reset)\n")
        
        let totalBytes = Int64(estimatedGB * 1_000_000_000)
        let state = DownloadProgressState(totalBytes: totalBytes)
        
        // 前置友好交互：进入下载器前，立刻打印 0% 初始进度条，避免握手连接期间用户觉得“卡住/没反应”
        print("\(ANSI.green)[░░░░░░░░░░░░░░░░░░░░] 0%\(ANSI.reset) (0 KB / \(humanReadableByteCount(totalBytes))) · 正在握手连接并拉取缓存元数据...", terminator: "")
        fflush(stdout)
        
        // 启动 50ms 后台高频插值流畅 UI 渲染刷新线程 (20 FPS 电影级丝滑，大幅填补 TCP 回调的卡顿间隙)
        let renderTask = Task {
            var lastPrintedTime = Date()
            var lastVirtualBytes: Int64 = 0
            
            while !state.isFinished {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50毫秒
                if state.isFinished { break }
                
                let now = Date()
                let elapsedSincePhysical = now.timeIntervalSince(state.lastPhysicalUpdateTime)
                
                // 虚拟插值滚算：物理大小 + 瞬时下载速率 * 自物理回调后流逝的时间
                let speedSec = state.speedBytesPerSec
                let physical = state.physicalBytes
                let virtualBytesAdded = Int64(speedSec * elapsedSincePhysical)
                
                // 限制虚拟飘算上限，防止网络突发性卡死时进度条自己无节制往前飘
                let maxVirtualBytes = min(physical + 35_000_000, totalBytes)
                let currentVirtualBytes = min(physical + virtualBytesAdded, maxVirtualBytes)
                
                let virtualProgress = totalBytes > 0 ? Double(currentVirtualBytes) / Double(totalBytes) : 0.0
                
                // 计算灵敏顺滑的瞬时虚拟下载速率
                let delta = now.timeIntervalSince(lastPrintedTime)
                let speedBytes = delta > 0 ? Double(max(currentVirtualBytes - lastVirtualBytes, 0)) / delta : 0.0
                
                let speedText = speedBytes > 1024 
                    ? humanReadableByteCount(Int64(speedBytes)) + "/s"
                    : (speedSec > 1024 ? humanReadableByteCount(Int64(speedSec)) + "/s" : "Zero KB/s")
                
                let downloadedText = humanReadableByteCount(currentVirtualBytes)
                let totalText = humanReadableByteCount(totalBytes)
                
                let width = 20
                let completed = Int(Double(width) * virtualProgress)
                let bar = String(repeating: "█", count: completed) + String(repeating: "░", count: width - completed)
                let percent = Int(virtualProgress * 100)
                
                // 计算高饱和度、平缓不抖动的倒计时剩余时间
                var etaText = "--:--"
                let activeSpeed = speedBytes > 0 ? speedBytes : speedSec
                if activeSpeed > 1024 && virtualProgress < 1.0 {
                    let remainingBytes = max(totalBytes - currentVirtualBytes, 0)
                    let etaSeconds = Int(Double(remainingBytes) / activeSpeed)
                    let m = etaSeconds / 60
                    let s = etaSeconds % 60
                    etaText = String(format: "%02d:%02d", m, s)
                }
                
                print("\(ANSI.clearLine)\(ANSI.green)[\(bar)] \(percent)%\(ANSI.reset) (\(downloadedText) / \(totalText)) · 速率: \(ANSI.yellow)\(speedText)\(ANSI.reset) · 剩余时间: \(ANSI.cyan)\(etaText)\(ANSI.reset)", terminator: "")
                fflush(stdout)
                
                lastPrintedTime = now
                lastVirtualBytes = currentVirtualBytes
            }
        }
        
        var lastPhysicalBytes: Int64 = 0
        var lastPhysicalTime = Date()
        // 首次回调时本地可能已有部分文件（断点续传），跳过第一次速率计算
        // 以本地已有字节数作为差分基准，避免把历史进度误算为瞬时速率
        var isFirstCallback = true
        
        do {
            _ = memoryController.configure()
            defer { memoryController.reclaim() }
            _ = try await Qwen3ASRModel.fromPretrained(
                modelId: resolved,
                cacheDir: cacheDir,
                progressHandler: { progress, message in
                    let now = Date()
                    let currentPhysicalBytes = Int64(Double(totalBytes) * progress)
                    
                    if isFirstCallback {
                        // 第一次回调：仅记录基准值，不计算速率（避免已有文件被算成瞬时速率）
                        isFirstCallback = false
                        lastPhysicalBytes = currentPhysicalBytes
                        lastPhysicalTime = now
                        state.update(progress: progress, speed: 0.0)
                        return
                    }
                    
                    // 物理回调更新真实的下载数据和物理计算的瞬时速率
                    let delta = now.timeIntervalSince(lastPhysicalTime)
                    let currentSpeed = delta > 0 ? Double(max(currentPhysicalBytes - lastPhysicalBytes, 0)) / delta : 0.0
                    
                    state.update(progress: progress, speed: currentSpeed)
                    
                    lastPhysicalTime = now
                    lastPhysicalBytes = currentPhysicalBytes
                }
            )
            _ = memoryController.reclaim()
            
            // 标记渲染线程结束并等待其退出
            state.finish()
            _ = await renderTask.result
            
            // 最终物理强制渲染完美的 100% 下载条，防止虚拟浮点误差
            let finalBar = String(repeating: "█", count: 20)
            let totalText = humanReadableByteCount(totalBytes)
            print("\(ANSI.clearLine)\(ANSI.green)[\(finalBar)] 100%\(ANSI.reset) (\(totalText) / \(totalText)) · 速率: 已完成 · 剩余时间: 00:00", terminator: "")
            fflush(stdout)
            
            print("\n\n\(ANSI.green)✓ \(modelName) 模型下载并安装成功！\(ANSI.reset)\n")
        } catch {
            state.finish()
            _ = await renderTask.result
            print("\n\n\(ANSI.red)✗ 下载失败：\(error.localizedDescription)\(ANSI.reset)")
            if error.localizedDescription.contains("Invalid metadata") || error.localizedDescription.contains("File metadata") {
                print("""
\(ANSI.yellow)💡 【ClawdHome 友情排障指引】：
检测到您当前配置了国内加速源 (\(loadHFConfig().endpoint))。
由于国内镜像站的 CDN 缓存会把 ETag 标记转换为弱 ETag (带有 W/" 前缀)，这会导致 Hugging Face Swift 校验机制失效并引发 metadata 错误。
建议您：
1. 在主菜单输入 4，选择 [2. 还原加速源为 Hugging Face 官方默认]；
2. 开启系统全局 VPN/代理后再次尝试下载，即可避开此校验缺陷并获得极速下载速度！
\(ANSI.reset)
""")
            }
            print("")
        }
        
        print("按回车键继续...", terminator: "")
        fflush(stdout)
        _ = readLine()
    }

    private static func interactiveTranscribe() async {
        print("\n\(ANSI.bold)--- 离线 ASR 语音转译 ---\(ANSI.reset)\n")
        
        let b06 = isModelDownloaded(modelID: "qwen3-asr-0.6b")
        let b17 = isModelDownloaded(modelID: "qwen3-asr-1.7b-8bit")
        
        guard b06 || b17 else {
            print("\(ANSI.red)✗ 本地没有检测到已下载的模型，请先选择 2 下载模型后再进行转写。\(ANSI.reset)\n")
            print("按回车键返回...", terminator: "")
            fflush(stdout)
            _ = readLine()
            return
        }
        
        print("请选择用于转译的本地模型：")
        if b06 {
            print("1. Qwen3-ASR 0.6B (已下载)")
        } else {
            print("\(ANSI.dim)1. Qwen3-ASR 0.6B (未下载，不可用)\(ANSI.reset)")
        }
        
        if b17 {
            print("2. Qwen3-ASR 1.7B 8-bit (已下载)")
        } else {
            print("\(ANSI.dim)2. Qwen3-ASR 1.7B 8-bit (未下载，不可用)\(ANSI.reset)")
        }
        print("")
        print("\(ANSI.bold)请选择模型编号 (1-2)：\(ANSI.reset)", terminator: "")
        fflush(stdout)
        
        guard let mChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        let modelID: String
        if mChoice == "1" && b06 {
            modelID = "qwen3-asr-0.6b"
        } else if mChoice == "2" && b17 {
            modelID = "qwen3-asr-1.7b-8bit"
        } else {
            print("\(ANSI.red)无效选项或所选模型未下载。\(ANSI.reset)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return
        }
        
        print("\n\(ANSI.bold)请输入本地音频文件的绝对路径（可直接拖拽文件入终端）：\(ANSI.reset)")
        print("> ", terminator: "")
        fflush(stdout)
        
        guard let inputPath = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        // 移去拖入带来的头尾包裹引号与空格转义
        var cleanedPath = inputPath
        if cleanedPath.hasPrefix("'") && cleanedPath.hasSuffix("'") {
            cleanedPath = String(cleanedPath.dropFirst().dropLast())
        } else if cleanedPath.hasPrefix("\"") && cleanedPath.hasSuffix("\"") {
            cleanedPath = String(cleanedPath.dropFirst().dropLast())
        }
        cleanedPath = cleanedPath.replacingOccurrences(of: "\\ ", with: " ")
        
        let audioURL = URL(fileURLWithPath: cleanedPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            print("\n\(ANSI.red)✗ 音频文件不存在：\(cleanedPath)\(ANSI.reset)\n")
            print("按回车键继续...", terminator: "")
            fflush(stdout)
            _ = readLine()
            return
        }
        
        let cacheDir = cacheDirectory(for: modelID)
        let resolved = resolveModelID(from: modelID)
        
        // 模型标准采样率（Whisper 规范）
        let modelSampleRate = 16000
        // 滑动窗口参数：30 秒/块（模型训练窗口），2 秒重叠防止边界截断
        let chunkSeconds = 30
        let overlapSeconds = 2
        let chunkSamples = chunkSeconds * modelSampleRate     // 480000 samples
        let overlapSamples = overlapSeconds * modelSampleRate  // 32000 samples
        let stepSamples = chunkSamples - overlapSamples        // 448000 samples/step

        do {
            let audioInfo = try StreamingAudioFileLoader.info(from: audioURL, targetSampleRate: modelSampleRate)
            let totalSamples = max(audioInfo.estimatedTotalSamples, 1)
            let audioDurationSec = audioInfo.durationSeconds

            let isDownloaded = isModelDownloaded(at: cacheDir)

            // 加载模型前先显示进度（长音频加载模型本身也要时间）
            print("\(ANSI.clearLine)\(ANSI.purple)⠙ 正在载入 MLX 推理模型...\(ANSI.reset)", terminator: "")
            fflush(stdout)

            _ = memoryController.configure()
            defer { memoryController.reclaim() }
            let model = try await Qwen3ASRModel.fromPretrained(
                modelId: resolved,
                cacheDir: cacheDir,
                offlineMode: isDownloaded
            )
            _ = memoryController.reclaim()

            // 短音频（≤ 30 秒）：直接转译，不分块
            if totalSamples <= chunkSamples {
                print("\(ANSI.clearLine)\(ANSI.purple)⠙ 正在转译（单段模式）...\(ANSI.reset)")
                fflush(stdout)
                
                let transcribeStart = CFAbsoluteTimeGetCurrent()
                var transcript = ""
                try StreamingAudioFileLoader.forEachChunk(
                    from: audioURL,
                    targetSampleRate: modelSampleRate,
                    chunkSamples: chunkSamples,
                    overlapSamples: overlapSamples
                ) { chunk in
                    let inference = memoryController.runReclaiming {
                        model.transcribe(
                            audio: chunk.samples,
                            sampleRate: modelSampleRate,
                            language: nil,
                            maxTokens: 1024
                        )
                    }
                    transcript = inference.value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - transcribeStart
                let speedRatio = elapsed > 0 ? (audioDurationSec / elapsed) : 0.0
                let speedText = speedRatio > 0 ? String(format: "%.1fx", speedRatio) : "--.-x"
                
                print("\(ANSI.clearLine)\(ANSI.green)✓ 转译圆满完成！耗时 \(String(format: "%.2f", elapsed)) 秒 (平均速率: \(speedText))\(ANSI.reset)\n")
                print("\(ANSI.bold)=== 离线转译文本结果 ===\(ANSI.reset)")
                print(transcript.isEmpty ? "\(ANSI.dim)（无语音内容识别出）\(ANSI.reset)" : transcript)
                print("\(ANSI.bold)===========================\(ANSI.reset)\n")
                
                if !transcript.isEmpty {
                    let segments = [TranscribeSegment(index: 1, startTime: 0.0, endTime: audioDurationSec, text: transcript)]
                    saveTranscribeFiles(segments: segments, audioURL: audioURL, fullTranscript: transcript)
                }
            } else {
                // 长音频：滑动窗口分块转译，逐块打印进度
                let totalChunks = Int(ceil(Double(totalSamples - overlapSamples) / Double(stepSamples)))
                print("\(ANSI.clearLine)\(ANSI.cyan)\u{1F4CB} 音频时长 \(String(format: "%.1f", audioDurationSec)) 秒，分 \(totalChunks) 块转译（每块 \(chunkSeconds) 秒）\(ANSI.reset)")
                fflush(stdout)

                var segments: [TranscribeSegment] = []
                var processedChunkCount = 0
                let transcribeStart = CFAbsoluteTimeGetCurrent()

                try StreamingAudioFileLoader.forEachChunk(
                    from: audioURL,
                    targetSampleRate: modelSampleRate,
                    chunkSamples: chunkSamples,
                    overlapSamples: overlapSamples
                ) { chunk in
                    processedChunkCount = chunk.index
                    let chunkStartSec = chunk.startTime(sampleRate: modelSampleRate)
                    let chunkEndSec = min(chunk.endTime(sampleRate: modelSampleRate), audioDurationSec)
                    let progress = Int(Double(chunk.index) / Double(totalChunks) * 100)
                    let bar = String(repeating: "\u{2588}", count: progress / 5) + String(repeating: "\u{2591}", count: 20 - progress / 5)
                    
                    let elapsed = CFAbsoluteTimeGetCurrent() - transcribeStart
                    let speedRatio = elapsed > 0 ? (chunkEndSec / elapsed) : 0.0
                    let speedText = speedRatio > 0 ? String(format: "%.1fx", speedRatio) : "--.-x"
                    
                    print("\(ANSI.clearLine)\(ANSI.green)[\(bar)] \(progress)%\(ANSI.reset) 块 \(chunk.index)/\(totalChunks)  [\(String(format: "%.0f", chunkStartSec))s - \(String(format: "%.0f", chunkEndSec))s] · 速率: \(ANSI.yellow)\(speedText)\(ANSI.reset)", terminator: "")
                    fflush(stdout)

                    let inference = memoryController.runReclaiming {
                        model.transcribe(
                            audio: chunk.samples,
                            sampleRate: modelSampleRate,
                            language: nil,
                            maxTokens: 1024
                        )
                    }
                    let chunkText = inference.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !chunkText.isEmpty {
                        segments.append(TranscribeSegment(
                            index: chunk.index,
                            startTime: chunkStartSec,
                            endTime: chunkEndSec,
                            text: chunkText
                        ))
                    }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - transcribeStart
                let avgSpeedRatio = elapsed > 0 ? (audioDurationSec / elapsed) : 0.0
                let avgSpeedText = avgSpeedRatio > 0 ? String(format: "%.1fx", avgSpeedRatio) : "--.-x"
                
                let fullTranscript = segments.map { $0.text }.joined(separator: " ")
                print("\n\(ANSI.green)✓ 转译圆满完成！共 \(processedChunkCount) 块，耗时 \(String(format: "%.2f", elapsed)) 秒 (平均速率: \(avgSpeedText))\(ANSI.reset)\n")
                print("\(ANSI.bold)=== 离线转译文本结果 ===\(ANSI.reset)")
                print(fullTranscript.isEmpty ? "\(ANSI.dim)（无语音内容识别出）\(ANSI.reset)" : fullTranscript)
                print("\(ANSI.bold)===========================\(ANSI.reset)\n")
                
                if !fullTranscript.isEmpty {
                    saveTranscribeFiles(segments: segments, audioURL: audioURL, fullTranscript: fullTranscript)
                }
            }
        } catch {
            print("\(ANSI.clearLine)\(ANSI.red)✗ 转译失败：\(error.localizedDescription)\(ANSI.reset)")
            if error.localizedDescription.contains("Invalid metadata") || error.localizedDescription.contains("File metadata") {
                print("""
\(ANSI.yellow)💡 【ClawdHome 友情排障指引】：
检测到您配置了国内加速源，这导致 Hugging Face 校验底层遇到了 CDN 弱 ETag (W/") 校验缺陷。
由于此模型已经下载成功，本次转译失败纯属网络握手缺陷。我们已为您对本地模型做出了纯离线加载机制优化！
\(ANSI.reset)
""")
            }
            print("")
        }

        print("按回车键继续...", terminator: "")
        fflush(stdout)
        _ = readLine()
    }

    private static func interactiveConfigure() async {
        print("\n\(ANSI.bold)--- 配置高速下载加速源 ---\(ANSI.reset)\n")
        let current = loadHFConfig()
        print("当前加速源：\(current.endpoint.isEmpty ? "默认官方 (Hugging Face)" : current.endpoint)")
        print("当前 Token ：\(current.token.isEmpty ? "未配置" : "已配置并受保护")")
        print("")
        print("1. 设置加速源为国内超高速镜像站 (hf-mirror.com)")
        print("2. 还原加速源为 Hugging Face 官方默认")
        print("3. 自定义加速源端点 URL")
        print("4. 设置 Hugging Face 鉴权 Token (可选，防限流)")
        print("5. 清空 Token")
        print("6. 返回主菜单")
        print("")
        print("\(ANSI.bold)请输入配置选项 (1-6)：\(ANSI.reset)", terminator: "")
        fflush(stdout)
        
        guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        switch choice {
        case "1":
            saveHFConfig(endpoint: "https://hf-mirror.com", token: current.token)
            applyHFConfigEnv()
            print("\n\(ANSI.green)✓ 下载端点已成功更新为 hf-mirror.com！\(ANSI.reset)\n")
        case "2":
            saveHFConfig(endpoint: "", token: current.token)
            applyHFConfigEnv()
            print("\n\(ANSI.green)✓ 已还原官方标准下载源。\(ANSI.reset)\n")
        case "3":
            print("\n请输入自定义加速源 URL (如：https://hf-mirror.com)：")
            print("> ", terminator: "")
            fflush(stdout)
            if let customUrl = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !customUrl.isEmpty {
                saveHFConfig(endpoint: customUrl, token: current.token)
                applyHFConfigEnv()
                print("\n\(ANSI.green)✓ 自定义源配置已成功保存！\(ANSI.reset)\n")
            }
        case "4":
            print("\n请输入 Hugging Face 访问 Token (可从 https://huggingface.co/settings/tokens 获取)：")
            print("> ", terminator: "")
            fflush(stdout)
            if let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                saveHFConfig(endpoint: current.endpoint, token: token)
                applyHFConfigEnv()
                print("\n\(ANSI.green)✓ Token 已安全配置并存入本地 UserDefaults！\(ANSI.reset)\n")
            }
        case "5":
            saveHFConfig(endpoint: current.endpoint, token: "")
            applyHFConfigEnv()
            print("\n\(ANSI.green)✓ Token 已清空。\(ANSI.reset)\n")
        default:
            return
        }
        
        print("按回车键继续...", terminator: "")
        fflush(stdout)
        _ = readLine()
    }

    private static func applyHFConfigEnv() {
        let current = loadHFConfig()
        if !current.endpoint.isEmpty {
            setenv("HF_ENDPOINT", current.endpoint, 1)
        } else {
            unsetenv("HF_ENDPOINT")
        }
        if !current.token.isEmpty {
            setenv("HF_TOKEN", current.token, 1)
        } else {
            unsetenv("HF_TOKEN")
        }
    }

    private static func loadHFConfig() -> (endpoint: String, token: String) {
        let endpoint = UserDefaults.standard.string(forKey: "hf_endpoint_preference") ?? ""
        let token = UserDefaults.standard.string(forKey: "hf_token_preference") ?? ""
        return (endpoint, token)
    }

    private static func saveHFConfig(endpoint: String, token: String) {
        UserDefaults.standard.set(endpoint, forKey: "hf_endpoint_preference")
        UserDefaults.standard.set(token, forKey: "hf_token_preference")
        UserDefaults.standard.synchronize()
    }

    private static func isModelDownloaded(modelID: String) -> Bool {
        let dir = cacheDirectory(for: modelID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let hasSafetensors = contents.contains { $0.pathExtension == "safetensors" }
        let hasVocab = contents.contains { $0.lastPathComponent == "vocab.json" }
        return hasSafetensors && hasVocab
    }

    private static func isModelDownloaded(at dir: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let hasSafetensors = contents.contains { $0.pathExtension == "safetensors" }
        let hasVocab = contents.contains { $0.lastPathComponent == "vocab.json" }
        return hasSafetensors && hasVocab
    }

    private static func speechCacheBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesURL
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
            .appendingPathComponent("qwen3-asr", isDirectory: true)
    }

    private static func cacheDirectory(for modelSpecifier: String) -> URL {
        let base = speechCacheBaseDirectory()
        let resolved = (modelSpecifier == "qwen3-asr-1.7b-8bit") 
            ? "aufklarer/Qwen3-ASR-1.7B-MLX-8bit" 
            : "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            
        let parts = resolved.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return base
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(parts[0], isDirectory: true)
                .appendingPathComponent(parts[1], isDirectory: true)
        } else {
            return base
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(resolved, isDirectory: true)
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
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

    private static func humanReadableByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(bytes, 0))
    }

    // MARK: - 静默机器调用接口模式 (Silent Machine Mode)

    private static func run(arguments: [String]) async throws -> AnyEncodable {
        guard arguments.count >= 2 else {
            throw SpeechToolError.missingCommand
        }

        switch arguments[1] {
        case "probe":
            return AnyEncodable(ProbeResponse(
                ok: true,
                command: "probe",
                message: "speech tool available",
                version: BuildInfo.version,
                supportedModelIDs: ["qwen3-asr-1.7b-8bit", "qwen3-asr-0.6b"]
            ))
        case "prepare-model":
            return AnyEncodable(try await prepareModel(arguments: Array(arguments.dropFirst(2))))
        case "transcribe":
            return AnyEncodable(try await transcribe(arguments: Array(arguments.dropFirst(2))))
        default:
            throw SpeechToolError.missingCommand
        }
    }

    private static func prepareModel(arguments: [String]) async throws -> PrepareModelResponse {
        let modelSpecifier = try value(for: "--model-id", in: arguments)
        let cacheDirectoryPath = try value(for: "--cache-dir", in: arguments)
        let cacheDirectory = URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SpeechToolError.invalidCacheDirectory(cacheDirectory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        let resolvedModelID = resolveModelID(from: modelSpecifier)
        let start = CFAbsoluteTimeGetCurrent()
        _ = memoryController.configure()
        defer { memoryController.reclaim() }
        _ = try await Qwen3ASRModel.fromPretrained(
            modelId: resolvedModelID,
            cacheDir: cacheDirectory,
            progressHandler: { progress, message in
                try? writeProgress(
                    SpeechToolProgressResponse(
                        kind: "progress",
                        command: "prepare-model",
                        fractionCompleted: progress,
                        message: message
                    )
                )
            }
        )
        let modelLoadMemory = memoryController.reclaim()
        try? writeProgress(
            SpeechToolProgressResponse(
                kind: "progress",
                command: "prepare-model",
                fractionCompleted: 1.0,
                message: "Ready",
                memorySnapshot: modelLoadMemory
            )
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return PrepareModelResponse(
            ok: true,
            command: "prepare-model",
            modelID: modelSpecifier,
            elapsedSeconds: elapsed,
            error: nil
        )
    }

    private static func transcribe(arguments: [String]) async throws -> TranscribeResponse {
        let filePath = try value(for: "--file", in: arguments)
        let modelSpecifier = try value(for: "--model-id", in: arguments)
        let cacheDirectoryPath = try value(for: "--cache-dir", in: arguments)
        let language = optionalValue(for: "--language", in: arguments)
        let chunkVocalEnhance = arguments.contains("--chunk-vocal-enhance")

        // --chunk-seconds：转写分块长度（秒），默认 30，合法范围 5...30
        let chunkSecondsRaw = optionalValue(for: "--chunk-seconds", in: arguments)
        let chunkSeconds: Int
        if let chunkSecondsRaw {
            guard let parsed = Int(chunkSecondsRaw), (5...30).contains(parsed) else {
                throw SpeechToolError.invalidChunkSeconds(chunkSecondsRaw)
            }
            chunkSeconds = parsed
        } else {
            chunkSeconds = 30
        }

        let audioURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SpeechToolError.missingAudioFile(audioURL.path)
        }
        // 存在但不可读（如跨用户权限、受保护目录），单独报错以便与"不存在"区分
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw SpeechToolError.unreadableAudioFile(audioURL.path)
        }

        let cacheDirectory = URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SpeechToolError.invalidCacheDirectory(cacheDirectory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        let resolvedModelID = resolveModelID(from: modelSpecifier)

        // 模型标准采样率（Whisper 规范）
        let modelSampleRate = 16000
        let audioInfo = try StreamingAudioFileLoader.info(from: audioURL, targetSampleRate: modelSampleRate)

        let isDownloaded = isModelDownloaded(at: cacheDirectory)
        _ = memoryController.configure()
        defer { memoryController.reclaim() }
        let model = try await Qwen3ASRModel.fromPretrained(
            modelId: resolvedModelID,
            cacheDir: cacheDirectory,
            offlineMode: isDownloaded,
            progressHandler: { progress, message in
                try? writeProgress(
                    SpeechToolProgressResponse(
                        kind: "progress",
                        command: "load-model",
                        fractionCompleted: progress,
                        message: message
                    )
                )
            }
        )
        let modelLoadMemory = memoryController.reclaim()
        try? writeProgress(
            SpeechToolProgressResponse(
                kind: "progress",
                command: "load-model",
                fractionCompleted: 1.0,
                message: "Ready",
                memorySnapshot: modelLoadMemory
            )
        )

        let start = CFAbsoluteTimeGetCurrent()

        // 滑动窗口参数：chunkSeconds 秒/块（默认 30，模型训练窗口上限），2 秒重叠防止边界截断
        let chunkSamples = chunkSeconds * modelSampleRate
        let overlapSamples = 2 * modelSampleRate     // 32000 samples

        let totalSamples = max(audioInfo.estimatedTotalSamples, 1)
        let transcript: String
        let payloadSegments: [TranscribeSegmentPayload]

        if totalSamples <= chunkSamples {
            // 短音频：直接转译
            try? writeProgress(
                SpeechToolProgressResponse(
                    kind: "progress",
                    command: "transcribe",
                    fractionCompleted: 0.1,
                    message: "正在提取声学特征进行转译..."
                )
            )
            var singleTranscript = ""
            var singleChunkIndex = 1
            var lastMemorySnapshot: SpeechInferenceMemorySnapshot?
            try StreamingAudioFileLoader.forEachChunk(
                from: audioURL,
                targetSampleRate: modelSampleRate,
                chunkSamples: chunkSamples,
                overlapSamples: overlapSamples
            ) { chunk in
                let samples = try samplesForTranscription(
                    from: chunk,
                    sampleRate: modelSampleRate,
                    chunkVocalEnhance: chunkVocalEnhance
                )
                let inference = memoryController.runReclaiming {
                    model.transcribe(
                        audio: samples,
                        sampleRate: modelSampleRate,
                        language: language,
                        maxTokens: 1024
                    )
                }
                singleTranscript = inference.value
                singleChunkIndex = chunk.index
                lastMemorySnapshot = inference.snapshot
            }
            transcript = singleTranscript
            let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            payloadSegments = cleanedTranscript.isEmpty ? [] : [
                TranscribeSegmentPayload(
                    index: singleChunkIndex,
                    start: 0,
                    end: audioInfo.durationSeconds,
                    text: cleanedTranscript
                )
            ]
            try? writeProgress(
                SpeechToolProgressResponse(
                    kind: "progress",
                    command: "transcribe",
                    fractionCompleted: 1.0,
                    message: "已完成 100%",
                    transcriptDelta: cleanedTranscript.isEmpty ? nil : cleanedTranscript,
                    memorySnapshot: lastMemorySnapshot
                )
            )
        } else {
            // 长音频：滑动窗口分块转译，逐块结果拼接，同时记录每块的起止时间戳
            var segments: [TranscribeSegmentPayload] = []
            let audioDurationSec = audioInfo.durationSeconds
            func progressMessage(fraction: Double, currentEndSec: Double, elapsed: Double) -> String {
                let speedRatio = elapsed > 0 ? (currentEndSec / elapsed) : 0.0
                if speedRatio > 0 {
                    let etaSec = max((audioDurationSec - currentEndSec) / speedRatio, 0)
                    return String(format: "已转写 %.0f%% (速率 %.1fx, 剩余 %.0fs)", fraction * 100, speedRatio, etaSec)
                }
                return String(format: "已转写 %.0f%%", fraction * 100)
            }
            
            try StreamingAudioFileLoader.forEachChunk(
                from: audioURL,
                targetSampleRate: modelSampleRate,
                chunkSamples: chunkSamples,
                overlapSamples: overlapSamples
            ) { chunk in
                let progressFraction = min(Double(chunk.startSample) / Double(totalSamples), 0.995)
                let currentEndSec = min(chunk.startTime(sampleRate: modelSampleRate), audioDurationSec)
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let message = progressMessage(fraction: progressFraction, currentEndSec: currentEndSec, elapsed: elapsed)
                
                try? writeProgress(
                    SpeechToolProgressResponse(
                        kind: "progress",
                        command: "transcribe",
                        fractionCompleted: progressFraction,
                        message: message
                    )
                )
                
                let samples = try samplesForTranscription(
                    from: chunk,
                    sampleRate: modelSampleRate,
                    chunkVocalEnhance: chunkVocalEnhance
                )
                let inference = memoryController.runReclaiming {
                    model.transcribe(
                        audio: samples,
                        sampleRate: modelSampleRate,
                        language: language,
                        maxTokens: 1024
                    )
                }
                let chunkText = inference.value
                let cleanedChunkText = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedChunkText.isEmpty {
                    segments.append(
                        TranscribeSegmentPayload(
                            index: chunk.index,
                            start: chunk.startTime(sampleRate: modelSampleRate),
                            end: min(chunk.endTime(sampleRate: modelSampleRate), audioDurationSec),
                            text: cleanedChunkText
                        )
                    )
                }
                let completedFraction = min(Double(chunk.endSample) / Double(totalSamples), 1.0)
                let completedEndSec = min(chunk.endTime(sampleRate: modelSampleRate), audioDurationSec)
                let completedElapsed = CFAbsoluteTimeGetCurrent() - start
                let completedMessage = progressMessage(
                    fraction: completedFraction,
                    currentEndSec: completedEndSec,
                    elapsed: completedElapsed
                )
                try? writeProgress(
                    SpeechToolProgressResponse(
                        kind: "progress",
                        command: "transcribe",
                        fractionCompleted: completedFraction,
                        message: completedMessage,
                        transcriptDelta: cleanedChunkText.isEmpty ? nil : cleanedChunkText,
                        memorySnapshot: inference.snapshot
                    )
                )
            }
            transcript = segments.map { $0.text }.joined(separator: " ")
            payloadSegments = segments
        }


        let elapsed = CFAbsoluteTimeGetCurrent() - start

        return TranscribeResponse(
            ok: true,
            command: "transcribe",
            modelID: modelSpecifier,
            transcript: transcript,
            elapsedSeconds: elapsed,
            error: nil,
            segments: payloadSegments,
            chunkSeconds: chunkSeconds
        )
    }

    private static func samplesForTranscription(
        from chunk: SpeechAudioChunk,
        sampleRate: Int,
        chunkVocalEnhance: Bool
    ) throws -> [Float] {
        guard chunkVocalEnhance else {
            return chunk.samples
        }
        return try SpeechAudioChunkEnhancer.enhance(chunk.samples, sampleRate: sampleRate)
    }

    private static func resolveModelID(from specifier: String) -> String {
        switch specifier {
        case "qwen3-asr-1.7b-8bit":
            return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case "qwen3-asr-0.6b":
            return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        default:
            return specifier
        }
    }

    private static func value(for flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag) else {
            throw SpeechToolError.missingValue(flag)
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw SpeechToolError.missingValue(flag)
        }
        return arguments[valueIndex]
    }

    private static func optionalValue(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private static func commandName(from arguments: [String]) -> String {
        guard arguments.count >= 2 else { return "unknown" }
        return arguments[1]
    }

    private static func writeJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnyEncodable(value))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeProgress(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnyEncodable(value))
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([0x0A]))
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60000) % 60
        let h = totalMs / 3600000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func saveTranscribeFiles(segments: [TranscribeSegment], audioURL: URL, fullTranscript: String) {
        let fileDirectory = audioURL.deletingLastPathComponent()
        let fileBaseName = audioURL.deletingPathExtension().lastPathComponent
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        
        let txtURL = fileDirectory.appendingPathComponent("\(fileBaseName)_\(timestamp).txt")
        let srtURL = fileDirectory.appendingPathComponent("\(fileBaseName)_\(timestamp).srt")
        let timelineURL = fileDirectory.appendingPathComponent("\(fileBaseName)_\(timestamp)_timeline.txt")
        
        // 1. 生成字幕内容 (SRT)
        var srtContent = ""
        for (idx, seg) in segments.enumerated() {
            srtContent += "\(idx + 1)\n"
            srtContent += "\(formatSRTTime(seg.startTime)) --> \(formatSRTTime(seg.endTime))\n"
            srtContent += "\(seg.text)\n\n"
        }
        
        // 2. 生成简易时间轴内容 (Timeline)
        var timelineContent = ""
        for seg in segments {
            let startMin = Int(seg.startTime) / 60
            let startSec = Int(seg.startTime) % 60
            let endMin = Int(seg.endTime) / 60
            let endSec = Int(seg.endTime) % 60
            timelineContent += String(format: "[%02d:%02d - %02d:%02d]  %@\n", startMin, startSec, endMin, endSec, seg.text)
        }
        
        do {
            try fullTranscript.write(to: txtURL, atomically: true, encoding: .utf8)
            try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
            try timelineContent.write(to: timelineURL, atomically: true, encoding: .utf8)
            
            print("\(ANSI.green)✓ 转译结果已自动保存至音频同级目录：\(ANSI.reset)")
            print("  \(ANSI.dim)1. 纯文本: \(ANSI.reset)\(txtURL.path)")
            print("  \(ANSI.dim)2. 标准字幕(SRT): \(ANSI.reset)\(srtURL.path)")
            print("  \(ANSI.dim)3. 时间轴对照: \(ANSI.reset)\(timelineURL.path)")
            print("")
        } catch {
            print("\(ANSI.red)✗ 保存转译文件失败: \(error.localizedDescription)\(ANSI.reset)\n")
        }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct TranscribeSegment {
    let index: Int
    let startTime: Double
    let endTime: Double
    let text: String
}

await ClawdHomeSpeechMain.main()
