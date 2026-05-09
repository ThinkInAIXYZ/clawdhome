#!/usr/bin/env bash
# release_notes_draft.sh — 生成中英文发布说明草稿
#
# 用法：
#   bash scripts/release_notes_draft.sh [--version 1.10.0] [--no-open] [--no-claude]
#
# 模式：
#   默认：调用 claude -p 生成高质量草稿（需要本机安装 claude CLI）
#   --no-claude：基于 git log 生成可编辑骨架（CI / 无 claude 环境适用）
#
# 兼容 macOS bash 3.2，零外部依赖（--no-claude 模式）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
OPEN_CMD="${OPEN_CMD:-open}"
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
VERSION="${VERSION:-}"
NO_OPEN=false
NO_CLAUDE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --no-open)   NO_OPEN=true; shift ;;
    --no-claude) NO_CLAUDE=true; shift ;;
    *)           shift ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

[ -n "$VERSION" ] || VERSION="$(bash "$SCRIPT_DIR/semver.sh")"

LAST_TAG="$(git describe --tags --match "v*" --abbrev=0 2>/dev/null || true)"
RANGE="${LAST_TAG:+${LAST_TAG}..HEAD}"
[ -n "$RANGE" ] || RANGE="HEAD"

COMMITS="$(git log "$RANGE" --oneline 2>/dev/null || true)"
[ -n "$COMMITS" ] || fail "未找到可用于生成发布说明的提交记录"

mkdir -p "$NOTES_DIR"
ZH_FILE="$NOTES_DIR/v${VERSION}.zh.md"
EN_FILE="$NOTES_DIR/v${VERSION}.en.md"

# ── claude 模式 ───────────────────────────────────────────────────────────────

if [ "$NO_CLAUDE" = false ] && ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  warn "未找到 $CLAUDE_BIN，自动降级到 --no-claude 模板模式"
  NO_CLAUDE=true
fi

if [ "$NO_CLAUDE" = false ]; then
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
# 新功能
- ...

# 改进与修复
- ...

[EN]
# New Features
- ...

# Improvements & Fixes
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

else
  # ── --no-claude：基于 git log 生成可编辑骨架 ─────────────────────────────

  log "生成 v${VERSION} 发布说明骨架（--no-claude 模式）..."

  FEAT_COMMITS="$(echo "$COMMITS" | grep ' feat' | sed 's/^[a-f0-9]* //' || true)"
  FIX_COMMITS="$(echo "$COMMITS"  | grep -E ' fix| refactor' | sed 's/^[a-f0-9]* //' || true)"
  OTHER_COMMITS="$(echo "$COMMITS" | grep -Ev ' feat| fix| refactor| chore| docs' | sed 's/^[a-f0-9]* //' || true)"

  # 中文骨架
  {
    echo "# 新功能"
    echo ""
    if [ -n "$FEAT_COMMITS" ]; then
      echo "$FEAT_COMMITS" | sed 's/^/- /'
    else
      echo "- （待填写）"
    fi
    echo ""
    echo "# 改进与修复"
    echo ""
    if [ -n "$FIX_COMMITS" ] || [ -n "$OTHER_COMMITS" ]; then
      [ -n "$FIX_COMMITS" ]   && echo "$FIX_COMMITS"   | sed 's/^/- /'
      [ -n "$OTHER_COMMITS" ] && echo "$OTHER_COMMITS" | sed 's/^/- /'
    else
      echo "- （待填写）"
    fi
    echo ""
    echo "<!--"
    echo "参考提交（v${LAST_TAG:-start}..HEAD）："
    echo "$COMMITS" | sed 's/^/  /'
    echo "-->"
  } > "$ZH_FILE"

  # 英文骨架
  {
    echo "# New Features"
    echo ""
    if [ -n "$FEAT_COMMITS" ]; then
      echo "$FEAT_COMMITS" | sed 's/^/- /'
    else
      echo "- (to be filled)"
    fi
    echo ""
    echo "# Improvements & Fixes"
    echo ""
    if [ -n "$FIX_COMMITS" ] || [ -n "$OTHER_COMMITS" ]; then
      [ -n "$FIX_COMMITS" ]   && echo "$FIX_COMMITS"   | sed 's/^/- /'
      [ -n "$OTHER_COMMITS" ] && echo "$OTHER_COMMITS" | sed 's/^/- /'
    else
      echo "- (to be filled)"
    fi
    echo ""
    echo "<!--"
    echo "Source commits (${LAST_TAG:-start}..HEAD):"
    echo "$COMMITS" | sed 's/^/  /'
    echo "-->"
  } > "$EN_FILE"

  warn "骨架已生成，请手动翻译和润色再发布"
fi

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
echo "  3. 确认后运行 make release-prepare"
