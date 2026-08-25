#!/bin/bash
# embed.sh has a from-scratch fallback for when Contents/document.wflow does
# not exist (e.g. it was deleted and someone runs `tools/embed.sh` cold to
# regenerate it). That path is otherwise never exercised: `plutil -lint`
# only checks plist syntax, and test_bundle.sh's embedded-string comparison
# only checks the `source` field -- neither would notice a regenerated
# document missing CanShowWhenRun (which gates the AppleScript's progress
# window) or the workflowMetaData needed for the Service to register and
# run correctly. This test actually forces the fallback path and inspects
# what it produces.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE/.."
WF="$DIR/Transcribe.workflow"
DOC="$WF/Contents/document.wflow"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$DOC" ] || fail "no document.wflow to move aside -- run tools/embed.sh once first"

BACKUP="$(mktemp -t transcribe_document_wflow_backup)"
cp "$DOC" "$BACKUP"
restore() { cp "$BACKUP" "$DOC"; rm -f "$BACKUP"; }
trap restore EXIT

rm -f "$DOC"
[ -f "$DOC" ] && fail "document.wflow still present after removal (test setup bug)"

"$DIR/tools/embed.sh" >/tmp/embed_fallback.log 2>&1 || fail "tools/embed.sh failed cold; see /tmp/embed_fallback.log"

[ -f "$DOC" ] || fail "cold embed.sh did not (re)create document.wflow"
plutil -lint "$DOC" >/dev/null || fail "cold-regenerated document.wflow is not valid plist"

python3 - "$DOC" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
a = d['actions'][0]['action']

def require(cond, label):
    if not cond:
        raise SystemExit(f"FAIL: cold-regenerated document.wflow missing/wrong: {label}")

require(a.get('CanShowWhenRun') is True, "CanShowWhenRun must be True (gates the progress window)")
require(a.get('AMAccepts', {}).get('Types') == ['com.apple.applescript.object'], "AMAccepts.Types")
require(a.get('AMProvides', {}).get('Types') == ['com.apple.applescript.object'], "AMProvides.Types")
require(a.get('Category') == ['AMCategoryUtilities'], "Category")
require(a.get('Keywords') == ['Run'], "Keywords")
require('0' in a.get('arguments', {}), "arguments.0")
require(a.get('isViewVisible') == 1, "isViewVisible")
require(bool(a.get('location')), "location")
require(bool(a.get('nibPath')), "nibPath")

meta = d.get('workflowMetaData', {})
for key, want in [
    ('serviceApplicationBundleID', 'com.apple.finder'),
    ('serviceInputTypeIdentifier', 'com.apple.Automator.fileSystemObject'),
    ('serviceOutputTypeIdentifier', 'com.apple.Automator.nothing'),
    ('workflowTypeIdentifier', 'com.apple.Automator.servicesMenu'),
    ('applicationBundleID', 'com.apple.finder'),
    ('inputTypeIdentifier', 'com.apple.Automator.fileSystemObject'),
    ('outputTypeIdentifier', 'com.apple.Automator.nothing'),
]:
    require(meta.get(key) == want, f"workflowMetaData.{key}")

# Fresh UUIDs, not the zero-padded placeholders a naive fallback might use,
# and non-empty.
for key in ('InputUUID', 'OutputUUID', 'UUID'):
    v = a.get(key, '')
    require(len(v) == 36 and v != '00000000-0000-0000-0000-000000000000', f"{key} must be a real generated UUID")
require(len({a['InputUUID'], a['OutputUUID'], a['UUID']}) == 3, "InputUUID/OutputUUID/UUID must all differ")
PY

# Re-embed the readable source is already done by embed.sh itself; confirm
# it actually matches src/transcribe.applescript on this cold-built doc too.
python3 - "$DOC" "$DIR/src/transcribe.applescript" <<'PY'
import plistlib, sys
wflow, src = sys.argv[1], sys.argv[2]
with open(wflow, 'rb') as f:
    d = plistlib.load(f)
embedded = d['actions'][0]['action']['ActionParameters']['source']
with open(src, encoding='utf-8') as f:
    readable = f.read()
if embedded != readable:
    raise SystemExit("FAIL: cold-regenerated document.wflow's embedded source differs from src/transcribe.applescript")
PY

echo "PASS: test_embed_fallback"
