#!/usr/bin/env bash
# changelog.sh — 从 git log 自动生成 CHANGELOG
#
# 用法：
#   bash scripts/changelog.sh --stdout
#   bash scripts/changelog.sh --stdout --lang zh --version 1.2.0
#   bash scripts/changelog.sh --write --lang zh --version 1.2.0 \
#     --notes-file release-notes/v1.2.0.zh.md --changelog CHANGELOG.zh.md
#
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 解析参数 ──────────────────────────────────────────────────────────────────

MODE="stdout"  # stdout | write
VERSION=""
LANG="en"
NOTES_FILE=""
CHANGELOG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stdout)     MODE="stdout"; shift ;;
    --write)      MODE="write"; shift ;;
    --version)    VERSION="$2"; shift 2 ;;
    --lang)       LANG="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --changelog)  CHANGELOG="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

# 自动获取版本号
if [ -z "$VERSION" ]; then
  VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "0.0.0")
fi

# ── 工具函数 ──────────────────────────────────────────────────────────────────

resolve_default_changelog() {
  case "$LANG" in
    zh) echo "$REPO_ROOT/CHANGELOG.zh.md" ;;
    en) echo "$REPO_ROOT/CHANGELOG.en.md" ;;
    *)
      echo "❌ 不支持的语言：$LANG" >&2
      exit 1
      ;;
  esac
}

title_for_lang() {
  case "$LANG" in
    zh) echo "更新记录" ;;
    *)  echo "Changelog" ;;
  esac
}

section_name() {
  case "$LANG:$1" in
    zh:features) echo "新功能" ;;
    zh:fixes) echo "修复" ;;
    zh:performance) echo "性能" ;;
    zh:chores) echo "杂项" ;;
    zh:other) echo "其他" ;;
    en:features) echo "Features" ;;
    en:fixes) echo "Fixes" ;;
    en:performance) echo "Performance" ;;
    en:chores) echo "Chores" ;;
    en:other) echo "Other" ;;
    *) echo "$1" ;;
  esac
}

append_section() {
  local current="$1"
  local key="$2"
  local body="$3"
  if [ -n "$body" ]; then
    current="${current}\n### $(section_name "$key")\n${body}"
  fi
  printf '%b' "$current"
}

if [ -z "$CHANGELOG" ]; then
  CHANGELOG="$(resolve_default_changelog)"
fi

# ── 获取最近 tag ──────────────────────────────────────────────────────────────

LATEST_TAG=$(git describe --tags --match "v*" --abbrev=0 2>/dev/null || echo "")
if [ -z "$LATEST_TAG" ]; then
  # 没有 tag，取所有 commit
  RANGE="HEAD"
else
  RANGE="${LATEST_TAG}..HEAD"
fi

# ── 按类型分组 commit ────────────────────────────────────────────────────────

FEATS=""
FIXES=""
PERFS=""
CHORES=""
OTHERS=""

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # 取 commit 摘要（去掉 hash）
  MSG=$(echo "$line" | sed 's/^[a-f0-9]* //')

  case "$MSG" in
    feat!:*|feat\(*\)!:*|feat:*|feat\(*\):*)
      # 去掉前缀
      CLEAN=$(echo "$MSG" | sed 's/^feat[^:]*: *//')
      FEATS="${FEATS}- ${CLEAN}\n"
      ;;
    fix!:*|fix\(*\)!:*|fix:*|fix\(*\):*)
      CLEAN=$(echo "$MSG" | sed 's/^fix[^:]*: *//')
      FIXES="${FIXES}- ${CLEAN}\n"
      ;;
    perf:*|perf\(*\):*)
      CLEAN=$(echo "$MSG" | sed 's/^perf[^:]*: *//')
      PERFS="${PERFS}- ${CLEAN}\n"
      ;;
    chore:*|chore\(*\):*|docs:*|docs\(*\):*|ci:*|ci\(*\):*|style:*|style\(*\):*|refactor:*|refactor\(*\):*|test:*|test\(*\):*)
      CLEAN=$(echo "$MSG" | sed 's/^[a-z]*[^:]*: *//')
      CHORES="${CHORES}- ${CLEAN}\n"
      ;;
    *)
      # 非 conventional commit — 归到 Other
      OTHERS="${OTHERS}- ${MSG}\n"
      ;;
  esac
done < <(git log "$RANGE" --oneline 2>/dev/null)

# ── 生成 Markdown ────────────────────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
OUTPUT="## [${VERSION}] - ${TODAY}\n"

if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || { echo "❌ 未找到 release notes: $NOTES_FILE" >&2; exit 1; }
  NOTES_BODY=$(cat "$NOTES_FILE")
  OUTPUT="${OUTPUT}\n${NOTES_BODY}\n"
else
  OUTPUT="$(append_section "$OUTPUT" "features" "$FEATS")"
  OUTPUT="$(append_section "$OUTPUT" "fixes" "$FIXES")"
  OUTPUT="$(append_section "$OUTPUT" "performance" "$PERFS")"
  OUTPUT="$(append_section "$OUTPUT" "chores" "$CHORES")"
  OUTPUT="$(append_section "$OUTPUT" "other" "$OTHERS")"
fi

# ── 输出 ──────────────────────────────────────────────────────────────────────

if [ "$MODE" = "stdout" ]; then
  printf '%b' "$OUTPUT"
  exit 0
fi

# write 模式：插入 changelog 顶部
TITLE="# $(title_for_lang)"

TMP=$(mktemp)
{
  printf '%s\n\n' "$TITLE"
  printf '%b' "$OUTPUT"
  if [ -f "$CHANGELOG" ]; then
    EXISTING_CONTENT=$(cat "$CHANGELOG")
    FIRST_LINE=$(head -1 "$CHANGELOG" || true)
    if [ "$FIRST_LINE" = "$TITLE" ]; then
      REMAINDER=$(tail -n +2 "$CHANGELOG")
    else
      REMAINDER="$EXISTING_CONTENT"
    fi
    if [ -n "${REMAINDER:-}" ]; then
      printf '\n%s' "$REMAINDER"
    fi
  fi
} > "$TMP"
mv "$TMP" "$CHANGELOG"

echo "✅ $(basename "$CHANGELOG") 已更新（v${VERSION}）"
