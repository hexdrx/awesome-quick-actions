#!/bin/zsh
# Unit tests for the pure handlers in src/filetools.applescript.
# Compiles the source, load-scripts it, and asserts handler return values.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/filetools.applescript"
WORK="$(mktemp -d)"
SCPT="$WORK/ft.scpt"

if ! osacompile -o "$SCPT" "$SRC" 2>"$WORK/compile.err"; then
  echo "COMPILE FAILED:"; cat "$WORK/compile.err"; exit 1
fi

pass=0; fail=0
call() { osascript -e "set s to load script POSIX file \"$SCPT\"" -e "tell s to $1" 2>/dev/null; }
check() { # desc expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1));
  else fail=$((fail+1)); print -r -- "FAIL: $1"; print -r -- "  expected: [$2]"; print -r -- "  actual:   [$3]"; fi
}

# --- Task 1: string helpers ---
check "baseName"        "file.txt"     "$(call 'baseName("/a/b/file.txt")')"
check "dirOf"           "/a/b"         "$(call 'dirOf("/a/b/file.txt")')"
check "extOf"           "txt"          "$(call 'extOf("/a/b/file.txt")')"
check "extOf none"      ""             "$(call 'extOf("/a/b/README")')"
check "baseOf"          "file"         "$(call 'baseOf("/a/b/file.txt")')"
check "baseOf dotted"   "a.b"          "$(call 'baseOf("/x/a.b.txt")')"
check "trimSpace"       "hi"           "$(call 'trimSpace("   hi  ")')"
check "replaceText"     "a-b-c"        "$(call 'replaceText("a.b.c", ".", "-")')"
check "padNum"          "007"          "$(call 'padNum(7, 3)')"
check "expand pad"      "Photo 001"    "$(call 'expandTemplate("Photo ###", 1)')"
check "expand wide"     "Photo 042"    "$(call 'expandTemplate("Photo ###", 42)')"
check "expand narrow"   "IMG_5"        "$(call 'expandTemplate("IMG_#", 5)')"
check "expand nohash"   "clip 007"     "$(call 'expandTemplate("clip", 7)')"

# --- Task 2: filesystem helpers ---
T2="$WORK/t2"; mkdir -p "$T2"
touch "$T2/a.txt"
check "pathExists yes"  "true"   "$(call "pathExists(\"$T2/a.txt\")")"
check "pathExists no"   "false"  "$(call "pathExists(\"$T2/nope.txt\")")"
check "isDir yes"       "true"   "$(call "isDir(\"$T2\")")"
check "isDir no"        "false"  "$(call "isDir(\"$T2/a.txt\")")"
check "uniqueName free" "$T2/b.txt"   "$(call "uniqueName(\"$T2\", \"b\", \"txt\")")"
check "uniqueName coll" "$T2/a 2.txt" "$(call "uniqueName(\"$T2\", \"a\", \"txt\")")"
check "uniqueName noext" "$T2/c"      "$(call "uniqueName(\"$T2\", \"c\", \"\")")"

# --- Task 3: copy path ---
check "fileURL simple"  "file:///a/b/file.txt"      "$(call 'posixToFileURL("/a/b/file.txt")')"
check "fileURL space"   "file:///a/b/my%20file.txt" "$(call 'posixToFileURL("/a/b/my file.txt")')"
check "nameOnly"        "file.txt"                   "$(call 'nameOnly("/a/b/file.txt")')"

# --- Task 4: checksum ---
printf 'hello' > "$T2/h.txt"
EXP256="$(/usr/bin/shasum -a 256 "$T2/h.txt" | cut -d' ' -f1)"
check "hashOf 256"  "$EXP256" "$(call "hashOf(\"$T2/h.txt\", \"256\")")"
check "hashesEqual case" "true"  "$(call "hashesEqual(\"ABCdef\", \"  abcdef \")")"
check "hashesEqual diff" "false" "$(call 'hashesEqual("aa", "bb")')"

# --- Task 5: new file target dir ---
mkdir -p "$T2/sub"
check "targetDir folder"  "$T2/sub" "$(call "targetDir({\"$T2/sub\"})")"
check "targetDir file"    "$T2"     "$(call "targetDir({\"$T2/a.txt\"})")"
check "targetDir multi"   "$T2"     "$(call "targetDir({\"$T2/a.txt\", \"$T2/h.txt\"})")"

# --- Task 6: rename logic ---
check "rename prefix"  "IMG_a"     "$(call 'newBaseFor("prefix", "a", "IMG_", "", 1)')"
check "rename suffix"  "a_final"   "$(call 'newBaseFor("suffix", "a", "_final", "", 1)')"
check "rename replace" "Photo"     "$(call 'newBaseFor("replace", "IMG", "IMG", "Photo", 1)')"
check "rename number"  "Shot 003"  "$(call 'newBaseFor("number", "whatever", "Shot ###", "", 3)')"

# integration: renameBatch on real files (prefix)
mkdir -p "$T2/rn"; touch "$T2/rn/one.txt" "$T2/rn/two.txt"
call "renameBatch({\"$T2/rn/one.txt\", \"$T2/rn/two.txt\"}, \"prefix\", \"x_\", \"\")" >/dev/null
check "renameBatch f1" "1" "$( [ -f "$T2/rn/x_one.txt" ] && echo 1 || echo 0 )"
check "renameBatch f2" "1" "$( [ -f "$T2/rn/x_two.txt" ] && echo 1 || echo 0 )"

# no-op safety: a replace that doesn't match must leave the file untouched,
# never bump it to " 2" (regression for the self-collision bug)
mkdir -p "$T2/rn2"; touch "$T2/rn2/photo.txt"
call "renameBatch({\"$T2/rn2/photo.txt\"}, \"replace\", \"xyz\", \"abc\")" >/dev/null
check "rename noop keep"   "1" "$( [ -f "$T2/rn2/photo.txt" ] && echo 1 || echo 0 )"
check "rename noop nobump" "1" "$( [ ! -e "$T2/rn2/photo 2.txt" ] && echo 1 || echo 0 )"

# --- static lint: reserved AppleScript element terms used as plain variables ---
# `set files to {}` / `set lines to {}` etc. compile fine but crash at runtime
# with -10006 ("Can't set every <term> to ..."). osacompile + unit tests can't
# reach the UI handlers where these live, so scan the source statically.
RESERVED='file|files|line|lines|word|words|text|item|items|paragraph|paragraphs|character|characters|folder|folders|disk|disks'
badres="$(grep -nE "set (end of )?(${RESERVED}) to " "$SRC" || true)"
if [ -n "$badres" ]; then
  fail=$((fail+1)); print -r -- "FAIL: reserved-word variable assignment(s) — will crash -10006 at runtime:"; print -r -- "$badres"
else
  pass=$((pass+1))
fi

print -r -- "---"; print -r -- "$pass passed, $fail failed"
rm -rf "$WORK"
[ $fail -eq 0 ]
