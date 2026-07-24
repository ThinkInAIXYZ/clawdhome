#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BIN="$(mktemp /tmp/clawdhome-asr-platform-tests.XXXXXX)"
trap 'rm -f "$TEST_BIN"' EXIT

/usr/bin/xcrun swiftc \
  "$REPO_ROOT/ClawdHomeCLI/ASRPlatformDetector.swift" \
  "$REPO_ROOT/tests/ASRPlatformDetectorTests.swift" \
  -o "$TEST_BIN"
"$TEST_BIN"
