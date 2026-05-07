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
#   2. changelog.sh 生成 CHANGELOG
#   3. git commit + tag
#   4. build-pkg.sh 构建打包
#   5. 同步 version.json release_notes
#   6. git push + gh release create
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

# ── 前置检查 ──────────────────────────────────────────────────────────────────

# 检查工作区是否干净（允许 CHANGELOG.md 未跟踪）
DIRTY=$(git status --porcelain 2>/dev/null | grep -v "^?? CHANGELOG.md$" | grep -v "^?? scripts/" || true)
if [ -n "$DIRTY" ]; then
  echo "$DIRTY"
  fail "工作区有未提交的更改，请先 commit 或 stash"
fi

# 检查 gh CLI
if [ "$SKIP_PUSH" = false ] && ! command -v gh &>/dev/null; then
  fail "需要 GitHub CLI（gh）。安装：brew install gh && gh auth login"
fi

# 检查 gh 登录状态
if [ "$SKIP_PUSH" = false ] && ! gh auth status &>/dev/null 2>&1; then
  fail "gh 未登录。请运行：gh auth login"
fi

# ── Step 1：计算版本号 ────────────────────────────────────────────────────────

CURRENT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" --current 2>/dev/null || echo "")
NEXT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "")
BUMP_TYPE=$(bash "$SCRIPT_DIR/semver.sh" --bump-type 2>/dev/null || echo "none")

[ -n "$NEXT_VERSION" ] || fail "无法计算下一版本号"

log "当前版本：${CURRENT_VERSION:-无 tag}"
log "下一版本：v${NEXT_VERSION}（${BUMP_TYPE} bump）"

if [ "$BUMP_TYPE" = "none" ]; then
  warn "自上次 tag 以来没有 feat/fix commit，将执行 patch bump"
fi

if [ "$DRY_RUN" = true ]; then
  echo ""
  log "=== DRY RUN 模式 — 以下为预览 ==="
  echo ""
  log "将生成的 CHANGELOG："
  bash "$SCRIPT_DIR/changelog.sh" --stdout --version "$NEXT_VERSION"
  echo ""
  log "将执行的操作："
  echo "  1. 更新 CHANGELOG.md"
  echo "  2. git commit -m \"chore(release): v${NEXT_VERSION}\""
  echo "  3. git tag -a v${NEXT_VERSION}"
  echo "  4. xcodebuild + pkgbuild → dist/ClawdHome-${NEXT_VERSION}.pkg"
  echo "  5. 同步 version.json"
  echo "  6. git push && git push --tags"
  echo "  7. gh release create v${NEXT_VERSION}"
  exit 0
fi

# ── Step 2：生成 CHANGELOG ────────────────────────────────────────────────────

log "生成 CHANGELOG..."
bash "$SCRIPT_DIR/changelog.sh" --write --version "$NEXT_VERSION"

# 同时获取 release notes 文本（用于 version.json 和 gh release）
RELEASE_NOTES=$(bash "$SCRIPT_DIR/changelog.sh" --stdout --version "$NEXT_VERSION")

# ── Step 3：commit + tag ──────────────────────────────────────────────────────

log "提交 release commit..."
git add CHANGELOG.md
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
    git reset --soft HEAD~1 2>/dev/null || true
    git restore --staged CHANGELOG.md 2>/dev/null || true
    warn "已回滚：删除 tag v${NEXT_VERSION}，撤销 release commit"
  fi
}
trap rollback EXIT

# ── Step 4：构建打包 ──────────────────────────────────────────────────────────

log "构建打包..."
bash "$SCRIPT_DIR/build-pkg.sh" --no-sync-api-version

PKG=$(ls -t dist/ClawdHome-*.pkg 2>/dev/null | head -1)
[ -n "$PKG" ] || fail "未找到 dist/ClawdHome-*.pkg"

ok "打包完成：$PKG"

# ── Step 5：同步 version.json ────────────────────────────────────────────────

if [ -f "$API_VERSION_JSON" ]; then
  log "同步 version.json..."

  DOWNLOAD_URL="https://clawdhome.app/download/ClawdHome-${NEXT_VERSION}.pkg"

  # 提取中文和英文 release notes（简单处理：用 changelog 内容）
  # 生成纯文本版 release notes（去掉 ## 和 ### 标记）
  NOTES_PLAIN=$(echo "$RELEASE_NOTES" | sed 's/^## .*//; s/^### //' | sed '/^$/d')

  TMP_JSON=$(mktemp)
  awk -v ver="$NEXT_VERSION" -v dl="$DOWNLOAD_URL" -v notes="$NOTES_PLAIN" '
  {
    if ($0 ~ /"version"[[:space:]]*:/) {
      sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" ver "\"")
    }
    if ($0 ~ /"download_url"[[:space:]]*:/) {
      sub(/"download_url"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"download_url\": \"" dl "\"")
    }
    print
  }' "$API_VERSION_JSON" > "$TMP_JSON"
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
  echo "$RELEASE_NOTES" > "$RELEASE_NOTES_FILE"

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
