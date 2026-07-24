import XCTest
@testable import ClawdHome

final class PrivacyFilterEngineTests: XCTestCase {
    func testDefaultSemanticModelRootDirectoryUsesApplicationSupport() {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)

        XCTAssertTrue(engine.semanticModelDirectory.path.contains("/Library/Application Support/ClawdHome/PrivacyFilterModels"))
        XCTAssertFalse(engine.semanticModelDirectory.path.contains("local-semantic"))
        XCTAssertFalse(engine.semanticModelDirectory.path.contains("/Library/Caches/"))
    }

    func testOpenAIPrivacyFilterQ4IsDefaultSemanticModel() {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)

        XCTAssertEqual(engine.selectedSemanticModel, .openAIPrivacyFilterQ4)
        XCTAssertTrue(engine.selectedSemanticModelDirectory.path.contains("openai-privacy-filter-q4"))
    }

    func testOnlyOpenAIQ4IsExposedAsInstallableSemanticModel() {
        XCTAssertEqual(PrivacySemanticModel.allCases, [.openAIPrivacyFilterQ4])
    }

    func testNativePipelineRedactsSecretsWithoutRemovingKeyName() async {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let text = "password=my_super_secret_123 token=abc_def_ghi_123456"

        let spans = await engine.analyze(text: text, engineType: .native)
        let redacted = engine.redact(text: text, spans: spans)

        XCTAssertTrue(redacted.contains("password="))
        XCTAssertTrue(redacted.contains("token="))
        XCTAssertFalse(redacted.contains("my_super_secret_123"))
        XCTAssertFalse(redacted.contains("abc_def_ghi_123456"))
    }

    func testOpenAIQ4ModeReturnsEmptyWhenModelUnavailable() async {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let text = "请联系 13912345678 或 security@example.com，API Key 是 sk-proj-a1B2c3D4e5F6g7H8i9J0k1L2M3N4O5P6q7R8s9T0u1V2w3X4。"

        let spans = await engine.analyze(text: text, engineType: .semanticLocal)

        XCTAssertTrue(spans.isEmpty)
    }

    func testOpenAIQ4ModeDoesNotCascadeAppleRuleDetections() async throws {
        let tempDir = try makeTemporaryDirectory()
        let toolURL = try makeFakePrivacyTool(in: tempDir)
        let engine = PrivacyFilterEngine(semanticRuntime: .tool(toolURL), modelBaseDirectory: tempDir.appendingPathComponent("PrivacyModels", isDirectory: true))
        engine.selectedSemanticModel = .openAIPrivacyFilterQ4
        engine.isRealModelReady = true

        let text = "My email is harry.potter@hogwarts.edu and my phone is 13912345678."
        let spans = await engine.analyze(text: text, engineType: .semanticLocal)

        XCTAssertTrue(spans.contains { $0.type == .email && $0.text == "harry.potter@hogwarts.edu" })
        XCTAssertFalse(spans.contains { $0.type == .phone && $0.text == "13912345678" })
    }

    func testRepeatedEntityReusesPlaceholder() async {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let text = "发送到 alpha@example.com，备用邮箱 alpha@example.com。"

        let spans = await engine.analyze(text: text, engineType: .native)
        let emailSpans = spans.filter { $0.type == .email }

        XCTAssertEqual(emailSpans.count, 2)
        XCTAssertEqual(Set(emailSpans.map(\.placeholder)).count, 1)
    }

    func testRedactionHandlesEmojiBeforeSensitiveSpan() async {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let text = "🔐 邮箱 alpha@example.com"

        let spans = await engine.analyze(text: text, engineType: .native)
        let redacted = engine.redact(text: text, spans: spans)

        XCTAssertEqual(redacted, "🔐 邮箱 {{EMAIL_1}}")
    }

    func testRestoreRehydratesLLMOutputFromLocalMapping() async {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let text = "请联系 alpha@example.com 或 13912345678。"

        let spans = await engine.analyze(text: text, engineType: .native)
        let mapping = engine.redactionMapping(from: spans)
        let llmOutput = "建议联系 {{EMAIL_1}}，紧急情况拨打 {{PHONE_1}}。"
        let restored = engine.restore(text: llmOutput, mappings: mapping)

        XCTAssertEqual(restored, "建议联系 alpha@example.com，紧急情况拨打 13912345678。")
    }

    func testRestoreDoesNotRehydrateIgnoredSpans() {
        let engine = PrivacyFilterEngine(semanticRuntime: .disabledForTests)
        let spans = [
            PrivacySpan(
                text: "alpha@example.com",
                type: .email,
                startOffset: 0,
                endOffset: 17,
                confidence: 0.95,
                placeholder: "{{EMAIL_1}}",
                isIgnored: true
            )
        ]

        let mapping = engine.redactionMapping(from: spans)
        let restored = engine.restore(text: "联系 {{EMAIL_1}}", mappings: mapping)

        XCTAssertTrue(mapping.isEmpty)
        XCTAssertEqual(restored, "联系 {{EMAIL_1}}")
    }

    func testPrepareOpenAIPrivacyFilterQ4InvokesStandaloneOnnxInstaller() async throws {
        let tempDir = try makeTemporaryDirectory()
        let toolURL = try makeFakePrivacyTool(in: tempDir)
        let modelDir = tempDir.appendingPathComponent("PrivacyModels", isDirectory: true)
        let engine = PrivacyFilterEngine(semanticRuntime: .tool(toolURL), modelBaseDirectory: modelDir)
        engine.selectedSemanticModel = .openAIPrivacyFilterQ4

        await engine.prepareSemanticModel()

        XCTAssertTrue(engine.isSemanticModelReady)
        let args = try String(contentsOf: tempDir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("prepare-onnx-model"))
        XCTAssertTrue(args.contains("--model-id"))
        XCTAssertTrue(args.contains("openai-privacy-filter-q4"))
        XCTAssertTrue(args.contains("--cache-dir"))
        XCTAssertTrue(args.contains(modelDir.appendingPathComponent("openai-privacy-filter-q4").path))
        XCTAssertTrue(args.contains("--progress-file"))
    }

    func testForcePrepareSemanticModelPassesForceFlag() async throws {
        let tempDir = try makeTemporaryDirectory()
        let toolURL = try makeFakePrivacyTool(in: tempDir)
        let modelDir = tempDir.appendingPathComponent("PrivacyModels", isDirectory: true)
        let engine = PrivacyFilterEngine(semanticRuntime: .tool(toolURL), modelBaseDirectory: modelDir)
        engine.selectedSemanticModel = .openAIPrivacyFilterQ4

        await engine.prepareSemanticModel(force: true)

        XCTAssertTrue(engine.isSemanticModelReady)
        let args = try String(contentsOf: tempDir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--force"))
        XCTAssertTrue(args.contains("--progress-file"))
    }

    func testOpenAIPrivacyFilterQ4AnalyzeInvokesStandaloneToolWithQ4ModelID() async throws {
        let tempDir = try makeTemporaryDirectory()
        let toolURL = try makeFakePrivacyTool(in: tempDir)
        let engine = PrivacyFilterEngine(semanticRuntime: .tool(toolURL), modelBaseDirectory: tempDir.appendingPathComponent("PrivacyModels", isDirectory: true))
        engine.selectedSemanticModel = .openAIPrivacyFilterQ4
        engine.isRealModelReady = true

        let text = "My email is harry.potter@hogwarts.edu"
        let spans = await engine.analyze(text: text, engineType: .semanticLocal)

        XCTAssertTrue(spans.contains { $0.type == .email && $0.text == "harry.potter@hogwarts.edu" })

        let args = try String(contentsOf: tempDir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("analyze"))
        XCTAssertTrue(args.contains("--model-id"))
        XCTAssertTrue(args.contains("openai-privacy-filter-q4"))
        XCTAssertTrue(args.contains("--cache-dir"))
        XCTAssertTrue(args.contains("openai-privacy-filter-q4"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivacyFilterEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFakePrivacyTool(in directory: URL) throws -> URL {
        let toolURL = directory.appendingPathComponent("fake-privacy-tool")
        let script = """
        #!/bin/sh
        printf "%s\\n" "$*" > "\(directory.path)/args.txt"
        cache_dir=""
        progress_file=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--cache-dir" ]; then
            shift
            cache_dir="$1"
          elif [ "$1" = "--progress-file" ]; then
            shift
            progress_file="$1"
          fi
          shift
        done
        if printf "%s\\n" "$(cat "\(directory.path)/args.txt")" | grep -q "prepare-onnx-model"; then
          mkdir -p "$cache_dir/onnx"
          /usr/bin/truncate -s 3039 "$cache_dir/config.json"
          /usr/bin/truncate -s 27868174 "$cache_dir/tokenizer.json"
          /usr/bin/truncate -s 234 "$cache_dir/tokenizer_config.json"
          /usr/bin/truncate -s 372 "$cache_dir/viterbi_calibration.json"
          /usr/bin/truncate -s 160219 "$cache_dir/onnx/model_q4.onnx"
          /usr/bin/truncate -s 917120144 "$cache_dir/onnx/model_q4.onnx_data"
          if [ -n "$progress_file" ]; then
            mkdir -p "$(dirname "$progress_file")"
            printf '{"modelID":"openai-privacy-filter-q4","status":"done","currentFile":null,"downloadedBytes":945152182,"totalBytes":945152182,"fileDownloadedBytes":0,"fileTotalBytes":0,"bytesPerSecond":0,"error":null}\\n' > "$progress_file"
          fi
          printf '{"ok":true,"command":"prepare-onnx-model","modelDirectory":"%s","modelID":"openai-privacy-filter-q4","dryRun":false,"requiredFiles":[],"totalBytes":0,"error":null}\\n' "$cache_dir"
          exit 0
        fi
        if printf "%s\\n" "$(cat "\(directory.path)/args.txt")" | grep -q "analyze"; then
          cat >/dev/null
          printf '{"ok":true,"command":"analyze","modelID":"openai-privacy-filter-q4","spans":[{"entity":"EMAIL","score":0.99,"word":"harry.potter@hogwarts.edu","start":12,"end":37}],"error":null}\\n'
          exit 0
        fi
        printf '{"ok":false,"command":"unknown","error":"unknown command"}\\n'
        exit 1
        """
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
        return toolURL
    }
}
