// swift-tools-version: 6.0

import Foundation
import PackageDescription

let enableONNXRuntime = ProcessInfo.processInfo.environment["CLAWDHOME_PRIVACY_FILTER_DISABLE_ONNX"] != "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
]

var targetDependencies: [Target.Dependency] = [
    .product(name: "HuggingFace", package: "swift-huggingface"),
    .product(name: "Tokenizers", package: "swift-transformers"),
]

if enableONNXRuntime {
    packageDependencies.append(
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2")
    )
    targetDependencies.append(
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
    )
}

let versionFilePath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("GeneratedVersion.swift").path
if !FileManager.default.fileExists(atPath: versionFilePath) {
    let fallbackContent = """
    // Auto-generated fallback for initial checkout - do not edit
    let kPrivacyFilterVersion = "1.1.0-dev"
    let kPrivacyFilterBuildTime = "Unknown"
    """
    try? fallbackContent.write(toFile: versionFilePath, atomically: true, encoding: .utf8)
}

let package = Package(
    name: "ClawdHomePrivacyFilter",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ClawdHomePrivacyFilter", targets: ["ClawdHomePrivacyFilter"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "ClawdHomePrivacyFilter",
            dependencies: targetDependencies,
            path: ".",
            exclude: ["Package.swift"],
            sources: ["main.swift", "GeneratedVersion.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
