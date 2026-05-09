#!/usr/bin/env bash
# release.sh — ClawdHome 发布编排入口
#
# 用法：
#   bash scripts/release.sh              # 完整发布（prepare → build → publish）
#   bash scripts/release.sh --dry-run    # 预览所有阶段，不执行任何写操作
#   bash scripts/release.sh --skip-push  # 跳过 git push 和 GitHub Release
#   bash scripts/release.sh --skip-prepare  # 跳过 prepare（已有 tag）
#   bash scripts/release.sh --skip-build    # 跳过构建（已有 pkg，重试 publish）
#
# 分阶段运行：
#   make release-prepare    # 仅 Step 1：版本/CHANGELOG/commit/tag
#   make release-build      # 仅 Step 2：arm64 + x64 打包
#   make release-publish    # 仅 Step 3：push + GitHub Release + website PR
#
# 兼容 macOS bash 3.2，需要 gh CLI（publish 阶段）。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=false
SKIP_PUSH=false
SKIP_PREPARE=false
SKIP_BUILD=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=true ;;
    --skip-push)     SKIP_PUSH=true ;;
    --skip-prepare)  SKIP_PREPARE=true ;;
    --skip-build)    SKIP_BUILD=true ;;
  esac
done

# 签名/公证环境变量透传给 release_build.sh（由 Makefile 的 release 目标设置）
export SIGN_APP="${SIGN_APP:-false}"
export SIGN_PKG="${SIGN_PKG:-false}"
export NOTARIZE="${NOTARIZE:-false}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
export APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
export PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# ── DRY RUN：依次预览三个阶段 ────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  # 计算目标版本号，让三个阶段的预览保持一致
  NEXT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "")
  [ -n "$NEXT_VERSION" ] || { echo "❌ 无法计算下一版本号" >&2; exit 1; }

  if [ "$SKIP_PREPARE" = false ]; then
    bash "$SCRIPT_DIR/release_prepare.sh" --dry-run
  fi
  echo ""
  if [ "$SKIP_BUILD" = false ]; then
    bash "$SCRIPT_DIR/release_build.sh" --dry-run --version "$NEXT_VERSION"
  fi
  echo ""
  if [ "$SKIP_PUSH" = true ]; then
    bash "$SCRIPT_DIR/release_publish.sh" --dry-run --version "$NEXT_VERSION" --skip-push
  else
    bash "$SCRIPT_DIR/release_publish.sh" --dry-run --version "$NEXT_VERSION"
  fi
  exit 0
fi

# ── 正式运行 ──────────────────────────────────────────────────────────────────

if [ "$SKIP_PREPARE" = false ]; then
  bash "$SCRIPT_DIR/release_prepare.sh"
fi

if [ "$SKIP_BUILD" = false ]; then
  bash "$SCRIPT_DIR/release_build.sh"
fi

if [ "$SKIP_PUSH" = true ]; then
  bash "$SCRIPT_DIR/release_publish.sh" --skip-push
else
  bash "$SCRIPT_DIR/release_publish.sh"
fi
