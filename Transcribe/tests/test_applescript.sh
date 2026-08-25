#!/bin/bash
# Static checks on the AppleScript: it must compile, and must avoid reserved words.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src/transcribe.applescript"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "missing: $SRC"

osacompile -o /tmp/transcribe_check.scpt "$SRC" 2>/tmp/osa.log \
  || fail "does not compile: $(cat /tmp/osa.log)"

# Reserved words as variables cause runtime -10006 errors.
if grep -nE '^[[:space:]]*set (file|files|line|lines|text|item|string|count|length|date)[[:space:]]+to' "$SRC"; then
  fail "reserved word used as a variable name"
fi

for h in findFFmpeg uniqueOut baseOf dirOf runEngine parseProgress engineErrorLines hasErrorFor; do
  grep -q "^on $h" "$SRC" || fail "missing handler: $h"
done

# The Automator-stub trap: resourceDir must prefer the installed Services
# path and never rely on `path to me` alone.
grep -q 'Library/Services/Transcribe.workflow/Contents/Resources' "$SRC" \
  || fail "resourceDir does not check the installed Services path"

# transcribe-ru must be invoked from the asset dir, not the bundle.
grep -q 'assetDir & "/transcribe-ru"' "$SRC" \
  || fail "transcribe-ru is not invoked from assetDir"
if grep -q 'resDir & "/transcribe-ru"' "$SRC"; then
  fail "transcribe-ru must not be invoked from resDir (bundle)"
fi

# stderr must be captured, not discarded.
if grep -qE 'do shell script[^"]*2>/dev/null' "$SRC"; then
  fail "engine stderr must not be discarded with 2>/dev/null"
fi

# The engine call must tolerate a multi-minute transcription.
grep -q 'with timeout of' "$SRC" || fail "no explicit AppleEvent timeout around the engine call"

# The .txt must be written natively, not via a shell heredoc.
if grep -q 'TRANSCRIBE_EOF' "$SRC"; then
  fail ".txt must be written natively (open for access/write), not a heredoc"
fi
grep -q 'open for access' "$SRC" || fail "no native file write (open for access) found"

# A partial WAV must not survive an aborted ffmpeg decode (Fix round 1, finding 1).
# `quoted form of w` (not `quoted form of (contents of w)`, which the cleanup
# loops use) is unique to the decode loop's own error handler.
grep -q 'rm -f " & quoted form of w$' "$SRC" \
  || fail "decode failure branch does not clean up the partial WAV"

# An engine ERROR for a file must suppress the generic empty-result message for
# that same file, not add both (Fix round 1, finding 2).
grep -q 'hasErrorFor(engErrLines' "$SRC" \
  || fail "empty-result message is not de-duplicated against engine ERROR lines"

echo "PASS: test_applescript"
