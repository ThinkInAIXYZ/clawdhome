#!/usr/bin/env bash
# build-pkg.sh
# 构建 ClawdHome Release 并打包为可分发的 .pkg 安装包
#
# 用法：
#   bash scripts/build-pkg.sh              # 构建 + 打包
#   bash scripts/build-pkg.sh --skip-build # 跳过 xcodebuild，直接打包（用于重复打包）
#   bash scripts/build-pkg.sh --no-sync-api-version # 不同步 clawdhome_website/api/version.json
#
# 输出：dist/ClawdHome-<VERSION>.pkg
#
# 依赖：xcodebuild（Xcode Command Line Tools）

set -euo pipefail
export LC_ALL=C  # 修复 Bash 3.2 UTF-8 编码问题

# ── 配置 ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="ClawdHome"
BUNDLE_ID="ai.clawdhome.mac"        # 当前 bundle ID，将来可改为 app.clawdhome
HELPER_LABEL="ai.clawdhome.mac.helper"
SCHEME="ClawdHome"
CONFIGURATION="Release"

ARCHIVE_PATH="$REPO_ROOT/build/${APP_NAME}.xcarchive"
EXPORT_DIR="$REPO_ROOT/build/export"
DIST_DIR="$REPO_ROOT/dist"
WEBSITE_DIR="${WEBSITE_DIR:-$REPO_ROOT/../clawdhome_website}"
API_VERSION_JSON="$WEBSITE_DIR/api/version.json"

SKIP_BUILD=false
SYNC_API_VERSION=true
for arg in "$@"; do
  [[ "$arg" == "--skip-build" ]] && SKIP_BUILD=true
  [[ "$arg" == "--no-sync-api-version" ]] && SYNC_API_VERSION=false
done

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

# ── Step 1：构建 ──────────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
  log "构建 $APP_NAME..."
  # 优先使用当前用户权限清理，避免 make pkg 触发 sudo 密码输入。
  # 若历史残留 root:wheel 文件导致删除失败，则提示一次性修复命令。
  if ! rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" 2>/dev/null; then
    fail "无法清理构建目录（可能存在 root 权限残留）。请先执行：sudo chown -R \"$(id -un)\":staff \"$REPO_ROOT/build\""
  fi

  # 清除 DerivedData 增量缓存，确保 Release 从干净状态编译
  # （避免 Debug 残留中间产物影响 Release archive）
  xcodebuild clean \
    -project "$REPO_ROOT/${APP_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -quiet

  xcodebuild archive \
    -project "$REPO_ROOT/${APP_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

  # 从 archive 中取出 app
  mkdir -p "$EXPORT_DIR"
  cp -r "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"
  ok "构建完成：$EXPORT_DIR/${APP_NAME}.app"
else
  log "跳过构建，使用已有：$EXPORT_DIR/${APP_NAME}.app"
  [ -d "$EXPORT_DIR/${APP_NAME}.app" ] || fail "未找到 $EXPORT_DIR/${APP_NAME}.app，请先构建"
fi

APP_BUNDLE="$EXPORT_DIR/${APP_NAME}.app"
APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$APP_INFO_PLIST" ] || fail "未找到 $APP_INFO_PLIST"

# 统一版本来源：始终以“构建产物 app 的 Info.plist”为准
FULL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)
[ -n "$FULL_VERSION" ] || fail "无法从构建产物读取 CFBundleShortVersionString"

PKG_NAME="${APP_NAME}-${FULL_VERSION}.pkg"
PKG_OUTPUT="$DIST_DIR/$PKG_NAME"

# ── Step 2：准备 pkg 目录结构 ─────────────────────────────────────────────────

log "准备安装包目录结构..."

PKG_ROOT="$REPO_ROOT/build/pkg-root"
PKG_SCRIPTS="$REPO_ROOT/build/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

mkdir -p "$PKG_ROOT/Applications"
mkdir -p "$PKG_ROOT/Library/PrivilegedHelperTools"
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$PKG_SCRIPTS"

# 拷贝 app（bundle 内的 plist 保留，供 SMAppService 手动安装时使用）
cp -r "$APP_BUNDLE" "$PKG_ROOT/Applications/"

# 从 bundle 中提取 Helper 二进制到系统路径
HELPER_IN_BUNDLE="$PKG_ROOT/Applications/${APP_NAME}.app/Contents/Library/LaunchDaemons/ClawdHomeHelper"
[ -f "$HELPER_IN_BUNDLE" ] || fail "未在 app bundle 中找到 ClawdHomeHelper"
cp "$HELPER_IN_BUNDLE" "$PKG_ROOT/Library/PrivilegedHelperTools/${HELPER_LABEL}"
chmod 555 "$PKG_ROOT/Library/PrivilegedHelperTools/${HELPER_LABEL}"

# 生成系统级 LaunchDaemon plist（用绝对路径 ProgramArguments，非 BundleProgram）
cat > "$PKG_ROOT/Library/LaunchDaemons/${HELPER_LABEL}.plist" << DAEMON_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${HELPER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/${HELPER_LABEL}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${HELPER_LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
DAEMON_PLIST
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/${HELPER_LABEL}.plist"

ok "目录结构准备完成"

# ── Step 3：preinstall 脚本（停止旧版本）─────────────────────────────────────

cat > "$PKG_SCRIPTS/preinstall" << PREINSTALL
#!/usr/bin/env bash
# 关闭 app
osascript -e 'tell application "${APP_NAME}" to quit' 2>/dev/null || true
# 停止旧 Helper daemon（如果在运行）
if launchctl print "system/${HELPER_LABEL}" &>/dev/null 2>&1; then
  launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null || true
fi
sleep 1
exit 0
PREINSTALL

# ── Step 4：postinstall 脚本 ──────────────────────────────────────────────────

cat > "$PKG_SCRIPTS/postinstall" << POSTINSTALL
#!/usr/bin/env bash
set -euo pipefail

HELPER="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

# 修正权限
chmod 555 "\$HELPER"
chown root:wheel "\$HELPER"
chown root:wheel "\$PLIST"
chmod 644 "\$PLIST"

# 解除 app 隔离（允许未签名 app 运行，无弹框）
xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true

# 注册并启动 Helper daemon
launchctl bootstrap system "\$PLIST" 2>/dev/null || true

echo "ClawdHome 安装完成"
exit 0
POSTINSTALL

chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"
ok "安装脚本生成完成"

# ── Step 5：打包 pkg ──────────────────────────────────────────────────────────

log "生成 $PKG_NAME..."
mkdir -p "$DIST_DIR"

pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "$BUNDLE_ID" \
  --version "$FULL_VERSION" \
  --install-location "/" \
  "$PKG_OUTPUT"

ok "安装包已生成：$PKG_OUTPUT"

if [ "$SYNC_API_VERSION" = true ] && [ -f "$API_VERSION_JSON" ]; then
  log "同步 $API_VERSION_JSON 版本号 -> $FULL_VERSION"
  DOWNLOAD_URL="https://clawdhome.app/download/ClawdHome-${FULL_VERSION}.pkg"
  TMP_API_JSON="$(mktemp)"
  awk -v v="$FULL_VERSION" -v dl="$DOWNLOAD_URL" '
    {
      if ($0 ~ /"version"[[:space:]]*:/) {
        sub(/"version"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"version\": \"" v "\"")
      }
      if ($0 ~ /"download_url"[[:space:]]*:/) {
        sub(/"download_url"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"download_url\": \"" dl "\"")
      }
      print
    }
  ' "$API_VERSION_JSON" > "$TMP_API_JSON"
  mv "$TMP_API_JSON" "$API_VERSION_JSON"
  chmod 644 "$API_VERSION_JSON"
  ok "已同步：$API_VERSION_JSON"
elif [ "$SYNC_API_VERSION" = true ]; then
  log "未找到 $API_VERSION_JSON，跳过 API 版本同步"
fi

# ── Step 6：清理临时目录 ──────────────────────────────────────────────────────

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

# ── 完成摘要 ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📦 ${PKG_NAME}"
echo "  版本：${FULL_VERSION}"
echo "  大小：$(du -sh "$PKG_OUTPUT" | cut -f1)"
echo "  路径：$PKG_OUTPUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "安装测试："
echo "  sudo installer -pkg \"$PKG_OUTPUT\" -target /"
echo ""
echo "发布到 GitHub："
echo "  gh release create v${FULL_VERSION} \"$PKG_OUTPUT\" --title \"ClawdHome ${FULL_VERSION}\""
echo ""
