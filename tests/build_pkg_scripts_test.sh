#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "❌ $*" >&2
  exit 1
}

grep -q 'rm -rf "/Applications/${APP_NAME}.app"' scripts/build-pkg.sh \
  || fail "pkg preinstall must remove the installed app bundle so downgrades replace newer app versions"

grep -q 'https://github.com/deepjerry-ai/clawdhome/releases/download/v${FULL_VERSION}/${PKG_NAME}' scripts/build-pkg.sh \
  || fail "pkg API version sync must point download_url at GitHub Release assets"

echo "✅ build pkg script tests passed"
