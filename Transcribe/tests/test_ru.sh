#!/bin/bash
# Golden test for transcribe-ru. Requires assets fetched into $ASSETS.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-ru}"
ASSETS="${ASSETS:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"
WAV="$HERE/fixtures/example.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"
[ -f "$WAV" ] || fail "fixture missing: $WAV (run Transcribe/tests/fetch_fixtures.sh)"

out="$("$BIN" --models "$ASSETS" "$WAV" 2>/tmp/ru_stderr.txt)"

echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

body="$(echo "$out" | sed -n '2p')"

# Capitalization at VAD segment boundaries is a segmentation artifact, not a
# correctness signal (e.g. "Счастлив" vs "счастлив" depending on where the VAD
# draws the line) — so match case-insensitively on the fixed prefix.
shopt -s nocasematch
case "$body" in
  "ничьих не требуя похвал"*) ;;
  *) fail "unexpected transcript prefix: $body" ;;
esac
shopt -u nocasematch

# The punct model must emit punctuation and capitals; the char model would not.
echo "$body" | grep -q '[.,]' || fail "no punctuation — wrong model variant?"

# Content words that must survive regardless of exact VAD segmentation.
for word in "требуя" "похвал" "надеждой" "лукоморья"; do
  echo "$body" | grep -qi "$word" || fail "missing expected content word: $word"
done

# The fixture yields more than one VAD segment, so assert the progress line shape
# rather than a literal "1 1" count.
grep -qE '^PROGRESS transcribe [0-9]+ [0-9]+ example\.wav$' /tmp/ru_stderr.txt \
  || fail "missing progress line; got: $(cat /tmp/ru_stderr.txt)"

echo "PASS: test_ru"

# --- Multi-file batch, ONE process ---
# transcribe-ru builds its SherpaOnnxOfflineRecognizer once and reuses it
# across every file in the batch (unlike transcribe-en's SpeechTranscriber,
# which cannot be reused across an analyzer run — see test_en.sh). Assert
# that explicitly rather than by absence of a crash: pass the same fixture
# twice to one invocation and check both records come back correct.
out2="$("$BIN" --models "$ASSETS" "$WAV" "$WAV" 2>/tmp/ru_stderr2.txt)"

echo "$out2" | grep -q '^=== FILE 1 ===$' || fail "multi-file batch: missing FILE 1 header"
echo "$out2" | grep -q '^=== FILE 2 ===$' || fail "multi-file batch: missing FILE 2 header"

body2_1="$(echo "$out2" | sed -n '2p')"
body2_2="$(echo "$out2" | awk '/^=== FILE 2 ===$/{f=1;next} f{print; exit}')"

shopt -s nocasematch
for b in "$body2_1" "$body2_2"; do
  case "$b" in
    "ничьих не требуя похвал"*) ;;
    *) fail "multi-file batch: unexpected transcript prefix: $b" ;;
  esac
done
shopt -u nocasematch

echo "PASS: test_ru (two-file batch, single process)"
