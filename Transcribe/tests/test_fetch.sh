#!/bin/bash
# The fetcher must be idempotent, verify checksums (not just presence),
# and leave no partial files after a real download. Fully self-contained:
# uses a throwaway manifest pointing at small local files via file:// URLs,
# so it exercises fetcher logic (not transport) and never depends on the
# developer machine's real Application Support state.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../src/fetch-ru-assets.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures: two small local files served via file:// ---
SRC="$TMP/src"; mkdir -p "$SRC"
printf 'alpha-content' > "$SRC/a.bin"
printf 'beta-content-a-bit-longer' > "$SRC/b.bin"
SHA_A="$(shasum -a 256 "$SRC/a.bin" | awk '{print $1}')"
SHA_B="$(shasum -a 256 "$SRC/b.bin" | awk '{print $1}')"

MANIFEST="$TMP/assets.manifest"
cat > "$MANIFEST" <<EOF
# test manifest
$SHA_A  a.bin  file://$SRC/a.bin
$SHA_B  b.bin  file://$SRC/b.bin
EOF

# --- (a) a complete, valid install: exit 0, nothing on stderr ---
ADIR_A="$TMP/assets_valid"; mkdir -p "$ADIR_A"
cp "$SRC/a.bin" "$ADIR_A/a.bin"
cp "$SRC/b.bin" "$ADIR_A/b.bin"

out="$(MANIFEST="$MANIFEST" ASSET_DIR="$ADIR_A" VERIFY_ONLY=1 "$SCRIPT" 2>&1 1>/dev/null)" \
  || fail "valid install failed verification"
[ -z "$out" ] || fail "valid install printed unexpected stderr: $out"

# --- (b) one corrupt file among otherwise-valid files must be caught ---
# This is the case that actually isolates checksum comparison: both files
# are present, so a fetcher that only checks existence (not content) would
# pass here by mistake.
ADIR_B="$TMP/assets_corrupt"; mkdir -p "$ADIR_B"
cp "$SRC/a.bin" "$ADIR_B/a.bin"
printf 'not-the-right-content' > "$ADIR_B/b.bin"

if MANIFEST="$MANIFEST" ASSET_DIR="$ADIR_B" VERIFY_ONLY=1 "$SCRIPT" 2>/dev/null; then
  fail "corrupt b.bin (with valid a.bin present) passed verification"
fi

# --- (c) a fetch must populate a missing file and leave no .part ---
ADIR_C="$TMP/assets_fetch"; mkdir -p "$ADIR_C"
cp "$SRC/a.bin" "$ADIR_C/a.bin"
# b.bin is entirely absent; the fetcher must download it.

MANIFEST="$MANIFEST" ASSET_DIR="$ADIR_C" "$SCRIPT" 2>"$TMP/fetch.log" \
  || fail "fetch of missing file failed: $(cat "$TMP/fetch.log")"

[ -f "$ADIR_C/b.bin" ] || fail "missing file was not fetched"
[ "$(shasum -a 256 "$ADIR_C/b.bin" | awk '{print $1}')" = "$SHA_B" ] \
  || fail "fetched file has the wrong checksum"
[ -z "$(find "$ADIR_C" -name '*.part' 2>/dev/null)" ] || fail "leftover .part files after a successful fetch"

# Having fetched it, a second run must now be idempotent and silent.
out2="$(MANIFEST="$MANIFEST" ASSET_DIR="$ADIR_C" VERIFY_ONLY=1 "$SCRIPT" 2>&1 1>/dev/null)" \
  || fail "post-fetch verification failed"
[ -z "$out2" ] || fail "post-fetch verification printed unexpected stderr: $out2"

# --- (d) a failed download must leave no .part either ---
ADIR_D="$TMP/assets_fail"; mkdir -p "$ADIR_D"
BADMANI="$TMP/assets_bad.manifest"
cat > "$BADMANI" <<EOF
0000000000000000000000000000000000000000000000000000000000000000  missing.bin  file://$SRC/does-not-exist.bin
EOF
if MANIFEST="$BADMANI" ASSET_DIR="$ADIR_D" "$SCRIPT" 2>/dev/null; then
  fail "fetch of a nonexistent URL unexpectedly succeeded"
fi
[ -z "$(find "$ADIR_D" -name '*.part' 2>/dev/null)" ] || fail "leftover .part files after a failed fetch"

echo "PASS: test_fetch"
