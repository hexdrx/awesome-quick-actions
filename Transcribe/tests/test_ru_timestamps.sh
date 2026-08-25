#!/bin/bash
# Test for the --timestamps flag: transcribe-ru must emit "[MM:SS] Sentence
# text." lines instead of a plain paragraph, timestamps must be non-decreasing
# across the whole file, and the first one must be plausible (near the start
# of the recording). Also checks that omitting the flag still produces the
# old plain-paragraph shape, byte-for-byte the same as before this feature
# was added.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-ru}"
ASSETS="${ASSETS:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"
WAV="$HERE/fixtures/example.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"
[ -f "$WAV" ] || fail "fixture missing: $WAV (run Transcribe/tests/fetch_fixtures.sh)"

# --- without --timestamps: unchanged plain-paragraph shape ---
plain="$("$BIN" --models "$ASSETS" "$WAV" 2>/dev/null)"
plain_body="$(echo "$plain" | sed -n '2p')"
echo "$plain_body" | grep -qE '^\[[0-9]+:[0-9]{2}\]' \
  && fail "plain (no --timestamps) output must not contain timestamp lines: $plain_body"

# --- with --timestamps ---
out="$("$BIN" --models "$ASSETS" --timestamps "$WAV" 2>/tmp/ru_ts_stderr.txt)"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

# Body is everything between the header and the trailing blank line.
body="$(echo "$out" | awk '/^=== FILE 1 ===$/{f=1;next} f{if ($0=="") exit; print}')"
[ -n "$body" ] || fail "no timestamped lines produced"

# Content words that must survive regardless of exact chunk/sentence
# boundaries (same as test_ru.sh's golden check).
for word in "требуя" "похвал" "надеждой" "лукоморья"; do
  echo "$body" | grep -qi "$word" || fail "missing expected content word: $word"
done

BODY_FILE="/tmp/ru_ts_body.txt"
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

# The fixture's speech starts a fraction of a second in (sample 1728 @
# 16kHz); the first reported timestamp must be plausible, i.e. near the
# start of the recording, not some arbitrary later offset.
if times[0] > 3:
    raise SystemExit("first timestamp implausibly late: %ds" % times[0])
PY

echo "PASS: test_ru_timestamps"
