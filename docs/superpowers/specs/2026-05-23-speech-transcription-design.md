# Speech Transcription Design

**Date:** 2026-05-23

**Status:** Approved in chat, pending implementation plan

**Goal:** Add a local audio-file speech-to-text workflow under AI Lab using `soniqo/speech-swift`, with model recommendation, model caching, result history, copy/export actions, no raw audio duplication, and preserved compatibility for Intel/macOS 14 builds by isolating the feature behind a dual-track architecture.

## Summary

ClawdHome will add a new first-party speech transcription tool under AI Lab. Supported machines will import a local audio file, run on-device transcription with `speech-swift`, review the transcript in-app, copy it, export it, and revisit it later from history.

This feature is app-local in its first version. It does not run through the privileged helper because the workflow is user-initiated, does not require root operations, and does not benefit from XPC isolation. The app target will own UI state, model recommendation, transcript persistence, export, and runtime capability detection. The concrete `speech-swift` integration will live in a separate Apple-Silicon-only executable tool built via a standalone Swift package and embedded into the app bundle only for supported slices.

The main ClawdHome app must remain compatible with Intel/macOS 14. The speech feature will therefore use a dual-track build: a speech module that is compiled only for Apple Silicon on macOS 15+, and a fallback path that compiles everywhere else and exposes an unavailable state in the UI.

## External Constraints

- `speech-swift` currently requires `Swift 6+`, `Xcode 16+`, `macOS 15+`, and Apple Silicon.
- `speech-swift` supports custom model cache directories through Swift API `cacheDir:`.
- First implementation scope is **audio-file import only**.
- First implementation scope is **single-file, single-task transcription only**.
- First implementation scope does **not** include microphone recording, batch processing, timestamps, diarization, or background queue orchestration.
- The feature must refuse execution on unsupported hardware, with a clear user-facing message when the app is not running on Apple Silicon.

## Product Scope

### Included

- AI Lab entry for speech-to-text
- Dedicated speech transcription view
- Local file import for common audio formats
- On-device transcription using `speech-swift`
- Machine-based model recommendation
- Download and reuse of local models
- Transcript history
- Copy transcript
- Export transcript as `TXT`
- Export transcript as `Markdown`
- Delete history items
- Reveal original source file in Finder when still present
- Unsupported-platform fallback state in AI Lab

### Excluded

- Real-time dictation
- Microphone capture
- Multi-file queue
- Automatic summary or post-processing
- Audio waveform editing
- Audio copy into app-owned storage
- Cross-user shared model service
- Helper-managed STT daemon

## Architecture

The feature is split into five layers. Four are app-side product layers, and one is a platform-scoped execution tool.

### 0. Speech Capability Layer

This layer decides whether speech transcription is available in the current build and on the current machine.

Responsibilities:

- Build and embed a real speech tool only for `arm64` + `macOS 15+`
- Skip embedding the tool on unsupported slices such as `x86_64`
- Expose one app-facing service regardless of platform
- Report unavailability reason for unsupported builds and runtimes

Design notes:

- The main `ClawdHome` target must not directly `import Qwen3ASR`.
- The `speech-swift` dependency should be isolated behind a standalone Swift package executable, `ClawdHomeSpeech`, with deployment target `macOS 15`.
- Unsupported environments should still build cleanly and present the AI Lab entry in a disabled or explanatory state.

### 1. SpeechTranscriptionService

Owns the transcription lifecycle and is the single execution interface used by the UI.

Responsibilities:

- Load or create the selected STT model
- Decode imported audio into the sample format expected by the selected backend
- Point `speech-swift` at the ClawdHome-managed cache directory
- Validate preconditions before execution
- Start, cancel, and complete one transcription task
- Report status, elapsed time, and errors back to UI

Design notes:

- The service must hide the concrete speech backend from the view layer.
- First implementation uses `Qwen3ASR` through the Apple-Silicon-only speech tool.
- The service boundary must allow swapping to `ParakeetASR`, `OmnilingualASR`, or another backend later without redesigning AI Lab UI.

### 2. SpeechModelAdvisor

Owns recommendation logic for model selection and readiness messaging.

Responsibilities:

- Inspect machine constraints
- Recommend a default model
- Explain downgrade reasons in user-facing text
- Report whether download is needed
- Report whether current conditions look risky for a large model

Initial signal inputs:

- Physical memory
- Current memory pressure or available memory estimate
- Whether local AI services are already running
- Free disk space at the chosen cache path

The first implementation will use deterministic rules, not benchmarking.

### 3. SpeechHistoryStore

Owns persistence for transcript history.

Responsibilities:

- Save completed, failed, and cancelled records
- Load history on app launch or first view access
- Update ordering
- Delete records
- Supply exportable record data to the UI

### 4. SpeechTranscriptionView

Owns the AI Lab tool surface for users.

Responsibilities:

- File picking
- Status display
- Model recommendation display
- Download actions
- Start and cancel actions
- Result preview
- Copy and export actions
- History browsing

## Why This Stays in the App Target

This workflow does not require privilege separation. The user manually selects the file, the result is consumed in the same UI session, and the persisted history is app-level product state. Moving STT into the helper would add XPC payload design, progress bridging, model cache coordination, and runtime lifecycle complexity without delivering meaningful isolation or security value for this feature.

The helper remains the right place for system services and privileged state. This STT workflow is neither.

## Dependency Integration

The repository will add `speech-swift` through a standalone Swift package nested under `ClawdHomeSpeech/`, but it must not be linked directly into the main app target if that would force the whole app to adopt `macOS 15` or Apple-Silicon-only constraints.

Instead, the integration should be split as follows:

- `ClawdHome` main app target keeps its existing broad compatibility path
- A standalone Swift package executable, `ClawdHomeSpeech`, owns the concrete `speech-swift` imports
- `ClawdHomeSpeech` is built only for `arm64` and uses deployment target `macOS 15`
- A post-build script embeds `ClawdHomeSpeech` into the app bundle only when the built app slice includes `arm64`
- `ClawdHome` talks to that executable through a service façade and presents an unavailable state when the bundled tool is absent

Initial speech model module target:

- `Qwen3ASR`

Possible shared utility modules from the package may be linked only if required by the exact API surface during implementation. The implementation should not over-link unrelated speech modules.

## Model Strategy

### Default model preference

Preferred default:

- `Qwen3-ASR 1.7B 8-bit`

Fallback preference:

- `Qwen3-ASR 0.6B`

### Recommendation behavior

The app should recommend `1.7B 8-bit` when the machine looks healthy enough to run it without obvious memory pressure. It should recommend `0.6B` when conditions look constrained.

The UI must explain the reason, for example:

- Available memory is currently low
- Another local AI service is already running
- Disk space is below the recommended threshold

### Model state categories

Each visible model option should resolve into one of these states:

- Recommended and ready
- Recommended but not downloaded
- Available but not recommended
- Risky on this machine

The UI does not need a full model matrix in version one. It only needs a clear recommended option and a smaller fallback.

## Model Cache Location

ClawdHome will not use the package default shared cache path. The app will explicitly provide a ClawdHome-owned cache directory:

- `~/Library/Caches/ClawdHome/SpeechModels/`

Suggested engine subdirectory:

- `~/Library/Caches/ClawdHome/SpeechModels/qwen3-asr/`

Rationale:

- Model files are reproducible cache artifacts, not durable user documents.
- ClawdHome needs predictable ownership for status inspection, size accounting, cleanup, and offline checks.
- macOS cache semantics fit this data better than `Application Support`.
- A custom path avoids mixing ClawdHome-managed assets with unrelated tools.

## Transcript History Storage

History will be persisted in:

- `~/Library/Application Support/ClawdHome/speech-history.json`

Each record should include:

- `id`
- `createdAt`
- `sourceFilePath`
- `sourceFileName`
- `sourceFileSizeBytes`
- `durationSeconds`
- `engineID`
- `modelID`
- `modelDisplayName`
- `languageHintOrDetectedLanguage`
- `transcriptText`
- `elapsedSeconds`
- `status`
- `errorSummary`

The app will not duplicate raw source audio into app storage.

If the source file is later deleted, the history record remains valid for transcript viewing and export. Only file reveal actions should fail.

## UI Placement

The existing AI Lab "Speech to text" card becomes a capability-aware entry point.

- On supported builds and machines, it opens the dedicated speech transcription surface.
- On unsupported builds or runtimes, it opens a lightweight explanatory state or disabled card detail that clearly says the feature requires Apple Silicon and macOS 15+.

The dedicated view should contain four sections.

### Top status section

Shows:

- Current engine name
- Recommended model
- Machine assessment
- Model availability state
- Download action when needed

### Import and execution section

Shows:

- Import audio button
- Selected file metadata
- Start transcription button
- Cancel button while running
- Running status and elapsed time

### Result section

Shows:

- Transcript output
- Copy action
- Export TXT action
- Export Markdown action

### History section

Shows:

- Reverse-chronological transcript records
- File name
- Timestamp
- Model used
- Elapsed time
- Completion state

Selecting a history item should reveal the full transcript and reuse the same copy/export actions.

## User Flow

1. User opens AI Lab.
2. User enters the speech transcription tool.
3. The app computes machine readiness and recommended model.
4. If speech is unavailable on this machine or build, the app explains why and exits the flow.
5. If the recommended model is not cached, the user downloads it.
6. The user imports an audio file.
7. The user starts transcription.
8. The app shows running state and allows cancellation.
9. The result appears in the transcript area.
10. The app writes a history entry.
11. The user copies or exports the result.

## File Handling

The tool will accept common audio file formats supported by the platform and by the chosen decoder path during implementation.

Imported files must be normalized into the input representation required by the selected STT backend, including any needed decode, channel conversion, and sample-rate conversion.

Validation must happen before transcription begins:

- File exists
- File is readable
- File extension or UTType is allowed
- Duration and file size are sane enough for v1 execution constraints

The implementation should prefer clear early rejection over late model execution failure.

## Export Behavior

### TXT export

Exports transcript text only.

### Markdown export

Exports:

- Title
- Source file name
- Source path
- Export time
- Model name
- Elapsed time
- Transcript body

Export uses `NSSavePanel`. The app does not auto-save on completion.

## Failure Handling

The feature must explicitly handle these cases.

### Model not downloaded

- Prevent transcription start
- Present download action

### Unsupported platform

- Compile a fallback implementation instead of the real backend
- Present a clear reason such as Intel CPU or macOS version too low
- Do not expose broken or half-wired controls

### Download failure

- Show actionable error
- Offer retry
- Do not pretend the model is ready

### Unsupported or unreadable input file

- Reject before execution
- Show clear UI error

### Model load failure

- Surface the failure clearly
- Suggest smaller model when appropriate

### High memory pressure or resource conflict

- Warn before start when known early
- Suggest stopping local LLM or selecting a smaller model

### Cancellation

- Stop task promptly when possible
- Mark record as cancelled
- Do not merge cancelled content into the current final result state

### Missing source file during history revisit

- Preserve transcript view and export
- Fail only the Finder reveal action

## Concurrency and Execution Rules

Version one will support one foreground transcription task at a time.

- No parallel transcriptions
- No background queue
- No retry queue
- No batch mode

If a task is running, the UI should disable actions that would start a second task.

## Localization

All new UI strings must use `L10n.k(...)` or `L10n.f(...)` and add both Chinese and English translations to `Stable.xcstrings`. English values must be real translations, not title-cased placeholders. Label lengths should follow the repository i18n style guide.

## Platform and Build Impact

This feature changes the build graph, but it must not force the entire app to drop Intel/macOS 14 compatibility.

Required outcomes:

- Main `ClawdHome` app remains shippable on Intel and on macOS 14
- Speech transcription backend is available only on Apple Silicon with macOS 15+
- Build configuration clearly separates supported and unsupported slices

Expected impact areas:

- `project.yml`
- Regenerated Xcode project metadata
- Target architecture and deployment-target condition wiring
- Package resolution and product linkage changes
- Potential Swift 6 adoption in the speech-specific target, without unnecessarily forcing unrelated app code to migrate all at once

Version one does not require microphone permission strings because it does not capture live audio. Those permissions should only be added when microphone recording is actually introduced.

## Testing Strategy

### Logic tests

- Model recommendation rules
- History record persistence and ordering
- Export text formatting

### Integration checks

- First-time model download
- Successful transcription of a small audio file
- Repeat transcription using already cached model
- History view after original file deletion
- Cancel during a long transcription

### Build verification

- Intel-compatible build path without the speech backend
- Apple-Silicon build path with the speech backend
- `xcodegen generate`
- `make build`
- Existing relevant test targets, if they remain compatible after the Swift 6 upgrade

## Implementation Sequencing

1. Update the spec and plan for dual-track compatibility instead of repo-wide baseline uplift.
2. Add `speech-swift` package and isolate it behind a speech-specific standalone executable package.
3. Wire build settings so unsupported architectures and OS versions compile the fallback path only.
4. Introduce shared app-side models for transcript tasks and history records.
5. Implement `SpeechModelAdvisor`.
6. Implement `SpeechHistoryStore`.
7. Implement `SpeechTranscriptionService` against a protocol with supported and unavailable implementations.
8. Build the dedicated speech transcription UI.
9. Wire AI Lab entry to the capability-aware feature.
10. Add copy, export, delete, and Finder reveal actions.
11. Run both supported and unsupported build-path validation.

## Execution Guidance

When implementation begins, bounded coding slices are good candidates for `gpt-5.3-codex`, especially:

- Model advisor rules
- History store serialization
- Export formatting
- Isolated SwiftUI subviews with clear file ownership

Repository-wide baseline upgrades and integration-heavy work should stay under the coordinating agent because they are more likely to collide with unrelated workspace changes.
