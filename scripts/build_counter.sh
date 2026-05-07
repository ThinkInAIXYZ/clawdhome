#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_FILE="${BUILD_COUNTER_FILE:-$REPO_ROOT/.build-version}"
INITIAL_BUILD="${INITIAL_BUILD_NUMBER:-500}"
LOCK_DIR="${BUILD_FILE}.lock"

sanitize_number() {
  local value="${1:-}"
  case "$value" in
    ''|*[!0-9]*) echo $((INITIAL_BUILD - 1)) ;;
    *) echo "$value" ;;
  esac
}

read_current() {
  if [ -f "$BUILD_FILE" ]; then
    local raw
    raw=$(tr -d '[:space:]' < "$BUILD_FILE")
    sanitize_number "$raw"
    return
  fi
  echo $((INITIAL_BUILD - 1))
}

acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 200 ]; then
      echo "failed to acquire build counter lock: $LOCK_DIR" >&2
      exit 1
    fi
    sleep 0.05
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

reserve_next() {
  acquire_lock
  local current next
  current=$(read_current)
  next=$((current + 1))
  printf '%s\n' "$next" > "$BUILD_FILE"
  echo "$next"
}

usage() {
  cat <<'EOF'
Usage:
  build_counter.sh current
  build_counter.sh next-preview
  build_counter.sh reserve
EOF
}

case "${1:-}" in
  current)
    read_current
    ;;
  next-preview)
    current="$(read_current)"
    echo $((current + 1))
    ;;
  reserve)
    reserve_next
    ;;
  *)
    usage
    exit 2
    ;;
esac
