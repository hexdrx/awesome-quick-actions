#!/bin/bash
# Golden test for transcribe-en. Generates its own fixture with `say`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-en}"
WAV="$HERE/fixtures/hello_en.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"

if [ ! -f "$WAV" ]; then
  say -v Samantha -o /tmp/hello_en.aiff "The quick brown fox jumps over the lazy dog."
  ffmpeg -y -loglevel error -i /tmp/hello_en.aiff -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"
fi

out="$("$BIN" "$WAV" 2>/tmp/en_stderr.txt)"

echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

body="$(echo "$out" | sed -n '2p' | tr '[:upper:]' '[:lower:]')"
for w in quick brown fox lazy dog; do
  echo "$body" | grep -q "$w" || fail "missing word '$w' in: $body"
done

grep -q '^PROGRESS transcribe 1 1 hello_en.wav$' /tmp/en_stderr.txt \
  || fail "missing progress line; got: $(cat /tmp/en_stderr.txt)"

echo "PASS: test_en"
