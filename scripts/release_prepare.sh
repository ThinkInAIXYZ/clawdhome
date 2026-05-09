#!/usr/bin/env bash
# release_prepare.sh — 发布准备：版本计算 → CHANGELOG 写入 → commit → tag
#
# 用法：
#   bash scripts/release_prepare.sh              # 正常运行
#   bash scripts/release_prepare.sh --dry-run    # 预览，不执行写操作
#
# 成功后写入 dist/.release-version 供后续脚本读取。
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
INFO_PLIST="$REPO_ROOT/ClawdHome/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
VERSION_FILE="$REPO_ROOT/dist/.release-version"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

fail_missing_notes() {
  local lang_label="$1"
  local notes_file="$2"
  cat >&2 <<EOF
❌ 缺少${lang_label} release notes：$notes_file

请先按下面步骤处理：
  1. 运行：make release-notes-draft
  2. 编辑并确认：$notes_file
  3. 预检查：make release-dry-run
  4. 正式发布：make release-prepare
EOF
  exit 1
}

set_plist_value() {
  local key="$1"
  local value="$2"
  "$PLIST_BUDDY" -c "Set :$key $value" "$INFO_PLIST" >/dev/null 2>&1 || \
    "$PLIST_BUDDY" -c "Add :$key string $value" "$INFO_PLIST" >/dev/null 2>&1
}

# ── 前置检查 ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = false ]; then
  DIRTY=$(git status --porcelain 2>/dev/null \
    | grep -v "^?? scripts/" \
    | grep -v "^?? release-notes/" \
    | grep -v "^?? dist/" \
    || true)
  if [ -n "$DIRTY" ]; then
    echo "$DIRTY"
    fail "工作区有未提交的更改，请先 commit 或 stash"
  fi
fi

# ── 计算版本号 ────────────────────────────────────────────────────────────────

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

# ── DRY RUN 预览 ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  if [ ! -f "$ZH_NOTES_FILE" ] || [ ! -f "$EN_NOTES_FILE" ]; then
    warn "未找到 release notes，以下预览使用 git log 草稿"
    [ -f "$ZH_NOTES_FILE" ] || warn "待补中文文件：$ZH_NOTES_FILE"
    [ -f "$EN_NOTES_FILE" ] || warn "待补英文文件：$EN_NOTES_FILE"
    warn "可先运行：make release-notes-draft"
  fi
  echo ""
  log "=== DRY RUN — release-prepare 预览 ==="
  echo ""
  log "将写入的中文 CHANGELOG："
  if [ -f "$ZH_NOTES_FILE" ]; then
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang zh --version "$NEXT_VERSION" --notes-file "$ZH_NOTES_FILE"
  else
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang zh --version "$NEXT_VERSION"
  fi
  echo ""
  log "将写入的英文 CHANGELOG："
  if [ -f "$EN_NOTES_FILE" ]; then
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang en --version "$NEXT_VERSION" --notes-file "$EN_NOTES_FILE"
  else
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang en --version "$NEXT_VERSION"
  fi
  echo ""
  log "将执行的操作："
  echo "  1. 更新 ClawdHome/Info.plist → ${NEXT_VERSION}"
  echo "  2. 写入 CHANGELOG.zh.md / CHANGELOG.en.md"
  echo "  3. git commit -m \"chore(release): v${NEXT_VERSION}\""
  echo "  4. git tag -a v${NEXT_VERSION}"
  echo "  5. 写入 dist/.release-version"
  exit 0
fi

[ -f "$ZH_NOTES_FILE" ] || fail_missing_notes "中文" "$ZH_NOTES_FILE"
[ -f "$EN_NOTES_FILE" ] || fail_missing_notes "英文" "$EN_NOTES_FILE"

# ── 写入 CHANGELOG ────────────────────────────────────────────────────────────

log "更新中英文 CHANGELOG..."
bash "$SCRIPT_DIR/changelog.sh" --write --lang zh --version "$NEXT_VERSION" --notes-file "$ZH_NOTES_FILE"
bash "$SCRIPT_DIR/changelog.sh" --write --lang en --version "$NEXT_VERSION" --notes-file "$EN_NOTES_FILE"

# ── 更新 Info.plist ───────────────────────────────────────────────────────────

log "更新 Info.plist 版本：${NEXT_VERSION}"
set_plist_value "CFBundleShortVersionString" "$NEXT_VERSION"

# ── commit + tag ──────────────────────────────────────────────────────────────

log "提交 release commit..."
git add "$INFO_PLIST" CHANGELOG.zh.md CHANGELOG.en.md "$ZH_NOTES_FILE" "$EN_NOTES_FILE"
git commit -m "chore(release): v${NEXT_VERSION}"

log "打 tag v${NEXT_VERSION}..."
git tag -a "v${NEXT_VERSION}" -m "Release v${NEXT_VERSION}"

NEED_ROLLBACK=true
rollback() {
  if [ "$NEED_ROLLBACK" = true ]; then
    warn "prepare 失败，正在回滚..."
    git tag -d "v${NEXT_VERSION}" 2>/dev/null || true
    git reset --hard HEAD~1 2>/dev/null || true
    warn "已回滚：删除 tag v${NEXT_VERSION}，撤销 release commit"
  fi
}
trap rollback EXIT

# ── 写版本状态文件 ────────────────────────────────────────────────────────────

mkdir -p "$REPO_ROOT/dist"
echo "$NEXT_VERSION" > "$VERSION_FILE"

NEED_ROLLBACK=false
trap - EXIT

ok "prepare 完成 → v${NEXT_VERSION}"
echo ""
echo "下一步："
echo "  make release-build    # 构建打包（arm64 + x64）"
echo "  make release-publish  # push + GitHub Release + website PR"
