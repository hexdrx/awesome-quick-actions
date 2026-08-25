# 🎙️ Transcribe

A Finder Quick Action that transcribes **audio and video** to text. Right-click file(s) → **Quick Actions → Transcribe** → choose **Русский** or **English** → a `.txt` transcript is written **next to the original** with a collision-safe name.

## Two engines

| Language | Engine | Why |
|----------|--------|-----|
| **English** | Apple's on-device `SpeechTranscriber` (macOS 26+) | Built into the OS — nothing to download from this repo. The en-US speech asset is Apple's own and system-managed (fetched and updated by macOS itself, not this action). |
| **Русский** | GigaAM v3 e2e RNN-T via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Apple's `SpeechTranscriber` has **no Russian locale at all**, so there's no on-device option to call — Transcribe ships its own model and runtime for it. GigaAM emits punctuation, capitalization, and normalized text directly (1025-token BPE vocabulary), so the Russian output needs no further cleanup. |

Both languages go through the same batch/progress/collision-safe pipeline; only the recognizer differs.

## What downloads on first Russian use

The Russian model isn't bundled — it's fetched once, on first use, and cached:

- Lands in `~/Library/Application Support/AwesomeQuickActions/transcribe/`
- ~257 MB total: encoder (224 MB) + decoder (4 MB) + joiner (2 MB) + silero VAD (~0.6 MB) + the `transcribe-ru` binary (~30 MB)
- Every file is checksum-verified against `assets.manifest` and installed atomically (no partial/corrupt state on a failed or interrupted download)
- English needs none of this — it never touches the network.

Long audio is segmented **in-process** by [silero VAD](https://github.com/snakers4/silero-vad) — no pyannote, no Hugging Face token required.

## Requirements

- `ffmpeg` — required for **both** languages; each file is decoded once to 16 kHz mono WAV before recognition.
  ```sh
  brew install ffmpeg
  ```
  Auto-detected in `/opt/homebrew/bin`, `/usr/local/bin` (Intel), `/opt/local/bin` (MacPorts), or `PATH`.
- **English** additionally requires **macOS 26+** (for `SpeechTranscriber`).
- **Russian** works on any macOS Transcribe supports — the model download happens on first use (see above).

## Install

```sh
./install.sh
```
or double-click `Transcribe.workflow` in Finder → **Install**.

## Uninstall

```sh
rm -rf ~/Library/Services/Transcribe.workflow
```
This does not remove the downloaded Russian model — delete `~/Library/Application Support/AwesomeQuickActions/transcribe/` separately if you want that space back.

## Rebuilding

The real sources are `src/transcribe.applescript` (the Automator front end) and `src/swift/` (the `transcribe-en` and `transcribe-ru` binaries, built against sherpa-onnx). To rebuild after editing:

```sh
tools/build.sh    # builds both universal (arm64 + x86_64) binaries
tools/embed.sh    # embeds the AppleScript + stages resources into Transcribe.workflow
./install.sh      # reinstalls into ~/Library/Services
```

`tools/build.sh` downloads the sherpa-onnx SDK on first run; `transcribe-ru` itself is never committed to git or bundled into the `.workflow` — it's distributed as a GitHub Release asset and fetched via `assets.manifest`, the same way the model files are.

## Licenses

The Russian pipeline is built on:

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — Apache-2.0
- [GigaAM v3](https://github.com/salute-developers/GigaAM) — MIT
- [silero-vad](https://github.com/snakers4/silero-vad) — MIT

The English pipeline uses only Apple's system frameworks (`Speech`), no third-party code.
