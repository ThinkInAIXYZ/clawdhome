#!/usr/bin/env bash
# install-helper-dev.sh
# 开发模式手动安装 ClawdHomeHelper LaunchDaemon（无需 Apple Developer ID）
# 用途：在真机上测试，绕过 SMAppService 签名要求
#
# 用法：
#   sudo bash apps/ClawdHome/scripts/install-helper-dev.sh           # 安装
#   sudo bash apps/ClawdHome/scripts/install-helper-dev.sh uninstall # 卸载

set -euo pipefail

LABEL="ai.clawdhome.mac.helper.dev"
RELEASE_LABEL="ai.clawdhome.mac.helper"
DEST_DIR="/Library/PrivilegedHelperTools"
DEST_BINARY="$DEST_DIR/$LABEL"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
RELEASE_PLIST_PATH="/Library/LaunchDaemons/$RELEASE_LABEL.plist"

ACTION="${1:-install}"

# ── 查找 DerivedData 中最新构建的 ClawdHomeHelper ─────────────────────────────
find_built_binary() {
    find "$HOME/Library/Developer/Xcode/DerivedData" \
        -name "ClawdHomeHelper" -type f \
        ! -path "*.dSYM/*" \
        2>/dev/null \
    | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
    | sort -rn \
    | head -1 \
    | awk '{print $2}'
}

case "$ACTION" in
# ── 安装 ──────────────────────────────────────────────────────────────────────
install)
    BUILT_BINARY=$(find_built_binary)
    if [ -z "$BUILT_BINARY" ]; then
        echo "❌ 未在 DerivedData 中找到 ClawdHomeHelper"
        echo "   请先在 Xcode 中 Build ClawdHome scheme（⌘B）"
        exit 1
    fi
    echo "📦 安装来源：$BUILT_BINARY"

    # 开发态安装时，先停掉 release helper，避免 dev/release 双 helper 并跑导致排查混乱。
    if launchctl print "system/$RELEASE_LABEL" >/dev/null 2>&1; then
        echo "🧹 检测到 release helper 正在运行，先停止：$RELEASE_LABEL"
        launchctl bootout system "$RELEASE_PLIST_PATH" 2>/dev/null || true
    fi

    # 必须先停止旧进程再替换二进制！
    # 否则内核延迟代码页校验会发现磁盘签名不匹配 → SIGKILL: Invalid Page
    launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
    sleep 1

    mkdir -p "$DEST_DIR"
    cp "$BUILT_BINARY" "$DEST_BINARY"
    chmod 555 "$DEST_BINARY"
    chown root:wheel "$DEST_BINARY"

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>Program</key>
    <string>${DEST_BINARY}</string>
    <key>MachServices</key>
    <dict>
        <key>${LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/clawdhome-helper-dev.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/clawdhome-helper-dev.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST_PATH"
    chmod 644 "$PLIST_PATH"

    launchctl bootstrap system "$PLIST_PATH"

    echo "✅ ClawdHomeHelper 已安装并启动（dev）"
    echo "   日志：tail -f /tmp/clawdhome-helper-dev.log"
    echo "   现在可以运行 ClawdHome.app 进行测试"
    ;;

# ── 卸载 ──────────────────────────────────────────────────────────────────────
uninstall)
    launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
    rm -f "$DEST_BINARY" "$PLIST_PATH"
    echo "✅ ClawdHomeHelper 已卸载"
    ;;

# ── 状态 ──────────────────────────────────────────────────────────────────────
status)
    if launchctl print "system/$LABEL" 2>/dev/null | grep -q "pid ="; then
        echo "🟢 ClawdHomeHelper 正在运行"
        launchctl print "system/$LABEL" | grep -E "pid|state"
    else
        echo "🔴 ClawdHomeHelper 未运行"
    fi
    ;;

*)
    echo "用法：sudo bash $0 [install|uninstall|status]"
    exit 1
    ;;
esac
