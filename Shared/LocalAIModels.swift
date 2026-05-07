// Shared/LocalAIModels.swift
import Foundation

struct LocalServiceStatus: Codable {
    var isInstalled: Bool
    var isRunning: Bool
    var pid: Int32
    var currentModelId: String   // 空字符串表示未加载
    var port: Int
}

struct LocalModelInfo: Codable, Identifiable {
    var id: String            // 目录名，如 "mlx-community/Qwen2.5-7B-Instruct-4bit"
    var displayName: String
    var sizeGB: Double        // 目录大小，0 = 未下载
    var isDownloaded: Bool
    var isManual: Bool        // true = 用户手动放入目录
}

struct LocalAudioStatus: Codable {
    var isInstalled: Bool
    var ttsRunning: Bool
    var sttRunning: Bool
    var ttsPid: Int32
    var sttPid: Int32
}

// MARK: - 精选本地模型（内置列表）
struct CuratedLocalModel: Identifiable {
    var id: String            // HuggingFace repo id，如 "mlx-community/Qwen2.5-7B-Instruct-4bit"
    var displayName: String
    var estimatedSizeGB: Double
    var description: String
}

let curatedLLMModels: [CuratedLocalModel] = [
    CuratedLocalModel(
        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
        displayName: "Qwen2.5 7B（推荐）",
        estimatedSizeGB: 4.5,
        description: "均衡型，中英双语，代码能力强"
    ),
    CuratedLocalModel(
        id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
        displayName: "Qwen2.5 3B（轻量）",
        estimatedSizeGB: 2.0,
        description: "内存占用小，速度快，8GB 机器首选"
    ),
    CuratedLocalModel(
        id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
        displayName: "Llama 3.2 3B",
        estimatedSizeGB: 1.8,
        description: "Meta 轻量旗舰，英文为主"
    ),
]

let curatedTTSModels: [CuratedLocalModel] = [
    CuratedLocalModel(
        id: "mlx-community/Qwen3-TTS-0.6B-MLX",
        displayName: "Qwen3-TTS 0.6B（快速）",
        estimatedSizeGB: 1.0,
        description: "响应快，拟真度高"
    ),
    CuratedLocalModel(
        id: "mlx-community/Qwen3-TTS-1.7B-MLX",
        displayName: "Qwen3-TTS 1.7B（高质量）",
        estimatedSizeGB: 2.5,
        description: "音质更自然，需更多内存"
    ),
]

let curatedSTTModels: [CuratedLocalModel] = [
    CuratedLocalModel(
        id: "mlx-community/whisper-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        estimatedSizeGB: 1.5,
        description: "飞快，多语言，推荐首选"
    ),
]
