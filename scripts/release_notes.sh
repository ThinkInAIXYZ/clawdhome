#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE=""
LANG=""
VERSION=""
NOTES_DIR="$REPO_ROOT/release-notes"

while [ $# -gt 0 ]; do
  case "$1" in
    --github)    MODE="github"; shift ;;
    --api)       MODE="api"; LANG="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --notes-dir) NOTES_DIR="$2"; shift 2 ;;
    *)           shift ;;
  esac
done

fail() {
  echo "❌ $*" >&2
  exit 1
}

[ -n "$MODE" ] || fail "需要指定 --github 或 --api <zh|en>"
[ -n "$VERSION" ] || fail "需要指定 --version"

if [[ "$VERSION" == v* ]]; then
  VERSION_NO_PREFIX="${VERSION#v}"
else
  VERSION_NO_PREFIX="$VERSION"
fi

ZH_FILE="$NOTES_DIR/v${VERSION_NO_PREFIX}.zh.md"
EN_FILE="$NOTES_DIR/v${VERSION_NO_PREFIX}.en.md"

[ -f "$ZH_FILE" ] || fail "未找到中文 release notes: $ZH_FILE"
[ -f "$EN_FILE" ] || fail "未找到英文 release notes: $EN_FILE"

markdown_to_plain() {
  sed \
    -e 's/^### \{0,1\}//' \
    -e 's/^## \{0,1\}//' \
    -e 's/^# \{0,1\}//' \
    -e '/^---$/d' \
    -e '/^[[:space:]]*$/N;/^\n$/D'
}

if [ "$MODE" = "github" ]; then
  {
    printf '## 中文\n\n'
    cat "$ZH_FILE"
    printf '\n\n---\n\n## English\n\n'
    cat "$EN_FILE"
    printf '\n'
  }
  exit 0
fi

case "$LANG" in
  zh) cat "$ZH_FILE" | markdown_to_plain ;;
  en) cat "$EN_FILE" | markdown_to_plain ;;
  *) fail "不支持的 API 语言：$LANG" ;;
esac
