#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-tool-embed-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Test.app"
APP_BIN_DIR="$APP_DIR/Contents/MacOS"
DEST_DIR="$APP_DIR/Contents/Library/Executables"
SCRIPT_DERIVED_FILE_DIR="${DERIVED_FILE_DIR:-$TMP_DIR/DerivedFiles}"
SRCROOT_NO_PREBUILT="$TMP_DIR/srcroot-no-prebuilt"

mkdir -p "$APP_BIN_DIR" "$SCRIPT_DERIVED_FILE_DIR" "$SRCROOT_NO_PREBUILT"

output="$(
  CONFIGURATION=Debug \
  CODESIGNING_FOLDER_PATH="$APP_DIR" \
  EXECUTABLE_NAME=TestApp \
  SRCROOT="$SRCROOT_NO_PREBUILT" \
  DERIVED_FILE_DIR="$SCRIPT_DERIVED_FILE_DIR" \
  /bin/bash "$ROOT/scripts/build-speech-tool.sh"
)"

if ! grep -q "skip speech tool build in Debug" <<<"$output"; then
  echo "Expected Debug builds to skip bundled speech tool compilation." >&2
  echo "$output" >&2
  exit 1
fi

test ! -e "$DEST_DIR/ClawdHomeSpeech"
test ! -e "$DEST_DIR/mlx.metallib"

PREBUILT_SRCROOT="$TMP_DIR/srcroot-with-prebuilt"
PREBUILT_APP_DIR="$TMP_DIR/Prebuilt.app"
PREBUILT_DEST_DIR="$PREBUILT_APP_DIR/Contents/Library/Executables"
mkdir -p "$PREBUILT_SRCROOT/build/Executables" "$PREBUILT_APP_DIR/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$PREBUILT_SRCROOT/build/Executables/ClawdHomeSpeech"
printf 'metallib' > "$PREBUILT_SRCROOT/build/Executables/mlx.metallib"
chmod +x "$PREBUILT_SRCROOT/build/Executables/ClawdHomeSpeech"

prebuilt_output="$(
  CONFIGURATION=Debug \
  CODESIGNING_FOLDER_PATH="$PREBUILT_APP_DIR" \
  EXECUTABLE_NAME=TestApp \
  SRCROOT="$PREBUILT_SRCROOT" \
  DERIVED_FILE_DIR="$SCRIPT_DERIVED_FILE_DIR" \
  /bin/bash "$ROOT/scripts/build-speech-tool.sh"
)"

if ! grep -q "copying pre-built speech tool" <<<"$prebuilt_output"; then
  echo "Expected Debug builds to copy an existing pre-built speech tool." >&2
  echo "$prebuilt_output" >&2
  exit 1
fi

test -x "$PREBUILT_DEST_DIR/ClawdHomeSpeech"
test -e "$PREBUILT_DEST_DIR/mlx.metallib"

SCRIPT_PATH="$ROOT/scripts/build-speech-tool.sh"
grep -q 'codesign --force' "$SCRIPT_PATH" \
  || { echo "Expected speech tool script to sign the embedded executable." >&2; exit 1; }
grep -q -- '--timestamp' "$SCRIPT_PATH" \
  || { echo "Expected speech tool signature to include a secure timestamp." >&2; exit 1; }
grep -q -- '--options runtime' "$SCRIPT_PATH" \
  || { echo "Expected speech tool signature to enable hardened runtime." >&2; exit 1; }

strip_line="$(grep -n '/usr/bin/strip "${DEST_TOOL}"' "$SCRIPT_PATH" | cut -d: -f1 | head -n 1)"
sign_line="$(grep -n '^sign_embedded_tool_if_needed$' "$SCRIPT_PATH" | cut -d: -f1 | tail -n 1)"
if [ -z "$strip_line" ] || [ -z "$sign_line" ] || [ "$strip_line" -ge "$sign_line" ]; then
  echo "Expected speech tool signing to run after strip so release packaging cannot modify the signed executable." >&2
  exit 1
fi

echo "Speech tool embed script test passed."
