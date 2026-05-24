# Speech Transcription Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an AI Lab audio-file transcription feature backed by `speech-swift` on Apple Silicon/macOS 15+ while preserving Intel/macOS 14 compatibility through a dual-track build.

**Architecture:** Keep `ClawdHome` as the compatibility-preserving app target, isolate `speech-swift` imports in a standalone Apple-Silicon-only Swift package executable, and let the app call that bundled tool through a service layer with runtime availability detection. Persist transcript history in app storage, keep model cache in `~/Library/Caches/ClawdHome/SpeechModels`, and surface the feature through a capability-aware AI Lab entry.

**Tech Stack:** SwiftUI, Swift 5.9 app target + Swift 6 standalone tool package, XcodeGen/project.yml, nested SPM package (`speech-swift`), Foundation/AppKit/AVFoundation, local JSON persistence, repository `L10n` + `Stable.xcstrings`.

---

## File Structure

### Build graph and packaging

- Modify: `project.yml`
  - Add a post-build script that builds and embeds the standalone speech tool only for arm64 app slices.
  - Keep the main `ClawdHome` target on `macOS 14`.
- Add: `ClawdHomeSpeech/Package.swift`
  - Own the standalone `speech-swift` dependency graph for the bundled tool.
- Add: `scripts/build-speech-tool.sh`
  - Build `ClawdHomeSpeech` with `swift build` and copy it into `Contents/Library/Executables` when supported.
- Modify: `ClawdHome.xcodeproj/project.pbxproj`
  - Regenerated output after `xcodegen generate`.

### App-side speech models and services

- Create: `ClawdHome/Models/SpeechTranscriptionModels.swift`
  - Shared app-side task state, history record, capability status, model recommendation data.
- Create: `ClawdHome/Services/SpeechModelAdvisor.swift`
  - Memory/disk/runtime heuristic rules.
- Create: `ClawdHome/Services/SpeechHistoryStore.swift`
  - JSON persistence for transcript history.
- Create: `ClawdHome/Services/SpeechTranscriptionService.swift`
  - App-facing service protocol, orchestration, copy/export helpers, supported/unavailable backend selection.

### Speech execution tool

- Add: `ClawdHomeSpeech/Package.swift`
- Modify: `ClawdHomeSpeech/main.swift`
  - Real `speech-swift` integration for `arm64` + `macOS 15+`, including probe, model preparation, and transcription commands.

### UI integration

- Modify: `ClawdHome/Views/AILabView.swift`
  - Replace coming-soon speech card with capability-aware entry.
- Create: `ClawdHome/Views/SpeechTranscriptionView.swift`
  - Main tool UI.
- Create: `ClawdHome/Views/SpeechHistoryList.swift`
  - Focused history/result list rendering if extraction improves clarity.
- Modify: `ClawdHome/ClawdHomeApp.swift`
  - Inject any shared speech stores/services if needed at app scope.

### Localization

- Modify: `ClawdHome/Stable.xcstrings`
  - Add all new Chinese and English UI strings.

### Tests

- Create: `tests/SpeechModelAdvisorTests.swift`
  - Rule-based recommendation tests.
- Create: `tests/SpeechHistoryStoreTests.swift`
  - Persistence, ordering, and delete tests.
- Create: `tests/SpeechExportFormattingTests.swift`
  - TXT/Markdown export formatting tests.

---

## Chunk 1: Build Graph and Availability Boundary

### Task 1: Add the speech package and standalone tool build

**Files:**
- Modify: `project.yml`
- Add: `ClawdHomeSpeech/Package.swift`
- Add: `scripts/build-speech-tool.sh`
- Modify: `ClawdHome.xcodeproj/project.pbxproj`

- [ ] **Step 1: Edit `project.yml` to call a standalone speech-tool build script instead of linking `speech-swift` into the app graph**

Implementation notes:
- Keep `speech-swift` out of the main Xcode project dependency graph.
- Add a standalone `ClawdHomeSpeech` Swift package with deployment target `macOS 15`.
- Build that package through `swift build --arch arm64`.
- Embed the resulting executable into `Contents/Library/Executables/ClawdHomeSpeech` only when the app slice includes `arm64`.
- Explicitly skip and clean up the bundled tool for `x86_64` builds.
- Keep `ClawdHome` target itself on `deploymentTarget: "14.0"`.

- [ ] **Step 2: Regenerate the Xcode project**

Run:
```bash
xcodegen generate
```

Expected:
- Project regenerates without schema errors.

- [ ] **Step 3: Inspect the regenerated diff**

Run:
```bash
git diff -- project.yml ClawdHome.xcodeproj/project.pbxproj
```

Expected:
- Only expected package/target/build-setting changes appear.

- [ ] **Step 4: Build both supported and unsupported paths explicitly**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHome -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHome -configuration Debug -destination 'platform=macOS,arch=x86_64' build
```

Expected:
- The arm64 build bundles the speech tool successfully.
- The x86_64 build succeeds and explicitly skips bundling the speech tool.

- [ ] **Step 5: Commit the build graph change**

```bash
git add project.yml ClawdHome.xcodeproj/project.pbxproj
git commit -m "build: add isolated speech target"
```

### Task 2: Define the app-side availability boundary

**Files:**
- Create: `ClawdHome/Models/SpeechTranscriptionModels.swift`
- Create: `ClawdHome/Services/SpeechTranscriptionService.swift`
- Test: `tests/ClawdHomeAppTests/SpeechModelAdvisorTests.swift`

- [ ] **Step 1: Keep unsupported fallback in the app-side service, not in the arm64-only tool**

Implementation notes:
- Capability detection must stay in app-side code so Intel/macOS 14 builds compile and show a stable unavailable state.
- The standalone tool should only contain supported-path execution logic.

- [ ] **Step 2: Verify unsupported files compile through the main app path**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHome -configuration Debug -destination 'platform=macOS,arch=x86_64' build
```

Expected:
- Unsupported path compiles cleanly and the bundle does not contain `ClawdHomeSpeech`.

---

## Chunk 2: App-Side Models, Recommendations, and History

### Task 3: Add shared speech models

**Files:**
- Create: `ClawdHome/Models/SpeechTranscriptionModels.swift`

- [ ] **Step 1: Define task/capability/history/model structs**

Implementation notes:
- Include lightweight Codable types for history persistence.
- Keep UI-facing enums stable and narrow.
- Separate raw backend model identifiers from display strings.

- [ ] **Step 2: Build to validate app model integration**

Run:
```bash
make build
```

Expected:
- New models compile without cross-target dependency issues.

- [ ] **Step 3: Commit the shared models**

```bash
git add ClawdHome/Models/SpeechTranscriptionModels.swift
git commit -m "feat: add speech transcription models"
```

### Task 4: Implement model recommendation rules first with tests

**Files:**
- Create: `ClawdHome/Services/SpeechModelAdvisor.swift`
- Create: `tests/SpeechModelAdvisorTests.swift`

- [ ] **Step 1: Write failing tests for recommendation rules**

Test cases:
- Adequate memory and disk recommends `1.7B`.
- Low available memory recommends `0.6B`.
- Running local AI service downgrades or warns.
- Unsupported hardware produces unavailable status.

- [ ] **Step 2: Run the targeted test entry to verify failure**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- New tests fail initially or are not yet wired because implementation is missing.

- [ ] **Step 3: Implement `SpeechModelAdvisor` minimally to satisfy the rules**

Implementation notes:
- Use deterministic thresholds.
- Keep thresholds centralized and documented.
- Do not reach into SwiftUI.

- [ ] **Step 4: Re-run targeted tests**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- Recommendation tests pass, or compile failures point to target wiring that should be fixed before proceeding.

- [ ] **Step 5: Commit recommendation logic**

```bash
git add ClawdHome/Services/SpeechModelAdvisor.swift tests/SpeechModelAdvisorTests.swift
git commit -m "feat: add speech model advisor"
```

### Task 5: Implement history storage with tests

**Files:**
- Create: `ClawdHome/Services/SpeechHistoryStore.swift`
- Create: `tests/SpeechHistoryStoreTests.swift`

- [ ] **Step 1: Write failing persistence tests**

Test cases:
- Save and reload preserves transcript text and metadata.
- Records sort newest first.
- Delete removes only the targeted item.
- Missing source file path does not corrupt history load.

- [ ] **Step 2: Run tests to confirm failure**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- Tests fail before store implementation exists.

- [ ] **Step 3: Implement `SpeechHistoryStore`**

Implementation notes:
- Use `~/Library/Application Support/ClawdHome/speech-history.json`.
- Use atomic writes.
- Keep load failure handling explicit.

- [ ] **Step 4: Re-run tests**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- History tests pass.

- [ ] **Step 5: Commit history storage**

```bash
git add ClawdHome/Services/SpeechHistoryStore.swift tests/SpeechHistoryStoreTests.swift
git commit -m "feat: add speech history store"
```

### Task 6: Implement export formatting with tests

**Files:**
- Modify: `ClawdHome/Services/SpeechTranscriptionService.swift`
- Create: `tests/SpeechExportFormattingTests.swift`

- [ ] **Step 1: Write failing tests for TXT and Markdown formatting**

Test cases:
- TXT export contains transcript only.
- Markdown export contains file metadata, model, elapsed time, and transcript.

- [ ] **Step 2: Run tests to verify failure**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- Export tests fail before implementation exists.

- [ ] **Step 3: Implement pure formatting helpers in the service layer**

Implementation notes:
- Keep formatting pure and testable.
- UI file-save panels should stay outside the formatter itself.

- [ ] **Step 4: Re-run tests**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
```

Expected:
- Export formatting tests pass.

- [ ] **Step 5: Commit export helpers**

```bash
git add tests/SpeechExportFormattingTests.swift ClawdHome/Services/SpeechTranscriptionService.swift
git commit -m "feat: add speech export formatting"
```

---

## Chunk 3: Supported Backend and App Service Orchestration

### Task 7: Implement the Apple-Silicon-only backend

**Files:**
- Create: `ClawdHomeSpeech/SupportedSpeechBackend.swift`
- Create: `ClawdHomeSpeech/AudioFileDecoder.swift`

- [ ] **Step 1: Add the audio decode/resample path**

Implementation notes:
- Decode imported files with platform APIs such as AVFoundation.
- Normalize to the sample format expected by `Qwen3ASR`.
- Keep decoder logic separate from model execution.

- [ ] **Step 2: Implement the real `speech-swift` backend**

Implementation notes:
- Use `cacheDir:` pointing at `~/Library/Caches/ClawdHome/SpeechModels/qwen3-asr/`.
- Handle model download/readiness checks.
- Keep error mapping explicit.

- [ ] **Step 3: Validate the supported build path**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHome -destination "platform=macOS" -configuration Debug build
```

Expected:
- Apple-Silicon/macOS-15-capable environment builds the real speech backend target.

- [ ] **Step 4: Commit the supported backend**

```bash
git add ClawdHomeSpeech/SupportedSpeechBackend.swift ClawdHomeSpeech/AudioFileDecoder.swift
git commit -m "feat: add supported speech backend"
```

### Task 8: Implement the app-facing transcription service

**Files:**
- Create: `ClawdHome/Services/SpeechTranscriptionService.swift`

- [ ] **Step 1: Wire the app-facing service to the backend abstraction**

Implementation notes:
- Resolve supported vs unavailable backend based on compile/runtime gates.
- Expose observable task state for SwiftUI.
- Keep cancellation ownership here, not in the view.

- [ ] **Step 2: Add history writes and copy/export integration points**

Implementation notes:
- Save completed, failed, and cancelled records through `SpeechHistoryStore`.
- Expose helper methods for copy/export actions.

- [ ] **Step 3: Build to validate orchestration**

Run:
```bash
make build
```

Expected:
- The service compiles and does not leak speech-target imports into the wrong build path.

- [ ] **Step 4: Commit the orchestration layer**

```bash
git add ClawdHome/Services/SpeechTranscriptionService.swift
git commit -m "feat: add speech transcription service"
```

---

## Chunk 4: AI Lab UI and Localization

### Task 9: Build the speech transcription UI

**Files:**
- Create: `ClawdHome/Views/SpeechTranscriptionView.swift`
- Create: `ClawdHome/Views/SpeechHistoryList.swift`
- Modify: `ClawdHome/ClawdHomeApp.swift`

- [ ] **Step 1: Build the dedicated speech transcription view skeleton**

Implementation notes:
- Top status section
- Import/execution section
- Result section
- History section

- [ ] **Step 2: Inject service/store dependencies**

Implementation notes:
- Prefer app-level environment injection only if the state should survive navigation naturally.
- Avoid over-globalizing transient per-tool state if a local `@State` owner is enough.

- [ ] **Step 3: Verify the view compiles**

Run:
```bash
make build
```

Expected:
- View compiles cleanly with placeholder wiring.

- [ ] **Step 4: Commit the base UI**

```bash
git add ClawdHome/Views/SpeechTranscriptionView.swift ClawdHome/Views/SpeechHistoryList.swift ClawdHome/ClawdHomeApp.swift
git commit -m "feat: add speech transcription view"
```

### Task 10: Wire AI Lab entry and unsupported-platform UX

**Files:**
- Modify: `ClawdHome/Views/AILabView.swift`

- [ ] **Step 1: Replace the static speech card with a capability-aware entry**

Implementation notes:
- Supported: open the full speech UI.
- Unsupported: show a reason string such as Intel CPU or macOS version too low.

- [ ] **Step 2: Build and manually inspect card state behavior**

Run:
```bash
make build
```

Expected:
- AI Lab builds and the speech card is no longer hard-coded as coming soon.

- [ ] **Step 3: Commit AI Lab wiring**

```bash
git add ClawdHome/Views/AILabView.swift
git commit -m "feat: wire ai lab speech entry"
```

### Task 11: Add localization strings

**Files:**
- Modify: `ClawdHome/Stable.xcstrings`

- [ ] **Step 1: Add all speech UI keys with both Chinese and English translations**

Implementation notes:
- Keep English labels short per repository rules.
- Use real English text, not title-cased keys.

- [ ] **Step 2: Run localization checks**

Run:
```bash
make i18n-check
```

Expected:
- No missing keys.
- No placeholder-English failures.

- [ ] **Step 3: Commit localization updates**

```bash
git add ClawdHome/Stable.xcstrings
git commit -m "i18n: add speech transcription strings"
```

---

## Chunk 5: Verification and Integration Hardening

### Task 12: Run end-to-end validation on both tracks

**Files:**
- Modify as needed based on findings: `project.yml`, `ClawdHome/Services/SpeechTranscriptionService.swift`, `ClawdHomeSpeech/*`, `ClawdHome/Views/SpeechTranscriptionView.swift`

- [ ] **Step 1: Validate the unsupported path**

Run:
```bash
make build
```

Expected:
- Broad compatibility build still succeeds.
- Unsupported environments show explanatory UI, not broken controls.

- [ ] **Step 2: Validate the supported path with a small audio file**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHome -destination "platform=macOS" -configuration Debug build
```

Manual check:
- Download model on supported machine.
- Transcribe a small file.
- Copy output.
- Export TXT and Markdown.
- Delete or move the source file, then confirm history is still readable.

- [ ] **Step 3: Run tests and i18n checks**

Run:
```bash
xcodebuild -project ClawdHome.xcodeproj -scheme ClawdHomeHelperTests -destination "platform=macOS" test
make i18n-check
```

Expected:
- New logic tests pass.
- i18n checks pass.

- [ ] **Step 4: Fix issues discovered during validation**

Implementation notes:
- Keep fixes scoped to the touched files.
- Preserve the dual-track boundary.

- [ ] **Step 5: Commit validation fixes**

```bash
git add project.yml ClawdHome ClawdHomeSpeech tests ClawdHome.xcodeproj/project.pbxproj
git commit -m "fix: harden speech transcription integration"
```

### Task 13: Final review and ship-ready verification

**Files:**
- Review-only across the speech feature change set

- [ ] **Step 1: Review the final diff for boundary violations**

Checklist:
- Main app target still supports macOS 14.
- No direct `speech-swift` imports leak into unsupported targets.
- No helper/XPC changes were introduced accidentally.
- No raw audio copies are persisted.

- [ ] **Step 2: Run final build once more**

Run:
```bash
make build
```

Expected:
- Final build succeeds on the compatibility path.

- [ ] **Step 3: Commit any last cleanup if needed**

```bash
git add -A
git commit -m "chore: finalize speech transcription feature"
```
