// swift-tools-version: 6.0

import PackageDescription
import Foundation

// 自动在解析阶段生成 GeneratedVersion.swift 以防止直接编译时报错
let versionFilePath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("GeneratedVersion.swift").path
if !FileManager.default.fileExists(atPath: versionFilePath) {
    let fallbackContent = """
    // Auto-generated fallback for initial checkout — do not edit
    let kSpeechVersion = "1.1.0-dev"
    let kSpeechBuildTime = "Unknown"
    """
    try? fallbackContent.write(toFile: versionFilePath, atomically: true, encoding: .utf8)
}

let package = Package(
    name: "ClawdHomeSpeech",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "ClawdHomeSpeech",
            targets: ["ClawdHomeSpeech"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.15"),
    ],
    targets: [
        .executableTarget(
            name: "ClawdHomeSpeech",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            path: ".",
            exclude: ["Package.swift"],
            sources: ["main.swift", "GeneratedVersion.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
