#!/usr/bin/env bash
# switch-release-test.sh
# 切换到“发布包验收模式”：
# 1) 清理当前 App + helper 安装残留（dev/release）
# 2) 安装指定 pkg（或 dist/ 最新 pkg）
# 3) 输出当前模式诊断
#
# 用法：
#   bash scripts/switch-release-test.sh
#   bash scripts/switch-release-test.sh /absolute/path/to/ClawdHome-*.pkg
#   ALLOW_UNSIGNED=true bash scripts/switch-release-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-false}"

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

PKG_PATH="${1:-}"
if [ -z "$PKG_PATH" ]; then
    PKG_PATH="$(ls -t "$REPO_ROOT"/dist/*.pkg 2>/dev/null | head -1 || true)"
fi

[ -n "$PKG_PATH" ] || fail "未找到可安装 pkg。请先运行 make pkg-signed 或 make notarize-pkg。"
[ -f "$PKG_PATH" ] || fail "pkg 不存在：$PKG_PATH"

log "目标安装包：$PKG_PATH"

SIG_OUT="$(pkgutil --check-signature "$PKG_PATH" 2>&1 || true)"
echo "$SIG_OUT"
if ! echo "$SIG_OUT" | grep -q "Status: signed by a certificate trusted by macOS"; then
    if [ "$ALLOW_UNSIGNED" = "true" ]; then
        warn "检测到非可信签名 pkg，但 ALLOW_UNSIGNED=true，继续安装。"
    else
        fail "该 pkg 不是受信任签名。若仅做本地临时测试，可加 ALLOW_UNSIGNED=true。"
    fi
fi

log "清理现有安装（保留用户数据）"
sudo bash "$SCRIPT_DIR/cleanup-clawdhome-install.sh"

log "安装发布包"
sudo installer -pkg "$PKG_PATH" -target /

ok "安装完成，输出当前模式诊断"
bash "$SCRIPT_DIR/doctor-helper-mode.sh"

echo ""
echo "下一步："
echo "  open -n /Applications/ClawdHome.app"
