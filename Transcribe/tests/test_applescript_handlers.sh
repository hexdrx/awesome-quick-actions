#!/bin/bash
# Runtime checks for the pure string-parsing handlers (sectionOf, engineErrorLines,
# hasErrorFor, rewriteErrorLines, trimBlank). Unlike `choose from list` /
# `display alert`, these have no UI surface, so they ARE testable headlessly:
# load the compiled script and call the handlers directly, entirely bypassing
# `on run` (so no dialog is ever triggered, and Automator's {input,
# parameters} are never needed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src/transcribe.applescript"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "missing: $SRC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

COMPILED="$WORK/transcribe_rt.scpt"
osacompile -o "$COMPILED" "$SRC" 2>"$WORK/osa.log" || fail "does not compile: $(cat "$WORK/osa.log")"

DRIVER="$WORK/driver.applescript"
cat > "$DRIVER" <<EOF
set eng to load script POSIX file "$COMPILED"

on assertEq(got, want, label)
	if got is not want then
		error "FAIL: " & label & " -- got [" & got & "] want [" & want & "]"
	end if
end assertEq

-- Real per-file record shape from main.swift: header, transcript, blank separator.
set sample3 to "=== FILE 1 ===" & return & "hello" & return & return & "=== FILE 2 ===" & return & "world two" & return & return & "=== FILE 3 ===" & return & return & return

my assertEq(eng's sectionOf(sample3, 1), "hello", "sectionOf first record")
my assertEq(eng's sectionOf(sample3, 2), "world two", "sectionOf middle record")
-- Real case (confirmed against the actual binaries): a pure-tone/silent input
-- still emits its header, and both a genuinely empty transcript and an
-- engine-side failure look identical on the wire -- header plus two blank lines.
my assertEq(eng's sectionOf(sample3, 3), "", "sectionOf last record, empty body")

-- "FILE 1" vs "FILE 10": the marker is "=== FILE 1 ===" including the trailing
-- "===" right after the digits, so it cannot occur as a literal substring of
-- "=== FILE 10 ===" (which has "0 ===" after the "1", not " ===").
set sample10 to "=== FILE 1 ===" & return & "one" & return & return & "=== FILE 10 ===" & return & "ten" & return & return
my assertEq(eng's sectionOf(sample10, 1), "one", "sectionOf FILE 1 does not bleed into FILE 10")
my assertEq(eng's sectionOf(sample10, 10), "ten", "sectionOf FILE 10 itself")
my assertEq(eng's sectionOf(sample10, 2), "", "sectionOf on a marker that is not present")

-- engineErrorLines: mixed PROGRESS/ERROR lines from both engines' real stderr shape.
set errBlob to "PROGRESS transcribe 1 1 a.wav" & return & "ERROR b.wav: something bad" & return & "ERROR: fetch failed" & return & "PROGRESS download 1 1 x"
set errLines to (eng's engineErrorLines(errBlob))
my assertEq((count of errLines), 2, "engineErrorLines ignores PROGRESS lines")
my assertEq(item 1 of errLines, "b.wav: something bad", "engineErrorLines keeps the basenamed ERROR line")
my assertEq(item 2 of errLines, "fetch failed", "engineErrorLines trims the colon-form ERROR line")
my assertEq((count of (eng's engineErrorLines(""))), 0, "engineErrorLines on an empty string")

-- hasErrorFor: the de-dup lookup used to suppress the generic "empty result"
-- message when a specific engine ERROR already explains the same file.
my assertEq(eng's hasErrorFor(errLines, "b.wav"), true, "hasErrorFor matches a basenamed ERROR line")
my assertEq(eng's hasErrorFor(errLines, "c.wav"), false, "hasErrorFor does not match an unrelated file")
my assertEq(eng's hasErrorFor(errLines, "b.wa"), false, "hasErrorFor does not prefix-match a shorter name")

-- trimBlank
my assertEq(eng's trimBlank(return & " hi " & return), "hi", "trimBlank strips CR/space from both ends")
my assertEq(eng's trimBlank(""), "", "trimBlank on an empty string")

-- Real shape (fix round 2): the engine only ever sees the temp WAV path on
-- argv, never the user's original filename, so its ERROR lines are keyed on
-- e.g. "transcribe_deadbeef.wav" -- a name the user never chose and cannot
-- recognise. The two names here are deliberately UNRELATED (not built from
-- each other), reproducing the real mismatch instead of a self-consistent
-- synthetic pair that could not expose it.
set tempWavs to {"/tmp/transcribe_a1b2c3d4.wav", "/tmp/transcribe_deadbeef.wav"}
set origFiles to {"note.mp3", "Интервью 12 марта.m4a"}
set realErrLines to (eng's engineErrorLines("ERROR transcribe_deadbeef.wav: The operation couldn't be completed. (avfaudio error 1954115647.)" & return & "PROGRESS transcribe 1 1 transcribe_deadbeef.wav"))
my assertEq((count of realErrLines), 1, "engineErrorLines extracts the real avfaudio-error ERROR shape")

-- hasErrorFor must be fed the basename the ENGINE actually saw (the temp
-- WAV). Comparing against the user's original filename -- the mistake fix
-- round 1 shipped -- must never match, or the dedup silently regresses to
-- always-false again.
my assertEq(eng's hasErrorFor(realErrLines, "Интервью 12 марта.m4a"), false, "hasErrorFor must NOT match the original filename -- the engine never saw it")
my assertEq(eng's hasErrorFor(realErrLines, "transcribe_deadbeef.wav"), true, "hasErrorFor matches when fed the temp WAV basename the engine actually printed")

-- rewriteErrorLines must translate the temp name back to the user's original
-- filename for display, keep the message body verbatim, and never let the
-- temp name leak into user-visible text.
set rewritten to (eng's rewriteErrorLines(realErrLines, tempWavs, origFiles))
my assertEq((count of rewritten), 1, "rewriteErrorLines preserves the line count")
my assertEq(item 1 of rewritten, "Интервью 12 марта.m4a: The operation couldn't be completed. (avfaudio error 1954115647.)", "rewriteErrorLines swaps the temp name for the original, keeping the message")
if item 1 of rewritten contains "transcribe_deadbeef" then
	error "FAIL: rewriteErrorLines leaked the temp WAV name into user-visible text"
end if

-- A line that doesn't match any known temp WAV (e.g. the fetcher's own
-- "ERROR: <message>", which never names a file) must pass through unchanged
-- rather than being mangled or dropped.
set unrelated to (eng's rewriteErrorLines({"не удалось скачать encoder.int8.onnx"}, tempWavs, origFiles))
my assertEq(item 1 of unrelated, "не удалось скачать encoder.int8.onnx", "rewriteErrorLines passes through a line naming no known temp WAV")

return "ALL_OK"
EOF

OUT="$(osascript "$DRIVER" 2>"$WORK/driver_err.log")" || fail "$(cat "$WORK/driver_err.log")"
[ "$OUT" = "ALL_OK" ] || fail "unexpected driver output: $OUT"

echo "PASS: test_applescript_handlers"
