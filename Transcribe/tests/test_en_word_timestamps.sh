#!/bin/bash
# Test for the --word-timestamps flag on transcribe-en: mirrors
# test_ru_word_timestamps.sh. Must emit one "[MM:SS.cc-MM:SS.cc] word" line
# per word instead of a plain paragraph or sentence-grouped lines. Unlike
# Russian, SpeechTranscriber gives a TRUE end time per word (a real
# audioTimeRange duration), so every word's end must be strictly greater
# than its start -- a zero-length word would mean the duration was silently
# dropped somewhere. Also checks that --timestamps and plain output are
# unaffected by this flag's existence.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-en}"
WAV="$HERE/fixtures/hello_en_multi.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"

# Reuses the same multi-sentence fixture as test_en_timestamps.sh.
if [ ! -f "$WAV" ]; then
  say -v Samantha -o /tmp/hello_en_multi.aiff \
    "Apples are red. Are bananas yellow? Cherries are definitely sweet."
  ffmpeg -y -loglevel error -i /tmp/hello_en_multi.aiff -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"
fi

# --- with --word-timestamps ---
out="$("$BIN" --word-timestamps "$WAV" 2>/tmp/en_wts_stderr.txt)"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

body="$(echo "$out" | awk '/^=== FILE 1 ===$/{f=1;next} f{if ($0=="") exit; print}')"
[ -n "$body" ] || fail "no word-timestamped lines produced"

body_lc="$(echo "$body" | tr '[:upper:]' '[:lower:]')"
for word in "apples" "bananas" "cherries"; do
  echo "$body_lc" | grep -qi "$word" || fail "missing expected content word: $word"
done

# Every word must be its own line -- a multi-word sentence collapsed onto
# one line would mean word-splitting silently regressed to sentence mode.
n_lines="$(echo "$body" | grep -c . || true)"
[ "$n_lines" -ge 6 ] || fail "expected at least 6 word lines, got $n_lines"

BODY_FILE="/tmp/en_wts_body.txt"
printf '%s\n' "$body" > "$BODY_FILE"

python3 - "$BODY_FILE" <<'PY' || fail "word-timestamped output shape/ordering invalid"
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    body = f.read()
lines = [l for l in body.split(chr(10)) if l.strip()]
if not lines:
    raise SystemExit("no lines to check")

pat = re.compile(r'^\[(\d{2,}):(\d{2})\.(\d{2})–(\d{2,}):(\d{2})\.(\d{2})\] (.+)$')
starts = []
for line in lines:
    m = pat.match(line)
    if not m:
        raise SystemExit("line does not match '[MM:SS.cc–MM:SS.cc] word' shape: %r" % line)
    smm, sss, scc, emm, ess, ecc, word = m.groups()
    if len(smm) < 2 or len(emm) < 2:
        raise SystemExit("minutes field not zero-padded to at least 2 digits: %r" % line)
    if not word.strip():
        raise SystemExit("empty word text: %r" % line)
    start = int(smm) * 6000 + int(sss) * 100 + int(scc)
    end = int(emm) * 6000 + int(ess) * 100 + int(ecc)
    if end <= start:
        raise SystemExit("word end must be strictly greater than start (real duration expected): %r" % line)
    starts.append(start)

for a, b in zip(starts, starts[1:]):
    if b < a:
        raise SystemExit("word starts are not non-decreasing: %r" % starts)

if starts[0] > 300:
    raise SystemExit("first word implausibly late: %d centiseconds" % starts[0])
PY

# --- --timestamps and plain output must be unaffected by this flag's mere
# existence (regression guard; the shape itself is covered by
# test_en_timestamps.sh) ---
plain="$("$BIN" "$WAV" 2>/dev/null)"
echo "$plain" | sed -n '2p' | grep -qE '^\[[0-9]+:[0-9]{2}' \
  && fail "plain output must not contain any timestamp line"

ts_out="$("$BIN" --timestamps "$WAV" 2>/dev/null)"
echo "$ts_out" | grep -qE '^\[[0-9]{2,}:[0-9]{2}\.[0-9]{2}' \
  && fail "--timestamps output must not switch to the word-level [MM:SS.cc] shape"

echo "PASS: test_en_word_timestamps"
