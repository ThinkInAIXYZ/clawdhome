#!/usr/bin/env bash
# release_build.sh — 构建打包（arm64 + x64）
#
# 用法：
#   bash scripts/release_build.sh [--version 1.10.0] [--dry-run]
#
# 版本号优先级：--version 参数 > dist/.release-version > 最新 git tag
# 需要环境变量：SIGN_APP / SIGN_PKG / NOTARIZE / APPLE_TEAM_ID 等（由 Makefile 传入）
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

VERSION_FILE="$REPO_ROOT/dist/.release-version"

DRY_RUN=false
NEXT_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) NEXT_VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *)         shift ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

# ── 确定版本号 ────────────────────────────────────────────────────────────────

if [ -z "$NEXT_VERSION" ]; then
  if [ -f "$VERSION_FILE" ]; then
    NEXT_VERSION="$(cat "$VERSION_FILE")"
  else
    NEXT_VERSION="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  fi
fi
[ -n "$NEXT_VERSION" ] || fail "无法确定版本号。请先运行 make release-prepare 或传入 --version"

PKG_ARM64="$REPO_ROOT/dist/ClawdHome-${NEXT_VERSION}-arm64.pkg"
PKG_X64="$REPO_ROOT/dist/ClawdHome-${NEXT_VERSION}-x64.pkg"

log "构建版本：v${NEXT_VERSION}"

# ── DRY RUN 预览 ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  echo ""
  log "=== DRY RUN — release-build 预览 ==="
  echo ""
  log "将执行的操作："
  echo "  1. RELEASE_VERSION=${NEXT_VERSION} PKG_ARCHS=arm64 bash scripts/build-pkg.sh --no-sync-api-version"
  echo "  2. RELEASE_VERSION=${NEXT_VERSION} PKG_ARCHS=x86_64 bash scripts/build-pkg.sh --no-sync-api-version"
  echo "  产物：dist/ClawdHome-${NEXT_VERSION}-arm64.pkg"
  echo "        dist/ClawdHome-${NEXT_VERSION}-x64.pkg"
  exit 0
fi

# ── 构建 ──────────────────────────────────────────────────────────────────────

log "构建打包（arm64）..."
RELEASE_VERSION="$NEXT_VERSION" PKG_ARCHS="arm64" bash "$SCRIPT_DIR/build-pkg.sh" --no-sync-api-version

log "构建打包（x86_64）..."
RELEASE_VERSION="$NEXT_VERSION" PKG_ARCHS="x86_64" bash "$SCRIPT_DIR/build-pkg.sh" --no-sync-api-version

[ -f "$PKG_ARM64" ] || fail "未找到 $PKG_ARM64"
[ -f "$PKG_X64" ]   || fail "未找到 $PKG_X64"

ok "打包完成：$PKG_ARM64"
ok "打包完成：$PKG_X64"
echo ""
echo "下一步："
echo "  make release-publish"
