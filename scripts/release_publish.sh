#!/usr/bin/env bash
# release_publish.sh — 发布：version.json 同步 → push → GitHub Release → website PR
#
# 用法：
#   bash scripts/release_publish.sh [--version 1.10.0] [--dry-run] [--skip-push]
#
# 版本号优先级：--version > dist/.release-version > 最新 git tag
# 可重复运行：push/gh release 已存在时会提示但不中断。
# 兼容 macOS bash 3.2，需要 gh CLI。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

WEBSITE_DIR="${WEBSITE_DIR:-$REPO_ROOT/../clawdhome_website}"
WEBSITE_REPO="${WEBSITE_REPO:-deepjerry-ai/clawdhome_website}"
API_VERSION_JSON="$WEBSITE_DIR/api/version.json"
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
VERSION_FILE="$REPO_ROOT/dist/.release-version"

DRY_RUN=false
SKIP_PUSH=false
NEXT_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   NEXT_VERSION="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true;      shift ;;
    --skip-push) SKIP_PUSH=true;    shift ;;
    *)           shift ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
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

ZH_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.zh.md"
EN_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.en.md"
PKG_ARM64="$REPO_ROOT/dist/ClawdHome-${NEXT_VERSION}-arm64.pkg"
PKG_X64="$REPO_ROOT/dist/ClawdHome-${NEXT_VERSION}-x64.pkg"

[ -f "$ZH_NOTES_FILE" ] || fail "未找到 $ZH_NOTES_FILE"
[ -f "$EN_NOTES_FILE" ] || fail "未找到 $EN_NOTES_FILE"

# ── 检查工具 ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = false ] && [ "$SKIP_PUSH" = false ]; then
  command -v gh &>/dev/null || fail "需要 GitHub CLI（gh）。安装：brew install gh && gh auth login"
  gh auth status &>/dev/null 2>&1 || fail "gh 未登录。请运行：gh auth login"
fi

log "发布版本：v${NEXT_VERSION}"

# ── 读取 release notes ────────────────────────────────────────────────────────

GITHUB_RELEASE_NOTES=$(bash "$SCRIPT_DIR/release_notes.sh" --github  --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_ZH=$(bash "$SCRIPT_DIR/release_notes.sh" --api zh  --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_EN=$(bash "$SCRIPT_DIR/release_notes.sh" --api en  --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")

# ── DRY RUN 预览 ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  echo ""
  log "=== DRY RUN — release-publish 预览 ==="
  echo ""
  log "将执行的操作："
  echo "  1. git push && git push origin v${NEXT_VERSION}"
  echo "  2. gh release create v${NEXT_VERSION} (附带 arm64 + x64 pkg)"
  if [ -f "$API_VERSION_JSON" ]; then
    echo "  3. 同步 api/version.json → v${NEXT_VERSION}"
    echo "     download_url → https://clawdhome.app/download/ClawdHome-${NEXT_VERSION}-arm64.pkg"
  fi
  if [ -d "$WEBSITE_DIR" ]; then
    echo "  4. 写入 website CHANGELOG.zh-CN.md / CHANGELOG.en.md"
    echo "     gh pr create --repo ${WEBSITE_REPO} --title 'chore(release): sync v${NEXT_VERSION} changelog'"
  fi
  echo ""
  log "GitHub Release 正文预览："
  echo "$GITHUB_RELEASE_NOTES"
  exit 0
fi

[ -f "$PKG_ARM64" ] || fail "未找到 $PKG_ARM64，请先运行 make release-build"
[ -f "$PKG_X64" ]   || fail "未找到 $PKG_X64，请先运行 make release-build"

# ── 同步 api/version.json ──────────────────────────────────────────────────────

if [ -f "$API_VERSION_JSON" ]; then
  log "同步 version.json..."

  DOWNLOAD_URL="https://clawdhome.app/download/ClawdHome-${NEXT_VERSION}-arm64.pkg"
  DOWNLOAD_URL_X64="https://clawdhome.app/download/ClawdHome-${NEXT_VERSION}-x64.pkg"

  TMP_JSON=$(mktemp)
  /usr/bin/python3 - "$API_VERSION_JSON" "$TMP_JSON" "$NEXT_VERSION" \
      "$DOWNLOAD_URL" "$DOWNLOAD_URL_X64" \
      "$API_RELEASE_NOTES_ZH" "$API_RELEASE_NOTES_EN" <<'PY'
import json, sys
src, dst, version, dl_url, dl_url_x64, notes_zh, notes_en = sys.argv[1:]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["version"]           = version
data["download_url"]      = dl_url
data["download_url_x64"]  = dl_url_x64
data["release_notes"]     = notes_zh
data["release_notes_en"]  = notes_en
with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  mv "$TMP_JSON" "$API_VERSION_JSON"
  chmod 644 "$API_VERSION_JSON"
  ok "version.json 已同步 → v${NEXT_VERSION}"
else
  warn "未找到 $API_VERSION_JSON，跳过 version.json 同步"
fi

# ── 复制 pkg 到 website/download ──────────────────────────────────────────────

if [ -d "$WEBSITE_DIR" ]; then
  WEBSITE_DOWNLOAD_DIR="$WEBSITE_DIR/download"
  mkdir -p "$WEBSITE_DOWNLOAD_DIR"
  cp -f "$PKG_ARM64" "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}-arm64.pkg"
  cp -f "$PKG_X64"   "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}-x64.pkg"
  cp -f "$PKG_ARM64" "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}.pkg"
  cp -f "$PKG_ARM64" "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest.pkg"
  cp -f "$PKG_X64"   "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest-x64.pkg"
  chmod 644 "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}-arm64.pkg" \
            "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}-x64.pkg" \
            "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}.pkg" \
            "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest.pkg" \
            "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest-x64.pkg"
  ok "pkg 已复制到 website/download"
fi

# ── website CHANGELOG + PR ────────────────────────────────────────────────────

if [ -d "$WEBSITE_DIR" ]; then
  log "创建 website changelog PR..."
  if [ "$SKIP_PUSH" = true ]; then
    bash "$SCRIPT_DIR/release_website_pr.sh" \
      --version "$NEXT_VERSION" \
      --notes-dir "$NOTES_DIR" \
      --website-dir "$WEBSITE_DIR" \
      --website-repo "$WEBSITE_REPO" \
      --skip-push
  else
    bash "$SCRIPT_DIR/release_website_pr.sh" \
      --version "$NEXT_VERSION" \
      --notes-dir "$NOTES_DIR" \
      --website-dir "$WEBSITE_DIR" \
      --website-repo "$WEBSITE_REPO"
  fi
fi

# ── push + GitHub Release ─────────────────────────────────────────────────────

if [ "$SKIP_PUSH" = false ]; then
  log "推送到远程仓库..."
  git push
  git push origin "v${NEXT_VERSION}"

  log "创建 GitHub Release..."
  RELEASE_NOTES_FILE=$(mktemp)
  echo "$GITHUB_RELEASE_NOTES" > "$RELEASE_NOTES_FILE"
  gh release create "v${NEXT_VERSION}" "$PKG_ARM64" "$PKG_X64" \
    --title "ClawdHome ${NEXT_VERSION}" \
    --notes-file "$RELEASE_NOTES_FILE" || \
    warn "GitHub Release 创建失败（可能已存在），请手动检查"
  rm -f "$RELEASE_NOTES_FILE"
  ok "GitHub Release v${NEXT_VERSION} 已创建"
else
  warn "跳过 push 和 GitHub Release（--skip-push）"
fi

# ── 完成摘要 ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ publish v${NEXT_VERSION} 完成"
echo ""
if [ "$SKIP_PUSH" = false ]; then
  echo "  GitHub Release：已创建"
fi
if [ -f "$API_VERSION_JSON" ]; then
  echo "  version.json：已同步"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -d "$WEBSITE_DIR" ]; then
  echo "下一步（合并 website PR 后部署）："
  echo "  cd $WEBSITE_DIR && make deploy"
fi
echo ""
