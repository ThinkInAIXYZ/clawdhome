#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "❌ $*" >&2
  exit 1
}

PROMPT="$(bash scripts/release_notes_draft.sh --version 9.9.9 --print-prompt)"

echo "$PROMPT" | grep -q "Classify changes relative to the last shipped release" \
  || fail "release notes prompt must classify against the last shipped release"

echo "$PROMPT" | grep -q "Do not classify fixes to unreleased features as release bug fixes" \
  || fail "release notes prompt must not expose unreleased internal fixes as release fixes"

echo "$PROMPT" | grep -q "newly added files/assets" \
  || fail "release notes prompt must treat new files/assets as newly added user-visible items"

echo "$PROMPT" | grep -q "File status since" \
  || fail "release notes prompt must include file status context"

echo "✅ release script tests passed"
