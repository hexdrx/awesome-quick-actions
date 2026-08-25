#!/bin/bash
# Regression test for the .txt write path.
#
# Two real bugs lived here, both invisible until a Finder run:
#   1. `use framework` puts the script in AppleScriptObjC mode, where the bare
#      `POSIX file` term fails with -1700, breaking EVERY write. Introduced the
#      moment the NSAlert dialog added the framework imports.
#   2. `do shell script` returns CR line endings, so a multi-line (--timestamps)
#      transcript landed as one long line in most editors.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src/transcribe.applescript"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
osacompile -o "$TMP/s.scpt" "$SRC" 2>/dev/null || fail "script does not compile"

OUT="$TMP/out.txt"
cat > "$TMP/drv.applescript" <<EOF
set s to load script POSIX file "$TMP/s.scpt"
set crText to "[00:01] Строка один." & (character id 13) & "[00:05] Вторая, с «ёлочками»." & (character id 13) & "[00:09] Третья 🎙"
return (s's writeUTF8("$OUT", crText)) as text
EOF
res="$(osascript "$TMP/drv.applescript")"
[ "$res" = "true" ] || fail "writeUTF8 returned $res (AppleScriptObjC POSIX file regression?)"
[ -f "$OUT" ] || fail "no file written"

# UTF-8 content survived, including Cyrillic, guillemets and emoji.
grep -q 'Строка один' "$OUT" || fail "Cyrillic lost"
grep -q '«ёлочками»' "$OUT" || fail "guillemets lost"
grep -q '🎙' "$OUT" || fail "emoji lost"

# CR must have become LF: three lines, no stray carriage returns.
if LC_ALL=C grep -q $'\r' "$OUT"; then fail "file still contains CR — LF normalisation regressed"; fi
n="$(wc -l < "$OUT" | tr -d ' ')"
[ "$n" = "3" ] || fail "expected 3 LF-terminated lines, got $n"

echo "PASS: test_write_utf8"
