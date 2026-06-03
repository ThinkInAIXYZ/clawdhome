#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-tool-embed-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Test.app"
APP_BIN_DIR="$APP_DIR/Contents/MacOS"
DEST_DIR="$APP_DIR/Contents/Library/Executables"
SCRIPT_DERIVED_FILE_DIR="${DERIVED_FILE_DIR:-$TMP_DIR/DerivedFiles}"

mkdir -p "$APP_BIN_DIR" "$SCRIPT_DERIVED_FILE_DIR"

output="$(
  CONFIGURATION=Debug \
  CODESIGNING_FOLDER_PATH="$APP_DIR" \
  EXECUTABLE_NAME=TestApp \
  SRCROOT="$ROOT" \
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

echo "Speech tool embed script test passed."
