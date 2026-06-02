// ClawdHome/Services/SpeechHistoryStore.swift
// 语音转写历史存储（目录拆分 + 物理双发 TXT + 智能估算时间轴 SRT，应用侧）

import Foundation

// 保留此私有结构体以供老数据反序列化与迁移使用
private struct SpeechHistoryFile: Codable {
    var version: Int = 1
    var items: [SpeechHistoryRecord] = []
}

// 轻量元数据模型，排除庞大的转写全文
private struct SpeechHistoryMetadata: Codable {
    var id: UUID
    var createdAt: Date
    var sourceFilePath: String
    var sourceFileName: String
    var sourceFileSizeBytes: Int64
    var durationSeconds: Double?
    var engineID: String
    var modelID: SpeechModelID
    var modelDisplayName: String
    var languageHintOrDetectedLanguage: String?
    var elapsedSeconds: Double
    var status: SpeechHistoryStatus
    var errorSummary: String?

    // 【新增】AI 智能润色元数据，用于左侧极速列表渲染与过滤
    var refinedTitle: String?
    var refinedSummary: String?
    var refinedTags: [String]?
    var vocalEnhanceEnabled: Bool?
}

private struct SpeechHistoryMetadataFile: Codable {
    var version: Int = 1
    var items: [SpeechHistoryMetadata] = []
}

final class SpeechHistoryStore {
    private let fileURL: URL // 保留作为旧文件路径与迁移锚点
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // 新的目录拆分存储路径
    private let baseDirectory: URL
    private let metadataURL: URL
    private let detailsDirectory: URL

    init(fileURL: URL = SpeechHistoryStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 自动计算新的分布式存储结构路径
        let base = fileURL.deletingLastPathComponent().appendingPathComponent("speech_transcription", isDirectory: true)
        self.baseDirectory = base
        self.metadataURL = base.appendingPathComponent("history-metadata.json")
        self.detailsDirectory = base.appendingPathComponent("records", isDirectory: true)

        // 自动检测老数据并执行无缝分拆迁移
        migrateIfNeeded()
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("ClawdHome", isDirectory: true)
            .appendingPathComponent("speech-history.json")
    }

    // 智能推导详情文件的路径（基于 yyyyMMdd_HHmmss_<UUID>）
    private func detailFileURL(for id: UUID, createdAt: Date, ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = formatter.string(from: createdAt)
        return detailsDirectory.appendingPathComponent("\(dateString)_\(id.uuidString).\(ext)")
    }

    // 自动检测老数据并迁移到分布式存储格式
    private func migrateIfNeeded() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        // 尝试解析旧格式文件
        guard let data = try? Data(contentsOf: fileURL),
              let oldFile = try? decoder.decode(SpeechHistoryFile.self, from: data)
        else {
            return
        }

        // 保证详情目标子目录存在
        try? fileManager.createDirectory(
            at: detailsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var metadatas: [SpeechHistoryMetadata] = []

        for item in oldFile.items {
            // 1. 保存纯文本 .txt
            let txtURL = detailFileURL(for: item.id, createdAt: item.createdAt, ext: "txt")
            try? item.transcriptText.write(to: txtURL, atomically: true, encoding: .utf8)

            // 2. 自动生成并保存带时间轴的 .srt
            let duration = item.durationSeconds ?? (Double(item.transcriptText.count) * 0.25)
            let srtContent = SpeechHistoryStore.generateSRT(from: item.transcriptText, duration: duration)
            let srtURL = detailFileURL(for: item.id, createdAt: item.createdAt, ext: "srt")
            try? srtContent.write(to: srtURL, atomically: true, encoding: .utf8)

            // 3. 抽取轻量元数据信息
            let meta = SpeechHistoryMetadata(
                id: item.id,
                createdAt: item.createdAt,
                sourceFilePath: item.sourceFilePath,
                sourceFileName: item.sourceFileName,
                sourceFileSizeBytes: item.sourceFileSizeBytes,
                durationSeconds: item.durationSeconds,
                engineID: item.engineID,
                modelID: item.modelID,
                modelDisplayName: item.modelDisplayName,
                languageHintOrDetectedLanguage: item.languageHintOrDetectedLanguage,
                elapsedSeconds: item.elapsedSeconds,
                status: item.status,
                errorSummary: item.errorSummary,
                refinedTitle: item.refinedTitle,
                refinedSummary: item.refinedSummary,
                refinedTags: item.refinedTags,
                vocalEnhanceEnabled: item.vocalEnhanceEnabled
            )
            metadatas.append(meta)
        }

        // 3. 写入轻量元数据索引文件
        let payload = SpeechHistoryMetadataFile(items: sortedMetasNewestFirst(metadatas))
        if let metadataData = try? encoder.encode(payload) {
            try? fileManager.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? metadataData.write(to: metadataURL, options: .atomic)
        }

        // 4. 重命名原单 JSON 文件备份为 speech-history.json.bak
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("json.bak")
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }

    // 加载历史列表：直接读取对应的纯文本 .txt，拥有顶级 I/O 效率且 100% 契合原有 API
    func load() -> [SpeechHistoryRecord] {
        let metadatas = loadMetadataList()
        return metadatas.map { meta in
            let txtURL = detailFileURL(for: meta.id, createdAt: meta.createdAt, ext: "txt")
            let text = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""

            let refinedURL = detailFileURL(for: meta.id, createdAt: meta.createdAt, ext: "refined.txt")
            let refined = try? String(contentsOf: refinedURL, encoding: .utf8)

            return SpeechHistoryRecord(
                id: meta.id,
                createdAt: meta.createdAt,
                sourceFilePath: meta.sourceFilePath,
                sourceFileName: meta.sourceFileName,
                sourceFileSizeBytes: meta.sourceFileSizeBytes,
                durationSeconds: meta.durationSeconds,
                engineID: meta.engineID,
                modelID: meta.modelID,
                modelDisplayName: meta.modelDisplayName,
                languageHintOrDetectedLanguage: meta.languageHintOrDetectedLanguage,
                transcriptText: text,
                refinedText: refined,
                refinedTitle: meta.refinedTitle,
                refinedSummary: meta.refinedSummary,
                refinedTags: meta.refinedTags,
                elapsedSeconds: meta.elapsedSeconds,
                status: meta.status,
                errorSummary: meta.errorSummary,
                vocalEnhanceEnabled: meta.vocalEnhanceEnabled
            )
        }
    }

    // 保存：常数级 O(1) 物理双写 TXT + SRT 机制
    func save(_ item: SpeechHistoryRecord) {
        // 1. 确保目录环境存在
        try? fileManager.createDirectory(
            at: detailsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // 2. 双发保存 —— (A) 直接写入 UTF-8 纯文本 .txt 文件
        let txtURL = detailFileURL(for: item.id, createdAt: item.createdAt, ext: "txt")
        try? item.transcriptText.write(to: txtURL, atomically: true, encoding: .utf8)

        // 【新增】保存 AI 智能精装稿到 _refined.txt 物理文件
        if let refined = item.refinedText, !refined.isEmpty {
            let refinedURL = detailFileURL(for: item.id, createdAt: item.createdAt, ext: "refined.txt")
            try? refined.write(to: refinedURL, atomically: true, encoding: .utf8)
        }

        // 3. 双发保存 —— (B) 自动分句估算时间戳并写入 .srt 字幕文件
        let duration = item.durationSeconds ?? (Double(item.transcriptText.count) * 0.25)
        let srtContent = Self.generateSRT(from: item.transcriptText, duration: duration)
        let srtURL = detailFileURL(for: item.id, createdAt: item.createdAt, ext: "srt")
        try? srtContent.write(to: srtURL, atomically: true, encoding: .utf8)

        // 4. 抽取新生成的轻量元数据信息
        let newMeta = SpeechHistoryMetadata(
            id: item.id,
            createdAt: item.createdAt,
            sourceFilePath: item.sourceFilePath,
            sourceFileName: item.sourceFileName,
            sourceFileSizeBytes: item.sourceFileSizeBytes,
            durationSeconds: item.durationSeconds,
            engineID: item.engineID,
            modelID: item.modelID,
            modelDisplayName: modelDisplayName(for: item.modelID),
            languageHintOrDetectedLanguage: item.languageHintOrDetectedLanguage,
            elapsedSeconds: item.elapsedSeconds,
            status: item.status,
            errorSummary: item.errorSummary,
            refinedTitle: item.refinedTitle,
            refinedSummary: item.refinedSummary,
            refinedTags: item.refinedTags,
            vocalEnhanceEnabled: item.vocalEnhanceEnabled
        )

        // 5. 更新元数据索引列表
        var metadatas = loadMetadataList()
        if let index = metadatas.firstIndex(where: { $0.id == item.id }) {
            metadatas[index] = newMeta
        } else {
            metadatas.append(newMeta)
        }

        writeMetadata(metadatas)
    }

    private func modelDisplayName(for modelID: SpeechModelID) -> String {
        switch modelID {
        case .qwen3ASR17B8Bit: return "Qwen3-ASR 1.7B 8-bit"
        case .qwen3ASR06B: return "Qwen3-ASR 0.6B"
        }
    }

    // 删除：独立移除对应的两个物理文件与索引登记
    func delete(id: UUID) {
        // 先从当前的元数据列表中查找该 ID 以获取对应的创建时间，从而精确定位文件名
        let metadatas = loadMetadataList()
        if let target = metadatas.first(where: { $0.id == id }) {
            // 1. 同时移除对应的 .txt 和 .srt 物理详情文件
            let txtURL = detailFileURL(for: target.id, createdAt: target.createdAt, ext: "txt")
            let srtURL = detailFileURL(for: target.id, createdAt: target.createdAt, ext: "srt")
            let refinedURL = detailFileURL(for: target.id, createdAt: target.createdAt, ext: "refined.txt")
            try? fileManager.removeItem(at: txtURL)
            try? fileManager.removeItem(at: srtURL)
            try? fileManager.removeItem(at: refinedURL)
        }

        // 2. 更新轻量元数据索引
        let filtered = metadatas.filter { $0.id != id }
        writeMetadata(filtered)
    }

    // MARK: - 智能时间轴字幕 SRT 生成核心算法

    static func generateSRT(from text: String, duration: Double) -> String {
        guard !text.isEmpty, duration > 0 else { return "" }

        let sentences = readableSubtitleLines(from: text)

        // 兜底：如果标点拆分失败，则整段作为单条字幕输出
        guard !sentences.isEmpty else {
            return "1\n00:00:00,000 --> \(formatSRTTime(duration))\n\(text)\n"
        }

        // 计算总字符数量
        let totalChars = sentences.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return "" }

        var srtContent = ""
        var currentProgress: Double = 0.0

        for (index, sentence) in sentences.enumerated() {
            // 按照字符长度在总字符中的比例估算句子显示的时长
            let sentenceDuration = (Double(sentence.count) / Double(totalChars)) * duration
            let start = currentProgress
            let end = min(start + sentenceDuration, duration)

            let startStr = formatSRTTime(start)
            let endStr = formatSRTTime(end)

            srtContent += "\(index + 1)\n"
            srtContent += "\(startStr) --> \(endStr)\n"
            srtContent += "\(sentence)\n\n"

            currentProgress = end
        }

        return srtContent
    }

    private static func readableSubtitleLines(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "。,，！？!?\n；;、")
        let fragments = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return [] }

        let minChars = 8
        let maxChars = 24
        var lines: [String] = []
        var current = ""

        for fragment in fragments {
            if current.isEmpty {
                current = fragment
                continue
            }

            let merged = current + fragment
            if current.count < minChars || merged.count <= maxChars {
                current = merged
            } else {
                lines.append(current)
                current = fragment
            }
        }

        if !current.isEmpty {
            if current.count < minChars, !lines.isEmpty {
                lines[lines.count - 1] += current
            } else {
                lines.append(current)
            }
        }

        return lines
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let s = (totalMs / 1000) % 60
        let m = (totalMs / 60000) % 60
        let h = totalMs / 3600000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - 辅助支撑方法

    private func loadMetadataList() -> [SpeechHistoryMetadata] {
        guard let data = try? Data(contentsOf: metadataURL),
              let file = try? decoder.decode(SpeechHistoryMetadataFile.self, from: data)
        else {
            return []
        }
        return sortedMetasNewestFirst(file.items)
    }

    private func writeMetadata(_ items: [SpeechHistoryMetadata]) {
        let payload = SpeechHistoryMetadataFile(items: sortedMetasNewestFirst(items))
        guard let data = try? encoder.encode(payload) else { return }

        try? fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func sortedMetasNewestFirst(_ items: [SpeechHistoryMetadata]) -> [SpeechHistoryMetadata] {
        items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
