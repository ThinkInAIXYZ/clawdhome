#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
OPEN_CMD="${OPEN_CMD:-open}"
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
VERSION="${VERSION:-}"
NO_OPEN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --no-open) NO_OPEN=true; shift ;;
    *) shift ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

[ -n "$VERSION" ] || VERSION="$(bash "$SCRIPT_DIR/semver.sh")"

if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  fail "未找到 $CLAUDE_BIN，请先安装并确认 claude -p 可用"
fi

LAST_TAG="$(git describe --tags --match "v*" --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  RANGE="${LAST_TAG}..HEAD"
else
  RANGE="HEAD"
fi

COMMITS="$(git log "$RANGE" --oneline 2>/dev/null || true)"
[ -n "$COMMITS" ] || fail "未找到可用于生成发布说明的提交记录"

mkdir -p "$NOTES_DIR"
ZH_FILE="$NOTES_DIR/v${VERSION}.zh.md"
EN_FILE="$NOTES_DIR/v${VERSION}.en.md"

PROMPT=$(cat <<EOF
You are writing public-facing software release notes for a macOS app called ClawdHome.

Write concise, user-friendly release notes for version ${VERSION} in BOTH Simplified Chinese and English.

Requirements:
- Keep only user-visible changes.
- Remove internal-only implementation details, tooling noise, and commit-style wording.
- Merge related commits into clearer product language.
- Be accurate and conservative. Do not invent features.
- Output exactly in this format:
[ZH]
### 新功能
- ...

### 改进与修复
- ...

[EN]
### Features
- ...

### Improvements & Fixes
- ...

Source commits since ${LAST_TAG:-project start}:
${COMMITS}
EOF
)

log "调用 claude -p 生成 v${VERSION} 发布说明草稿..."
RAW_OUTPUT="$("$CLAUDE_BIN" -p "$PROMPT")"
[ -n "$RAW_OUTPUT" ] || fail "claude -p 没有返回内容"

ZH_CONTENT="$(printf '%s\n' "$RAW_OUTPUT" | awk '
  /^\[ZH\]$/ {in_zh=1; next}
  /^\[EN\]$/ {in_zh=0}
  in_zh {print}
')"

EN_CONTENT="$(printf '%s\n' "$RAW_OUTPUT" | awk '
  /^\[EN\]$/ {in_en=1; next}
  in_en {print}
')"

[ -n "${ZH_CONTENT//$'\n'/}" ] || fail "未能从 claude 输出中解析出中文部分"
[ -n "${EN_CONTENT//$'\n'/}" ] || fail "未能从 claude 输出中解析出英文部分"

printf '%s\n' "$ZH_CONTENT" > "$ZH_FILE"
printf '%s\n' "$EN_CONTENT" > "$EN_FILE"

ok "已生成：$ZH_FILE"
ok "已生成：$EN_FILE"

if [ "$NO_OPEN" = false ]; then
  log "打开生成的 Markdown 供确认和修改..."
  "$OPEN_CMD" "$ZH_FILE" "$EN_FILE"
fi

echo ""
echo "下一步："
echo "  1. 检查并编辑上述两个文件"
echo "  2. 运行 make release-dry-run"
echo "  3. 确认后运行 make release"
