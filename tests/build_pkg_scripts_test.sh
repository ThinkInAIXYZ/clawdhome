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

echo "✅ build pkg script tests passed"
