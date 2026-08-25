#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../Transcribe.workflow"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$WF" ] || fail "no bundle at $WF"
plutil -lint "$WF/Contents/Info.plist" >/dev/null || fail "bad Info.plist"
plutil -lint "$WF/Contents/document.wflow" >/dev/null || fail "bad document.wflow"

for r in transcribe-en fetch-ru-assets.sh assets.manifest workflowCustomImageTemplate.png; do
  [ -e "$WF/Contents/Resources/$r" ] || fail "missing resource: $r"
done
[ -x "$WF/Contents/Resources/transcribe-en" ] || fail "transcribe-en not executable in bundle"
[ -x "$WF/Contents/Resources/fetch-ru-assets.sh" ] || fail "fetcher not executable in bundle"

# The embedded script must match the readable source.
python3 - "$WF/Contents/document.wflow" "$HERE/../src/transcribe.applescript" <<'PY'
import plistlib, sys
wflow, src = sys.argv[1], sys.argv[2]
with open(wflow, 'rb') as f:
    d = plistlib.load(f)
embedded = d['actions'][0]['action']['ActionParameters']['source']
with open(src, encoding='utf-8') as f:
    readable = f.read()
if embedded.strip() != readable.strip():
    raise SystemExit("embedded source differs from src/transcribe.applescript")
PY

echo "PASS: test_bundle"
