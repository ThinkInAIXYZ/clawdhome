#!/usr/bin/env bash
# semver.sh — 从 git tag + conventional commits 自动计算语义化版本号
#
# 用法：
#   bash scripts/semver.sh              # 输出下一版本号（如 1.2.0）
#   bash scripts/semver.sh --current    # 输出当前 tag 版本号（如 1.1.7）
#   bash scripts/semver.sh --bump-type  # 仅输出 bump 类型（major/minor/patch/none）
#
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 解析参数 ──────────────────────────────────────────────────────────────────

MODE="next"  # next | current | bump-type
for arg in "$@"; do
  case "$arg" in
    --current)    MODE="current" ;;
    --bump-type)  MODE="bump-type" ;;
  esac
done

# ── 获取当前 tag 版本 ────────────────────────────────────────────────────────

get_current_version() {
  local tag
  tag=$(git describe --tags --match "v*" --abbrev=0 2>/dev/null || echo "")
  if [ -z "$tag" ]; then
    echo ""
    return
  fi
  # 去掉 v 前缀
  echo "${tag#v}"
}

CURRENT=$(get_current_version)

if [ "$MODE" = "current" ]; then
  if [ -z "$CURRENT" ]; then
    echo "未找到 v* tag" >&2
    exit 1
  fi
  echo "$CURRENT"
  exit 0
fi

# ── 解析版本号为 MAJOR.MINOR.PATCH ──────────────────────────────────────────

if [ -z "$CURRENT" ]; then
  echo "未找到 v* tag，无法计算下一版本。请先打初始 tag（如 git tag v1.1.7）" >&2
  exit 1
fi

MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)

# 默认值
[ -z "$MAJOR" ] && MAJOR=0
[ -z "$MINOR" ] && MINOR=0
[ -z "$PATCH" ] && PATCH=0

# ── 遍历自 tag 以来的 commit 确定 bump 类型 ─────────────────────────────────

LATEST_TAG=$(git describe --tags --match "v*" --abbrev=0 2>/dev/null)
BUMP="none"  # none | patch | minor | major

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # 检查 commit body 中的 BREAKING CHANGE
  HASH=$(echo "$line" | cut -d' ' -f1)
  BODY=$(git log -1 --format="%b" "$HASH" 2>/dev/null || echo "")
  SUBJECT=$(echo "$line" | cut -d' ' -f2-)

  if echo "$BODY" | grep -q "BREAKING CHANGE:" 2>/dev/null; then
    BUMP="major"
    continue
  fi

  # 检查标题前缀：优先匹配 conventional commit，再用关键词推断
  MATCHED=false
  case "$SUBJECT" in
    # Conventional Commits（严格匹配）
    feat!:*|feat\(*\)!:*) [ "$BUMP" != "major" ] && BUMP="major"; MATCHED=true ;;
    fix!:*|fix\(*\)!:*)   [ "$BUMP" != "major" ] && BUMP="major"; MATCHED=true ;;
    feat:*|feat\(*\):*)   { [ "$BUMP" = "none" ] || [ "$BUMP" = "patch" ]; } && BUMP="minor"; MATCHED=true ;;
    fix:*|fix\(*\):*)     [ "$BUMP" = "none" ] && BUMP="patch"; MATCHED=true ;;
    perf:*|perf\(*\):*)   [ "$BUMP" = "none" ] && BUMP="patch"; MATCHED=true ;;
    chore:*|chore\(*\):*|docs:*|docs\(*\):*|ci:*|ci\(*\):*|style:*|style\(*\):*|refactor:*|refactor\(*\):*|test:*|test\(*\):*|build:*|build\(*\):*)
      MATCHED=true ;;  # 明确的 chore 类不触发 bump
  esac

  # 非 conventional commit — 用关键词智能推断
  if [ "$MATCHED" = false ]; then
    LOWER=$(echo "$SUBJECT" | tr '[:upper:]' '[:lower:]')
    case "$LOWER" in
      add\ *|feat\ *|implement\ *|support\ *|new\ *|introduce\ *)
        { [ "$BUMP" = "none" ] || [ "$BUMP" = "patch" ]; } && BUMP="minor" ;;
      fix\ *|bugfix\ *|hotfix\ *|patch\ *|resolve\ *)
        [ "$BUMP" = "none" ] && BUMP="patch" ;;
      update\ *|improve\ *|enhance\ *|optimize\ *|upgrade\ *|open\ *)
        [ "$BUMP" = "none" ] && BUMP="patch" ;;
    esac
  fi
done < <(git log "${LATEST_TAG}..HEAD" --oneline 2>/dev/null)

if [ "$MODE" = "bump-type" ]; then
  echo "$BUMP"
  exit 0
fi

# ── 计算下一版本号 ────────────────────────────────────────────────────────────

case "$BUMP" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  none)
    # 没有 feat/fix commit — 默认 patch bump
    PATCH=$((PATCH + 1))
    ;;
esac

echo "${MAJOR}.${MINOR}.${PATCH}"
