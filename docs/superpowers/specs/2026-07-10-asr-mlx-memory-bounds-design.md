# ASR MLX Memory Bounds Design

**Date:** 2026-07-10

**Status:** Approved in chat, pending written-spec review

**Goal:** Keep Qwen3-ASR long-audio transcription memory bounded without changing the model, audio chunking, decoding limit, or transcript quality.

## Context

`ClawdHomeSpeech` currently streams long audio as 30-second, 16 kHz mono chunks with a 2-second overlap. A one-hour recording therefore does not reside in a single in-memory PCM array. Live inspection of a Qwen3-ASR 1.7B 8-bit transcription instead showed a 29.9 GB physical footprint, of which 29.8 GB was `IOAccelerator (graphics)` memory while the ordinary malloc heap was about 33 MB.

The current `speech-swift` Qwen3-ASR path creates variable-sized Metal buffers while growing the decoder KV cache. MLX retains released buffers in its recycling cache unless the application supplies a lower cache limit or clears the cache. `ClawdHomeSpeech` currently does neither, so repeated chunk inference can make the process footprint grow with recording duration even though the input audio is streamed.

## Scope

### Included

- Give `ClawdHomeSpeech` direct access to MLX memory controls.
- Set a bounded MLX recycling-cache limit before model loading.
- Reclaim cached MLX buffers after model loading and after every audio chunk.
- Record structured active, cached, peak, and configured-limit metrics in existing progress events.
- Cover the memory policy and lifecycle ordering with deterministic tests.
- Verify that long transcription memory plateaus instead of growing with chunk count.

### Excluded

- Changing Qwen3-ASR 1.7B 8-bit to another model or quantization.
- Changing the 30-second chunk size or 2-second overlap.
- Changing `maxTokens` from 1024.
- Replacing or redesigning the Qwen3-ASR KV cache.
- Forking or patching `speech-swift`.
- Adding new user-visible settings or UI.

## Approaches Considered

### 1. Clear the MLX cache after each chunk

This is the smallest change, but it only acts after a chunk finishes. A single decoder invocation can still retain enough differently sized buffers to create a large peak before the cleanup runs.

### 2. Bound the cache and reclaim at lifecycle boundaries

This is the selected approach. A cache limit constrains growth during each chunk, while explicit reclamation removes stale buffers between chunks. The model weights and live inference arrays remain active and are not cleared.

### 3. Modify `speech-swift`

Moving the policy into `speech-swift` could provide deeper control, but it would require a fork or a build-time source patch and would increase dependency-upgrade cost. The current issue can be addressed at the `ClawdHomeSpeech` process boundary without changing upstream decoding behavior.

## Architecture

The implementation adds a small policy layer and an MLX-backed runtime adapter.

### `SpeechInferenceMemoryPolicy`

Location:

- `ClawdHomeSpeech/Sources/ClawdHomeSpeechCore/SpeechInferenceMemoryPolicy.swift`

Responsibilities:

- Calculate a cache limit from physical memory.
- Represent a memory snapshot independently of MLX.
- Keep sizing logic deterministic and testable without loading a model.

The cache-limit formula is:

```text
limit = clamp(physicalMemoryBytes / 32, 256 MiB, 1 GiB)
```

Examples:

| Physical memory | MLX cache limit |
|---:|---:|
| 8 GB | 256 MiB |
| 16 GB | 512 MiB |
| 32 GB | 1 GiB |
| 64 GB | 1 GiB |

The limit applies only to MLX's reusable free-buffer cache. It does not cap active model weights or active inference tensors.

### `SpeechMLXMemoryController`

Location:

- `ClawdHomeSpeech/Sources/ClawdHomeSpeechRuntime/SpeechMLXMemoryController.swift`

Responsibilities:

- Adapt MLX `Memory.cacheLimit`, `Memory.clearCache()`, and `Memory.snapshot()` to the policy types.
- Configure the cache limit once per process before model loading.
- Reclaim cached buffers after model loading and after each transcription chunk.
- Return post-reclamation snapshots for progress reporting.

The controller accepts a backend interface. Production uses MLX's process-wide `Memory` APIs; tests use an in-memory fake to verify call ordering and snapshots without running Qwen3-ASR.

### Package boundaries

`ClawdHomeSpeech/Package.swift` will:

- Add a direct `mlx-swift` package dependency compatible with the already resolved 0.31.3 version.
- Add a `ClawdHomeSpeechRuntime` target depending on `ClawdHomeSpeechCore` and the MLX product.
- Add a `ClawdHomeSpeechRuntimeTests` target.
- Make the `ClawdHomeSpeech` executable depend on `ClawdHomeSpeechRuntime`.

The main macOS app target remains isolated from MLX and continues to communicate with the embedded executable through JSON lines.

## Runtime Lifecycle

For `prepare-model`, silent `transcribe`, and interactive transcription, the process follows this order:

1. Construct the controller using `ProcessInfo.processInfo.physicalMemory`.
2. Set `Memory.cacheLimit` before loading Qwen3-ASR.
3. Load the selected model using the existing `fromPretrained` call.
4. Clear only recyclable MLX buffers after model loading and capture a snapshot.
5. Stream audio using the existing 30-second/2-second-overlap loader.
6. Run one unchanged `model.transcribe` call per chunk.
7. Clear recyclable MLX buffers when the chunk finishes and capture a snapshot.
8. Repeat steps 6–7 for the remaining chunks.
9. Perform final cache reclamation before the command returns, including error paths.

Cleanup must use `defer` at command and chunk boundaries so thrown audio-processing or file errors do not skip reclamation. Cleanup does not discard the model object or any active MLX arrays still referenced by it.

## Progress Telemetry

Existing progress JSON objects gain these optional integer fields:

- `mlxActiveMemoryBytes`
- `mlxCacheMemoryBytes`
- `mlxPeakMemoryBytes`
- `mlxCacheLimitBytes`

The fields are populated on the post-model-load event and on each completed-chunk event. Existing app and CLI decoders remain compatible because Swift's `JSONDecoder` ignores unknown keys. No memory values are added to user-facing status text in this change.

The metrics make it possible to distinguish:

- active model/inference memory that cannot be reclaimed;
- reusable cache memory that should stay below the configured limit;
- historical peak memory;
- the policy selected for the current Mac.

## Transcript-Quality Invariants

The following values remain unchanged:

- model identifier and model weights;
- input PCM samples;
- 16 kHz sample rate;
- 30-second chunk size;
- 2-second overlap;
- language hint;
- greedy decoding behavior;
- `maxTokens = 1024`;
- chunk transcript concatenation.

MLX cache reclamation affects only buffers that MLX reports as inactive. It does not alter numerical precision, token selection, or model state. Given identical inputs and model files, normalized transcript output must remain identical before and after the change.

## Error Handling

- An invalid or zero physical-memory value falls back to the minimum 256 MiB cache limit.
- Cache configuration and reclamation are process-local and do not affect the main app or other MLX processes.
- Existing model-download, audio-decode, cancellation, and transcription errors keep their current JSON contracts.
- Reclamation runs through `defer` when model loading or chunk processing exits early.
- Memory telemetry is diagnostic metadata and must never turn an otherwise successful transcription into a failure.

## Testing

### Unit tests

`ClawdHomeSpeechCoreTests` will verify:

- zero and sub-8 GB inputs select 256 MiB;
- 16 GB selects 512 MiB;
- 32 GB and larger inputs never exceed 1 GiB;
- snapshot values remain byte-accurate.

`ClawdHomeSpeechRuntimeTests` will use a fake backend to verify:

- configuration sets the calculated cache limit before clearing;
- post-model-load reclamation clears once and returns the backend snapshot;
- every completed chunk clears once;
- cleanup still runs when a supplied chunk body throws;
- reported snapshots include the configured limit.

Existing audio streaming tests continue to verify 30-second chunks and 2-second overlap.

### Compatibility tests

The app-side progress parser will decode a progress line containing all four new memory fields and continue to expose the existing progress and transcript-delta values unchanged.

### Integration verification

1. Build the standalone tool with `make build-speech`.
2. Transcribe the same representative audio with the baseline and optimized binaries using the same model cache and language hint.
3. Compare normalized transcript output for exact equality.
4. Run a long input and record post-chunk MLX snapshots from 25% through 75% progress.
5. Confirm cache memory returns below the configured limit after each chunk.
6. Confirm total MLX active-plus-cache memory does not grow by more than 10% between the 25% and 75% checkpoints.
7. Confirm cancellation and tool exit release the process-owned Metal allocations.

## Acceptance Criteria

- Qwen3-ASR 1.7B 8-bit, 30-second chunks, 2-second overlap, and 1024-token decoding remain unchanged.
- The same input and language hint produce an identical normalized transcript.
- A 16 GB Mac receives a 512 MiB MLX recycling-cache limit.
- A 64 GB Mac receives no more than a 1 GiB MLX recycling-cache limit.
- Post-chunk cache snapshots remain at or below the configured limit.
- Active-plus-cache MLX memory at 75% progress is no more than 10% above the value at 25% progress.
- The existing app and CLI continue to parse progress and final result JSON.
- Unit tests, speech package tests, the speech tool build, and relevant app parser tests pass.

## Rollout and Follow-up

This change ships as a process-local memory policy with no settings migration and no UI change. If integration measurements show that a 512 MiB cache causes a material throughput regression on 16 GB hardware, a later change may tune the sizing formula using measured data while preserving the same bounded-policy interface.

KV-cache preallocation, adaptive token limits, and model fallback remain separate follow-ups because they can affect decoder implementation or product behavior and are outside the approved zero-quality-risk scope.
