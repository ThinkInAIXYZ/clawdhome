#!/usr/bin/env bash
# cleanup-clawdhome-install.sh
# 清除已安装的 ClawdHome.app 与其 privileged helper。
#
# 用法：
#   sudo bash scripts/cleanup-clawdhome-install.sh
#   sudo bash scripts/cleanup-clawdhome-install.sh --purge-data
#   sudo bash scripts/cleanup-clawdhome-install.sh --purge-data --purge-crash-reports
#
# 默认仅清除安装产物，不删除用户数据（例如 /Users/*/.openclaw）。

set -euo pipefail

LABEL="ai.clawdhome.mac.helper"
DEV_LABEL="ai.clawdhome.mac.helper.dev"
APP_PATH="/Applications/ClawdHome.app"
HELPER_BIN="/Library/PrivilegedHelperTools/${LABEL}"
HELPER_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DEV_HELPER_BIN="/Library/PrivilegedHelperTools/${DEV_LABEL}"
DEV_HELPER_PLIST="/Library/LaunchDaemons/${DEV_LABEL}.plist"
VAR_STATE_DIR="/var/lib/clawdhome"
HELPER_LOG_GLOB="/tmp/clawdhome-helper.log*"
CRASH_REPORT_GLOB="/Library/Logs/DiagnosticReports/ai.clawdhome.mac.helper-*.ips"

PURGE_DATA=0
PURGE_CRASH_REPORTS=0

for arg in "$@"; do
    case "$arg" in
        --purge-data)
            PURGE_DATA=1
            ;;
        --purge-crash-reports)
            PURGE_CRASH_REPORTS=1
            ;;
        -h|--help)
            sed -n '1,26p' "$0"
            exit 0
            ;;
        *)
            echo "❌ 未知参数: $arg"
            echo "   用法: sudo bash $0 [--purge-data] [--purge-crash-reports]"
            exit 1
            ;;
    esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "❌ 请使用 sudo 运行：sudo bash $0"
    exit 1
fi

echo "==> 停止并卸载 helper launchd 服务"
launchctl bootout system "$HELPER_PLIST" 2>/dev/null || true
launchctl remove "$LABEL" 2>/dev/null || true
launchctl bootout system "$DEV_HELPER_PLIST" 2>/dev/null || true
launchctl remove "$DEV_LABEL" 2>/dev/null || true

echo "==> 删除 helper 安装产物"
rm -f "$HELPER_BIN" "$HELPER_PLIST" "$DEV_HELPER_BIN" "$DEV_HELPER_PLIST"

echo "==> 删除 App 安装产物"
rm -rf "$APP_PATH"

if [ "$PURGE_DATA" -eq 1 ]; then
    echo "==> 清理 helper 运行状态与日志"
    rm -rf "$VAR_STATE_DIR"
    rm -f $HELPER_LOG_GLOB 2>/dev/null || true
fi

if [ "$PURGE_CRASH_REPORTS" -eq 1 ]; then
    echo "==> 清理 helper 崩溃报告"
    rm -f $CRASH_REPORT_GLOB 2>/dev/null || true
fi

echo "✅ 清理完成"
echo "   下一步建议：重启系统后重新安装签名安装包。"
