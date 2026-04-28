#!/usr/bin/env bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FRONTEND_DIR="$ROOT/EmbeddedLLMWiki/frontend"
OUT_DIR="${TARGET_BUILD_DIR:?missing TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?missing UNLOCALIZED_RESOURCES_FOLDER_PATH}/wiki"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:$HOME/Library/pnpm:$PATH"

if ! command -v npm >/dev/null 2>&1 && [ -d "$HOME/.nvm/versions/node" ]; then
  latest_nvm_bin="$(find "$HOME/.nvm/versions/node" -mindepth 2 -maxdepth 2 -type d -name bin 2>/dev/null | sort -V | tail -n 1)"
  if [ -n "${latest_nvm_bin:-}" ]; then
    export PATH="$latest_nvm_bin:$PATH"
  fi
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm not found. Install Node.js or expose npm to GUI apps." >&2
  exit 127
fi

cd "$FRONTEND_DIR"

if [ ! -d node_modules ]; then
  npm ci
fi

npm run build

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
rsync -a --delete "$FRONTEND_DIR/dist/" "$OUT_DIR/"
