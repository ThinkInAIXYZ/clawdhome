// swift-tools-version: 6.0

import PackageDescription

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
            sources: ["main.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
