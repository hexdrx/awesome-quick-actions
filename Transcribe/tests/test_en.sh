#!/bin/bash
# Golden test for transcribe-en. Generates its own fixtures with `say`.
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

# --- Resample path: 44.1kHz stereo, distinct from the 16kHz mono fixture
# above, to exercise the AVAudioConverter path (transcribe-ru's fixtures
# and the fixture above are both already 16kHz mono, so the converter's
# no-op branch is all they ever cover). A real voice memo or screen
# recording is commonly 44.1kHz/stereo, so this is also realistic input,
# not just an adversarial one.
#
# The tail-word assertion below is the one that actually discriminates a
# truncated conversion: if the converter's output buffer capacity estimate
# is too small, or the final flush is dropped, the transcript stops
# early -- the head of the sentence still comes through fine, but the
# tail is silently missing. Checking only head words would pass on a
# truncated transcript; checking tail words would not.
WAV2="$HERE/fixtures/hello_en_44k_stereo.wav"
if [ ! -f "$WAV2" ]; then
  say -v Samantha -o /tmp/hello_en_44k.aiff \
    "She sells seashells by the seashore while singing a happy tune under the bright summer sky."
  ffmpeg -y -loglevel error -i /tmp/hello_en_44k.aiff -ac 2 -ar 44100 -c:a pcm_s16le "$WAV2"
fi

out2="$("$BIN" "$WAV2" 2>/tmp/en_stderr2.txt)"

echo "$out2" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout (44.1kHz/stereo)"

body2="$(echo "$out2" | sed -n '2p' | tr '[:upper:]' '[:lower:]')"
for w in she sells seashells; do
  echo "$body2" | grep -q "$w" || fail "missing head word '$w' in 44.1kHz/stereo transcript: $body2"
done
for w in bright summer sky; do
  echo "$body2" | grep -q "$w" || fail "missing tail word '$w' in 44.1kHz/stereo transcript (possible truncation): $body2"
done

grep -q '^PROGRESS transcribe 1 1 hello_en_44k_stereo.wav$' /tmp/en_stderr2.txt \
  || fail "missing progress line for 44.1kHz/stereo fixture; got: $(cat /tmp/en_stderr2.txt)"

echo "PASS: test_en (44.1kHz stereo resample)"
