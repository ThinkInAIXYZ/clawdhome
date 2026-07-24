# Privacy Filter Q4 UI Closure Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users install and use OpenAI Privacy Filter q4 from the ClawdHome UI with reliable local status, clear recovery actions, and real model-backed detection.

**Architecture:** Keep PrivacyFilterEngine as the app-facing coordinator and ClawdHomePrivacyFilter as the standalone runtime boundary. The app exposes two local semantic model options: the existing lightweight bundled model and the q4 ONNX model. The CLI owns download, status, inspect, and inference behavior for each model ID so UI state and actual usage cannot drift.

**Tech Stack:** SwiftUI, Swift Observation, standalone SwiftPM executable, swift-huggingface Hub snapshot downloads, ONNX Runtime Swift package, Hugging Face Tokenizers where buildable, shell/XCTest coverage.

---

## File Structure

- Modify `ClawdHomePrivacyFilter/Package.swift`: dependency shape for Hub, Tokenizers, and ONNX Runtime.
- Modify `ClawdHomePrivacyFilter/main.swift`: q4 status, download, inspect, and q4 analyze/redact dispatch.
- Modify `ClawdHome/Services/PrivacyFilterEngine.swift`: model selection, q4 directory, q4 prepare/status/open-directory APIs, and q4 analyze invocation.
- Modify `ClawdHome/Views/PrivacyFilterView.swift`: UI controls for model choice, q4 install, status, directory, and error display.
- Modify `ClawdHome/Stable.xcstrings`: localized user-facing strings.
- Modify `tests/PrivacyFilterToolTests.sh`: CLI behavior coverage that does not require 945MB download.
- Modify `tests/ClawdHomeAppXCTests/PrivacyFilterEngineTests.swift`: app engine command routing coverage.

## Task 1: Model Selection Contract

- [ ] Add a q4 model ID constant in app engine.
- [ ] Add tests proving q4 prepare calls `prepare-onnx-model` and q4 analyze calls `analyze --model-id openai-privacy-filter-q4`.
- [ ] Implement app engine state for both lightweight and q4 models.
- [ ] Verify existing lightweight model tests remain green.

## Task 2: UI Install and Status

- [ ] Add UI model selector under Local Semantic engine.
- [ ] Show per-model install state, install action, open-directory action, and error text.
- [ ] Ensure q4 install is clearly marked as large and local.
- [ ] Add i18n keys with Chinese and English values.
- [ ] Verify `make i18n-check`.

## Task 3: CLI Q4 Runtime

- [ ] Keep `prepare-onnx-model --dry-run` network-free.
- [ ] Ensure q4 status checks all required model files.
- [ ] Enable q4 `analyze/redact` dispatch separate from lightweight model.
- [ ] Add tokenizer + ONNX Runtime inference if dependencies build in product configuration.
- [ ] If full q4 inference cannot be linked in the current environment, keep the UI using q4 only after the executable reports runtime support and surface an actionable error instead of silently falling back.

## Task 4: Verification

- [ ] Run `bash tests/PrivacyFilterToolTests.sh`.
- [ ] Run `bash tests/PrivacyFilterToolEmbedScriptTests.sh`.
- [ ] Run focused XCTest for PrivacyFilterEngine.
- [ ] Run `make build`.
- [ ] Run `make i18n-check`.
- [ ] Use the built app bundle's embedded `ClawdHomePrivacyFilter` to verify q4 dry-run/status.
- [ ] If practical in the current environment, perform one real q4 download + inspect + analyze smoke test.
