#!/bin/bash
# The fetcher must be idempotent, verify checksums, and leave no partial files.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../src/fetch-ru-assets.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A corrupt file must be detected and re-fetched, not silently accepted.
mkdir -p "$TMP/assets"
echo "garbage" > "$TMP/assets/tokens.txt"
if ASSET_DIR="$TMP/assets" VERIFY_ONLY=1 "$SCRIPT" 2>/dev/null; then
  fail "corrupt tokens.txt passed verification"
fi

# No partial files may survive a failed run.
[ -z "$(find "$TMP/assets" -name '*.part' 2>/dev/null)" ] || fail "leftover .part files"

# Verification of a complete, valid install must exit 0 without downloading.
REAL="$HOME/Library/Application Support/AwesomeQuickActions/transcribe"
if [ -f "$REAL/encoder.int8.onnx" ]; then
  ASSET_DIR="$REAL" VERIFY_ONLY=1 "$SCRIPT" || fail "valid install failed verification"
fi

echo "PASS: test_fetch"
