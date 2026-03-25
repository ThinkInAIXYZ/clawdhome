#!/usr/bin/env bash
# changelog.sh — 从 git log 自动生成 CHANGELOG
#
# 用法：
#   bash scripts/changelog.sh --stdout              # 输出当前版本 changelog 到终端
#   bash scripts/changelog.sh --stdout --version 1.2.0  # 指定版本号
#   bash scripts/changelog.sh --write --version 1.2.0   # 写入 CHANGELOG.md 顶部
#
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 解析参数 ──────────────────────────────────────────────────────────────────

MODE="stdout"  # stdout | write
VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stdout)   MODE="stdout"; shift ;;
    --write)    MODE="write"; shift ;;
    --version)  VERSION="$2"; shift 2 ;;
    *)          shift ;;
  esac
done

# 自动获取版本号
if [ -z "$VERSION" ]; then
  VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "0.0.0")
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

if [ -n "$FEATS" ]; then
  OUTPUT="${OUTPUT}\n### Features\n${FEATS}"
fi
if [ -n "$FIXES" ]; then
  OUTPUT="${OUTPUT}\n### Fixes\n${FIXES}"
fi
if [ -n "$PERFS" ]; then
  OUTPUT="${OUTPUT}\n### Performance\n${PERFS}"
fi
if [ -n "$CHORES" ]; then
  OUTPUT="${OUTPUT}\n### Chores\n${CHORES}"
fi
if [ -n "$OTHERS" ]; then
  OUTPUT="${OUTPUT}\n### Other\n${OTHERS}"
fi

# ── 输出 ──────────────────────────────────────────────────────────────────────

if [ "$MODE" = "stdout" ]; then
  printf '%b' "$OUTPUT"
  exit 0
fi

# write 模式：插入 CHANGELOG.md 顶部
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

if [ ! -f "$CHANGELOG" ]; then
  printf '%s\n\n%b' "# Changelog" "$OUTPUT" > "$CHANGELOG"
else
  # 在 # Changelog 标题后插入新版本块
  TMP=$(mktemp)
  {
    head -1 "$CHANGELOG"
    echo ""
    printf '%b' "$OUTPUT"
    # 跳过原文件第一行（标题行）和紧跟的空行
    tail -n +2 "$CHANGELOG"
  } > "$TMP"
  mv "$TMP" "$CHANGELOG"
fi

echo "✅ CHANGELOG.md 已更新（v${VERSION}）"
