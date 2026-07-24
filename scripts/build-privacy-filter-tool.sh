#!/bin/bash
set -euo pipefail

SRCROOT="${SRCROOT:-$(pwd)}"
CONFIGURATION="${CONFIGURATION:-release}"
DERIVED_FILE_DIR="${DERIVED_FILE_DIR:-${SRCROOT}/build}"

if [ -n "${CODESIGNING_FOLDER_PATH:-}" ]; then
  DEST_DIR="${CODESIGNING_FOLDER_PATH}/Contents/Library/Executables"
  IS_XCODE_BUILD=true
else
  DEST_DIR="${SRCROOT}/build/Executables"
  IS_XCODE_BUILD=false
fi

DEST_TOOL="${DEST_DIR}/ClawdHomePrivacyFilter"
BUILD_STAMP_NAME=".clawdhome-privacy-filter-build.stamp"

CONFIGURATION_LOWER="$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')"
case "${CONFIGURATION_LOWER}" in
  release) ;;
  *) CONFIGURATION_LOWER="debug" ;;
esac

should_build_in_debug() {
  case "${CLAWDHOME_BUILD_PRIVACY_FILTER_IN_DEBUG:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

privacy_sign_identity() {
  local identity
  for identity in \
    "${CLAWDHOME_PRIVACY_FILTER_SIGN_IDENTITY:-}" \
    "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" \
    "${EXPANDED_CODE_SIGN_IDENTITY:-}" \
    "${CODE_SIGN_IDENTITY:-}"; do
    if [ -n "${identity}" ] && [ "${identity}" != "-" ]; then
      printf '%s' "${identity}"
      return 0
    fi
  done
}

should_sign_embedded_tool() {
  [ "${IS_XCODE_BUILD}" = true ] || return 1
  [ "${CONFIGURATION_LOWER}" = "release" ] || return 1
  [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] || return 1
  [ -n "$(privacy_sign_identity)" ] || return 1
}

sign_embedded_tool_if_needed() {
  should_sign_embedded_tool || return 0
  local identity
  identity="$(privacy_sign_identity)"
  echo "▶︎ signing bundled privacy filter tool"
  /usr/bin/codesign --force \
    --sign "${identity}" \
    --timestamp \
    --options runtime \
    "${DEST_TOOL}"
}

compute_build_fingerprint() {
  (
    cd "${SRCROOT}"
    /usr/bin/shasum \
      "ClawdHomePrivacyFilter/Package.swift" \
      "ClawdHomePrivacyFilter/main.swift" \
      "scripts/build-privacy-filter-tool.sh" \
      "project.yml" \
      "Makefile"
  ) | /usr/bin/shasum | /usr/bin/awk '{print $1}'
}

if [ "${IS_XCODE_BUILD}" = true ] \
  && [ "${CONFIGURATION_LOWER}" = "debug" ] \
  && ! should_build_in_debug; then
  echo "⏭ skip privacy filter tool build in Debug (set CLAWDHOME_BUILD_PRIVACY_FILTER_IN_DEBUG=1 to enable)"

  SRC_TOOL="${SRCROOT}/build/Executables/ClawdHomePrivacyFilter"
  if [ -f "${SRC_TOOL}" ]; then
    echo "▶︎ copying pre-built privacy filter tool from build/Executables to app bundle"
    mkdir -p "${DEST_DIR}"
    cp "${SRC_TOOL}" "${DEST_TOOL}"
    chmod +x "${DEST_TOOL}"
    sign_embedded_tool_if_needed
  fi
  exit 0
fi

PACKAGE_PATH="${SRCROOT}/ClawdHomePrivacyFilter"
SCRATCH_PATH="${DERIVED_FILE_DIR}/ClawdHomePrivacyFilter.build"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
STAMP_PATH="${SCRATCH_PATH}/${BUILD_STAMP_NAME}"
FINGERPRINT="$(
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "${CONFIGURATION_LOWER}" \
    "${SDK_PATH}" \
    "${CLAWDHOME_PRIVACY_FILTER_ENABLE_ONNX:-}" \
    "${CLAWDHOME_PRIVACY_FILTER_DISABLE_ONNX:-}" \
    "$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ')" \
    "$(compute_build_fingerprint)"
)"

if [ -f "${STAMP_PATH}" ] \
  && [ -f "${DEST_TOOL}" ] \
  && [ "$(/bin/cat "${STAMP_PATH}")" = "${FINGERPRINT}" ]; then
  echo "⏭ skip privacy filter tool build (inputs unchanged)"
  sign_embedded_tool_if_needed
  exit 0
fi

echo "▶︎ building bundled privacy filter tool (${CONFIGURATION_LOWER})"

BUILD_NUM="${CLAWDHOME_BUILD_NUMBER_OVERRIDE:-${CURRENT_PROJECT_VERSION:-}}"
if [ -z "$BUILD_NUM" ]; then
  BUILD_NUM=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || echo 0)
fi
MARKETING_VER="${CLAWDHOME_MARKETING_VERSION_OVERRIDE:-${MARKETING_VERSION:-}}"
if [ -z "$MARKETING_VER" ]; then
  MARKETING_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${SRCROOT}/ClawdHome/Info.plist" 2>/dev/null || true)
fi
if [ -n "$MARKETING_VER" ] && [ -n "$BUILD_NUM" ]; then
  PRIVACY_FILTER_VER="${MARKETING_VER} (${BUILD_NUM})"
elif [ -n "$MARKETING_VER" ]; then
  PRIVACY_FILTER_VER="${MARKETING_VER}"
else
  PRIVACY_FILTER_VER="${BUILD_NUM}"
fi

BUILD_TIME=$(date "+%Y-%m-%d %H:%M:%S")

OUT_VER="${SRCROOT}/ClawdHomePrivacyFilter/GeneratedVersion.swift"
echo "// Auto-generated - do not edit" > "${OUT_VER}"
echo "let kPrivacyFilterVersion = \"${PRIVACY_FILTER_VER}\"" >> "${OUT_VER}"
echo "let kPrivacyFilterBuildTime = \"${BUILD_TIME}\"" >> "${OUT_VER}"

/usr/bin/xcrun --sdk macosx swift build \
  --package-path "${PACKAGE_PATH}" \
  --configuration "${CONFIGURATION_LOWER}" \
  --product ClawdHomePrivacyFilter \
  --scratch-path "${SCRATCH_PATH}" \
  -Xswiftc -sdk \
  -Xswiftc "${SDK_PATH}"

BUILT_TOOL="${SCRATCH_PATH}/${CONFIGURATION_LOWER}/ClawdHomePrivacyFilter"
if [ ! -f "${BUILT_TOOL}" ]; then
  echo "error: privacy filter tool build finished without executable" >&2
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp "${BUILT_TOOL}" "${DEST_TOOL}"
chmod +x "${DEST_TOOL}"
echo "${FINGERPRINT}" > "${STAMP_PATH}"

sign_embedded_tool_if_needed
echo "✅ privacy filter tool ready: ${DEST_TOOL}"
