#!/usr/bin/env bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUNTIME_DIR="$ROOT/EmbeddedLLMWiki/runtime"
OUT_DIR="${TARGET_BUILD_DIR:?missing TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?missing UNLOCALIZED_RESOURCES_FOLDER_PATH}/EmbeddedLLMWiki"
BIN_NAME="llm-wiki-runtime"
PROFILE_DIR="debug"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:$HOME/Library/pnpm:$PATH"

if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust or expose cargo to GUI apps." >&2
  exit 127
fi

cd "$RUNTIME_DIR"

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  cargo build --release --bin "$BIN_NAME"
  PROFILE_DIR="release"
else
  cargo build --bin "$BIN_NAME"
fi

mkdir -p "$OUT_DIR"
cp "$RUNTIME_DIR/target/$PROFILE_DIR/$BIN_NAME" "$OUT_DIR/$BIN_NAME"
chmod +x "$OUT_DIR/$BIN_NAME"
