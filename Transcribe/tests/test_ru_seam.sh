#!/bin/bash
# Regression test for the VAD segment-padding seam (Finding 1, fix round 1):
# padded decode windows for adjacent VAD segments must never overlap.
#
# Builds a short-gap fixture at test time (not committed — see Transcribe/.gitignore)
# by splicing two DISTINCT stretches of example.wav back together with roughly 0.3s
# of silence between them: the first ends "...грешные мои." (segment 0 of the golden
# fixture) and the second begins "У Лукоморья дуб зелёный." (segment 1). Because the
# two halves are lexically distinct, any word appearing adjacent-duplicated at the
# splice is unambiguously a seam artifact, not content the source audio legitimately
# repeats.
#
# CAVEAT: this test does NOT discriminate pre-fix from post-fix — it passes on both.
# On this corpus the overlap region lands in near-silence (the VAD's own minimum
# reported gap, ~4192 samples, exceeds tailPad=3200), and the RNN-T greedy decoder
# partitions it cleanly rather than duplicating. It still exercises and guards the
# seam code path; it does not prove the seam fix.
#
# Requires ffmpeg and assets fetched into $ASSETS (same as test_ru.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-ru}"
ASSETS="${ASSETS:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"
SRC="$HERE/fixtures/example.wav"
SEAM="$HERE/fixtures/seam.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"
[ -f "$SRC" ] || fail "fixture missing: $SRC (run Transcribe/tests/fetch_fixtures.sh)"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg not found — needed to build the seam fixture"

# example.wav is 180640 samples @ 16kHz. Segment 0 of the golden fixture spans
# roughly [1728, 136800) ("Ничьих ... грешные мои."); segment 1 spans roughly
# [148160, 176224) ("У Лукоморья дуб зелёный."). Splice them back together with
# 7200 samples (0.45s) of digital silence — this reliably yields a real VAD gap of
# a few hundred ms (roughly 0.3s once VAD's own hysteresis is applied), well under
# the leadPad+tailPad (8000-sample) band where padded windows can overlap.
ffmpeg -hide_banner -loglevel error -y \
  -i "$SRC" -f lavfi -i "anullsrc=r=16000:cl=mono" \
  -filter_complex "\
[0:a]atrim=start_sample=1728:end_sample=136800,asetpts=PTS-STARTPTS[a1];\
[1:a]atrim=start_sample=0:end_sample=7200,asetpts=PTS-STARTPTS[sil];\
[0:a]atrim=start_sample=148160:end_sample=176224,asetpts=PTS-STARTPTS[a2];\
[a1][sil][a2]concat=n=3:v=0:a=1[out]" \
  -map "[out]" -ar 16000 -ac 1 -c:a pcm_s16le "$SEAM" \
  || fail "ffmpeg failed to build the seam fixture"

out="$("$BIN" --models "$ASSETS" "$SEAM" 2>/tmp/ru_seam_stderr.txt)"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"
body="$(echo "$out" | sed -n '2p')"

# Both halves' content must survive the splice.
echo "$body" | grep -qi "требуя" || fail "missing content from segment 0: $body"
echo "$body" | grep -qi "лукоморья" || fail "missing content from segment 1: $body"

# No word may appear twice in a row (case-insensitively, punctuation ignored) — a
# clean partition writes each word once; an overlapping decode window can write the
# same trailing/leading word from both sides of the seam.
python3 - "$body" <<'PY' || fail "adjacent duplicate word at the seam: $body"
import re, sys
words = re.findall(r"[^\W\d_]+", sys.argv[1].lower(), re.UNICODE)
for a, b in zip(words, words[1:]):
    if a == b:
        sys.exit(1)
PY

echo "PASS: test_ru_seam"
