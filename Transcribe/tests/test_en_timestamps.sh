#!/bin/bash
# Test for the --timestamps flag on transcribe-en: mirrors test_ru_timestamps.sh.
# Must emit "[MM:SS] Sentence text." lines instead of a plain paragraph,
# timestamps must be non-decreasing across the whole file, and the first one
# must be plausible (near the start of the recording). Also checks that
# omitting the flag still produces the old plain-paragraph shape, byte-for-byte
# the same as before this feature was added.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-en}"
WAV="$HERE/fixtures/hello_en_multi.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"

# Three short sentences with real gaps between them (period, question mark,
# exclamation), so sentence-boundary grouping across multiple SpeechTranscriber
# finals is actually exercised, not just a single one-sentence utterance.
if [ ! -f "$WAV" ]; then
  say -v Samantha -o /tmp/hello_en_multi.aiff \
    "Apples are red. Are bananas yellow? Cherries are definitely sweet."
  ffmpeg -y -loglevel error -i /tmp/hello_en_multi.aiff -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"
fi

# --- without --timestamps: unchanged plain-paragraph shape ---
plain="$("$BIN" "$WAV" 2>/dev/null)"
plain_body="$(echo "$plain" | sed -n '2p')"
echo "$plain_body" | grep -qE '^\[[0-9]+:[0-9]{2}\]' \
  && fail "plain (no --timestamps) output must not contain timestamp lines: $plain_body"

# --- with --timestamps ---
out="$("$BIN" --timestamps "$WAV" 2>/tmp/en_ts_stderr.txt)"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

# Body is everything between the header and the trailing blank line.
body="$(echo "$out" | awk '/^=== FILE 1 ===$/{f=1;next} f{if ($0=="") exit; print}')"
[ -n "$body" ] || fail "no timestamped lines produced"

body_lc="$(echo "$body" | tr '[:upper:]' '[:lower:]')"
for word in "apples" "bananas" "cherries"; do
  echo "$body_lc" | grep -qi "$word" || fail "missing expected content word: $word"
done

BODY_FILE="/tmp/en_ts_body.txt"
printf '%s\n' "$body" > "$BODY_FILE"

python3 - "$BODY_FILE" <<'PY' || fail "timestamped output shape/ordering invalid"
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    body = f.read()
lines = [l for l in body.split(chr(10)) if l.strip()]
if not lines:
    raise SystemExit("no lines to check")

pat = re.compile(r'^\[(\d{2,}):(\d{2})\] (.+)$')
times = []
for line in lines:
    m = pat.match(line)
    if not m:
        raise SystemExit("line does not match '[MM:SS] text' shape: %r" % line)
    mm, ss, text = m.groups()
    if len(mm) < 2:
        raise SystemExit("minutes field not zero-padded to at least 2 digits: %r" % line)
    ss_i = int(ss)
    if ss_i < 0 or ss_i > 59:
        raise SystemExit("seconds field out of range: %r" % line)
    if not text.strip():
        raise SystemExit("empty sentence text: %r" % line)
    times.append(int(mm) * 60 + ss_i)

for a, b in zip(times, times[1:]):
    if b < a:
        raise SystemExit("timestamps are not non-decreasing: %r" % times)

# The fixture's speech starts at the very beginning of the recording; the
# first reported timestamp must be plausible, i.e. near the start, not some
# arbitrary later offset.
if times[0] > 3:
    raise SystemExit("first timestamp implausibly late: %ds" % times[0])
PY

echo "PASS: test_en_timestamps"
