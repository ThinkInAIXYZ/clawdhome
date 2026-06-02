#!/usr/bin/env bash
# release_notes_draft.sh — 生成中英文发布说明草稿
#
# 用法：
#   bash scripts/release_notes_draft.sh [--version 1.10.0] [--no-open] [--no-claude] [--pi] [--print-prompt]
#
# 模式：
#   默认：调用 claude -p 生成高质量草稿（需要本机安装 claude CLI）
#   --pi / RELEASE_NOTES_AI=pi：调用 pi -p 生成草稿（默认本地 Qwopus 模型）
#   --no-claude：基于 git log 生成可编辑骨架（CI / 无 claude 环境适用）
#
# 兼容 macOS bash 3.2，零外部依赖（--no-claude 模式）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
PI_BIN="${PI_BIN:-pi}"
PI_PROVIDER="${PI_PROVIDER:-ta_omlx}"
PI_MODEL="${PI_MODEL:-Qwopus3.6-35B-A3B-v1-oQ4}"
AI_MODE="${RELEASE_NOTES_AI:-claude}"
OPEN_CMD="${OPEN_CMD:-open}"
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
VERSION="${VERSION:-}"
NO_OPEN=false
NO_CLAUDE=false
PRINT_PROMPT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --no-open)   NO_OPEN=true; shift ;;
    --no-claude) NO_CLAUDE=true; shift ;;
    --pi)        AI_MODE=pi; shift ;;
    --ai)        AI_MODE="$2"; shift 2 ;;
    --print-prompt) PRINT_PROMPT=true; shift ;;
    *)           echo "❌ 未知参数：$1" >&2; exit 1 ;;
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
FILE_STATUS="$(git diff --name-status "$RANGE" 2>/dev/null || true)"
DIFF_STAT="$(git diff --stat "$RANGE" 2>/dev/null || true)"

mkdir -p "$NOTES_DIR"
ZH_FILE="$NOTES_DIR/v${VERSION}.zh.md"
EN_FILE="$NOTES_DIR/v${VERSION}.en.md"

build_prompt() {
  cat <<EOF
You are writing public-facing software release notes for a macOS app called ClawdHome.

Write concise, user-friendly release notes for version ${VERSION} in BOTH Simplified Chinese and English.

Baseline:
- Classify changes relative to the last shipped release, ${LAST_TAG:-project start}.
- A bug fix made while developing an unreleased feature is not a user-visible release fix unless users of ${LAST_TAG:-the last release} could experience that bug.

Classification rules:
- "New Features" means a user-visible capability, screen, workflow, integration, or asset set did not exist in ${LAST_TAG:-the last release}.
- "Improvements & Fixes" means an existing ${LAST_TAG:-last-release} capability was refined, polished, made faster, made more reliable, or fixed.
- Do not classify fixes to unreleased features as release bug fixes. Fold them into the new feature description or omit them.
- Do not write "updated", "improved", or "optimized" for newly added files/assets. Use "added", "introduced", or "new".
- For newly added files/assets, describe them as new only when they are user-visible; otherwise omit them.
- Do not duplicate the same item across both sections.

Requirements:
- Keep only user-visible changes.
- Remove internal-only implementation details, tooling noise, tests, build scripts, and commit-style wording.
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

File status since ${LAST_TAG:-project start}:
${FILE_STATUS}

Diff stat since ${LAST_TAG:-project start}:
${DIFF_STAT}
EOF
}

PROMPT="$(build_prompt)"

if [ "$PRINT_PROMPT" = true ]; then
  printf '%s\n' "$PROMPT"
  exit 0
fi

# ── AI 模式 ───────────────────────────────────────────────────────────────────

if [ "$NO_CLAUDE" = false ] && [ "$AI_MODE" = "claude" ] && ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  warn "未找到 $CLAUDE_BIN，自动降级到 --no-claude 模板模式"
  NO_CLAUDE=true
fi

if [ "$NO_CLAUDE" = false ]; then
  case "$AI_MODE" in
    claude)
      log "调用 claude -p 生成 v${VERSION} 发布说明草稿..."
      RAW_OUTPUT="$("$CLAUDE_BIN" -p "$PROMPT")"
      [ -n "$RAW_OUTPUT" ] || fail "claude -p 没有返回内容"
      ;;
    pi)
      command -v "$PI_BIN" >/dev/null 2>&1 || fail "未找到 $PI_BIN，请安装 pi 或使用 --no-claude"
      log "调用 pi -p（${PI_PROVIDER}/${PI_MODEL}）生成 v${VERSION} 发布说明草稿..."
      RAW_OUTPUT="$("$PI_BIN" -p --no-tools --no-context-files --no-session --provider "$PI_PROVIDER" --model "$PI_MODEL" "$PROMPT")"
      [ -n "$RAW_OUTPUT" ] || fail "pi -p 没有返回内容"
      ;;
    *)
      fail "未知 AI 模式：$AI_MODE（支持 claude / pi / --no-claude）"
      ;;
  esac

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
