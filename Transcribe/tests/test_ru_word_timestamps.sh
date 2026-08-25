#!/bin/bash
# Test for the --word-timestamps flag on transcribe-ru: mirrors
# test_en_word_timestamps.sh. Must emit one "[MM:SS.cc-MM:SS.cc] word" line
# per word instead of a plain paragraph or sentence-grouped lines.
#
# Unlike English, GigaAM (RNN-T, not TDT) has no real per-token duration, so
# a word's end is INFERRED as the onset of the next word (or the chunk's end
# for the last word of a chunk) -- an upper bound, not an exact end. This
# test only asserts end >= start (never end > start, which real data would
# not always satisfy) and non-decreasing starts.
#
# It also asserts the multi-token BPE assembly: "лукоморья" (from
# "У лукоморья дуб зелёный" in the example.wav fixture) is built from
# several subword tokens by the real model and must appear as ONE
# word-timestamp line, not split across several.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-ru}"
ASSETS="${ASSETS:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"
WAV="$HERE/fixtures/example.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"
[ -f "$WAV" ] || fail "fixture missing: $WAV (run Transcribe/tests/fetch_fixtures.sh)"

# --- with --word-timestamps ---
out="$("$BIN" --models "$ASSETS" --word-timestamps "$WAV" 2>/tmp/ru_wts_stderr.txt)"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

body="$(echo "$out" | awk '/^=== FILE 1 ===$/{f=1;next} f{if ($0=="") exit; print}')"
[ -n "$body" ] || fail "no word-timestamped lines produced"

for word in "требуя" "похвал" "надеждой"; do
  echo "$body" | grep -qi "$word" || fail "missing expected content word: $word"
done

# "лукоморья" is assembled from multiple BPE subword tokens (confirmed
# against the real model/binary: "лу" "ко" "мо" "рь" "я") -- it must appear
# as ONE line, not several fragment lines.
n_matches="$(echo "$body" | grep -ciE '^\[.*\] лукоморья,?$' || true)"
[ "$n_matches" -eq 1 ] || fail "expected exactly one 'лукоморья' word line (multi-token assembly), got $n_matches"
if echo "$body" | grep -qiE '^\[.*\] (лу|ко|мо|рь)$'; then
  fail "a fragment of 'лукоморья' appeared as its own word line -- multi-token words are not being merged"
fi

# Every word must be its own line.
n_lines="$(echo "$body" | grep -c . || true)"
[ "$n_lines" -ge 10 ] || fail "expected at least 10 word lines, got $n_lines"

BODY_FILE="/tmp/ru_wts_body.txt"
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
    # Russian end times are an INFERRED upper bound -- only end >= start is
    # guaranteed, not end > start.
    if end < start:
        raise SystemExit("word end must not precede its own start: %r" % line)
    starts.append(start)

for a, b in zip(starts, starts[1:]):
    if b < a:
        raise SystemExit("word starts are not non-decreasing: %r" % starts)

if starts[0] > 300:
    raise SystemExit("first word implausibly late: %d centiseconds" % starts[0])
PY

# --- --timestamps and plain output must be unaffected by this flag's mere
# existence (regression guard; the shape itself is covered by
# test_ru_timestamps.sh) ---
plain="$("$BIN" --models "$ASSETS" "$WAV" 2>/dev/null)"
echo "$plain" | sed -n '2p' | grep -qE '^\[[0-9]+:[0-9]{2}' \
  && fail "plain output must not contain any timestamp line"

ts_out="$("$BIN" --models "$ASSETS" --timestamps "$WAV" 2>/dev/null)"
echo "$ts_out" | grep -qE '^\[[0-9]{2,}:[0-9]{2}\.[0-9]{2}' \
  && fail "--timestamps output must not switch to the word-level [MM:SS.cc] shape"

echo "PASS: test_ru_word_timestamps"
