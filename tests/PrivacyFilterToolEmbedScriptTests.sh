#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/privacy-filter-embed-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SRCROOT_WITH_PREBUILT="$TMP_DIR/srcroot-with-prebuilt"
APP_DIR="$TMP_DIR/Test.app"
DEST_DIR="$APP_DIR/Contents/Library/Executables"
SCRIPT_DERIVED_FILE_DIR="$TMP_DIR/DerivedFiles"

mkdir -p "$SRCROOT_WITH_PREBUILT/build/Executables" "$DEST_DIR" "$SCRIPT_DERIVED_FILE_DIR"

printf '#!/bin/sh\necho new privacy tool\n' > "$SRCROOT_WITH_PREBUILT/build/Executables/ClawdHomePrivacyFilter"
printf '#!/bin/sh\necho stale privacy tool\n' > "$DEST_DIR/ClawdHomePrivacyFilter"
chmod +x "$SRCROOT_WITH_PREBUILT/build/Executables/ClawdHomePrivacyFilter" "$DEST_DIR/ClawdHomePrivacyFilter"

output="$(
  CONFIGURATION=Debug \
  CODESIGNING_FOLDER_PATH="$APP_DIR" \
  SRCROOT="$SRCROOT_WITH_PREBUILT" \
  DERIVED_FILE_DIR="$SCRIPT_DERIVED_FILE_DIR" \
  /bin/bash "$ROOT/scripts/build-privacy-filter-tool.sh"
)"

if ! grep -q "copying pre-built privacy filter tool" <<<"$output"; then
  echo "Expected Debug builds to copy the pre-built privacy filter tool into the app bundle." >&2
  echo "$output" >&2
  exit 1
fi

actual="$("$DEST_DIR/ClawdHomePrivacyFilter")"
if [ "$actual" != "new privacy tool" ]; then
  echo "Expected the app bundle privacy tool to be overwritten with the current pre-built tool." >&2
  echo "Actual: $actual" >&2
  exit 1
fi

echo "Privacy filter tool embed script test passed."
