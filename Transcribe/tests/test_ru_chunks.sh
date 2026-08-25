#!/bin/bash
# Coverage-invariant test for the VAD-guided chunker (replaces test_ru_seam.sh,
# which guarded lead/tail padding around VAD segments that no longer exists:
# VAD is now used only to choose where to CUT, never what to keep, so there
# is no onset-clipping seam left to pad around).
#
# The invariant: decode chunks must tile the whole file exactly. The first
# chunk starts at sample 0, the last chunk ends at the last sample, and every
# chunk starts exactly where the previous one ended -- no gap (dropped
# audio) and no overlap (duplicated audio) anywhere.
#
# Builds a short-gap fixture at test time (not committed -- see
# Transcribe/.gitignore) by splicing two DISTINCT stretches of example.wav
# back together with ~0.45s of digital silence between them -- the same
# fixture test_ru_seam.sh (fix round 1) built, reused here because a real
# VAD-detected gap is exactly what gives the chunker a candidate cut point
# to exercise.
#
# Requires ffmpeg, python3, and assets fetched into $ASSETS (same as test_ru.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-ru}"
ASSETS="${ASSETS:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"
SRC="$HERE/fixtures/example.wav"
SEAM="$HERE/fixtures/seam.wav"
STDERR_LOG="/tmp/ru_chunks_stderr.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"
[ -f "$SRC" ] || fail "fixture missing: $SRC (run Transcribe/tests/fetch_fixtures.sh)"
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg not found — needed to build the seam fixture"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

# example.wav is 180640 samples @ 16kHz. Segment 0 of the golden fixture spans
# roughly [1728, 136800) ("Ничьих ... грешные мои."); segment 1 spans roughly
# [148160, 176224) ("У Лукоморья дуб зелёный."). The chunker only ever cuts
# when a chunk would otherwise exceed 20s (320000 samples), so a short splice
# alone (as fix-round-1's test_ru_seam.sh used) always decodes as a single
# chunk and never exercises a real cut. Build a fixture that actually crosses
# the 20s boundary instead: segment 0, a short 0.45s gap, segment 1, a long
# 12s gap, segment 1 again -- total ~24.4s, with a real VAD gap landing
# comfortably inside the first 20s so the chunker must choose a genuine
# candidate cut point rather than falling back to an exact-20s cut.
ffmpeg -hide_banner -loglevel error -y \
  -i "$SRC" -f lavfi -i "anullsrc=r=16000:cl=mono" \
  -filter_complex "\
[0:a]atrim=start_sample=1728:end_sample=136800,asetpts=PTS-STARTPTS[a1];\
[1:a]atrim=start_sample=0:end_sample=7200,asetpts=PTS-STARTPTS[sil1];\
[0:a]atrim=start_sample=148160:end_sample=176224,asetpts=PTS-STARTPTS[a2];\
[1:a]atrim=start_sample=0:end_sample=192000,asetpts=PTS-STARTPTS[sil2];\
[0:a]atrim=start_sample=148160:end_sample=176224,asetpts=PTS-STARTPTS[a2b];\
[a1][sil1][a2][sil2][a2b]concat=n=5:v=0:a=1[out]" \
  -map "[out]" -ar 16000 -ac 1 -c:a pcm_s16le "$SEAM" \
  || fail "ffmpeg failed to build the seam fixture"

TOTAL_SAMPLES="$(python3 -c "import wave; print(wave.open('$SEAM').getnframes())")"

# TRANSCRIBE_RU_DEBUG_CHUNKS=1 makes the binary emit "DEBUG CHUNK <start> <end>"
# lines on stderr, one per decode chunk -- a debug-only path that does not
# alter the stdout contract (checked below same as any other invocation).
out="$(TRANSCRIBE_RU_DEBUG_CHUNKS=1 "$BIN" --models "$ASSETS" "$SEAM" 2>"$STDERR_LOG")"
echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"
body="$(echo "$out" | sed -n '2p')"

# Both halves' content must survive the splice -- proof the chunker never
# drops audio, not just that its reported bounds look contiguous.
echo "$body" | grep -qi "требуя" || fail "missing content from segment 0: $body"
echo "$body" | grep -qi "лукоморья" || fail "missing content from segment 1: $body"

python3 - "$TOTAL_SAMPLES" "$STDERR_LOG" <<'PY' || fail "chunk coverage invariant violated"
import sys
total = int(sys.argv[1])
chunks = []
with open(sys.argv[2]) as f:
    for line in f:
        if line.startswith("DEBUG CHUNK "):
            _, _, s, e = line.split()
            chunks.append((int(s), int(e)))

if not chunks:
    sys.exit("no DEBUG CHUNK lines found in stderr")
# The spliced gap should give the chunker a real candidate cut point; a
# single chunk would mean the coverage checks below never exercise a seam.
if len(chunks) < 2:
    sys.exit("expected multiple chunks from a gapped fixture, got %d" % len(chunks))
if chunks[0][0] != 0:
    sys.exit("first chunk does not start at sample 0: %r" % (chunks[0],))
if chunks[-1][1] != total:
    sys.exit(
        "last chunk does not end at the last sample (%d != %d): %r"
        % (chunks[-1][1], total, chunks[-1])
    )
for a, b in zip(chunks, chunks[1:]):
    if a[1] != b[0]:
        sys.exit("gap or overlap between chunks %r and %r" % (a, b))
for s, e in chunks:
    if e <= s:
        sys.exit("empty or inverted chunk: %r" % ((s, e),))
PY

echo "PASS: test_ru_chunks"
