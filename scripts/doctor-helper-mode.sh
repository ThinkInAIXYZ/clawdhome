#!/usr/bin/env bash
# doctor-helper-mode.sh
# 检查当前机器 ClawdHome 的安装/运行模式，识别开发态与发布态是否混用。
#
# 用法：
#   bash scripts/doctor-helper-mode.sh

set -euo pipefail

REL_LABEL="ai.clawdhome.mac.helper"
DEV_LABEL="ai.clawdhome.mac.helper.dev"
APP_PATH="/Applications/ClawdHome.app"
REL_PLIST="/Library/LaunchDaemons/${REL_LABEL}.plist"
DEV_PLIST="/Library/LaunchDaemons/${DEV_LABEL}.plist"
REL_HELPER="/Library/PrivilegedHelperTools/${REL_LABEL}"
DEV_HELPER="/Library/PrivilegedHelperTools/${DEV_LABEL}"

info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }

echo "== ClawdHome 模式诊断 =="

echo ""
echo "[1/5] 运行中的 App 进程"
APP_PROC="$(ps aux 2>/dev/null | grep -E '[C]lawdHome\.app/Contents/MacOS/ClawdHome' || true)"
if [ -z "$APP_PROC" ]; then
    warn "当前未检测到运行中的 ClawdHome 进程"
else
    echo "$APP_PROC"
    if echo "$APP_PROC" | grep -q "/Applications/ClawdHome.app/"; then
        ok "当前运行来源：/Applications（安装包路径）"
    else
        warn "当前运行来源不是 /Applications，疑似 Xcode/DerivedData 直跑"
    fi
fi

echo ""
echo "[2/5] App 签名校验"
if [ -d "$APP_PATH" ]; then
    if codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/tmp/clawdhome-app-sign-check.log 2>&1; then
        ok "App 签名通过：$APP_PATH"
    else
        warn "App 签名失败：$APP_PATH"
        sed -n '1,4p' /tmp/clawdhome-app-sign-check.log || true
    fi
else
    warn "未找到 $APP_PATH"
fi

echo ""
echo "[3/5] Helper 服务状态"
for label in "$REL_LABEL" "$DEV_LABEL"; do
    if launchctl print "system/$label" >/tmp/clawdhome-helper-state.log 2>&1; then
        pid="$(awk '/pid =/{print $3; exit}' /tmp/clawdhome-helper-state.log)"
        ok "$label 正在运行 (pid=${pid:-unknown})"
    else
        info "$label 未运行"
    fi
done

echo ""
echo "[4/5] LaunchDaemon 配置来源"
for plist in "$REL_PLIST" "$DEV_PLIST"; do
    if [ -f "$plist" ]; then
        echo "--- $plist"
        plutil -p "$plist" 2>/dev/null | grep -E '"BundleProgram"|"Program"|"ProgramArguments"|"StandardOutPath"|"Label"'
    else
        info "未找到 $plist"
    fi
done

echo ""
echo "[5/5] Helper 二进制签名"
for helper in "$REL_HELPER" "$DEV_HELPER"; do
    if [ -f "$helper" ]; then
        echo "--- $helper"
        codesign -dv --verbose=2 "$helper" 2>&1 | grep -E 'Identifier=|Signature=|TeamIdentifier=' || true
    else
        info "未找到 $helper"
    fi
done

echo ""
echo "== 结论建议 =="
has_rel=0
has_dev=0
[ -f "$REL_PLIST" ] && has_rel=1
[ -f "$DEV_PLIST" ] && has_dev=1

if [ "$has_rel" -eq 1 ] && [ "$has_dev" -eq 1 ]; then
    warn "检测到 release/dev 双 helper 并存，建议先清理再按单一模式运行。"
    echo "  清理命令：sudo bash scripts/cleanup-clawdhome-install.sh --purge-data"
elif [ "$has_dev" -eq 1 ]; then
    info "当前偏开发模式（dev helper）。用于 Xcode 本地调试是正常的。"
elif [ "$has_rel" -eq 1 ]; then
    info "当前偏发布模式（release helper）。用于验收发布包是正常的。"
else
    warn "未检测到有效 helper 安装。"
fi
