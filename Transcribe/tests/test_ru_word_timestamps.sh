#!/bin/bash
# Test for the --word-timestamps flag on transcribe-ru: mirrors
# test_en_word_timestamps.sh. Must emit one "[MM:SS.cc-MM:SS.cc] word" line
# per word instead of a plain paragraph or sentence-grouped lines.
#
# Unlike English, GigaAM (RNN-T, not TDT) has no real per-token duration.
# A word's raw end (the next word's onset, or the decode chunk's own end
# for a chunk's last word) is therefore clamped to the end of the silero
# VAD speech segment enclosing that word's last real (alphanumeric) token
# -- real acoustic evidence of where speech actually stopped, rather than
# a number dominated by whatever silence follows. This is still an upper
# bound, not an exact end: only end >= start is guaranteed, never
# end > start.
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

# A generous ceiling on real.wav (no word here is expected to legitimately
# run anywhere near this long) -- regression guard against the VAD clamp
# silently breaking and word ends going back to being dominated by
# trailing silence (measured on a real recording before this clamp
# existed: worst case was 7.60s for a 0.48s-median file).
CEILING_CENTIS = 200  # 2.00s

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
    # Russian end times are an upper bound -- only end >= start is
    # guaranteed, not end > start.
    if end < start:
        raise SystemExit("word end must not precede its own start: %r" % line)
    if end - start > CEILING_CENTIS:
        raise SystemExit(
            "word length %.2fs exceeds the sane ceiling (%.2fs) -- VAD clamp "
            "may have regressed: %r" % ((end - start) / 100, CEILING_CENTIS / 100, line))
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

# --- VAD-clamp alignment invariant, exercised across a REAL chunk boundary ---
#
# The clamp compares a word's last-content-token time (chunk-relative
# timestamp + that chunk's absolute-second offset) against VAD speech
# segments (computed once per file, in absolute SAMPLE coordinates,
# converted to absolute seconds). Getting that offset arithmetic wrong
# would silently clamp to the wrong segment -- on the single-chunk
# example.wav fixture above, chunkOffsetSeconds is always 0, so an offset
# bug would slip past every check so far. Build the same multi-chunk
# "seam" fixture test_ru_chunks.sh uses (a genuine ~24.4s file, guaranteed
# to decode as 2+ chunks) and verify, from the DEBUG VAD / DEBUG CHUNK
# lines TRANSCRIBE_RU_DEBUG_CHUNKS=1 exposes, that EVERY printed word end
# is explained by one of exactly two things:
#   (a) no clamp applied -- end equals the naive next-token onset (the
#       next word's start within the same chunk, or that chunk's own end
#       for the chunk's last word), or
#   (b) a clamp DID apply -- end exactly equals the end of some real VAD
#       speech segment, and that segment's end is <= the naive onset.
# A wrong offset would make (b) essentially never hold by coincidence, so
# this is a real correctness check, not a shape check.
SEAM="$HERE/fixtures/seam.wav"
SRC="$HERE/fixtures/example.wav"
if command -v ffmpeg >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
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

  SEAM_STDERR="/tmp/ru_wts_seam_stderr.txt"
  seam_out="$(TRANSCRIBE_RU_DEBUG_CHUNKS=1 "$BIN" --models "$ASSETS" --word-timestamps "$SEAM" 2>"$SEAM_STDERR")"
  echo "$seam_out" | grep -q '^=== FILE 1 ===$' || fail "seam: missing file header in stdout"
  seam_body="$(echo "$seam_out" | awk '/^=== FILE 1 ===$/{f=1;next} f{if ($0=="") exit; print}')"
  [ -n "$seam_body" ] || fail "seam: no word-timestamped lines produced"

  n_chunks="$(grep -c '^DEBUG CHUNK ' "$SEAM_STDERR" || true)"
  [ "$n_chunks" -ge 2 ] || fail "seam fixture decoded as $n_chunks chunk(s), expected >= 2 -- the offset invariant below needs a real chunk boundary"

  SEAM_BODY_FILE="/tmp/ru_wts_seam_body.txt"
  printf '%s\n' "$seam_body" > "$SEAM_BODY_FILE"

  python3 - "$SEAM_BODY_FILE" "$SEAM_STDERR" <<'PY' || fail "VAD-clamp alignment invariant violated"
import re, sys

body_path, stderr_path = sys.argv[1], sys.argv[2]
SR = 16000
TOL = 0.011  # centisecond rounding on both sides of the comparison

vad_segs, chunks = [], []
with open(stderr_path, encoding="utf-8") as f:
    for line in f:
        if line.startswith("DEBUG VAD "):
            _, _, s, e = line.split()
            vad_segs.append((int(s) / SR, int(e) / SR))
        elif line.startswith("DEBUG CHUNK "):
            _, _, s, e = line.split()
            chunks.append((int(s) / SR, int(e) / SR))
if not vad_segs:
    raise SystemExit("no DEBUG VAD lines found -- debug dump missing or disabled")
if not chunks:
    raise SystemExit("no DEBUG CHUNK lines found -- debug dump missing or disabled")

pat = re.compile(r'^\[(\d{2,}):(\d{2})\.(\d{2})–(\d{2,}):(\d{2})\.(\d{2})\] (.+)$')
words = []
with open(body_path, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        m = pat.match(line)
        if not m:
            raise SystemExit("line does not match the word-timestamp shape: %r" % line)
        smm, sss, scc, emm, ess, ecc, w = m.groups()
        start = int(smm) * 60 + int(sss) + int(scc) / 100
        end = int(emm) * 60 + int(ess) + int(ecc) / 100
        words.append((start, end, w, line))

def chunk_of(t):
    for cs, ce in chunks:
        if cs - TOL <= t <= ce + TOL:
            return (cs, ce)
    return None

seen_clamp = False
for i, (start, end, w, line) in enumerate(words):
    ch = chunk_of(start)
    if ch is None:
        raise SystemExit("word start %.3f falls in no decode chunk: %r" % (start, line))
    cs, ce = ch
    if i + 1 < len(words) and words[i + 1][0] <= ce + TOL:
        naive_onset = words[i + 1][0]
    else:
        naive_onset = ce

    if abs(end - naive_onset) <= TOL:
        continue  # (a) no clamp applied -- matches the naive onset

    # (b) a clamp must have applied: `end` must exactly equal some VAD
    # segment's end, and that end must be <= the naive onset (otherwise
    # the clamp could not have produced it).
    matched = any(abs(end - seg_end) <= TOL and seg_end <= naive_onset + TOL
                  for seg_start, seg_end in vad_segs)
    if not matched:
        raise SystemExit(
            "word end %.3f matches neither the naive next-token onset "
            "(%.3f) nor any real VAD segment end -- offset/clamp "
            "arithmetic is producing a value with no evidence behind it: %r"
            % (end, naive_onset, line))
    seen_clamp = True

if not seen_clamp:
    raise SystemExit("no word in the seam fixture was ever clamped by a VAD segment -- "
                      "the invariant above never actually exercised case (b)")
PY
else
  echo "SKIP: seam-fixture VAD-alignment invariant (ffmpeg/python3 not available)" >&2
fi

echo "PASS: test_ru_word_timestamps"
