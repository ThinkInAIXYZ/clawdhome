#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/speech-tool-embed-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_DIR="$TMP_DIR/Test.app"
APP_BIN_DIR="$APP_DIR/Contents/MacOS"
APP_BIN="$APP_BIN_DIR/TestApp"
DEST_DIR="$APP_DIR/Contents/Library/Executables"
SCRIPT_DERIVED_FILE_DIR="${DERIVED_FILE_DIR:-$TMP_DIR/DerivedFiles}"

mkdir -p "$APP_BIN_DIR" "$SCRIPT_DERIVED_FILE_DIR"

cat > "$TMP_DIR/main.c" <<'EOF'
int main(void) { return 0; }
EOF

xcrun --sdk macosx clang -arch arm64 "$TMP_DIR/main.c" -o "$APP_BIN"

CONFIGURATION=Debug \
CODESIGNING_FOLDER_PATH="$APP_DIR" \
EXECUTABLE_NAME=TestApp \
SRCROOT="$ROOT" \
DERIVED_FILE_DIR="$SCRIPT_DERIVED_FILE_DIR" \
/bin/bash "$ROOT/scripts/build-speech-tool.sh"

test -x "$DEST_DIR/ClawdHomeSpeech"
test -f "$DEST_DIR/mlx.metallib"

echo "Speech tool embed script test passed."
