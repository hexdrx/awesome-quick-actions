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

for h in findFFmpeg uniqueOut baseOf dirOf runEngine parseProgress engineErrorLines hasErrorFor rewriteErrorLines; do
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

# Fix round 2: the engine only ever sees the temp WAV path, never the user's
# original filename, so hasErrorFor must be compared against the temp WAV's
# basename -- comparing against `srcPath` (the original file) never matches
# and silently regresses to the pre-fix always-false behaviour.
if grep -q 'hasErrorFor(engErrLines, my baseName(srcPath))' "$SRC"; then
  fail "hasErrorFor is compared against the original filename, not the temp WAV the engine actually saw"
fi
grep -q 'hasErrorFor(engErrLines, my baseName(tempWav))' "$SRC" \
  || fail "hasErrorFor is not compared against the temp WAV basename"

# A raw engine ERROR line names the temp WAV (e.g. "transcribe_<tag>.wav"),
# which is meaningless to the user. It must be rewritten to the user's
# original filename before ever reaching an alert.
grep -q 'rewriteErrorLines(engErrLines, wavs, decoded)' "$SRC" \
  || fail "engine ERROR lines are not rewritten to the original filename before display"

for h in nonProgressLines majorVersionOf; do
  grep -q "^on $h" "$SRC" || fail "missing handler: $h"
done

# English must be gated on macOS 26+ in the AppleScript itself: transcribe-en
# is built with nothing weak-linked, so it fails at dyld load before its own
# #available guard ever runs -- that guard's message is unreachable dead
# code, and this check is what actually surfaces it to a pre-26 user.
grep -q 'lang is "English" and (my majorVersionOf(system version of (system info))) < 26' "$SRC" \
  || fail "English is not gated on macOS 26+ before dispatch"

# The hard-failure alert must never fall back to the raw, unfiltered engine
# stderr blob (PROGRESS chatter + temp WAV names) -- it must go through
# nonProgressLines first.
if grep -qE '^\s*set failMsg to engErr$' "$SRC"; then
  fail "hard-failure alert falls back to the raw unfiltered engErr blob"
fi
grep -q 'rewriteErrorLines(my nonProgressLines(engErr), wavs, decoded)' "$SRC" \
  || fail "hard-failure fallback does not filter PROGRESS lines out of engErr"

# The model-fetch failure alert must extract ERROR lines rather than
# dumping do shell script's raw combined-output error message verbatim.
grep -q 'set errLines to my engineErrorLines(errMsg)' "$SRC" \
  || fail "model-fetch failure alert does not filter errMsg through engineErrorLines"

# assetDir (derived once from the user's Library folder) must be the single
# source of truth for where Russian assets live -- passed explicitly to the
# fetcher rather than letting it independently re-derive the path from $HOME.
grep -q 'ASSET_DIR=" & quoted form of assetDir' "$SRC" \
  || fail "fetch-ru-assets.sh is not invoked with an explicit ASSET_DIR override"

# The dialog must be a real NSAlert with a checkbox, not the old bare
# `choose from list` -- but `use framework` requires `use scripting
# additions` right after it, or every Standard Additions call in the file
# (display alert, do shell script, path to, ...) fails to compile.
grep -q 'use framework "AppKit"' "$SRC" || fail "AppKit framework not used for the dialog"
grep -q 'use scripting additions' "$SRC" || fail "use scripting additions missing (required once use framework is present)"
grep -q 'current application.s NSAlert' "$SRC" || fail "dialog is not built with NSAlert"
grep -q 'NSControlStateValueOff' "$SRC" || fail "timestamps checkbox is not initialised off by default"

for h in askLangAndTimestamps showTranscribeAlert enginePathFor engineArgsFor; do
  grep -q "^on $h" "$SRC" || fail "missing handler: $h"
done

# The dialog must be guarded: any NSAlert construction/runModal failure must
# fall back to the old `choose from list`, not let the whole action die.
grep -q 'choose from list {"Русский", "English"}' "$SRC" \
  || fail "no choose-from-list fallback for a broken NSAlert dialog"

# --timestamps must be threaded through runEngine to whichever binary is
# dispatched, without breaking Russian's existing --models handling.
grep -q 'on runEngine(lang, resDir, assetDir, wavs, wantTimestamps)' "$SRC" \
  || fail "runEngine does not accept wantTimestamps"
grep -q 'runEngine(lang, resDir, assetDir, wavs, wantTimestamps)' "$SRC" \
  || fail "runEngine is not called with wantTimestamps"
grep -q -- '--models' "$SRC" || fail "Russian --models handling is missing"

echo "PASS: test_applescript"
