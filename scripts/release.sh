#!/usr/bin/env bash
# release.sh — ClawdHome 一键发布脚本
#
# 用法：
#   bash scripts/release.sh              # 完整发布流程
#   bash scripts/release.sh --dry-run    # 仅预览，不执行任何写操作
#   bash scripts/release.sh --skip-push  # 跳过 git push 和 GitHub Release
#
# 流程：
#   1. semver.sh 计算下一版本号
#   2. 读取 release-notes/vX.Y.Z.{zh,en}.md
#   3. 更新 CHANGELOG.zh.md / CHANGELOG.en.md
#   4. git commit + tag
#   5. build-pkg.sh 构建打包
#   6. 同步 version.json release_notes / release_notes_en
#   7. git push + gh release create
#
# 兼容 macOS bash 3.2，需要 gh CLI。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 配置 ──────────────────────────────────────────────────────────────────────

WEBSITE_DIR="${WEBSITE_DIR:-$REPO_ROOT/../clawdhome_website}"
API_VERSION_JSON="$WEBSITE_DIR/api/version.json"
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
INFO_PLIST="$REPO_ROOT/ClawdHome/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DRY_RUN=false
SKIP_PUSH=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --skip-push)  SKIP_PUSH=true ;;
  esac
done

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

set_plist_value() {
  local key="$1"
  local value="$2"
  "$PLIST_BUDDY" -c "Set :$key $value" "$INFO_PLIST" >/dev/null 2>&1 || \
    "$PLIST_BUDDY" -c "Add :$key string $value" "$INFO_PLIST" >/dev/null 2>&1
}

render_changelog_preview() {
  local lang="$1"
  local notes_file="$2"
  if [ -f "$notes_file" ]; then
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang "$lang" --version "$NEXT_VERSION" --notes-file "$notes_file"
  else
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang "$lang" --version "$NEXT_VERSION"
  fi
}

# ── 前置检查 ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = false ]; then
  # 检查工作区是否干净（允许文档草稿目录未跟踪）
  DIRTY=$(git status --porcelain 2>/dev/null | grep -v "^?? scripts/" | grep -v "^?? release-notes/" || true)
  if [ -n "$DIRTY" ]; then
    echo "$DIRTY"
    fail "工作区有未提交的更改，请先 commit 或 stash"
  fi
fi

# 检查 gh CLI
if [ "$DRY_RUN" = false ] && [ "$SKIP_PUSH" = false ] && ! command -v gh &>/dev/null; then
  fail "需要 GitHub CLI（gh）。安装：brew install gh && gh auth login"
fi

# 检查 gh 登录状态
if [ "$DRY_RUN" = false ] && [ "$SKIP_PUSH" = false ] && ! gh auth status &>/dev/null 2>&1; then
  fail "gh 未登录。请运行：gh auth login"
fi

# ── Step 1：计算版本号 ────────────────────────────────────────────────────────

CURRENT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" --current 2>/dev/null || echo "")
NEXT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "")
BUMP_TYPE=$(bash "$SCRIPT_DIR/semver.sh" --bump-type 2>/dev/null || echo "none")

[ -n "$NEXT_VERSION" ] || fail "无法计算下一版本号"

log "当前版本：${CURRENT_VERSION:-无 tag}"
log "下一版本：v${NEXT_VERSION}（${BUMP_TYPE} bump）"

ZH_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.zh.md"
EN_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.en.md"

if [ "$BUMP_TYPE" = "none" ]; then
  warn "自上次 tag 以来没有 feat/fix commit，将执行 patch bump"
fi

if [ "$DRY_RUN" = true ]; then
  if [ ! -f "$ZH_NOTES_FILE" ] || [ ! -f "$EN_NOTES_FILE" ]; then
    warn "未找到正式 release notes，以下预览使用 git log 自动生成的草稿"
    [ -f "$ZH_NOTES_FILE" ] || warn "待补中文文件：$ZH_NOTES_FILE"
    [ -f "$EN_NOTES_FILE" ] || warn "待补英文文件：$EN_NOTES_FILE"
    warn "可先运行：make release-notes-draft"
  fi
  echo ""
  log "=== DRY RUN 模式 — 以下为预览 ==="
  echo ""
  log "将写入的中文 CHANGELOG："
  render_changelog_preview zh "$ZH_NOTES_FILE"
  echo ""
  log "将写入的英文 CHANGELOG："
  render_changelog_preview en "$EN_NOTES_FILE"
  echo ""
  log "将执行的操作："
  echo "  1. 更新 ClawdHome/Info.plist -> ${NEXT_VERSION}"
  echo "  2. 更新 CHANGELOG.zh.md / CHANGELOG.en.md"
  echo "  3. git commit -m \"chore(release): v${NEXT_VERSION}\""
  echo "  4. git tag -a v${NEXT_VERSION}"
  echo "  5. xcodebuild + pkgbuild/productsign${NOTARIZE:+ + notarize} → dist/ClawdHome-${NEXT_VERSION}.pkg"
  echo "  6. 同步 version.json（含中英文 release notes）"
  echo "  7. git push && git push --tags"
  echo "  8. gh release create v${NEXT_VERSION}"
  exit 0
fi

[ -f "$ZH_NOTES_FILE" ] || fail "缺少中文 release notes：$ZH_NOTES_FILE"
[ -f "$EN_NOTES_FILE" ] || fail "缺少英文 release notes：$EN_NOTES_FILE"

# ── Step 2：生成 CHANGELOG ────────────────────────────────────────────────────

log "更新中英文 CHANGELOG..."
bash "$SCRIPT_DIR/changelog.sh" --write --lang zh --version "$NEXT_VERSION" --notes-file "$ZH_NOTES_FILE"
bash "$SCRIPT_DIR/changelog.sh" --write --lang en --version "$NEXT_VERSION" --notes-file "$EN_NOTES_FILE"

# GitHub Release 和应用内更新使用同一份 release-notes 源
GITHUB_RELEASE_NOTES=$(bash "$SCRIPT_DIR/release_notes.sh" --github --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_ZH=$(bash "$SCRIPT_DIR/release_notes.sh" --api zh --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_EN=$(bash "$SCRIPT_DIR/release_notes.sh" --api en --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")

# 统一 release 版本：正式发布时将 Info.plist 对齐到即将发布的 semver
log "更新 Info.plist 版本：${NEXT_VERSION}"
set_plist_value "CFBundleShortVersionString" "$NEXT_VERSION"

# ── Step 3：commit + tag ──────────────────────────────────────────────────────

log "提交 release commit..."
git add "$INFO_PLIST" CHANGELOG.zh.md CHANGELOG.en.md "$ZH_NOTES_FILE" "$EN_NOTES_FILE"
git commit -m "chore(release): v${NEXT_VERSION}"

log "打 tag v${NEXT_VERSION}..."
git tag -a "v${NEXT_VERSION}" -m "Release v${NEXT_VERSION}"

# 设置回滚点
RELEASE_COMMIT=$(git rev-parse HEAD)
NEED_ROLLBACK=true

# ── 回滚函数 ──────────────────────────────────────────────────────────────────

rollback() {
  if [ "$NEED_ROLLBACK" = true ]; then
    warn "发布失败，正在回滚..."
    git tag -d "v${NEXT_VERSION}" 2>/dev/null || true
    git reset --hard HEAD~1 2>/dev/null || true
    warn "已回滚：删除 tag v${NEXT_VERSION}，撤销 release commit"
  fi
}
trap rollback EXIT

# ── Step 4：构建打包 ──────────────────────────────────────────────────────────

log "构建打包..."
RELEASE_VERSION="$NEXT_VERSION" bash "$SCRIPT_DIR/build-pkg.sh" --no-sync-api-version

PKG=$(ls -t dist/ClawdHome-*.pkg 2>/dev/null | head -1)
[ -n "$PKG" ] || fail "未找到 dist/ClawdHome-*.pkg"

ok "打包完成：$PKG"

# ── Step 5：同步 version.json ────────────────────────────────────────────────

if [ -f "$API_VERSION_JSON" ]; then
  log "同步 version.json..."

  DOWNLOAD_URL="https://clawdhome.app/download/ClawdHome-${NEXT_VERSION}.pkg"

  TMP_JSON=$(mktemp)
  /usr/bin/python3 - "$API_VERSION_JSON" "$TMP_JSON" "$NEXT_VERSION" "$DOWNLOAD_URL" "$API_RELEASE_NOTES_ZH" "$API_RELEASE_NOTES_EN" <<'PY'
import json
import sys

src, dst, version, download_url, notes_zh, notes_en = sys.argv[1:]
with open(src, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data["version"] = version
data["download_url"] = download_url
data["release_notes"] = notes_zh
data["release_notes_en"] = notes_en

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  mv "$TMP_JSON" "$API_VERSION_JSON"
  chmod 644 "$API_VERSION_JSON"

  # 复制 pkg 到网站 download 目录
  WEBSITE_DOWNLOAD_DIR="$WEBSITE_DIR/download"
  if [ -d "$WEBSITE_DIR" ]; then
    mkdir -p "$WEBSITE_DOWNLOAD_DIR"
    cp -f "$PKG" "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}.pkg"
    cp -f "$PKG" "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest.pkg"
    chmod 644 "$WEBSITE_DOWNLOAD_DIR/ClawdHome-${NEXT_VERSION}.pkg"
    chmod 644 "$WEBSITE_DOWNLOAD_DIR/ClawdHome-latest.pkg"
    ok "已复制 pkg 到网站 download 目录"
  fi

  ok "version.json 已同步 → v${NEXT_VERSION}"
else
  warn "未找到 $API_VERSION_JSON，跳过 API 版本同步"
fi

# ── Step 6：push + GitHub Release ────────────────────────────────────────────

if [ "$SKIP_PUSH" = false ]; then
  log "推送到远程仓库..."
  git push
  git push --tags

  log "创建 GitHub Release..."
  RELEASE_NOTES_FILE=$(mktemp)
  echo "$GITHUB_RELEASE_NOTES" > "$RELEASE_NOTES_FILE"

  gh release create "v${NEXT_VERSION}" "$PKG" \
    --title "ClawdHome ${NEXT_VERSION}" \
    --notes-file "$RELEASE_NOTES_FILE"

  rm -f "$RELEASE_NOTES_FILE"
  ok "GitHub Release v${NEXT_VERSION} 已创建"
else
  warn "跳过 push 和 GitHub Release（--skip-push）"
fi

# 发布成功，取消回滚
NEED_ROLLBACK=false
trap - EXIT

# ── 完成摘要 ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Release v${NEXT_VERSION} 完成"
echo ""
echo "  版本：${CURRENT_VERSION:-无} → ${NEXT_VERSION}"
echo "  Bump：${BUMP_TYPE}"
echo "  PKG：$PKG"
echo "  Tag：v${NEXT_VERSION}"
if [ "$SKIP_PUSH" = false ]; then
  echo "  GitHub Release：已创建"
fi
if [ -f "$API_VERSION_JSON" ]; then
  echo "  version.json：已同步"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -d "$WEBSITE_DIR" ]; then
  echo "下一步（更新线上网站）："
  echo "  cd $WEBSITE_DIR && make deploy"
fi
echo ""
