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

DEST_TOOL="${DEST_DIR}/ClawdHomeSpeech"
DEST_METALLIB="${DEST_DIR}/mlx.metallib"
MLX_FENCE_RELATIVE_PATH="checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/fence.metal"
BUILD_STAMP_NAME=".clawdhome-speech-build.stamp"

cleanup_tool() {
  if [ -f "${DEST_TOOL}" ]; then
    rm -f "${DEST_TOOL}"
  fi
  if [ -f "${DEST_METALLIB}" ]; then
    rm -f "${DEST_METALLIB}"
  fi
}

patch_mlx_fence_kernel_if_needed() {
  local fence_path="${SCRATCH_PATH}/${MLX_FENCE_RELATIVE_PATH}"
  [ -f "${fence_path}" ] || return 0

  if ! /usr/bin/grep -Eq "coherent\(system\)|thread_scope_system|memory_order_seq_cst" "${fence_path}"; then
    return 0
  fi

  echo "▶︎ patching mlx fence.metal for current Metal toolchain"
  /bin/chmod u+w "${fence_path}"
  cat > "${fence_path}" <<'EOF'
#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

kernel void input_coherent(device uint* input [[buffer(0)]],
                           constant uint& size [[buffer(1)]],
                           uint index [[thread_position_in_grid]]) {
  if (index < size) {
    input[index] = input[index];
  }
}

kernel void fence_update(device atomic_uint* timestamp [[buffer(0)]],
                         constant uint& value [[buffer(1)]]) {
  atomic_store_explicit(timestamp, value, memory_order_relaxed);
}

kernel void fence_wait(device atomic_uint* timestamp [[buffer(0)]],
                       constant uint& value [[buffer(1)]]) {
  while (atomic_load_explicit(timestamp, memory_order_relaxed) < value) {
  }
}
EOF
  /bin/chmod u-w "${fence_path}"
}

compute_build_fingerprint() {
  (
    cd "${SRCROOT}"
    /usr/bin/shasum \
      "ClawdHomeSpeech/Package.swift" \
      "ClawdHomeSpeech/Package.resolved" \
      "ClawdHomeSpeech/main.swift" \
      "scripts/build-speech-tool.sh" \
      "project.yml" \
      "Makefile"
  ) | /usr/bin/shasum | /usr/bin/awk '{print $1}'
}

CONFIGURATION_LOWER="$(echo "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')"
case "${CONFIGURATION_LOWER}" in
  release) ;;
  *) CONFIGURATION_LOWER="debug" ;;
esac

should_build_speech_in_debug() {
  case "${CLAWDHOME_BUILD_SPEECH_IN_DEBUG:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${IS_XCODE_BUILD}" = true ] \
  && [ "${CONFIGURATION_LOWER}" = "debug" ] \
  && ! should_build_speech_in_debug; then
  echo "⏭ skip speech tool build in Debug (set CLAWDHOME_BUILD_SPEECH_IN_DEBUG=1 to enable)"
  cleanup_tool
  exit 0
fi

# 仅在 Apple Silicon 主机上构建；Intel 构建显式不包含该能力。
if [ "$(uname -m)" != "arm64" ]; then
  echo "⏭ skip speech tool embed (host is not Apple Silicon)"
  cleanup_tool
  exit 0
fi

if [ "${IS_XCODE_BUILD}" = true ]; then
  APP_BIN="${CODESIGNING_FOLDER_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
  if [ ! -f "${APP_BIN}" ]; then
    echo "⏭ skip speech tool embed (app binary missing)"
    cleanup_tool
    exit 0
  fi

  APP_ARCHS="$(/usr/bin/lipo -archs "${APP_BIN}" 2>/dev/null || true)"
  if ! echo "${APP_ARCHS}" | /usr/bin/grep -qw "arm64"; then
    echo "⏭ skip speech tool embed (app slice does not include arm64)"
    cleanup_tool
    exit 0
  fi
fi

PACKAGE_PATH="${SRCROOT}/ClawdHomeSpeech"
SCRATCH_PATH="${DERIVED_FILE_DIR}/ClawdHomeSpeech.build"
SDK_PATH="$(
  /usr/bin/xcrun --sdk macosx --show-sdk-path
)"
STAMP_PATH="${SCRATCH_PATH}/${BUILD_STAMP_NAME}"
FINGERPRINT="$(
  printf '%s\n%s\n%s\n%s\n' \
    "${CONFIGURATION_LOWER}" \
    "${SDK_PATH}" \
    "$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ')" \
    "$(compute_build_fingerprint)"
)"

if [ -f "${STAMP_PATH}" ] \
  && [ -f "${DEST_TOOL}" ] \
  && [ -f "${DEST_METALLIB}" ] \
  && [ "$(/bin/cat "${STAMP_PATH}")" = "${FINGERPRINT}" ]; then
  echo "⏭ skip speech tool build (inputs unchanged)"
  exit 0
fi

echo "▶︎ building bundled speech tool (${CONFIGURATION_LOWER})"
patch_mlx_fence_kernel_if_needed

/usr/bin/xcrun --sdk macosx swift build \
  --package-path "${PACKAGE_PATH}" \
  --configuration "${CONFIGURATION_LOWER}" \
  --arch arm64 \
  --product ClawdHomeSpeech \
  --scratch-path "${SCRATCH_PATH}" \
  -Xswiftc -sdk \
  -Xswiftc "${SDK_PATH}"

BUILT_TOOL="${SCRATCH_PATH}/${CONFIGURATION_LOWER}/ClawdHomeSpeech"
if [ ! -f "${BUILT_TOOL}" ]; then
  echo "error: bundled speech tool build finished without executable" >&2
  exit 1
fi

MLX_METALLIB_SCRIPT="${SCRATCH_PATH}/checkouts/speech-swift/scripts/build_mlx_metallib.sh"
if [ ! -x "${MLX_METALLIB_SCRIPT}" ]; then
  echo "error: speech-swift metallib builder missing at ${MLX_METALLIB_SCRIPT}" >&2
  exit 1
fi

echo "▶︎ building mlx.metallib (${CONFIGURATION_LOWER})"
# 依赖拉取发生在 swift build 期间；首次构建时这里再补丁一次，确保 fence.metal 已修复。
patch_mlx_fence_kernel_if_needed
BUILD_DIR="${SCRATCH_PATH}" "${MLX_METALLIB_SCRIPT}" "${CONFIGURATION_LOWER}"

BUILT_METALLIB="$(find "${SCRATCH_PATH}" -path "*/${CONFIGURATION_LOWER}/mlx.metallib" -type f | head -n 1 || true)"
if [ -z "${BUILT_METALLIB}" ] || [ ! -f "${BUILT_METALLIB}" ]; then
  echo "error: mlx.metallib build finished without artifact" >&2
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp "${BUILT_TOOL}" "${DEST_TOOL}"
cp "${BUILT_METALLIB}" "${DEST_METALLIB}"
chmod +x "${DEST_TOOL}"

# 剥离可执行程序的调试和多余符号 (仅在 release 配置下，减少约 17MB 空间)
if [ "${CONFIGURATION_LOWER}" = "release" ]; then
  echo "▶︎ stripping executable to shrink binary size"
  /usr/bin/strip "${DEST_TOOL}"
fi

# 对 mlx.metallib 进行符号剥离和压缩 (仅在 release 配置下，减少约 13MB 空间)
if [ "${CONFIGURATION_LOWER}" = "release" ]; then
  if /usr/bin/xcrun -find metal-strip >/dev/null 2>&1; then
    echo "▶︎ stripping and compressing mlx.metallib"
    if /usr/bin/xcrun metal-strip -S -T --compress-sections=all "${DEST_METALLIB}" -o "${DEST_METALLIB}.stripped"; then
      mv "${DEST_METALLIB}.stripped" "${DEST_METALLIB}"
    else
      echo "⏭ skip metal-strip (invocation failed on current toolchain)"
      rm -f "${DEST_METALLIB}.stripped"
    fi
  else
    echo "⏭ skip metal-strip (metal-strip utility not found)"
  fi
fi

# 复制伴随的资源和 Bundle 文件夹（包含 MLX 核心 GPU 算力所需的 mlx-swift_Cmlx.bundle/default.metallib 文件）
find "${SCRATCH_PATH}/${CONFIGURATION_LOWER}" -maxdepth 1 \( -name "*.resources" -o -name "*.bundle" \) -type d | while read -r src_res; do
  echo "▶︎ copying built resources: $(basename "${src_res}")"
  cp -R "${src_res}" "${DEST_DIR}/"
done

printf '%s' "${FINGERPRINT}" > "${STAMP_PATH}"
