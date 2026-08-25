#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'Transcribe/install.sh' "$ROOT/install.sh" || fail "root install.sh does not install Transcribe"
grep -q 'Transcribe.workflow' "$ROOT/uninstall.sh" || fail "root uninstall.sh does not remove Transcribe"
grep -q 'Transcribe' "$ROOT/README.md" || fail "root README has no Transcribe row"
[ -f "$ROOT/Transcribe/README.md" ] || fail "Transcribe/README.md missing"

# Every manifest URL must resolve, including the Release-hosted binary.
while read -r sha name url; do
  case "$sha" in ''|'#'*) continue ;; esac
  code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url")
  [ "$code" = "200" ] || fail "manifest URL for $name returned $code: $url"
done < "$ROOT/Transcribe/assets.manifest"

echo "PASS: test_integration"
