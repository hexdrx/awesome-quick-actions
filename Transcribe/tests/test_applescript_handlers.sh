#!/bin/bash
# Runtime checks for the pure string-parsing handlers (sectionOf, engineErrorLines,
# hasErrorFor, rewriteErrorLines, trimBlank, enginePathFor, engineArgsFor).
# Unlike `choose from list` / `display alert` / the NSAlert timestamps dialog
# (askLangAndTimestamps / showTranscribeAlert), these have no UI surface, so
# they ARE testable headlessly: load the compiled script and call the
# handlers directly, entirely bypassing `on run` (so no dialog is ever
# triggered, and Automator's {input, parameters} are never needed).
#
# NOT covered here, and cannot be covered headlessly: the NSAlert dialog
# itself (askLangAndTimestamps / showTranscribeAlert) -- runModal() blocks
# on real UI, so its construction, its fallback-to-`choose from list` path,
# and reading the popup/checkbox state back can only be exercised by a human
# clicking through the actual Quick Action.
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

-- nonProgressLines: the last-resort hard-failure fallback used when the
-- engine died without emitting a single ERROR line (e.g. a crash) -- must
-- strip PROGRESS chatter but keep everything else, including a line that
-- happens not to start with "ERROR" at all (a raw crash message).
set crashBlob to "PROGRESS download 0 1 en-US" & return & "PROGRESS download 1 1 en-US" & return & "PROGRESS transcribe 1 1 transcribe_9f3ac21b.wav"
set npLines to (eng's nonProgressLines(crashBlob))
my assertEq((count of npLines), 0, "nonProgressLines drops an all-PROGRESS blob entirely")

set mixedBlob to "PROGRESS transcribe 1 1 a.wav" & return & "Fatal error: something crashed" & return & "PROGRESS download 1 1 x"
set mixedLines to (eng's nonProgressLines(mixedBlob))
my assertEq((count of mixedLines), 1, "nonProgressLines keeps the one non-PROGRESS line")
my assertEq(item 1 of mixedLines, "Fatal error: something crashed", "nonProgressLines keeps the line verbatim")
my assertEq((count of (eng's nonProgressLines(""))), 0, "nonProgressLines on an empty string")

-- majorVersionOf: used to gate English on macOS 26+ (transcribe-en fails at
-- dyld load, not at its own #available guard, on anything older).
my assertEq(eng's majorVersionOf("14.6.1"), 14, "majorVersionOf parses a three-part version")
my assertEq(eng's majorVersionOf("26.0"), 26, "majorVersionOf parses a two-part version")
my assertEq(eng's majorVersionOf("15"), 15, "majorVersionOf parses a bare major version")

-- enginePathFor: Russian dispatches from assetDir (fetched, not bundled),
-- English dispatches from resDir (the bundle's own Resources).
my assertEq(eng's enginePathFor("Русский", "/res", "/assets"), "/assets/transcribe-ru", "enginePathFor Russian uses assetDir")
my assertEq(eng's enginePathFor("English", "/res", "/assets"), "/res/transcribe-en", "enginePathFor English uses resDir")

-- engineArgsFor: --models is Russian-only; --timestamps / --word-timestamps
-- thread through to both languages alike, only when the dialog's matching
-- checkbox is checked. "по словам" (wantWordTimestamps) always wins over
-- "Таймкоды" (wantTimestamps) -- there is no combination of the two
-- checkboxes that produces neither flag when either is checked, and the two
-- flags are never passed together.
my assertEq(eng's engineArgsFor("Русский", "/assets", false, false), "--models " & quoted form of "/assets", "engineArgsFor Russian, neither checkbox")
my assertEq(eng's engineArgsFor("Русский", "/assets", true, false), "--models " & quoted form of "/assets" & " --timestamps", "engineArgsFor Russian, Таймкоды only")
my assertEq(eng's engineArgsFor("Русский", "/assets", false, true), "--models " & quoted form of "/assets" & " --word-timestamps", "engineArgsFor Russian, по словам only")
my assertEq(eng's engineArgsFor("Русский", "/assets", true, true), "--models " & quoted form of "/assets" & " --word-timestamps", "engineArgsFor Russian, both checked -- по словам wins")
my assertEq(eng's engineArgsFor("English", "/assets", false, false), "", "engineArgsFor English, neither checkbox has no flags at all")
my assertEq(eng's engineArgsFor("English", "/assets", true, false), "--timestamps", "engineArgsFor English, Таймкоды only")
my assertEq(eng's engineArgsFor("English", "/assets", false, true), "--word-timestamps", "engineArgsFor English, по словам only")
my assertEq(eng's engineArgsFor("English", "/assets", true, true), "--word-timestamps", "engineArgsFor English, both checked -- по словам wins")

return "ALL_OK"
EOF

OUT="$(osascript "$DRIVER" 2>"$WORK/driver_err.log")" || fail "$(cat "$WORK/driver_err.log")"
[ "$OUT" = "ALL_OK" ] || fail "unexpected driver output: $OUT"

echo "PASS: test_applescript_handlers"
