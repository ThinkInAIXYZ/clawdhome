#!/usr/bin/env bash
# release_website_pr.sh — 更新 website CHANGELOG 并开 PR
#
# 用法：
#   bash scripts/release_website_pr.sh \
#     --version 1.10.0 \
#     --notes-dir release-notes \
#     --website-dir ../clawdhome_website \
#     --website-repo deepjerry-ai/clawdhome_website \
#     [--skip-push]
#
# 行为：
#   1. fetch origin/main
#   2. 创建 release/v{VERSION} 分支（已存在则重置）
#   3. 写入 CHANGELOG.zh-CN.md / CHANGELOG.en.md（从 release-notes/ 直接取）
#   4. git add 上述文件 + api/version.json + download/*.pkg（若有变动）
#   5. commit + push + gh pr create
#   6. 若无 remote / --skip-push：仅本地 commit，输出手动操作提示
# 兼容 macOS bash 3.2，零外部依赖。

set -euo pipefail
export LC_ALL=C

VERSION=""
NOTES_DIR=""
WEBSITE_DIR=""
WEBSITE_REPO=""
SKIP_PUSH=false

while [ $# -gt 0 ]; do
  case "$1" in
    --version)      VERSION="$2";      shift 2 ;;
    --notes-dir)    NOTES_DIR="$2";    shift 2 ;;
    --website-dir)  WEBSITE_DIR="$2";  shift 2 ;;
    --website-repo) WEBSITE_REPO="$2"; shift 2 ;;
    --skip-push)    SKIP_PUSH=true;    shift ;;
    *)              shift ;;
  esac
done

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

[ -n "$VERSION" ]     || { warn "release_website_pr: 未指定 --version，跳过"; exit 0; }
[ -d "$WEBSITE_DIR" ] || { warn "website 目录不存在（${WEBSITE_DIR}），跳过"; exit 0; }

ZH_NOTES="$NOTES_DIR/v${VERSION}.zh.md"
EN_NOTES="$NOTES_DIR/v${VERSION}.en.md"
[ -f "$ZH_NOTES" ] || { warn "未找到 $ZH_NOTES，跳过 website PR"; exit 0; }
[ -f "$EN_NOTES" ] || { warn "未找到 $EN_NOTES，跳过 website PR"; exit 0; }

ZH_CHANGELOG="$WEBSITE_DIR/CHANGELOG.zh-CN.md"
EN_CHANGELOG="$WEBSITE_DIR/CHANGELOG.en.md"
[ -f "$ZH_CHANGELOG" ] || { warn "未找到 $ZH_CHANGELOG，跳过 website PR"; exit 0; }
[ -f "$EN_CHANGELOG" ] || { warn "未找到 $EN_CHANGELOG，跳过 website PR"; exit 0; }

BRANCH="release/v${VERSION}"
TODAY=$(date +%Y-%m-%d)

# ── 检查 remote ───────────────────────────────────────────────────────────────

HAS_REMOTE=false
if git -C "$WEBSITE_DIR" remote | grep -q origin; then
  HAS_REMOTE=true
fi

if [ "$SKIP_PUSH" = false ] && [ "$HAS_REMOTE" = false ]; then
  warn "website 仓没有 remote origin，将仅本地 commit，不 push/开 PR"
  SKIP_PUSH=true
fi

# ── 同步 remote main（软失败）────────────────────────────────────────────────

if [ "$HAS_REMOTE" = true ]; then
  log "同步 website origin/main..."
  git -C "$WEBSITE_DIR" fetch origin main --quiet 2>/dev/null || \
    warn "fetch origin/main 失败，继续使用本地 HEAD"
fi

# ── 创建发布分支 ──────────────────────────────────────────────────────────────

# 确定基准：优先从 origin/main，其次从本地 HEAD
if git -C "$WEBSITE_DIR" show-ref --quiet "refs/remotes/origin/main" 2>/dev/null; then
  BASE_REF="origin/main"
else
  BASE_REF="HEAD"
fi

if git -C "$WEBSITE_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
  log "分支 $BRANCH 已存在，重置到 $BASE_REF..."
  git -C "$WEBSITE_DIR" checkout "$BRANCH" --quiet
  git -C "$WEBSITE_DIR" reset --hard "$BASE_REF" --quiet
else
  log "创建分支 $BRANCH（基于 $BASE_REF）..."
  git -C "$WEBSITE_DIR" checkout -b "$BRANCH" "$BASE_REF" --quiet
fi

# ── 写入 CHANGELOG.zh-CN.md ──────────────────────────────────────────────────

log "写入 website CHANGELOG.zh-CN.md..."
/usr/bin/python3 - "$ZH_CHANGELOG" "$VERSION" "$ZH_NOTES" "$TODAY" <<'PY'
import sys, re

changelog_path, version, notes_path, today = sys.argv[1:]

with open(notes_path, "r", encoding="utf-8") as f:
    notes_raw = f.read().strip()

# 降一级标题（# 新功能 → ## 新功能），方便嵌套在版本段下
notes_body = re.sub(r'^# ', '## ', notes_raw, flags=re.MULTILINE)

new_section = "## {version} — {today}\n\n{body}\n\n---\n\n".format(
    version=version, today=today, body=notes_body
)

with open(changelog_path, "r", encoding="utf-8") as f:
    content = f.read()

# 在第一个 "## " 版本段之前插入（保留文件头注释）
match = re.search(r'^## ', content, re.MULTILINE)
if match:
    pos = match.start()
    content = content[:pos] + new_section + content[pos:]
else:
    content = content.rstrip() + "\n\n" + new_section

with open(changelog_path, "w", encoding="utf-8") as f:
    f.write(content)
PY

ok "CHANGELOG.zh-CN.md 已更新"

# ── 写入 CHANGELOG.en.md ─────────────────────────────────────────────────────

log "写入 website CHANGELOG.en.md..."
/usr/bin/python3 - "$EN_CHANGELOG" "$VERSION" "$EN_NOTES" "$TODAY" <<'PY'
import sys, re

changelog_path, version, notes_path, today = sys.argv[1:]

with open(notes_path, "r", encoding="utf-8") as f:
    notes_raw = f.read().strip()

notes_body = re.sub(r'^# ', '## ', notes_raw, flags=re.MULTILINE)

new_section = "## {version} — {today}\n\n{body}\n\n---\n\n".format(
    version=version, today=today, body=notes_body
)

with open(changelog_path, "r", encoding="utf-8") as f:
    content = f.read()

match = re.search(r'^## ', content, re.MULTILINE)
if match:
    pos = match.start()
    content = content[:pos] + new_section + content[pos:]
else:
    content = content.rstrip() + "\n\n" + new_section

with open(changelog_path, "w", encoding="utf-8") as f:
    f.write(content)
PY

ok "CHANGELOG.en.md 已更新"

# ── git add + commit ──────────────────────────────────────────────────────────

log "暂存 website 变更..."
git -C "$WEBSITE_DIR" add CHANGELOG.zh-CN.md CHANGELOG.en.md

# api/version.json（由 release_publish.sh 提前写好）
if git -C "$WEBSITE_DIR" diff --quiet HEAD -- api/version.json 2>/dev/null || \
   git -C "$WEBSITE_DIR" diff --cached --quiet -- api/version.json 2>/dev/null; then
  git -C "$WEBSITE_DIR" add api/version.json 2>/dev/null || true
else
  git -C "$WEBSITE_DIR" add api/version.json 2>/dev/null || true
fi

# download/*.pkg（大文件，只加本版本新包）
for pkg_file in "$WEBSITE_DIR/download/ClawdHome-${VERSION}"*.pkg \
                "$WEBSITE_DIR/download/ClawdHome-latest.pkg" \
                "$WEBSITE_DIR/download/ClawdHome-latest-x64.pkg"; do
  [ -f "$pkg_file" ] && git -C "$WEBSITE_DIR" add "$pkg_file" 2>/dev/null || true
done

git -C "$WEBSITE_DIR" commit -m "chore(release): sync v${VERSION} changelog"
ok "website commit 完成"

# ── push + PR ─────────────────────────────────────────────────────────────────

if [ "$SKIP_PUSH" = false ]; then
  log "推送 $BRANCH 到 origin..."
  # 确保 remote main 存在（gh pr create 需要 base 分支在 remote）
  if ! git -C "$WEBSITE_DIR" show-ref --quiet "refs/remotes/origin/main" 2>/dev/null; then
    log "remote main 不存在，先推送本地 main..."
    git -C "$WEBSITE_DIR" -c http.version=HTTP/1.1 push origin main || \
      warn "推送 main 失败，PR 可能无法创建"
  fi
  git -C "$WEBSITE_DIR" -c http.version=HTTP/1.1 push origin "$BRANCH"

  PR_BODY=$(printf '## 更新内容\n\n### 中文\n\n%s\n\n---\n\n### English\n\n%s\n' \
    "$(cat "$ZH_NOTES")" "$(cat "$EN_NOTES")")

  PR_OUT=$(gh pr create \
    --repo "$WEBSITE_REPO" \
    --base main \
    --head "$BRANCH" \
    --title "chore(release): sync v${VERSION} changelog" \
    --body "$PR_BODY" 2>&1 || true)

  if echo "$PR_OUT" | grep -q "https://"; then
    ok "website PR 已创建：$(echo "$PR_OUT" | grep 'https://')"
  else
    warn "PR 创建失败（可能已存在）：$PR_OUT"
    warn "分支已推送：origin/$BRANCH"
    warn "请手动在 https://github.com/${WEBSITE_REPO} 开 PR"
  fi
else
  echo ""
  warn "已跳过 push。website 分支已在本地 commit，请手动推送并开 PR："
  echo "  cd $WEBSITE_DIR"
  echo "  git push origin $BRANCH"
  echo "  gh pr create --repo ${WEBSITE_REPO} --base main --head $BRANCH"
fi
