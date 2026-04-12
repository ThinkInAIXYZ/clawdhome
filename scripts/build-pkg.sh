#!/usr/bin/env bash
# build-pkg.sh
# 构建 ClawdHome Release 并打包为可分发的 .pkg 安装包
#
# 用法：
#   bash scripts/build-pkg.sh              # 构建 + 打包
#   bash scripts/build-pkg.sh --skip-build # 跳过 xcodebuild，直接打包（用于重复打包）
#   PKG_ARCHS=x86_64 bash scripts/build-pkg.sh # 构建 Intel 包
#   PKG_ARCHS="arm64 x86_64" bash scripts/build-pkg.sh # 构建 Universal 包
#   bash scripts/build-pkg.sh --sync-api-version    # 同步 clawdhome_website/api/version.json（默认不同步）
#   SIGN_APP=true SIGN_PKG=true bash scripts/build-pkg.sh # 生成 Developer ID 签名 pkg
#   SIGN_APP=true SIGN_PKG=true NOTARIZE=true NOTARY_PROFILE=clawdhome-release bash scripts/build-pkg.sh
#
# 输出：dist/ClawdHome-<VERSION>-<ARCH>.pkg（如 -arm64 / -x64 / -universal）
#
# 依赖：xcodebuild / codesign / productsign / notarytool（按需）

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
SOURCE_INFO_PLIST="$REPO_ROOT/ClawdHome/Info.plist"
BUILD_COUNTER_FILE="$REPO_ROOT/.build-version"
INITIAL_BUILD_NUMBER=500
BUILD_COUNTER_SCRIPT="$SCRIPT_DIR/build_counter.sh"

SKIP_BUILD=false
SYNC_API_VERSION=false
SIGN_APP="${SIGN_APP:-false}"
SIGN_PKG="${SIGN_PKG:-false}"
NOTARIZE="${NOTARIZE:-false}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-Y7P5QLKLYG}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Developer ID Application: Mengjun Xie (Y7P5QLKLYG)}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-Developer ID Installer: Mengjun Xie (Y7P5QLKLYG)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
QUIET_XCODE="${QUIET_XCODE:-true}"
PKG_ARCHS_RAW="${PKG_ARCHS:-arm64}"
for arg in "$@"; do
  [[ "$arg" == "--skip-build" ]] && SKIP_BUILD=true
  [[ "$arg" == "--no-sync-api-version" ]] && SYNC_API_VERSION=false
  [[ "$arg" == "--sync-api-version" ]] && SYNC_API_VERSION=true
done

normalize_pkg_archs() {
  local raw="$1"
  local normalized
  normalized=$(echo "$raw" | tr ',' ' ' | xargs)
  case "$normalized" in
    arm64) echo "arm64" ;;
    x86_64|x64|intel) echo "x86_64" ;;
    "arm64 x86_64"|"x86_64 arm64"|universal|universal2) echo "arm64 x86_64" ;;
    *) fail "不支持的 PKG_ARCHS：$raw（支持：arm64 / x86_64 / arm64 x86_64）" ;;
  esac
}

PKG_ARCHS="$(normalize_pkg_archs "$PKG_ARCHS_RAW")"
case "$PKG_ARCHS" in
  arm64) PKG_ARCH_SUFFIX="-arm64" ;;
  x86_64) PKG_ARCH_SUFFIX="-x64" ;;
  "arm64 x86_64") PKG_ARCH_SUFFIX="-universal" ;;
  *) fail "内部错误：未知架构组合 $PKG_ARCHS" ;;
esac

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

assert_bool() {
  case "$2" in
    true|false) ;;
    *) fail "$1 必须是 true 或 false（当前：$2）" ;;
  esac
}

assert_bool "SIGN_APP" "$SIGN_APP"
assert_bool "SIGN_PKG" "$SIGN_PKG"
assert_bool "NOTARIZE" "$NOTARIZE"
assert_bool "QUIET_XCODE" "$QUIET_XCODE"

if [ "$NOTARIZE" = true ] && [ "$SIGN_PKG" != true ]; then
  fail "NOTARIZE=true 时必须同时设置 SIGN_PKG=true"
fi

if [ "$NOTARIZE" = true ] && [ -z "$NOTARY_PROFILE" ]; then
  fail "NOTARIZE=true 时必须提供 NOTARY_PROFILE（xcrun notarytool store-credentials 的 profile 名）"
fi

read_source_plist() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$SOURCE_INFO_PLIST" 2>/dev/null || true
}

compute_marketing_version() {
  if [ -n "$RELEASE_VERSION" ]; then
    echo "$RELEASE_VERSION"
    return
  fi

  local current_version next_version describe fallback_version
  current_version=$(bash "$SCRIPT_DIR/semver.sh" --current 2>/dev/null || true)
  next_version=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || true)
  describe=$(git describe --tags --match "v*" --long --dirty --always 2>/dev/null || true)
  fallback_version=$(read_source_plist "CFBundleShortVersionString")

  if [[ "$describe" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-g([0-9a-f]+)(-dirty)?$ ]]; then
    if [ "${BASH_REMATCH[2]}" = "0" ] && [ -z "${BASH_REMATCH[4]:-}" ]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
    [ -n "$next_version" ] && echo "$next_version" && return
  fi

  [ -n "$current_version" ] && echo "$current_version" && return
  [ -n "$fallback_version" ] && echo "$fallback_version" && return
  echo "0.0.0"
}

compute_build_number() {
  if [ "$SKIP_BUILD" = false ]; then
    BUILD_COUNTER_FILE="$BUILD_COUNTER_FILE" \
      INITIAL_BUILD_NUMBER="$INITIAL_BUILD_NUMBER" \
      bash "$BUILD_COUNTER_SCRIPT" reserve
    return
  fi

  local reserved_build fallback_build
  reserved_build=$(BUILD_COUNTER_FILE="$BUILD_COUNTER_FILE" \
    INITIAL_BUILD_NUMBER="$INITIAL_BUILD_NUMBER" \
    bash "$BUILD_COUNTER_SCRIPT" current)
  fallback_build=$(read_source_plist "CFBundleVersion")
  [ "$reserved_build" -ge "$INITIAL_BUILD_NUMBER" ] && echo "$reserved_build" && return
  [ -n "$fallback_build" ] && echo "$fallback_build" && return
  echo "$INITIAL_BUILD_NUMBER"
}

BUILD_MARKETING_VERSION=$(compute_marketing_version)
BUILD_NUMBER=$(compute_build_number)

run_xcodebuild() {
  local log_file="$1"
  shift

  if [ "$QUIET_XCODE" = true ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! xcodebuild "$@" >"$log_file" 2>&1; then
      echo "❌ xcodebuild 失败，日志：$log_file" >&2
      tail -n 120 "$log_file" >&2 || true
      exit 1
    fi
    ok "xcodebuild 完成（日志：$log_file）"
  else
    xcodebuild "$@"
  fi
}

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
  XCODE_ARGS=(
    -project "$REPO_ROOT/${APP_NAME}.xcodeproj"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
  )

  run_xcodebuild "$REPO_ROOT/build/logs/xcodebuild-clean.log" clean "${XCODE_ARGS[@]}" -destination "generic/platform=macOS" -quiet

  ARCHIVE_ARGS=(
    archive
    "${XCODE_ARGS[@]}"
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    ARCHS="$PKG_ARCHS"
    ONLY_ACTIVE_ARCH=NO
  )

  if [ "$SIGN_APP" = true ]; then
    log "使用 Developer ID 签名 archive..."
    ARCHIVE_ARGS+=(
      DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$APP_SIGN_IDENTITY"
      CLAWDHOME_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      CLAWDHOME_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      MARKETING_VERSION="$BUILD_MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      INFOPLIST_KEY_CFBundleShortVersionString="$BUILD_MARKETING_VERSION"
      INFOPLIST_KEY_CFBundleVersion="$BUILD_NUMBER"
      OTHER_CODE_SIGN_FLAGS="--timestamp"
      ENABLE_HARDENED_RUNTIME=YES
    )
  else
    ARCHIVE_ARGS+=(
      CODE_SIGN_IDENTITY=-
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGNING_ALLOWED=NO
      CLAWDHOME_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      CLAWDHOME_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      MARKETING_VERSION="$BUILD_MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      INFOPLIST_KEY_CFBundleShortVersionString="$BUILD_MARKETING_VERSION"
      INFOPLIST_KEY_CFBundleVersion="$BUILD_NUMBER"
    )
  fi

  run_xcodebuild "$REPO_ROOT/build/logs/xcodebuild-archive.log" "${ARCHIVE_ARGS[@]}"

  # 从 archive 中取出 app
  mkdir -p "$EXPORT_DIR"
  cp -r "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"
  ok "构建完成：$EXPORT_DIR/${APP_NAME}.app"

  # 额外构建 CLI 工具
  log "构建 ClawdHomeCLI..."
  CLI_BUILD_ARGS=(
    -project "$REPO_ROOT/${APP_NAME}.xcodeproj"
    -scheme "ClawdHomeCLI"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=macOS"
    ARCHS="$PKG_ARCHS"
    ONLY_ACTIVE_ARCH=NO
    CLAWDHOME_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
    CLAWDHOME_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
  )
  if [ "$SIGN_APP" = true ]; then
    CLI_BUILD_ARGS+=(
      DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$APP_SIGN_IDENTITY"
      OTHER_CODE_SIGN_FLAGS="--timestamp"
      ENABLE_HARDENED_RUNTIME=YES
    )
  else
    CLI_BUILD_ARGS+=(
      CODE_SIGN_IDENTITY=-
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGNING_ALLOWED=NO
    )
  fi
  run_xcodebuild "$REPO_ROOT/build/logs/xcodebuild-cli.log" build "${CLI_BUILD_ARGS[@]}"

  # 将 CLI 二进制嵌入 App bundle
  CLI_BINARY=$(find "$REPO_ROOT/build" -path "*/Release/ClawdHomeCLI" -not -path "*.xcarchive*" 2>/dev/null | head -1)
  if [ -z "$CLI_BINARY" ]; then
    # Release 模式下可能在 DerivedData 中
    CLI_BINARY=$(find ~/Library/Developer/Xcode/DerivedData/ClawdHome-*/Build/Products/Release/ClawdHomeCLI 2>/dev/null | head -1)
  fi
  if [ -n "$CLI_BINARY" ] && [ -f "$CLI_BINARY" ]; then
    cp "$CLI_BINARY" "$EXPORT_DIR/${APP_NAME}.app/Contents/MacOS/clawdhome-cli"
    chmod +x "$EXPORT_DIR/${APP_NAME}.app/Contents/MacOS/clawdhome-cli"
    ok "CLI 已嵌入 App bundle"

    # CLI 嵌入后需要重新签名整个 app bundle（archive 签名在嵌入前完成，嵌入后封印失效）
    if [ "$SIGN_APP" = true ]; then
      log "重新签名 app bundle（CLI 嵌入后）..."
      codesign --force --deep --sign "$APP_SIGN_IDENTITY" --timestamp --options runtime \
        "$EXPORT_DIR/${APP_NAME}.app"
      ok "app bundle 重新签名完成"
    fi
  else
    echo "⚠️  未找到 ClawdHomeCLI 二进制，跳过 CLI 嵌入"
  fi
else
  log "跳过构建，使用已有：$EXPORT_DIR/${APP_NAME}.app"
  [ -d "$EXPORT_DIR/${APP_NAME}.app" ] || fail "未找到 $EXPORT_DIR/${APP_NAME}.app，请先构建"
fi

APP_BUNDLE="$EXPORT_DIR/${APP_NAME}.app"
APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$APP_INFO_PLIST" ] || fail "未找到 $APP_INFO_PLIST"

if [ "$SIGN_APP" = true ]; then
  require_cmd codesign
  log "校验 app 签名..."
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  ok "app 签名校验通过"
fi

# 统一版本来源：始终以“构建产物 app 的 Info.plist”为准
FULL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)
[ -n "$FULL_VERSION" ] || fail "无法从构建产物读取 CFBundleShortVersionString"
APP_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" 2>/dev/null || true)
[ -n "$APP_BUILD_NUMBER" ] || fail "无法从构建产物读取 CFBundleVersion"

if [ -n "$RELEASE_VERSION" ]; then
  PKG_VERSION_LABEL="${FULL_VERSION}${PKG_ARCH_SUFFIX}"
else
  PKG_VERSION_LABEL="${FULL_VERSION}-b${APP_BUILD_NUMBER}${PKG_ARCH_SUFFIX}"
fi

PKG_NAME="${APP_NAME}-${PKG_VERSION_LABEL}.pkg"
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

# 安装 CLI 命令行工具（symlink 到 /usr/local/bin）
CLI_SOURCE="/Applications/${APP_NAME}.app/Contents/MacOS/clawdhome-cli"
CLI_LINK="/usr/local/bin/clawdhome"
if [ -f "\$CLI_SOURCE" ]; then
  mkdir -p /usr/local/bin
  ln -sf "\$CLI_SOURCE" "\$CLI_LINK"
  echo "CLI 已安装: \$CLI_LINK"
fi

echo "ClawdHome 安装完成"
exit 0
POSTINSTALL

chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"
ok "安装脚本生成完成"

# ── Step 5：打包 pkg ──────────────────────────────────────────────────────────

log "生成 $PKG_NAME..."
mkdir -p "$DIST_DIR"

UNSIGNED_PKG_OUTPUT="$PKG_OUTPUT"
if [ "$SIGN_PKG" = true ]; then
  UNSIGNED_PKG_OUTPUT="$DIST_DIR/${APP_NAME}-${FULL_VERSION}${PKG_ARCH_SUFFIX}.unsigned.pkg"
  rm -f "$UNSIGNED_PKG_OUTPUT" "$PKG_OUTPUT"
fi

pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "$BUNDLE_ID" \
  --version "$FULL_VERSION" \
  --install-location "/" \
  "$UNSIGNED_PKG_OUTPUT"

if [ "$SIGN_PKG" = true ]; then
  require_cmd productsign
  require_cmd pkgutil
  log "使用 Developer ID Installer 签名 pkg..."
  productsign \
    --sign "$PKG_SIGN_IDENTITY" \
    --timestamp \
    "$UNSIGNED_PKG_OUTPUT" \
    "$PKG_OUTPUT"
  pkgutil --check-signature "$PKG_OUTPUT"
  rm -f "$UNSIGNED_PKG_OUTPUT"
  ok "pkg 签名校验通过"
fi

if [ "$NOTARIZE" = true ]; then
  require_cmd xcrun
  require_cmd stapler
  require_cmd spctl
  log "提交 pkg 公证..."
  xcrun notarytool submit "$PKG_OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  log "写入 notarization ticket..."
  xcrun stapler staple "$PKG_OUTPUT"
  xcrun stapler validate "$PKG_OUTPUT"
  log "校验 Gatekeeper 对已公证 pkg 的放行状态..."
  spctl --assess --type install --verbose=2 "$PKG_OUTPUT"
  ok "pkg 公证完成"
fi

ok "安装包已生成：$PKG_OUTPUT"

if [ "$SYNC_API_VERSION" = true ] && [ -f "$API_VERSION_JSON" ]; then
  log "同步 $API_VERSION_JSON 版本号 -> $FULL_VERSION"
  DOWNLOAD_URL="https://clawdhome.app/download/${PKG_NAME}"
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
echo "  App 版本：${FULL_VERSION}"
echo "  Build：${APP_BUILD_NUMBER}"
echo "  架构：${PKG_ARCHS}"
echo "  包版本：${PKG_VERSION_LABEL}"
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
