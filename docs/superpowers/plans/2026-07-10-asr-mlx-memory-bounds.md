# ASR MLX Memory Bounds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound and reclaim MLX recycling-cache memory during Qwen3-ASR long-audio transcription without changing model inputs, decoding parameters, or transcript output.

**Architecture:** Put deterministic cache sizing and progress payload types in `ClawdHomeSpeechCore`, then add a focused `ClawdHomeSpeechRuntime` target that adapts those types to MLX's process-wide `Memory` API. Configure the cache before every model load, reclaim after model loading and every chunk, and emit post-reclamation snapshots through backward-compatible JSON progress fields.

**Tech Stack:** Swift 6, Swift Package Manager, MLX Swift 0.31.3, speech-swift 0.0.15, XCTest, AVFoundation, macOS 15+ for the standalone speech tool.

## Global Constraints

- Keep Qwen3-ASR 1.7B 8-bit, 16 kHz input, 30-second chunks, 2-second overlap, greedy decoding, and `maxTokens = 1024` unchanged.
- Do not fork or patch `speech-swift`.
- Do not add user-visible settings, UI, or localized strings.
- The main `ClawdHome` app remains macOS 14 compatible and must not link MLX; only the macOS 15+ `ClawdHomeSpeech` package may link it.
- The MLX cache limit is `clamp(physicalMemoryBytes / 32, 256 MiB, 1 GiB)`.
- Memory telemetry is optional JSON metadata and must never make a successful transcription fail.
- Preserve unrelated dirty-worktree changes. Stage only files named in the current task.
- Code comments and Makefile help text remain Chinese; git commit summaries remain English.

---

### Task 1: Deterministic memory policy and snapshot types

**Files:**
- Create: `ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechInferenceMemoryPolicy.swift`
- Create: `ClawdHomeSpeech/Tests/ClawdHomeSpeechCoreTests/SpeechInferenceMemoryPolicyTests.swift`

**Interfaces:**
- Consumes: `physicalMemoryBytes: UInt64` from `ProcessInfo.processInfo.physicalMemory`.
- Produces: `SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes:) -> Int` and `SpeechInferenceMemorySnapshot` for the runtime controller and progress payload.

- [ ] **Step 1: Write the failing policy tests**

Create `SpeechInferenceMemoryPolicyTests.swift`:

```swift
import XCTest
@testable import ClawdHomeSpeechCore

final class SpeechInferenceMemoryPolicyTests: XCTestCase {
    private let mib: UInt64 = 1024 * 1024
    private let gib: UInt64 = 1024 * 1024 * 1024

    func testCacheLimitUsesMinimumForMissingOrSmallMemory() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 0),
            256 * Int(mib)
        )
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 4 * gib),
            256 * Int(mib)
        )
    }

    func testCacheLimitScalesForSixteenGigabytes() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 16 * gib),
            512 * Int(mib)
        )
    }

    func testCacheLimitCapsAtOneGibibyte() {
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 32 * gib),
            Int(gib)
        )
        XCTAssertEqual(
            SpeechInferenceMemoryPolicy.cacheLimitBytes(forPhysicalMemoryBytes: 64 * gib),
            Int(gib)
        )
    }

    func testSnapshotKeepsByteCountsExactly() {
        let snapshot = SpeechInferenceMemorySnapshot(
            activeMemoryBytes: 11,
            cacheMemoryBytes: 22,
            peakMemoryBytes: 33,
            cacheLimitBytes: 44
        )

        XCTAssertEqual(snapshot.activeMemoryBytes, 11)
        XCTAssertEqual(snapshot.cacheMemoryBytes, 22)
        XCTAssertEqual(snapshot.peakMemoryBytes, 33)
        XCTAssertEqual(snapshot.cacheLimitBytes, 44)
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechInferenceMemoryPolicyTests
```

Expected: compilation fails because `SpeechInferenceMemoryPolicy` and `SpeechInferenceMemorySnapshot` do not exist.

- [ ] **Step 3: Implement the minimal policy and snapshot**

Create `SpeechInferenceMemoryPolicy.swift`:

```swift
import Foundation

public enum SpeechInferenceMemoryPolicy {
    public static let minimumCacheLimitBytes = 256 * 1024 * 1024
    public static let maximumCacheLimitBytes = 1024 * 1024 * 1024

    public static func cacheLimitBytes(forPhysicalMemoryBytes physicalMemoryBytes: UInt64) -> Int {
        let scaled = physicalMemoryBytes / 32
        let minimum = UInt64(minimumCacheLimitBytes)
        let maximum = UInt64(maximumCacheLimitBytes)
        return Int(min(max(scaled, minimum), maximum))
    }
}

public struct SpeechInferenceMemorySnapshot: Equatable, Sendable {
    public let activeMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let peakMemoryBytes: Int
    public let cacheLimitBytes: Int

    public init(
        activeMemoryBytes: Int,
        cacheMemoryBytes: Int,
        peakMemoryBytes: Int,
        cacheLimitBytes: Int
    ) {
        self.activeMemoryBytes = activeMemoryBytes
        self.cacheMemoryBytes = cacheMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.cacheLimitBytes = cacheLimitBytes
    }
}
```

- [ ] **Step 4: Run the policy tests and verify GREEN**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechInferenceMemoryPolicyTests
```

Expected: four tests pass.

- [ ] **Step 5: Commit the policy**

```bash
git add ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechInferenceMemoryPolicy.swift ClawdHomeSpeech/Tests/ClawdHomeSpeechCoreTests/SpeechInferenceMemoryPolicyTests.swift
git commit -m "feat(speech): add bounded MLX memory policy"
```

---

### Task 2: Testable MLX memory controller

**Files:**
- Modify: `ClawdHomeSpeech/Package.swift`
- Create: `ClawdHomeSpeech/Sources/ClawdHomeSpeechRuntime/SpeechMLXMemoryController.swift`
- Create: `ClawdHomeSpeech/Tests/ClawdHomeSpeechRuntimeTests/SpeechMLXMemoryControllerTests.swift`

**Interfaces:**
- Consumes: `SpeechInferenceMemoryPolicy` and `SpeechInferenceMemorySnapshot` from Task 1; MLX `Memory.cacheLimit`, `Memory.clearCache()`, `Memory.activeMemory`, `Memory.cacheMemory`, and `Memory.peakMemory`.
- Produces: `SpeechMLXMemoryBackend`, `LiveSpeechMLXMemoryBackend`, and `SpeechMLXMemoryController.configure()`, `reclaim()`, and `runReclaiming(_:)`.

- [ ] **Step 1: Add package target scaffolding**

Update `ClawdHomeSpeech/Package.swift` so its dependencies and targets contain these exact additions:

```swift
dependencies: [
    .package(url: "https://github.com/soniqo/speech-swift.git", from: "0.0.15"),
    .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
],
```

Add `"ClawdHomeSpeechRuntime"` to the executable dependencies and add the runtime/test targets:

```swift
.target(
    name: "ClawdHomeSpeechRuntime",
    dependencies: [
        "ClawdHomeSpeechCore",
        .product(name: "MLX", package: "mlx-swift"),
    ],
    path: "Sources/ClawdHomeSpeechRuntime"
),
```

```swift
.testTarget(
    name: "ClawdHomeSpeechRuntimeTests",
    dependencies: ["ClawdHomeSpeechRuntime"],
    path: "Tests/ClawdHomeSpeechRuntimeTests"
),
```

This step is package scaffolding only; it must not introduce runtime behavior.

- [ ] **Step 2: Write the failing controller tests**

Create `SpeechMLXMemoryControllerTests.swift`:

```swift
import XCTest
@testable import ClawdHomeSpeechRuntime

final class SpeechMLXMemoryControllerTests: XCTestCase {
    private final class FakeBackend: SpeechMLXMemoryBackend {
        var activeMemoryBytes = 100
        var cacheMemoryBytes = 200
        var peakMemoryBytes = 300
        var events: [String] = []
        var cacheLimitBytes = 0 {
            didSet { events.append("limit:\(cacheLimitBytes)") }
        }

        func clearCache() {
            events.append("clear")
            cacheMemoryBytes = 0
        }
    }

    private enum TestError: Error {
        case failed
    }

    func testConfigureSetsLimitBeforeClearingAndReturnsSnapshot() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        let snapshot = controller.configure()

        XCTAssertEqual(backend.events, ["limit:536870912", "clear"])
        XCTAssertEqual(snapshot.activeMemoryBytes, 100)
        XCTAssertEqual(snapshot.cacheMemoryBytes, 0)
        XCTAssertEqual(snapshot.peakMemoryBytes, 300)
        XCTAssertEqual(snapshot.cacheLimitBytes, 536870912)
    }

    func testRunReclaimingReturnsValueAndPostClearSnapshot() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        let result = controller.runReclaiming { "transcript" }

        XCTAssertEqual(result.value, "transcript")
        XCTAssertEqual(result.snapshot.cacheMemoryBytes, 0)
        XCTAssertEqual(backend.events, ["clear"])
    }

    func testRunReclaimingClearsWhenOperationThrows() {
        let backend = FakeBackend()
        let controller = SpeechMLXMemoryController(
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            backend: backend
        )

        XCTAssertThrowsError(
            try controller.runReclaiming { () throws -> String in
                throw TestError.failed
            }
        )
        XCTAssertEqual(backend.events, ["clear"])
    }
}
```

- [ ] **Step 3: Run the controller tests and verify RED**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechMLXMemoryControllerTests
```

Expected: compilation fails because the runtime controller types do not exist.

- [ ] **Step 4: Implement the MLX backend and controller**

Create `SpeechMLXMemoryController.swift`:

```swift
import ClawdHomeSpeechCore
import Foundation
import MLX

public protocol SpeechMLXMemoryBackend: AnyObject {
    var activeMemoryBytes: Int { get }
    var cacheMemoryBytes: Int { get }
    var peakMemoryBytes: Int { get }
    var cacheLimitBytes: Int { get set }
    func clearCache()
}

public final class LiveSpeechMLXMemoryBackend: SpeechMLXMemoryBackend {
    public init() {}

    public var activeMemoryBytes: Int { Memory.activeMemory }
    public var cacheMemoryBytes: Int { Memory.cacheMemory }
    public var peakMemoryBytes: Int { Memory.peakMemory }

    public var cacheLimitBytes: Int {
        get { Memory.cacheLimit }
        set { Memory.cacheLimit = newValue }
    }

    public func clearCache() {
        Memory.clearCache()
    }
}

public final class SpeechMLXMemoryController {
    private let backend: any SpeechMLXMemoryBackend
    public let configuredCacheLimitBytes: Int

    public convenience init(physicalMemoryBytes: UInt64) {
        self.init(
            physicalMemoryBytes: physicalMemoryBytes,
            backend: LiveSpeechMLXMemoryBackend()
        )
    }

    public init(
        physicalMemoryBytes: UInt64,
        backend: any SpeechMLXMemoryBackend
    ) {
        self.backend = backend
        self.configuredCacheLimitBytes = SpeechInferenceMemoryPolicy.cacheLimitBytes(
            forPhysicalMemoryBytes: physicalMemoryBytes
        )
    }

    @discardableResult
    public func configure() -> SpeechInferenceMemorySnapshot {
        backend.cacheLimitBytes = configuredCacheLimitBytes
        backend.clearCache()
        return snapshot()
    }

    @discardableResult
    public func reclaim() -> SpeechInferenceMemorySnapshot {
        backend.clearCache()
        return snapshot()
    }

    public func runReclaiming<T>(
        _ operation: () throws -> T
    ) rethrows -> (value: T, snapshot: SpeechInferenceMemorySnapshot) {
        do {
            let value = try operation()
            return (value, reclaim())
        } catch {
            reclaim()
            throw error
        }
    }

    private func snapshot() -> SpeechInferenceMemorySnapshot {
        SpeechInferenceMemorySnapshot(
            activeMemoryBytes: backend.activeMemoryBytes,
            cacheMemoryBytes: backend.cacheMemoryBytes,
            peakMemoryBytes: backend.peakMemoryBytes,
            cacheLimitBytes: configuredCacheLimitBytes
        )
    }
}
```

- [ ] **Step 5: Run the controller and full speech-package tests**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechMLXMemoryControllerTests
swift test --package-path ClawdHomeSpeech
```

Expected: controller tests pass, followed by all speech-package tests passing.

- [ ] **Step 6: Commit the runtime controller**

```bash
git add ClawdHomeSpeech/Package.swift ClawdHomeSpeech/Package.resolved ClawdHomeSpeech/Sources/ClawdHomeSpeechRuntime/SpeechMLXMemoryController.swift ClawdHomeSpeech/Tests/ClawdHomeSpeechRuntimeTests/SpeechMLXMemoryControllerTests.swift
git commit -m "feat(speech): control MLX cache lifecycle"
```

---

### Task 3: Backward-compatible memory telemetry

**Files:**
- Create: `ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechToolProgressResponse.swift`
- Create: `ClawdHomeSpeech/Tests/ClawdHomeSpeechCoreTests/SpeechToolProgressResponseTests.swift`
- Modify: `ClawdHomeSpeech/main.swift:69-92`
- Modify: `ClawdHome/Services/SpeechToolOutputParser.swift:3-25`
- Modify: `tests/ClawdHomeAppXCTests/SpeechFeatureTests.swift:574-581`

**Interfaces:**
- Consumes: `SpeechInferenceMemorySnapshot` from Task 1.
- Produces: `SpeechToolProgressResponse` JSON fields `mlxActiveMemoryBytes`, `mlxCacheMemoryBytes`, `mlxPeakMemoryBytes`, and `mlxCacheLimitBytes`; matching optional fields on app-side `SpeechToolProgressEvent`.

- [ ] **Step 1: Write the failing core payload test**

Create `SpeechToolProgressResponseTests.swift`:

```swift
import Foundation
import XCTest
@testable import ClawdHomeSpeechCore

final class SpeechToolProgressResponseTests: XCTestCase {
    func testEncodesFlatMLXMemoryFields() throws {
        let response = SpeechToolProgressResponse(
            kind: "progress",
            command: "transcribe",
            fractionCompleted: 0.5,
            message: "half",
            transcriptDelta: "text",
            memorySnapshot: SpeechInferenceMemorySnapshot(
                activeMemoryBytes: 11,
                cacheMemoryBytes: 22,
                peakMemoryBytes: 33,
                cacheLimitBytes: 44
            )
        )

        let data = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["mlxActiveMemoryBytes"] as? Int, 11)
        XCTAssertEqual(json["mlxCacheMemoryBytes"] as? Int, 22)
        XCTAssertEqual(json["mlxPeakMemoryBytes"] as? Int, 33)
        XCTAssertEqual(json["mlxCacheLimitBytes"] as? Int, 44)
        XCTAssertEqual(json["transcriptDelta"] as? String, "text")
    }
}
```

- [ ] **Step 2: Run the core payload test and verify RED**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechToolProgressResponseTests
```

Expected: compilation fails because `SpeechToolProgressResponse` does not exist.

- [ ] **Step 3: Implement the progress response in the core target**

Create `SpeechToolProgressResponse.swift`:

```swift
import Foundation

public struct SpeechToolProgressResponse: Codable, Sendable {
    public let kind: String
    public let command: String
    public let fractionCompleted: Double
    public let message: String
    public let transcript: String?
    public let transcriptDelta: String?
    public let mlxActiveMemoryBytes: Int?
    public let mlxCacheMemoryBytes: Int?
    public let mlxPeakMemoryBytes: Int?
    public let mlxCacheLimitBytes: Int?

    public init(
        kind: String,
        command: String,
        fractionCompleted: Double,
        message: String,
        transcript: String? = nil,
        transcriptDelta: String? = nil,
        memorySnapshot: SpeechInferenceMemorySnapshot? = nil
    ) {
        self.kind = kind
        self.command = command
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.transcript = transcript
        self.transcriptDelta = transcriptDelta
        self.mlxActiveMemoryBytes = memorySnapshot?.activeMemoryBytes
        self.mlxCacheMemoryBytes = memorySnapshot?.cacheMemoryBytes
        self.mlxPeakMemoryBytes = memorySnapshot?.peakMemoryBytes
        self.mlxCacheLimitBytes = memorySnapshot?.cacheLimitBytes
    }
}
```

Delete the private `ProgressResponse` declaration from `ClawdHomeSpeech/main.swift` and replace every `ProgressResponse(` call with `SpeechToolProgressResponse(`.

- [ ] **Step 4: Run the core payload test and verify GREEN**

Run:

```bash
swift test --package-path ClawdHomeSpeech --filter SpeechToolProgressResponseTests
```

Expected: the payload test passes.

- [ ] **Step 5: Write the failing app parser test**

Add this test next to `testTranscriptionProgressEventDecodesPartialTranscript`:

```swift
func testTranscriptionProgressEventDecodesMLXMemoryTelemetry() {
    let progressLine = #"{"command":"transcribe","fractionCompleted":0.5,"kind":"progress","message":"已转写 50%","transcriptDelta":"文本","mlxActiveMemoryBytes":11,"mlxCacheMemoryBytes":22,"mlxPeakMemoryBytes":33,"mlxCacheLimitBytes":44}"#

    let progress = SpeechToolOutputParser.progressEvent(from: progressLine)

    XCTAssertEqual(progress?.transcriptDelta, "文本")
    XCTAssertEqual(progress?.mlxActiveMemoryBytes, 11)
    XCTAssertEqual(progress?.mlxCacheMemoryBytes, 22)
    XCTAssertEqual(progress?.mlxPeakMemoryBytes, 33)
    XCTAssertEqual(progress?.mlxCacheLimitBytes, 44)
}
```

- [ ] **Step 6: Run the app parser test and verify RED**

Run:

```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeAppTests -destination 'platform=macOS' -only-testing:ClawdHomeAppTests/SpeechFeatureTests/testTranscriptionProgressEventDecodesMLXMemoryTelemetry test
```

Expected: compilation fails because `SpeechToolProgressEvent` has no MLX memory properties.

- [ ] **Step 7: Add optional memory fields to the app event**

Extend `SpeechToolProgressEvent` with:

```swift
let mlxActiveMemoryBytes: Int?
let mlxCacheMemoryBytes: Int?
let mlxPeakMemoryBytes: Int?
let mlxCacheLimitBytes: Int?
```

Extend its initializer with defaulted arguments and assignments:

```swift
mlxActiveMemoryBytes: Int? = nil,
mlxCacheMemoryBytes: Int? = nil,
mlxPeakMemoryBytes: Int? = nil,
mlxCacheLimitBytes: Int? = nil
```

```swift
self.mlxActiveMemoryBytes = mlxActiveMemoryBytes
self.mlxCacheMemoryBytes = mlxCacheMemoryBytes
self.mlxPeakMemoryBytes = mlxPeakMemoryBytes
self.mlxCacheLimitBytes = mlxCacheLimitBytes
```

- [ ] **Step 8: Run parser and speech-package tests**

Run:

```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeAppTests -destination 'platform=macOS' -only-testing:ClawdHomeAppTests/SpeechFeatureTests/testTranscriptionProgressEventDecodesMLXMemoryTelemetry test
swift test --package-path ClawdHomeSpeech
```

Expected: the parser test and all speech-package tests pass.

- [ ] **Step 9: Commit telemetry contracts**

```bash
git add ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechToolProgressResponse.swift ClawdHomeSpeech/Tests/ClawdHomeSpeechCoreTests/SpeechToolProgressResponseTests.swift ClawdHomeSpeech/main.swift ClawdHome/Services/SpeechToolOutputParser.swift tests/ClawdHomeAppXCTests/SpeechFeatureTests.swift
git commit -m "feat(speech): report MLX memory telemetry"
```

---

### Task 4: Apply bounded memory lifecycle to every Qwen3-ASR path

**Files:**
- Modify: `ClawdHomeSpeech/main.swift:254-395, 423-624, 830-1045`
- Modify: `scripts/build-speech-tool.sh:108-119`
- Modify: `project.yml:101-108`
- Modify: `ClawdHome.xcodeproj/project.pbxproj:1223-1229`

**Interfaces:**
- Consumes: `SpeechMLXMemoryController` from Task 2 and `SpeechToolProgressResponse(memorySnapshot:)` from Task 3.
- Produces: bounded model-load and per-chunk cache behavior in interactive download, interactive transcription, silent `prepare-model`, and silent `transcribe`.

- [ ] **Step 1: Capture a baseline binary and quality fixture before integration edits**

Run:

```bash
mkdir -p /tmp/clawdhome-asr-baseline
cp /Applications/ClawdHome.app/Contents/Library/Executables/ClawdHomeSpeech /tmp/clawdhome-asr-baseline/ClawdHomeSpeech
cp /Applications/ClawdHome.app/Contents/Library/Executables/mlx.metallib /tmp/clawdhome-asr-baseline/mlx.metallib
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -ss 0 -t 65 -i '/Users/jerry/Downloads/高梦康.m4a' -ac 1 -ar 16000 -c:a pcm_f32le /tmp/clawdhome-asr-quality-fixture.wav
```

Expected: baseline executable, adjacent metallib, and a 65-second WAV fixture exist under `/tmp`.

- [ ] **Step 2: Import the tested runtime and centralize one controller per process**

Add the import:

```swift
import ClawdHomeSpeechRuntime
```

Inside `ClawdHomeSpeechMain`, add:

```swift
private static let memoryController = SpeechMLXMemoryController(
    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
)
```

- [ ] **Step 3: Configure and reclaim around all four model-loading paths**

Immediately before each `Qwen3ASRModel.fromPretrained` call in `interactiveDownload`, `interactiveTranscribe`, `prepareModel`, and silent `transcribe`, insert:

```swift
_ = memoryController.configure()
defer { memoryController.reclaim() }
```

Immediately after each successful model load, reclaim loader buffers:

```swift
let modelLoadMemory = memoryController.reclaim()
```

For paths that discard the loaded model, use `_ = memoryController.reclaim()` instead of introducing an unused `modelLoadMemory` constant.

In silent `prepareModel`, emit a final post-load event:

```swift
try? writeProgress(
    SpeechToolProgressResponse(
        kind: "progress",
        command: "prepare-model",
        fractionCompleted: 1.0,
        message: "Ready",
        memorySnapshot: modelLoadMemory
    )
)
```

In silent `transcribe`, emit the corresponding model-ready event:

```swift
try? writeProgress(
    SpeechToolProgressResponse(
        kind: "progress",
        command: "load-model",
        fractionCompleted: 1.0,
        message: "Ready",
        memorySnapshot: modelLoadMemory
    )
)
```

- [ ] **Step 4: Reclaim after every interactive transcription chunk**

Replace each interactive `model.transcribe(...)` expression with the controller wrapper while keeping every argument unchanged:

```swift
let inference = memoryController.runReclaiming {
    model.transcribe(
        audio: chunk.samples,
        sampleRate: modelSampleRate,
        language: nil,
        maxTokens: 1024
    )
}
let chunkText = inference.value.trimmingCharacters(in: .whitespacesAndNewlines)
```

For the short interactive branch, assign `transcript = inference.value.trimmingCharacters(...)`. Do not change chunk construction, overlap, or transcript joining.

- [ ] **Step 5: Reclaim and attach telemetry after every silent transcription chunk**

In the short branch, declare:

```swift
var lastMemorySnapshot: SpeechInferenceMemorySnapshot?
```

Wrap inference:

```swift
let inference = memoryController.runReclaiming {
    model.transcribe(
        audio: samples,
        sampleRate: modelSampleRate,
        language: language,
        maxTokens: 1024
    )
}
singleTranscript = inference.value
lastMemorySnapshot = inference.snapshot
```

Attach `memorySnapshot: lastMemorySnapshot` to the short branch's 100% progress response.

In the long branch, wrap the unchanged inference call:

```swift
let inference = memoryController.runReclaiming {
    model.transcribe(
        audio: samples,
        sampleRate: modelSampleRate,
        language: language,
        maxTokens: 1024
    )
}
let chunkText = inference.value
```

Attach `memorySnapshot: inference.snapshot` to that chunk's completed progress response.

- [ ] **Step 6: Add new source files to build invalidation inputs**

Add these three paths to `compute_build_fingerprint()` in `scripts/build-speech-tool.sh`:

```bash
"ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechInferenceMemoryPolicy.swift" \
"ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechToolProgressResponse.swift" \
"ClawdHomeSpeech/Sources/ClawdHomeSpeechRuntime/SpeechMLXMemoryController.swift" \
```

Add the same paths, prefixed with `$(SRCROOT)/`, to the speech post-build script `inputFiles` in `project.yml` and `ClawdHome.xcodeproj/project.pbxproj`. Do not regenerate or rewrite unrelated project sections.

- [ ] **Step 7: Run package tests and build the release speech tool**

Run:

```bash
swift test --package-path ClawdHomeSpeech
make build-speech
```

Expected: all package tests pass; `build/Executables/ClawdHomeSpeech` and `build/Executables/mlx.metallib` are produced.

- [ ] **Step 8: Run the relevant app parser tests**

Run:

```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeAppTests -destination 'platform=macOS' -only-testing:ClawdHomeAppTests/SpeechFeatureTests/testTranscriptionProgressEventDecodesPartialTranscript -only-testing:ClawdHomeAppTests/SpeechFeatureTests/testTranscriptionProgressEventDecodesMLXMemoryTelemetry test
```

Expected: both tests pass.

- [ ] **Step 9: Commit lifecycle integration without staging unrelated dirty hunks**

```bash
git add ClawdHomeSpeech/main.swift scripts/build-speech-tool.sh
git add -p project.yml ClawdHome.xcodeproj/project.pbxproj
git commit -m "fix(speech): bound MLX memory across audio chunks"
```

For the interactive `git add -p`, stage only the three new `ClawdHomeSpeech` input paths from Step 6. Split or edit a combined hunk so the pre-existing Privacy Filter additions remain unstaged.

---

### Task 5: Quality and long-audio memory verification

**Files:**
- Verify only; no repository files are modified.
- Runtime artifacts: `/tmp/clawdhome-asr-baseline`, `/tmp/clawdhome-asr-quality-fixture.wav`, `/tmp/clawdhome-asr-*.json`, and `/tmp/clawdhome-asr-*.jsonl`.

**Interfaces:**
- Consumes: baseline executable from Task 4 Step 1 and optimized executable from Task 4 Step 8.
- Produces: exact transcript comparison plus long-run telemetry proving cache bounds and memory plateau.

- [ ] **Step 1: Transcribe the quality fixture with baseline and optimized binaries**

Run:

```bash
/tmp/clawdhome-asr-baseline/ClawdHomeSpeech transcribe --file /tmp/clawdhome-asr-quality-fixture.wav --model-id qwen3-asr-1.7b-8bit --cache-dir '/Users/jerry/Library/Caches/ClawdHome/SpeechModels/qwen3-asr/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit' --language zh > /tmp/clawdhome-asr-baseline.json 2> /tmp/clawdhome-asr-baseline-progress.jsonl
build/Executables/ClawdHomeSpeech transcribe --file /tmp/clawdhome-asr-quality-fixture.wav --model-id qwen3-asr-1.7b-8bit --cache-dir '/Users/jerry/Library/Caches/ClawdHome/SpeechModels/qwen3-asr/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit' --language zh > /tmp/clawdhome-asr-optimized.json 2> /tmp/clawdhome-asr-optimized-progress.jsonl
tail -n 1 /tmp/clawdhome-asr-baseline.json | /opt/homebrew/bin/jq -r '.transcript' > /tmp/clawdhome-asr-baseline.txt
tail -n 1 /tmp/clawdhome-asr-optimized.json | /opt/homebrew/bin/jq -r '.transcript' > /tmp/clawdhome-asr-optimized.txt
cmp /tmp/clawdhome-asr-baseline.txt /tmp/clawdhome-asr-optimized.txt
```

Expected: `cmp` exits 0, proving identical transcript output for the same model, PCM input, and language hint.

- [ ] **Step 2: Verify optimized progress events contain bounded post-chunk snapshots**

Run:

```bash
/opt/homebrew/bin/jq -s '[.[] | select(.command == "transcribe" and .mlxCacheMemoryBytes != null)] | {events:length,maxCache:(map(.mlxCacheMemoryBytes)|max),limit:.[0].mlxCacheLimitBytes}' /tmp/clawdhome-asr-optimized-progress.jsonl
```

Expected: at least three completed-chunk events; `maxCache` is less than or equal to `limit`.

- [ ] **Step 3: Run the optimized tool on the full long recording**

Run:

```bash
build/Executables/ClawdHomeSpeech transcribe --file '/Users/jerry/Downloads/高梦康.m4a' --model-id qwen3-asr-1.7b-8bit --cache-dir '/Users/jerry/Library/Caches/ClawdHome/SpeechModels/qwen3-asr/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit' --language zh > /tmp/clawdhome-asr-long.json 2> /tmp/clawdhome-asr-long-progress.jsonl
```

Expected: command exits 0 and final JSON reports `ok: true`.

- [ ] **Step 4: Calculate the 25%-to-75% memory plateau**

Run:

```bash
/opt/homebrew/bin/jq -s '
  [.[] | select(.command == "transcribe" and .mlxActiveMemoryBytes != null)] as $m
  | ($m | map(select(.fractionCompleted >= 0.25)) | first) as $q1
  | ($m | map(select(.fractionCompleted >= 0.75)) | first) as $q3
  | {
      events: ($m | length),
      q1Bytes: ($q1.mlxActiveMemoryBytes + $q1.mlxCacheMemoryBytes),
      q3Bytes: ($q3.mlxActiveMemoryBytes + $q3.mlxCacheMemoryBytes),
      growthRatio: (($q3.mlxActiveMemoryBytes + $q3.mlxCacheMemoryBytes) / ($q1.mlxActiveMemoryBytes + $q1.mlxCacheMemoryBytes)),
      maxPostChunkCache: ($m | map(.mlxCacheMemoryBytes) | max),
      cacheLimit: $m[0].mlxCacheLimitBytes
    }
' /tmp/clawdhome-asr-long-progress.jsonl
```

Expected: `growthRatio <= 1.10` and `maxPostChunkCache <= cacheLimit`.

- [ ] **Step 5: Run the full verification suite**

Run:

```bash
swift test --package-path ClawdHomeSpeech
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeAppTests -destination 'platform=macOS' -only-testing:ClawdHomeAppTests/SpeechFeatureTests test
make build-speech
git diff --check
git status --short
```

Expected: tests and build pass; `git diff --check` is clean; only pre-existing unrelated worktree changes remain unstaged.

- [ ] **Step 6: Review final diff against the approved design**

Run:

```bash
git diff 40f87db..HEAD -- ClawdHomeSpeech ClawdHome/Services/SpeechToolOutputParser.swift tests/ClawdHomeAppXCTests/SpeechFeatureTests.swift scripts/build-speech-tool.sh project.yml ClawdHome.xcodeproj/project.pbxproj
```

Expected: the diff contains only cache policy, controller, telemetry, lifecycle wiring, tests, and build-input tracking; it contains no model, chunking, overlap, language, or `maxTokens` changes.
