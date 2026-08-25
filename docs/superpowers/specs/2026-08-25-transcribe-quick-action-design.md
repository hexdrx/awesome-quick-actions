# Transcribe Quick Action — Design

**Date:** 2026-08-25
**Status:** Approved, ready for implementation planning

## Summary

A Finder Quick Action that transcribes selected audio/video files to text.
Right-click → **Transcribe** → pick `Русский` or `English` → a `.txt` lands next
to each original.

The two languages use entirely different engines, because macOS covers one of
them well and the other not at all:

| | Engine | Ships with the repo | First-run download |
|---|---|---|---|
| **English** | Apple `SpeechAnalyzer` / `SpeechTranscriber` | `bin/transcribe-en` (~200 KB) | Apple locale asset (system-managed) |
| **Russian** | sherpa-onnx + GigaAM v3 e2e RNN-T | nothing | `transcribe-ru` (~25 MB) + model (~232 MB) |

## Why this split

macOS 26.3 ships `SpeechTranscriber`, a modern on-device recognizer.
`SpeechTranscriber.supportedLocales` covers `en-*`, `de-*`, `es-*`, `fr-*`,
`it-*`, `ja-JP`, `ko-KR`, `pt-*`, `zh-*`, `yue-CN` — **and no Russian**. Russian
exists only in the legacy `SFSpeechRecognizer` (Siri-era quality, weak
punctuation).

So English gets the native engine — no download from us, no dependency, good
quality. Russian needs an external model, and GigaAM v3 is the strongest open
option.

## Rejected alternatives

- **ONNX FastConformer for English.** Strictly worse than the native engine:
  same-or-lower quality, plus an ONNX runtime and a model download for a
  language macOS already handles well.
- **PyTorch GigaAM in a `uv`-managed venv.** Works, but needs Python + torch
  (~1 GB) on the user's machine. Rejected against the "clone and run" constraint.
- **CoreML export of GigaAM.** Would have required converting the model with
  `coremltools`, reimplementing log-mel features on vDSP, and hand-writing the
  RNN-T greedy loop in Swift. Obsolete: someone already published the ONNX
  export in sherpa-onnx's native format.
- **`istupakov/gigaam-v3-onnx`** (MIT, same weights, includes `v3_e2e_rnnt`).
  Correct model, but packaged for `onnx-asr`, which is Python.
- **`transcribe_longform` from GigaAM's own code.** Requires `pyannote.audio`,
  an `HF_TOKEN`, and accepting the license of a gated segmentation model.
  Unacceptable friction for a right-click action.

## Architecture

```
Transcribe/
├── Transcribe.workflow/            # bundle + waveform icon (light/dark)
│   └── Contents/{Info.plist,document.wflow,Resources/,QuickLook/}
├── src/transcribe.applescript      # menu, ffmpeg detection, progress, dispatch
├── src/swift/
│   ├── en/main.swift               # SpeechAnalyzer + SpeechTranscriber
│   └── ru/main.swift               # sherpa-onnx C API: VAD + OfflineRecognizer
├── bin/transcribe-en               # prebuilt universal binary, committed
├── tools/build.sh                  # builds both; statically links sherpa-onnx
├── install.sh
└── README.md
```

Binaries are **prebuilt** rather than compiled at install time. Compiling would
require Xcode Command Line Tools, which is a heavier ask than `ffmpeg`. Install
is `git clone`, so no quarantine attribute is set on them.

`bin/transcribe-ru` is *not* committed — at ~25 MB it would bloat the repo, and
every sherpa-onnx bump would add another copy to history. It is published to
GitHub Releases and fetched lazily. `install.sh` therefore needs no network, and
English-only users download nothing from us.

### Component responsibilities

- **`transcribe.applescript`** — owns all user interaction: the language menu,
  the progress bar, error dialogs, and locating `ffmpeg`. Contains no
  recognition logic. Reuses the `ffmpeg` detection logic from
  `Convert/src/convert.applescript` (`/opt/homebrew/bin`, `/usr/local/bin`,
  `/opt/local/bin`, `PATH`).
- **`transcribe-en`** — `transcribe-en <wav>...`, writes transcript to stdout,
  progress to stderr. Depends only on system frameworks.
- **`transcribe-ru`** — `transcribe-ru --models <dir> <wav>...`, same contract.
  Depends only on the statically linked sherpa-onnx.
- **model store** — a shell function in `transcribe.applescript` that ensures
  `~/Library/Application Support/AwesomeQuickActions/transcribe/` is populated
  before invoking `transcribe-ru`.

Each binary takes a **list** of WAVs and is invoked **once per batch**, not once
per file. Model load costs seconds; paying it per file makes a ten-file batch
needlessly painful.

## Data flow

```
selection → language menu → for each file: ffmpeg → 16 kHz mono WAV (temp)
         → transcribe-{en,ru} (one process, all files)
         → <original-basename>.txt next to the original
```

`ffmpeg` runs once per file to normalize any container to 16 kHz mono WAV. It
does **not** cut the audio into chunks.

### Chunking is the VAD's job, not ffmpeg's

The `LONGFORM_THRESHOLD = 25 * SAMPLE_RATE` in GigaAM's `modeling_gigaam.py` is
a property of the PyTorch wrapper — the point where `transcribe()` delegates to
`transcribe_longform()`. It is not a limit of the model. The ONNX encoder has a
dynamic time axis and `pos_emb_max_len: 5000` rotary embeddings.

Segmentation is still required, for two real reasons: attention is quadratic in
sequence length, so a long file exhausts memory; and the model was trained on
segments under 30 s, so quality degrades on longer input. GigaAM's own code
targets `max_duration: 22.0` with a `strict_limit_duration: 30.0`.

sherpa-onnx's built-in **silero VAD** does this in-process, splitting on
silence. Cutting with `ffmpeg` instead would mean temp files on disk and
boundaries placed by a timer rather than by speech — words severed mid-utterance.

## Russian engine

**Library:** sherpa-onnx v1.13.6 (Apache-2.0), from
`sherpa-onnx-v1.13.6-osx-universal2-static-no-tts-lib.tar.bz2` (37.1 MB). The
`no-tts` variant omits text-to-speech, which we do not use. Universal2 covers
both architectures.

**Model:** `csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16`
— GigaAM v3 **e2e** RNN-T already in sherpa-onnx's native layout.

| File | Size |
|---|---|
| `encoder.int8.onnx` | 224 MB |
| `decoder.onnx` | 4 MB |
| `joiner.onnx` | 2 MB |
| `tokens.txt` | 1025 entries |
| `silero_vad.onnx` (separate download) | ~2 MB |

The `punct` variant is the one that matters. Its `tokens.txt` holds 1025 BPE
tokens including `.`, `,`, `«`, `₽`, `€`, `$` and uppercase letters — the model
emits punctuation, capitalization and normalized text directly. The non-`punct`
sibling has a 34-token lowercase character vocabulary and no punctuation.

**Required configuration:**

```
model_type  = "nemo_transducer"
feature_dim = 64
```

Both are mandatory. The encoder's ONNX metadata carries `normalize_type`,
`pred_rnn_layers` and `pred_hidden`, but **not** `vocab_size`, so sherpa-onnx
cannot infer the model type and fails with
`offline-transducer-model.cc:InitDecoder 'vocab_size' does not exist in the metadata`.
This is [issue #3619](https://github.com/k2-fsa/sherpa-onnx/issues/3619), closed
after the reporter confirmed both parameters fix it.

**Features** are kaldi-native-fbank with hann window, `dither = 0`,
`remove_dc_offset = false`, `preemph_coeff = 0`, 64 mel bins, `low_freq = 0`,
`high_freq = 8000`, `round_to_power_of_two = false`. sherpa-onnx computes these
internally; we only pass `feature_dim`.

**Pipeline:** WAV → silero VAD → segments → `OfflineRecognizer` per segment →
join with spaces.

## English engine

`SpeechAnalyzer` with `SpeechTranscriber(locale: en-US)`.

`SpeechTranscriber.installedLocales` is empty on a fresh machine. When `en-US`
is absent, request it via `AssetInventory.assetInstallationRequest` and report
download progress. The asset is system-managed and shared with other apps; we
neither host nor version it.

Audio reaches the analyzer as `AnalyzerInput` built from the `ffmpeg`-produced
WAV. Only finalized results are collected.

## Model store

Location: `~/Library/Application Support/AwesomeQuickActions/transcribe/`

On the first Russian run, download `transcribe-ru` and the model files from this
repo's GitHub Releases as one step (~257 MB total), showing progress. Each file
is verified against a SHA-256 recorded in the repo, written to a temporary name,
and only then atomically renamed into place — an interrupted download leaves no
partial state and re-runs cleanly.

Subsequent runs find the files present and skip straight to transcription.

## Output

`<original-basename>.txt`, written next to the original, collision-safe by the
same rule the other actions use.

`.srt` is deliberately out of scope for v1. Both engines already produce the
timing data it would need — the VAD yields segment boundaries, and
`SpeechTranscriber` yields per-token timings — so it stays cheap to add later.

## Error handling

| Condition | Behavior |
|---|---|
| `ffmpeg` absent | Dialog in the style of Convert, with the `brew install ffmpeg` hint |
| Download interrupted | Temp file discarded, nothing renamed, actionable message |
| Checksum mismatch | Treated as a failed download; file discarded |
| `en-US` asset unavailable (offline) | Clear message naming the network as the cause |
| `ffmpeg` cannot decode a file | That file is skipped and named in the summary; the batch continues |
| Empty transcript (silence) | Warn, and do not write an empty `.txt` |

## Testing

**Golden test (Russian).** The model repo ships `test_wavs/example.wav` and
`test-onnx-rnnt.py`. The expected transcript begins
`ничьих не требуя похвал…` (per issue #3619). Capture the exact reference string
during the spike and assert on it. No reference has to be invented.

**Long-audio test.** A file over two minutes, to confirm VAD segmentation is
sane: no lost words at boundaries, no duplicated text across segments.

**English tests.** A `say`-generated sample plus one real recording.

**Batch test.** Several files at once, confirming the model is loaded once and
per-file `.txt` files land in the right places.

## Implementation order

1. **Spike.** Download the sherpa-onnx library and the model, transcribe
   `example.wav`, compare against the reference string. This settles the only
   remaining unknown before any UI work exists.
2. Russian binary: VAD segmentation, batch input, progress on stderr.
3. English binary, including the asset-installation path.
4. Model store: download, checksum, atomic rename.
5. AppleScript: menu, progress, error dialogs, `ffmpeg` detection.
6. Bundle, icon, `install.sh`, `README.md`, root `install.sh`/`uninstall.sh`
   and README table entries.

If the spike fails, the fallback is the `uv`-managed PyTorch venv described
under Rejected alternatives — slower and heavier, but known to work.

## Notes

- Licenses: sherpa-onnx Apache-2.0, GigaAM MIT. Both permit redistribution;
  attribute both in `README.md`.
- The stale docstring in `test-onnx-rnnt.py` reports a joiner output dimension
  of 513. `tokens.txt` has 1025 entries. The docstring is a leftover from
  another model — do not trust it; confirm the real dimension during the spike.
- Dialog text stays Russian, matching the other actions in this repo.
