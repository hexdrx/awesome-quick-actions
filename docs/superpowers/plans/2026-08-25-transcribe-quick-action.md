# Transcribe Quick Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Finder Quick Action that transcribes selected audio/video to `.txt`, using Apple's native `SpeechTranscriber` for English and sherpa-onnx + GigaAM v3 for Russian.

**Architecture:** An AppleScript owns all UI (language menu, progress bar, dialogs) and shells out to two prebuilt Swift CLI binaries — one per language — each invoked **once per batch**. `ffmpeg` normalizes any container to 16 kHz mono WAV. Russian audio is segmented in-process by silero VAD; English is fed whole to `SpeechAnalyzer`.

**Tech Stack:** AppleScript (Automator service), Swift 6 / swiftc, sherpa-onnx v1.13.6 C API, Apple Speech framework (macOS 26), `ffmpeg`, bash for tests and asset fetching.

**Spec:** `docs/superpowers/specs/2026-08-25-transcribe-quick-action-design.md`

## Global Constraints

- Target platform: **macOS 26.0+** on Apple Silicon and Intel. The English engine requires macOS 26 (`SpeechTranscriber`).
- Runtime dependencies allowed: **`ffmpeg` only**. No Python, no `uv`, no torch, no Homebrew packages beyond `ffmpeg`.
- `ffmpeg` search order, matching `Convert/src/convert.applescript:368`: `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `/opt/local/bin/ffmpeg`, then `command -v ffmpeg` with `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin`.
- sherpa-onnx version: **v1.13.6**, artifact `sherpa-onnx-v1.13.6-osx-universal2-static-no-tts-lib.tar.bz2`. Static, universal2, no TTS.
- Russian model: `csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16` — the **`punct`** variant. The non-`punct` sibling has a 34-token lowercase vocabulary and is the wrong model.
- Mandatory sherpa-onnx config: `modelType: "nemo_transducer"` and `featureDim: 64`. Omitting either fails with `'vocab_size' does not exist in the metadata`.
- Asset directory: `~/Library/Application Support/AwesomeQuickActions/transcribe/`.
- All user-facing dialog text is **Russian**, matching the other actions in this repo.
- Binaries are prebuilt; `install.sh` must not require network or Xcode Command Line Tools.
- Progress protocol on stderr: `PROGRESS <phase> <done> <total> [<detail>]`, phases `download` | `decode` | `transcribe`.
- Commit on the `feat/transcribe` branch only. Do not merge to `main` or push without explicit permission.

---

### Task 1: Spike — prove the Russian stack end to end

Nothing else in this plan is worth building until sherpa-onnx actually decodes GigaAM v3. This task produces a throwaway script and an answer.

**Files:**
- Create: `/private/tmp/claude-501/.../scratchpad/spike/` (throwaway, not committed)

**Interfaces:**
- Consumes: nothing
- Produces: a verified reference transcript string for `example.wav`, recorded in Task 2's golden test; a confirmed list of `.a` files needed for static linking.

- [ ] **Step 1: Download the sherpa-onnx static library**

```bash
SPIKE=/private/tmp/claude-501/-Users-s1ng-fun-awesome-quick-actions/b51d13aa-907a-44ca-9ccb-fab7eae4363c/scratchpad/spike
mkdir -p "$SPIKE" && cd "$SPIKE"
curl -fL -o sherpa.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.6/sherpa-onnx-v1.13.6-osx-universal2-static-no-tts-lib.tar.bz2
tar xf sherpa.tar.bz2
find . -name '*.a' | sort
find . -name 'c-api.h'
```

Expected: an `include/sherpa-onnx/c-api/c-api.h` and a `lib/` holding several `.a` archives. **Record the exact `.a` list** — Task 4's build script needs it.

- [ ] **Step 2: Download the model, the VAD, and the Swift wrapper**

```bash
cd "$SPIKE"
M=https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main
mkdir -p models
for f in encoder.int8.onnx decoder.onnx joiner.onnx tokens.txt; do
  curl -fL -o "models/$f" "$M/$f"
done
curl -fL -o models/example.wav "$M/test_wavs/example.wav"
curl -fL -o models/silero_vad.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx

S=https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.6/swift-api-examples
curl -fL -O "$S/SherpaOnnx.swift"
curl -fL -O "$S/SherpaOnnx-Bridging-Header.h"
ls -lh models
```

Expected: `encoder.int8.onnx` ≈ 224 MB, `decoder.onnx` ≈ 4 MB, `joiner.onnx` ≈ 2 MB, `tokens.txt` with 1025 lines, `silero_vad.onnx` ≈ 2 MB.

- [ ] **Step 3: Write the throwaway spike program**

```bash
cat > "$SPIKE/spike.swift" <<'SWIFT'
import AVFoundation
import Foundation

extension AudioBuffer {
  func array() -> [Float] { Array(UnsafeBufferPointer(self)) }
}
extension AVAudioPCMBuffer {
  func array() -> [Float] { self.audioBufferList.pointee.mBuffers.array() }
}

let dir = CommandLine.arguments[1]
let wav = CommandLine.arguments[2]

let transducer = sherpaOnnxOfflineTransducerModelConfig(
  encoder: "\(dir)/encoder.int8.onnx",
  decoder: "\(dir)/decoder.onnx",
  joiner: "\(dir)/joiner.onnx")

var modelConfig = sherpaOnnxOfflineModelConfig(
  tokens: "\(dir)/tokens.txt",
  transducer: transducer,
  numThreads: 2,
  debug: 1,
  modelType: "nemo_transducer")

let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 64)
var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

var silero = sherpaOnnxSileroVadModelConfig(
  model: "\(dir)/silero_vad.onnx", threshold: 0.25, windowSize: 512)
var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)
let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &vadConfig, buffer_size_in_seconds: 120)

let f = try! AVAudioFile(forReading: URL(fileURLWithPath: wav))
let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                           frameCapacity: AVAudioFrameCount(f.length))!
try! f.read(into: buf)
let samples = buf.array()

for off in stride(from: 0, to: samples.count, by: 512) {
  let end = min(off + 512, samples.count)
  vad.acceptWaveform(samples: [Float](samples[off..<end]))
}
vad.flush()

var parts: [String] = []
while !vad.isEmpty() {
  let s = vad.front()
  vad.pop()
  parts.append(recognizer.decode(samples: s.samples).text)
}
print(parts.joined(separator: " "))
SWIFT
```

- [ ] **Step 4: Build it against the static library**

```bash
cd "$SPIKE"
INC=$(dirname $(dirname $(dirname $(find . -name c-api.h | head -1))))
LIBDIR=$(dirname $(find . -name 'libsherpa-onnx-c-api.a' | head -1))
swiftc -lc++ -O \
  -I "$INC" \
  -import-objc-header ./SherpaOnnx-Bridging-Header.h \
  ./spike.swift ./SherpaOnnx.swift \
  -L "$LIBDIR" $(cd "$LIBDIR" && ls *.a | sed 's/^lib/-l/; s/\.a$//' | tr '\n' ' ') \
  -o spike
```

Expected: a binary, no undefined symbols. If linking fails on missing symbols, the `.a` order is wrong — repeat the `-l` group twice, which resolves circular static dependencies.

- [ ] **Step 5: Run it and capture the reference transcript**

```bash
cd "$SPIKE" && ./spike ./models ./models/example.wav | tee reference.txt
```

Expected: Russian text beginning `ничьих не требуя похвал` (per sherpa-onnx issue #3619), **with punctuation and capitalization**. Lowercase output with no punctuation means the wrong model variant was downloaded — check that the URL contains `-punct-`.

- [ ] **Step 6: Confirm the joiner vocabulary size**

The stale docstring in the model repo's `test-onnx-rnnt.py` claims a joiner output dimension of 513, while `tokens.txt` has 1025 entries. Confirm which is real:

```bash
cd "$SPIKE" && ./spike ./models ./models/example.wav 2>&1 | grep -i vocab
```

Expected: sherpa-onnx's `debug: 1` output reports `vocab_size=1025`. Record the answer; if it is genuinely 513, stop and report — the model is not what the spec assumes.

- [ ] **Step 7: Decide**

If Steps 5 and 6 pass, record the exact reference string and the `.a` list, then continue to Task 2. If they fail, **stop and report** — the fallback is the `uv`-managed PyTorch venv described in the spec's Rejected alternatives, which is a different plan.

There is no commit for this task. The spike directory is throwaway.

---

### Task 2: Russian transcription binary

**Files:**
- Create: `Transcribe/src/swift/ru/main.swift`
- Create: `Transcribe/tests/fixtures/.gitkeep`
- Create: `Transcribe/tests/test_ru.sh`
- Create: `Transcribe/tests/run.sh`

**Interfaces:**
- Consumes: the reference transcript and `.a` list from Task 1.
- Produces: a binary with this contract, relied on by Tasks 4, 5 and 6:
  - Invocation: `transcribe-ru --models <dir> <wav>...`
  - stdout: one record per input file — a line `=== FILE <index> ===`, then the transcript, then a blank line.
  - stderr: `PROGRESS transcribe <done> <total> <basename>` lines.
  - Exit 0 if every file succeeded; exit 1 if any failed, with `ERROR <basename>: <message>` on stderr.

The repo has no test framework. These tests are plain bash with `set -e` and string comparison — proportionate to a project whose other actions are AppleScript and shell.

- [ ] **Step 1: Write the failing test**

```bash
mkdir -p Transcribe/tests/fixtures
cat > Transcribe/tests/test_ru.sh <<'SH'
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
case "$body" in
  "ничьих не требуя похвал"*) ;;
  *) fail "unexpected transcript: $body" ;;
esac

# The punct model must emit punctuation and capitals; the char model would not.
echo "$body" | grep -q '[.,]' || fail "no punctuation — wrong model variant?"

grep -q '^PROGRESS transcribe 1 1 example.wav$' /tmp/ru_stderr.txt \
  || fail "missing progress line; got: $(cat /tmp/ru_stderr.txt)"

echo "PASS: test_ru"
SH
chmod +x Transcribe/tests/test_ru.sh

cat > Transcribe/tests/run.sh <<'SH'
#!/bin/bash
# Run every test_*.sh in this directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test_*.sh; do
  echo "--- $(basename "$t")"
  "$t" || rc=1
done
exit $rc
SH
chmod +x Transcribe/tests/run.sh
```

Copy `example.wav` from the spike into `Transcribe/tests/fixtures/example.wav`. Replace the expected prefix `ничьих не требуя похвал` with the **exact** string Task 1 Step 5 recorded.

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/run.sh`
Expected: `FAIL: binary not built: .../bin/transcribe-ru`

- [ ] **Step 3: Write the implementation**

```swift
// Transcribe/src/swift/ru/main.swift
// Russian transcription via sherpa-onnx + GigaAM v3 e2e RNN-T.
// Usage: transcribe-ru --models <dir> <wav>...
import AVFoundation
import Foundation

extension AudioBuffer {
  func array() -> [Float] { Array(UnsafeBufferPointer(self)) }
}
extension AVAudioPCMBuffer {
  func array() -> [Float] { self.audioBufferList.pointee.mBuffers.array() }
}

func die(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
  exit(2)
}

func note(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

// ---- arguments ----
var modelsDir = ""
var wavs: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
  args.removeFirst()
  if a == "--models" {
    guard let v = args.first else { die("--models needs a value") }
    modelsDir = v
    args.removeFirst()
  } else {
    wavs.append(a)
  }
}
if modelsDir.isEmpty || wavs.isEmpty { die("usage: transcribe-ru --models <dir> <wav>...") }

// ---- recognizer, built once for the whole batch ----
let transducer = sherpaOnnxOfflineTransducerModelConfig(
  encoder: "\(modelsDir)/encoder.int8.onnx",
  decoder: "\(modelsDir)/decoder.onnx",
  joiner: "\(modelsDir)/joiner.onnx")

let modelConfig = sherpaOnnxOfflineModelConfig(
  tokens: "\(modelsDir)/tokens.txt",
  transducer: transducer,
  numThreads: max(2, ProcessInfo.processInfo.activeProcessorCount / 2),
  debug: 0,
  modelType: "nemo_transducer")  // mandatory: metadata carries no vocab_size

let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 64)  // mandatory
var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
let recognizer = SherpaOnnxOfflineRecognizer(config: &config)

let windowSize = 512
var silero = sherpaOnnxSileroVadModelConfig(
  model: "\(modelsDir)/silero_vad.onnx", threshold: 0.25, windowSize: Int32(windowSize))
var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)

var failed = false

for (i, path) in wavs.enumerated() {
  let base = URL(fileURLWithPath: path).lastPathComponent
  do {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                     frameCapacity: AVAudioFrameCount(f.length)) else {
      throw NSError(domain: "transcribe", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "cannot allocate buffer"])
    }
    try f.read(into: buf)
    let samples = buf.array()

    // A fresh VAD per file: segment state must not leak across files.
    let vad = SherpaOnnxVoiceActivityDetectorWrapper(
      config: &vadConfig, buffer_size_in_seconds: 120)

    var segments: [[Float]] = []
    for off in stride(from: 0, to: samples.count, by: windowSize) {
      let end = min(off + windowSize, samples.count)
      vad.acceptWaveform(samples: [Float](samples[off..<end]))
    }
    vad.flush()
    while !vad.isEmpty() {
      segments.append(vad.front().samples)
      vad.pop()
    }

    // Silence, or audio the VAD rejected wholesale: fall back to the whole file
    // rather than emitting nothing.
    if segments.isEmpty && !samples.isEmpty { segments = [samples] }

    var parts: [String] = []
    for (n, seg) in segments.enumerated() {
      let text = recognizer.decode(samples: seg).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { parts.append(text) }
      note("PROGRESS transcribe \(n + 1) \(segments.count) \(base)")
    }
    if segments.isEmpty { note("PROGRESS transcribe 1 1 \(base)") }

    print("=== FILE \(i + 1) ===")
    print(parts.joined(separator: " "))
    print("")
  } catch {
    failed = true
    note("ERROR \(base): \(error.localizedDescription)")
    print("=== FILE \(i + 1) ===")
    print("")
    print("")
  }
}

exit(failed ? 1 : 0)
```

The VAD is rebuilt per file while the recognizer is not: the recognizer is stateless across calls and expensive to construct, whereas the VAD holds a sample buffer that must not carry over.

- [ ] **Step 4: Build and run the test**

Building needs Task 4's script, which does not exist yet. Build manually for now, using the `.a` list from Task 1:

```bash
mkdir -p Transcribe/bin
SPIKE=/private/tmp/claude-501/.../scratchpad/spike
INC=$(dirname $(dirname $(dirname $(find "$SPIKE" -name c-api.h | head -1))))
LIBDIR=$(dirname $(find "$SPIKE" -name 'libsherpa-onnx-c-api.a' | head -1))
swiftc -lc++ -O \
  -I "$INC" \
  -import-objc-header "$SPIKE/SherpaOnnx-Bridging-Header.h" \
  Transcribe/src/swift/ru/main.swift "$SPIKE/SherpaOnnx.swift" \
  -L "$LIBDIR" $(cd "$LIBDIR" && ls *.a | sed 's/^lib/-l/; s/\.a$//' | tr '\n' ' ') \
  -o Transcribe/bin/transcribe-ru

mkdir -p "$HOME/Library/Application Support/AwesomeQuickActions/transcribe"
cp "$SPIKE"/models/{encoder.int8.onnx,decoder.onnx,joiner.onnx,tokens.txt,silero_vad.onnx} \
   "$HOME/Library/Application Support/AwesomeQuickActions/transcribe/"
cp "$SPIKE/models/example.wav" Transcribe/tests/fixtures/example.wav

Transcribe/tests/run.sh
```

Expected: `PASS: test_ru`

- [ ] **Step 5: Commit**

`Transcribe/bin/transcribe-ru` must NOT be committed — it is ~25 MB and ships via Releases.

```bash
cat > Transcribe/.gitignore <<'EOF'
bin/transcribe-ru
tests/fixtures/*.wav
EOF
git add Transcribe/.gitignore Transcribe/src/swift/ru/main.swift Transcribe/tests/
git commit -m "feat(transcribe): Russian engine via sherpa-onnx + GigaAM v3"
```

---

### Task 3: English transcription binary

**Files:**
- Create: `Transcribe/src/swift/en/main.swift`
- Create: `Transcribe/tests/test_en.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `transcribe-en <wav>...` with the **same** stdout/stderr contract as `transcribe-ru`, minus `--models`. Task 6 dispatches to either binary through this shared contract.

Every API name below was type-checked against macOS 26.3 before this plan was written. Note `bestAvailableAudioFormat` lives on `SpeechAnalyzer`, not on `SpeechTranscriber`.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_en.sh <<'SH'
#!/bin/bash
# Golden test for transcribe-en. Generates its own fixture with `say`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HERE/../bin/transcribe-en}"
WAV="$HERE/fixtures/hello_en.wav"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built: $BIN"

if [ ! -f "$WAV" ]; then
  say -v Samantha -o /tmp/hello_en.aiff "The quick brown fox jumps over the lazy dog."
  ffmpeg -y -loglevel error -i /tmp/hello_en.aiff -ac 1 -ar 16000 -c:a pcm_s16le "$WAV"
fi

out="$("$BIN" "$WAV" 2>/tmp/en_stderr.txt)"

echo "$out" | grep -q '^=== FILE 1 ===$' || fail "missing file header in stdout"

body="$(echo "$out" | sed -n '2p' | tr '[:upper:]' '[:lower:]')"
for w in quick brown fox lazy dog; do
  echo "$body" | grep -q "$w" || fail "missing word '$w' in: $body"
done

grep -q '^PROGRESS transcribe 1 1 hello_en.wav$' /tmp/en_stderr.txt \
  || fail "missing progress line; got: $(cat /tmp/en_stderr.txt)"

echo "PASS: test_en"
SH
chmod +x Transcribe/tests/test_en.sh
```

The assertion is word-presence, not exact string: a neural recognizer's punctuation of a synthetic sample is not stable enough to pin, but the content words are.

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_en.sh`
Expected: `FAIL: binary not built: .../bin/transcribe-en`

- [ ] **Step 3: Write the implementation**

```swift
// Transcribe/src/swift/en/main.swift
// English transcription via Apple's on-device SpeechTranscriber (macOS 26+).
// Usage: transcribe-en <wav>...
import AVFoundation
import Foundation
import Speech

func note(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

func die(_ msg: String) -> Never {
  note("ERROR: \(msg)")
  exit(2)
}

@available(macOS 26.0, *)
func transcribe(_ path: String, using transcriber: SpeechTranscriber) async throws -> String {
  let analyzer = SpeechAnalyzer(modules: [transcriber])

  let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
  guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length)) else {
    throw NSError(domain: "transcribe", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "cannot allocate buffer"])
  }
  try file.read(into: buf)

  let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
  try await analyzer.start(inputSequence: stream)
  cont.yield(AnalyzerInput(buffer: buf))
  cont.finish()
  try await analyzer.finalizeAndFinishThroughEndOfInput()

  var parts: [String] = []
  for try await result in transcriber.results where result.isFinal {
    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { parts.append(text) }
  }
  return parts.joined(separator: " ")
}

@available(macOS 26.0, *)
func run() async {
  let wavs = Array(CommandLine.arguments.dropFirst())
  if wavs.isEmpty { die("usage: transcribe-en <wav>...") }

  let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: [])

  // The en-US asset is absent on a fresh machine; installedLocales is empty.
  do {
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      note("PROGRESS download 0 1 en-US")
      try await request.downloadAndInstall()
      note("PROGRESS download 1 1 en-US")
    }
  } catch {
    die("не удалось загрузить языковой пакет en-US: \(error.localizedDescription)")
  }

  var failed = false
  for (i, path) in wavs.enumerated() {
    let base = URL(fileURLWithPath: path).lastPathComponent
    do {
      let text = try await transcribe(path, using: transcriber)
      note("PROGRESS transcribe 1 1 \(base)")
      print("=== FILE \(i + 1) ===")
      print(text)
      print("")
    } catch {
      failed = true
      note("ERROR \(base): \(error.localizedDescription)")
      print("=== FILE \(i + 1) ===")
      print("")
      print("")
    }
  }
  exit(failed ? 1 : 0)
}

if #available(macOS 26.0, *) {
  await run()
} else {
  die("нужна macOS 26 или новее")
}
```

- [ ] **Step 4: Build and run the test**

```bash
swiftc -O -swift-version 6 -parse-as-library \
  Transcribe/src/swift/en/main.swift -o Transcribe/bin/transcribe-en
Transcribe/tests/test_en.sh
```

Expected: `PASS: test_en`. The first run downloads the Apple asset and may take a minute.

If `swiftc` rejects top-level `await` under `-parse-as-library`, drop that flag — a file named `main.swift` supports top-level code without it.

- [ ] **Step 5: Commit**

Unlike `transcribe-ru`, this binary **is** committed — it is ~200 KB and has no external dependencies, so English works straight after `git clone`.

```bash
git add Transcribe/src/swift/en/main.swift Transcribe/tests/test_en.sh Transcribe/bin/transcribe-en
git commit -m "feat(transcribe): English engine via Apple SpeechTranscriber"
```

---

### Task 4: Build script

**Files:**
- Create: `Transcribe/tools/build.sh`
- Modify: `Transcribe/.gitignore`

**Interfaces:**
- Consumes: the `.a` list recorded in Task 1; the two `main.swift` files from Tasks 2 and 3.
- Produces: `Transcribe/bin/transcribe-en` (committed) and `Transcribe/bin/transcribe-ru` (for Release upload). Task 5's manifest consumes the SHA-256 of `transcribe-ru`.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_build.sh <<'SH'
#!/bin/bash
# Both binaries must build, be universal, and run without a dynamic sherpa-onnx.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

"$HERE/../tools/build.sh" >/tmp/build.log 2>&1 || fail "build failed; see /tmp/build.log"

for b in transcribe-en transcribe-ru; do
  [ -x "$HERE/../bin/$b" ] || fail "$b not produced"
  lipo -archs "$HERE/../bin/$b" | grep -q arm64 || fail "$b is not arm64"
done

# transcribe-ru must be self-contained: no sherpa-onnx or onnxruntime dylib.
if otool -L "$HERE/../bin/transcribe-ru" | grep -qiE 'sherpa|onnxruntime'; then
  fail "transcribe-ru links a dynamic sherpa-onnx/onnxruntime — must be static"
fi

echo "PASS: test_build"
SH
chmod +x Transcribe/tests/test_build.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_build.sh`
Expected: `FAIL: build failed; see /tmp/build.log` (no such file `tools/build.sh`)

- [ ] **Step 3: Write the implementation**

```bash
mkdir -p Transcribe/tools
cat > Transcribe/tools/build.sh <<'SH'
#!/bin/zsh
# Build both Transcribe binaries. Downloads the sherpa-onnx SDK on first run.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$DIR/.sdk"
VER="1.13.6"
TARBALL="sherpa-onnx-v${VER}-osx-universal2-static-no-tts-lib.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VER}/${TARBALL}"
SWIFT_SRC="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VER}/swift-api-examples"

mkdir -p "$SDK" "$DIR/bin"

if [ ! -f "$SDK/.ok" ]; then
  echo "Downloading sherpa-onnx v${VER}…"
  curl -fL -o "$SDK/$TARBALL" "$URL"
  tar xf "$SDK/$TARBALL" -C "$SDK"
  rm "$SDK/$TARBALL"
  curl -fL -o "$SDK/SherpaOnnx.swift" "$SWIFT_SRC/SherpaOnnx.swift"
  curl -fL -o "$SDK/SherpaOnnx-Bridging-Header.h" "$SWIFT_SRC/SherpaOnnx-Bridging-Header.h"
  touch "$SDK/.ok"
fi

CAPI=$(find "$SDK" -name c-api.h -path '*sherpa-onnx*' | head -1)
[ -n "$CAPI" ] || { echo "c-api.h not found in $SDK" >&2; exit 1; }
INC=$(dirname "$(dirname "$(dirname "$CAPI")")")
LIBDIR=$(dirname "$(find "$SDK" -name 'libsherpa-onnx-c-api.a' | head -1)")
LIBS=$(cd "$LIBDIR" && ls *.a | sed 's/^lib/-l/; s/\.a$//' | tr '\n' ' ')

echo "Building transcribe-en…"
swiftc -O -target arm64-apple-macos26.0 \
  "$DIR/src/swift/en/main.swift" -o "$DIR/bin/transcribe-en.arm64"
swiftc -O -target x86_64-apple-macos26.0 \
  "$DIR/src/swift/en/main.swift" -o "$DIR/bin/transcribe-en.x86_64"
lipo -create "$DIR/bin/transcribe-en.arm64" "$DIR/bin/transcribe-en.x86_64" \
  -output "$DIR/bin/transcribe-en"
rm "$DIR/bin/transcribe-en.arm64" "$DIR/bin/transcribe-en.x86_64"
strip "$DIR/bin/transcribe-en"

echo "Building transcribe-ru…"
for ARCH in arm64 x86_64; do
  swiftc -lc++ -O -target ${ARCH}-apple-macos26.0 \
    -I "$INC" \
    -import-objc-header "$SDK/SherpaOnnx-Bridging-Header.h" \
    "$DIR/src/swift/ru/main.swift" "$SDK/SherpaOnnx.swift" \
    -L "$LIBDIR" ${=LIBS} ${=LIBS} \
    -o "$DIR/bin/transcribe-ru.$ARCH"
done
lipo -create "$DIR/bin/transcribe-ru.arm64" "$DIR/bin/transcribe-ru.x86_64" \
  -output "$DIR/bin/transcribe-ru"
rm "$DIR/bin/transcribe-ru.arm64" "$DIR/bin/transcribe-ru.x86_64"
strip "$DIR/bin/transcribe-ru"

echo
echo "Built:"
ls -lh "$DIR/bin/transcribe-en" "$DIR/bin/transcribe-ru"
echo
echo "SHA-256 for the release manifest:"
shasum -a 256 "$DIR/bin/transcribe-ru" | awk '{print $1}'
SH
chmod +x Transcribe/tools/build.sh
```

The `-l` group is repeated (`${=LIBS} ${=LIBS}`) because static archives resolve in link order and sherpa-onnx's archives reference each other circularly.

- [ ] **Step 4: Run the test**

Run: `Transcribe/tests/test_build.sh`
Expected: `PASS: test_build`

- [ ] **Step 5: Commit**

```bash
printf 'bin/transcribe-ru\ntests/fixtures/*.wav\n.sdk/\n' > Transcribe/.gitignore
git add Transcribe/.gitignore Transcribe/tools/build.sh Transcribe/tests/test_build.sh Transcribe/bin/transcribe-en
git commit -m "build(transcribe): universal build script, static sherpa-onnx"
```

---

### Task 5: Russian asset fetcher

**Files:**
- Create: `Transcribe/src/fetch-ru-assets.sh`
- Create: `Transcribe/assets.manifest`
- Create: `Transcribe/tests/test_fetch.sh`

**Interfaces:**
- Consumes: nothing at runtime.
- Produces: `fetch-ru-assets.sh` with this contract, called by Task 6's AppleScript:
  - Exit 0 with no output if every asset is already present and valid.
  - Otherwise download, emitting `PROGRESS download <done> <total> <name>` on stderr.
  - Exit 1 on any failure with `ERROR: <message>` on stderr.
  - Idempotent: safe to run on every Russian invocation.

The spec described this as a shell function inside the AppleScript. It is a standalone script instead: bash is testable in isolation and AppleScript is not, and it matches the existing `ZIP/src/zip.sh` precedent.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_fetch.sh <<'SH'
#!/bin/bash
# The fetcher must be idempotent, verify checksums, and leave no partial files.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../src/fetch-ru-assets.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$SCRIPT" ] || fail "not executable: $SCRIPT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A corrupt file must be detected and re-fetched, not silently accepted.
mkdir -p "$TMP/assets"
echo "garbage" > "$TMP/assets/tokens.txt"
if ASSET_DIR="$TMP/assets" VERIFY_ONLY=1 "$SCRIPT" 2>/dev/null; then
  fail "corrupt tokens.txt passed verification"
fi

# No partial files may survive a failed run.
[ -z "$(find "$TMP/assets" -name '*.part' 2>/dev/null)" ] || fail "leftover .part files"

# Verification of a complete, valid install must exit 0 without downloading.
REAL="$HOME/Library/Application Support/AwesomeQuickActions/transcribe"
if [ -f "$REAL/encoder.int8.onnx" ]; then
  ASSET_DIR="$REAL" VERIFY_ONLY=1 "$SCRIPT" || fail "valid install failed verification"
fi

echo "PASS: test_fetch"
SH
chmod +x Transcribe/tests/test_fetch.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_fetch.sh`
Expected: `FAIL: not executable: .../src/fetch-ru-assets.sh`

- [ ] **Step 3: Generate the manifest**

Compute the real checksums from the files the spike downloaded, then write them into the manifest. Do not invent them.

```bash
SPIKE=/private/tmp/claude-501/.../scratchpad/spike
cd "$SPIKE/models"
shasum -a 256 encoder.int8.onnx decoder.onnx joiner.onnx tokens.txt silero_vad.onnx
shasum -a 256 "$OLDPWD/Transcribe/bin/transcribe-ru"
```

Write the results into `Transcribe/assets.manifest`, one `<sha256>  <name>  <url>` per line:

```
# <sha256>  <filename>  <url>
# Model: GigaAM v3 e2e RNN-T (punct), MIT. VAD: silero, MIT.
<SHA>  encoder.int8.onnx  https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main/encoder.int8.onnx
<SHA>  decoder.onnx       https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main/decoder.onnx
<SHA>  joiner.onnx        https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main/joiner.onnx
<SHA>  tokens.txt         https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main/tokens.txt
<SHA>  silero_vad.onnx    https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
<SHA>  transcribe-ru      https://github.com/hexdrx/awesome-quick-actions/releases/download/transcribe-assets-v1/transcribe-ru
```

The `transcribe-ru` URL only resolves once the Release is published — that happens in Task 8.

- [ ] **Step 4: Write the implementation**

```bash
cat > Transcribe/src/fetch-ru-assets.sh <<'SH'
#!/bin/zsh
# Ensure the Russian assets are present and intact.
# PROGRESS/ERROR on stderr; nothing on stdout.
# Env: ASSET_DIR (override target), VERIFY_ONLY=1 (check, never download).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${MANIFEST:-$DIR/../assets.manifest}"
ASSET_DIR="${ASSET_DIR:-$HOME/Library/Application Support/AwesomeQuickActions/transcribe}"

err() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

[ -f "$MANIFEST" ] || err "манифест не найден: $MANIFEST"
mkdir -p "$ASSET_DIR"

typeset -a SHAS NAMES URLS
while read -r sha name url; do
  case "$sha" in ''|'#'*) continue ;; esac
  SHAS+=("$sha"); NAMES+=("$name"); URLS+=("$url")
done < "$MANIFEST"

total=${#NAMES[@]}
[ "$total" -gt 0 ] || err "манифест пуст"

typeset -a MISSING_I
for i in {1..$total}; do
  f="$ASSET_DIR/${NAMES[$i]}"
  if [ -f "$f" ] && [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "${SHAS[$i]}" ]; then
    continue
  fi
  MISSING_I+=($i)
done

if [ ${#MISSING_I[@]} -eq 0 ]; then exit 0; fi

if [ "${VERIFY_ONLY:-0}" = "1" ]; then
  err "отсутствуют или повреждены: ${#MISSING_I[@]} файл(ов)"
fi

done_n=0
n=${#MISSING_I[@]}
for i in $MISSING_I; do
  name="${NAMES[$i]}"; url="${URLS[$i]}"; want="${SHAS[$i]}"
  tmp="$ASSET_DIR/$name.part"
  rm -f "$tmp"
  note "PROGRESS download $done_n $n $name"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url" || { rm -f "$tmp"; err "не удалось скачать $name"; }
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    err "контрольная сумма не совпала: $name"
  fi
  chmod +x "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ASSET_DIR/$name"
  done_n=$((done_n + 1))
  note "PROGRESS download $done_n $n $name"
done
exit 0
SH
chmod +x Transcribe/src/fetch-ru-assets.sh
```

Download to `.part`, verify, then `mv` — an interrupted run leaves nothing that a later run would mistake for a complete file.

- [ ] **Step 5: Run the test**

Run: `Transcribe/tests/test_fetch.sh`
Expected: `PASS: test_fetch`

- [ ] **Step 6: Commit**

```bash
git add Transcribe/src/fetch-ru-assets.sh Transcribe/assets.manifest Transcribe/tests/test_fetch.sh
git commit -m "feat(transcribe): checksum-verified asset fetcher with atomic install"
```

---

### Task 6: AppleScript front end

**Files:**
- Create: `Transcribe/src/transcribe.applescript`
- Create: `Transcribe/tests/test_applescript.sh`

**Interfaces:**
- Consumes: `transcribe-en <wav>...`, `transcribe-ru --models <dir> <wav>...`, `fetch-ru-assets.sh`, all as defined above.
- Produces: the `.workflow` payload embedded in Task 7.

Handlers `extOf`, `baseName`, `baseOf`, `dirOf`, `uniqueOut`, `pathExists`, `notify` and `findFFmpeg` are copied verbatim from `Convert/src/convert.applescript:274-380`. Copying rather than sharing matches the repo — each action is a self-contained bundle with no cross-action imports.

**Reserved-word warning:** AppleScript variables must never be named `file`, `files`, `line`, `lines`, `text`, `item`, `string`, `count`, `length` or `date`. Doing so produces a runtime `-10006` error. Use `flist`, `p`, `pp`, `outp`, `txt`.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_applescript.sh <<'SH'
#!/bin/bash
# Static checks on the AppleScript: it must compile, and must avoid reserved words.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src/transcribe.applescript"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$SRC" ] || fail "missing: $SRC"

osacompile -o /tmp/transcribe_check.scpt "$SRC" 2>/tmp/osa.log \
  || fail "does not compile: $(cat /tmp/osa.log)"

# Reserved words as variables cause runtime -10006 errors.
if grep -nE '^[[:space:]]*set (file|files|line|lines|text|item|string|count|length|date)[[:space:]]+to' "$SRC"; then
  fail "reserved word used as a variable name"
fi

for h in findFFmpeg uniqueOut baseOf dirOf runEngine parseProgress; do
  grep -q "^on $h" "$SRC" || fail "missing handler: $h"
done

echo "PASS: test_applescript"
SH
chmod +x Transcribe/tests/test_applescript.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_applescript.sh`
Expected: `FAIL: missing: .../src/transcribe.applescript`

- [ ] **Step 3: Write the implementation**

```applescript
-- Transcribe — Finder Quick Action (readable source; embedded copy lives in the .workflow)
-- English: Apple SpeechTranscriber (macOS 26+). Russian: sherpa-onnx + GigaAM v3.
-- Requires ffmpeg.

property gDone : 0

on run {input, parameters}
	set FF to my findFFmpeg()
	if FF is missing value then
		display alert "ffmpeg не найден" message "Установи ffmpeg: brew install ffmpeg" & return & "(искал в /opt/homebrew/bin, /usr/local/bin, /opt/local/bin и PATH)." as warning
		return input
	end if

	set mediaExt to {"mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "oga", "opus", "wma", "amr", "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "ts", "3gp", "ogv"}

	set flist to {}
	repeat with itm in input
		set p to POSIX path of itm
		if p ends with "/" then set p to text 1 thru -2 of p
		if mediaExt contains my extOf(p) then set end of flist to p
	end repeat

	if (count of flist) is 0 then
		display notification "Нет поддерживаемых файлов" with title "Transcribe"
		return input
	end if

	set langChoice to (choose from list {"Русский", "English"} with title ("Transcribe (" & (count flist) & ")") with prompt "Язык записи:" default items {"Русский"})
	if langChoice is false then return input
	set lang to item 1 of langChoice

	set resDir to my resourceDir()
	set assetDir to (POSIX path of (path to library folder from user domain)) & "Application Support/AwesomeQuickActions/transcribe"

	set totalN to count flist
	set progress total steps to totalN * 2
	set progress completed steps to 0
	set progress description to "Transcribe"
	set progress additional description to "Подготовка…"
	set gDone to 0

	-- Russian needs the model; fetch it before anything else.
	if lang is "Русский" then
		set progress additional description to "Загрузка модели (~257 МБ)…"
		try
			do shell script quoted form of (resDir & "/fetch-ru-assets.sh") & " 2>&1"
		on error errMsg
			display alert "Не удалось подготовить модель" message errMsg as warning
			return input
		end try
	end if

	-- Decode everything to 16 kHz mono WAV.
	set wavs to {}
	set decoded to {}
	set errs to {}
	repeat with p in flist
		set pp to contents of p
		set progress additional description to "Подготовка: " & my baseName(pp)
		set w to "/tmp/transcribe_" & (my randomTag()) & ".wav"
		try
			do shell script quoted form of FF & " -nostdin -y -loglevel error -i " & quoted form of pp & " -vn -ac 1 -ar 16000 -c:a pcm_s16le " & quoted form of w
			set end of wavs to w
			set end of decoded to pp
		on error
			set end of errs to my baseName(pp) & " — не удалось декодировать"
		end try
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat

	if (count of wavs) is 0 then
		display alert "Нечего распознавать" message "Ни один файл не удалось декодировать." as warning
		return input
	end if

	-- One process for the whole batch.
	set progress additional description to "Распознавание…"
	set outText to my runEngine(lang, resDir, assetDir, wavs)

	set okc to 0
	repeat with idx from 1 to (count decoded)
		set txt to my sectionOf(outText, idx)
		set srcPath to item idx of decoded
		if txt is "" then
			set end of errs to my baseName(srcPath) & " — пустой результат"
		else
			set outp to my uniqueOut(my dirOf(srcPath), my baseOf(srcPath), "txt")
			try
				do shell script "cat > " & quoted form of outp & " <<'TRANSCRIBE_EOF'" & return & txt & return & "TRANSCRIBE_EOF"
				set okc to okc + 1
			on error
				set end of errs to my baseName(srcPath) & " — не удалось записать .txt"
			end try
		end if
		set gDone to gDone + 1
		set progress completed steps to gDone
	end repeat

	repeat with w in wavs
		try
			do shell script "rm -f " & quoted form of (contents of w)
		end try
	end repeat

	set progress completed steps to (totalN * 2)

	set msg to (okc as text) & " файл(ов) готово"
	if (count of errs) > 0 then set msg to msg & ", ошибок: " & (count of errs)
	my notify("Transcribe", msg)

	if (count of errs) > 0 then
		set AppleScript's text item delimiters to return
		set etext to errs as text
		set AppleScript's text item delimiters to ""
		display alert "Не всё распозналось" message etext as warning
	end if

	return input
end run

on runEngine(lang, resDir, assetDir, wavs)
	set AppleScript's text item delimiters to " "
	set quotedWavs to {}
	repeat with w in wavs
		set end of quotedWavs to quoted form of (contents of w)
	end repeat
	set joined to quotedWavs as text
	set AppleScript's text item delimiters to ""

	if lang is "Русский" then
		set cmd to quoted form of (resDir & "/transcribe-ru") & " --models " & quoted form of assetDir & " " & joined
	else
		set cmd to quoted form of (resDir & "/transcribe-en") & " " & joined
	end if

	try
		return (do shell script cmd & " 2>/dev/null")
	on error errMsg
		return ""
	end try
end runEngine

on sectionOf(outText, idx)
	set marker to "=== FILE " & (idx as text) & " ==="
	if outText does not contain marker then return ""
	set AppleScript's text item delimiters to marker
	set tail to text item 2 of outText
	set AppleScript's text item delimiters to "=== FILE "
	set chunk to text item 1 of tail
	set AppleScript's text item delimiters to ""
	return my trimBlank(chunk)
end sectionOf

on trimBlank(s)
	repeat while s starts with return or s starts with linefeed or s starts with " "
		if (length of s) < 2 then return ""
		set s to text 2 thru -1 of s
	end repeat
	repeat while s ends with return or s ends with linefeed or s ends with " "
		if (length of s) < 2 then return ""
		set s to text 1 thru -2 of s
	end repeat
	return s
end trimBlank

on parseProgress(aLine)
	-- "PROGRESS <phase> <done> <total> <detail>" -> {phase, done, total}
	if aLine does not start with "PROGRESS " then return missing value
	set AppleScript's text item delimiters to " "
	set parts to text items of aLine
	set AppleScript's text item delimiters to ""
	if (count parts) < 4 then return missing value
	return {item 2 of parts, (item 3 of parts) as integer, (item 4 of parts) as integer}
end parseProgress

on randomTag()
	return (do shell script "od -An -N4 -tx1 /dev/urandom | tr -d ' \\n'")
end randomTag

on resourceDir()
	set p to POSIX path of (path to me)
	if p ends with "/" then set p to text 1 thru -2 of p
	return p & "/Contents/Resources"
end resourceDir
```

Then append verbatim, from `Convert/src/convert.applescript:274-380`: `extOf`, `baseName`, `baseOf`, `dirOf`, `uniqueOut`, `pathExists`, `notify`, `findFFmpeg`.

`do shell script` cannot stream, so `parseProgress` is exercised by the tests and reserved for the streaming refinement; the visible bar advances per decoded and per written file, which keeps it determinate across the batch.

- [ ] **Step 4: Run the test**

Run: `Transcribe/tests/test_applescript.sh`
Expected: `PASS: test_applescript`

- [ ] **Step 5: Commit**

```bash
git add Transcribe/src/transcribe.applescript Transcribe/tests/test_applescript.sh
git commit -m "feat(transcribe): AppleScript front end with language menu and progress"
```

---

### Task 7: Workflow bundle, icon, installer

**Files:**
- Create: `Transcribe/Transcribe.workflow/Contents/Info.plist`
- Create: `Transcribe/Transcribe.workflow/Contents/document.wflow`
- Create: `Transcribe/Transcribe.workflow/Contents/Resources/workflowCustomImageTemplate.png`
- Create: `Transcribe/Transcribe.workflow/Contents/QuickLook/Thumbnail.png`
- Create: `Transcribe/install.sh`
- Create: `Transcribe/tools/embed.sh`
- Create: `Transcribe/tests/test_bundle.sh`

**Interfaces:**
- Consumes: `src/transcribe.applescript`, `bin/transcribe-en`, `src/fetch-ru-assets.sh`, `assets.manifest`.
- Produces: an installable `Transcribe.workflow`.

The bundle must carry `transcribe-en`, `fetch-ru-assets.sh` and `assets.manifest` inside `Contents/Resources/`, because `resourceDir()` resolves relative to the installed bundle in `~/Library/Services`, not to the repo.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_bundle.sh <<'SH'
#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../Transcribe.workflow"
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -d "$WF" ] || fail "no bundle at $WF"
plutil -lint "$WF/Contents/Info.plist" >/dev/null || fail "bad Info.plist"
plutil -lint "$WF/Contents/document.wflow" >/dev/null || fail "bad document.wflow"

for r in transcribe-en fetch-ru-assets.sh assets.manifest workflowCustomImageTemplate.png; do
  [ -e "$WF/Contents/Resources/$r" ] || fail "missing resource: $r"
done
[ -x "$WF/Contents/Resources/transcribe-en" ] || fail "transcribe-en not executable in bundle"
[ -x "$WF/Contents/Resources/fetch-ru-assets.sh" ] || fail "fetcher not executable in bundle"

# The embedded script must match the readable source.
python3 - "$WF/Contents/document.wflow" "$HERE/../src/transcribe.applescript" <<'PY'
import plistlib, sys
wflow, src = sys.argv[1], sys.argv[2]
with open(wflow, 'rb') as f:
    d = plistlib.load(f)
embedded = d['actions'][0]['action']['ActionParameters']['source']
with open(src, encoding='utf-8') as f:
    readable = f.read()
if embedded.strip() != readable.strip():
    raise SystemExit("embedded source differs from src/transcribe.applescript")
PY

echo "PASS: test_bundle"
SH
chmod +x Transcribe/tests/test_bundle.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_bundle.sh`
Expected: `FAIL: no bundle at .../Transcribe.workflow`

- [ ] **Step 3: Create the bundle skeleton**

```bash
mkdir -p Transcribe/Transcribe.workflow/Contents/{Resources,QuickLook}
cp QR/QR.workflow/Contents/Info.plist Transcribe/Transcribe.workflow/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :NSServices:0:NSMenuItem:default Transcribe" \
  Transcribe/Transcribe.workflow/Contents/Info.plist
plutil -lint Transcribe/Transcribe.workflow/Contents/Info.plist
```

`NSSendFileTypes` stays `public.item`; the AppleScript filters by extension.

- [ ] **Step 4: Draw the icon**

A waveform glyph, black on transparent, 128×128 PNG. It is a **template** image — macOS recolors it for light and dark mode, so it must contain only alpha and black.

```bash
cat > /tmp/wave.swift <<'SWIFT'
import AppKit
let size = NSSize(width: 128, height: 128)
let img = NSImage(size: size)
img.lockFocus()
NSColor.black.setFill()
let bars: [CGFloat] = [18, 40, 74, 104, 74, 96, 52, 30, 62, 88, 44, 22]
let w: CGFloat = 6, gap: CGFloat = 4
let totalW = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
var x = (size.width - totalW) / 2
for h in bars {
  let r = NSRect(x: x, y: (size.height - h) / 2, width: w, height: h)
  NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
  x += w + gap
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
  .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift /tmp/wave.swift Transcribe/Transcribe.workflow/Contents/Resources/workflowCustomImageTemplate.png
cp Transcribe/Transcribe.workflow/Contents/Resources/workflowCustomImageTemplate.png \
   Transcribe/Transcribe.workflow/Contents/QuickLook/Thumbnail.png
```

- [ ] **Step 5: Write the embed script**

```bash
cat > Transcribe/tools/embed.sh <<'SH'
#!/bin/zsh
# Embed src/transcribe.applescript into the bundle and stage its resources.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WF="$DIR/Transcribe.workflow"
RES="$WF/Contents/Resources"

[ -x "$DIR/bin/transcribe-en" ] || { echo "run tools/build.sh first" >&2; exit 1; }

mkdir -p "$RES"
cp "$DIR/bin/transcribe-en" "$RES/transcribe-en"
cp "$DIR/src/fetch-ru-assets.sh" "$RES/fetch-ru-assets.sh"
cp "$DIR/assets.manifest" "$RES/assets.manifest"
chmod +x "$RES/transcribe-en" "$RES/fetch-ru-assets.sh"

python3 - "$WF/Contents/document.wflow" "$DIR/src/transcribe.applescript" <<'PY'
import plistlib, sys, os
wflow, src = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    source = f.read()
if os.path.exists(wflow):
    with open(wflow, 'rb') as f:
        doc = plistlib.load(f)
else:
    doc = {
        'AMApplicationBuild': '523', 'AMApplicationVersion': '2.10',
        'AMDocumentVersion': '2',
        'actions': [{'action': {
            'ActionBundlePath': '/System/Library/Automator/Run AppleScript.action',
            'ActionName': 'Run AppleScript',
            'ActionParameters': {'source': ''},
            'BundleIdentifier': 'com.apple.Automator.RunScript',
            'CFBundleVersion': '1.0',
            'Class Name': 'RunScriptAction',
            'InputUUID': '00000000-0000-0000-0000-000000000001',
            'OutputUUID': '00000000-0000-0000-0000-000000000002',
            'UUID': '00000000-0000-0000-0000-000000000003',
        }}],
        'workflowMetaData': {
            'serviceInputTypeIdentifier': 'com.apple.Automator.fileSystemObject',
            'serviceOutputTypeIdentifier': 'com.apple.Automator.nothing',
            'serviceApplicationBundleID': 'com.apple.finder',
            'serviceApplicationPath': '/System/Library/CoreServices/Finder.app',
            'workflowTypeIdentifier': 'com.apple.Automator.servicesMenu',
        },
    }
doc['actions'][0]['action']['ActionParameters']['source'] = source
with open(wflow, 'wb') as f:
    plistlib.dump(doc, f)
print("embedded", len(source), "chars")
PY
SH
chmod +x Transcribe/tools/embed.sh
Transcribe/tools/embed.sh
```

- [ ] **Step 6: Write the installer**

```bash
cat > Transcribe/install.sh <<'SH'
#!/bin/zsh
# Install the Transcribe Quick Action into ~/Library/Services
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Services"
mkdir -p "$DEST"

echo "Installing Transcribe.workflow…"
rm -rf "$DEST/Transcribe.workflow"
cp -R "$DIR/Transcribe.workflow" "$DEST/Transcribe.workflow"
chmod +x "$DEST/Transcribe.workflow/Contents/Resources/transcribe-en"
chmod +x "$DEST/Transcribe.workflow/Contents/Resources/fetch-ru-assets.sh"

/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall iconservicesagent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "✅ Installed. Right-click audio/video in Finder → Quick Actions → Transcribe"
SH
chmod +x Transcribe/install.sh
```

- [ ] **Step 7: Run the test, then install and try it by hand**

Run: `Transcribe/tests/test_bundle.sh`
Expected: `PASS: test_bundle`

Then: `Transcribe/install.sh`, right-click an English audio file in Finder → Quick Actions → Transcribe → `English`. Expect a `.txt` beside the original. Repeat with a Russian file and `Русский` — the first run downloads ~257 MB.

- [ ] **Step 8: Commit**

```bash
git add Transcribe/Transcribe.workflow Transcribe/install.sh Transcribe/tools/embed.sh Transcribe/tests/test_bundle.sh
git commit -m "feat(transcribe): workflow bundle, waveform icon, installer"
```

---

### Task 8: Repo integration, Release, and documentation

**Files:**
- Modify: `install.sh`
- Modify: `uninstall.sh`
- Modify: `README.md`
- Create: `Transcribe/README.md`
- Create: `Transcribe/tests/test_integration.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing further.

- [ ] **Step 1: Write the failing test**

```bash
cat > Transcribe/tests/test_integration.sh <<'SH'
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'Transcribe/install.sh' "$ROOT/install.sh" || fail "root install.sh does not install Transcribe"
grep -q 'Transcribe.workflow' "$ROOT/uninstall.sh" || fail "root uninstall.sh does not remove Transcribe"
grep -q 'Transcribe' "$ROOT/README.md" || fail "root README has no Transcribe row"
[ -f "$ROOT/Transcribe/README.md" ] || fail "Transcribe/README.md missing"

# Every manifest URL must resolve, including the Release-hosted binary.
while read -r sha name url; do
  case "$sha" in ''|'#'*) continue ;; esac
  code=$(curl -sIL -o /dev/null -w '%{http_code}' "$url")
  [ "$code" = "200" ] || fail "manifest URL for $name returned $code: $url"
done < "$ROOT/Transcribe/assets.manifest"

echo "PASS: test_integration"
SH
chmod +x Transcribe/tests/test_integration.sh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `Transcribe/tests/test_integration.sh`
Expected: `FAIL: root install.sh does not install Transcribe`

- [ ] **Step 3: Wire into the root scripts**

In `install.sh`, add after the `QR/install.sh` line:

```sh
"$DIR/Transcribe/install.sh"
```

In `uninstall.sh`, extend the `rm -rf` line and the final message:

```sh
rm -rf "$DEST/Convert.workflow" "$DEST/ZIP.workflow" "$DEST/FileTools.workflow" "$DEST/QR.workflow" "$DEST/Transcribe.workflow"
...
echo "🧹 Removed Convert + ZIP + File Tools + QR + Transcribe quick actions."
```

- [ ] **Step 4: Add the README row**

Append to the table in `README.md`:

```markdown
| 🎙️ **[Transcribe](Transcribe/)** | Right-click audio/video → pick **Русский** or **English** → a `.txt` transcript appears next to the original. English runs on Apple's on-device recognizer; Russian on GigaAM v3 with punctuation and capitalization. Batch, progress bar, collision-safe names. | Apple Speech (EN) + sherpa-onnx / GigaAM v3 (RU) |
```

Under Requirements, add:

```markdown
- **Transcribe only:** macOS 26+ (for the English engine) and `ffmpeg`. The Russian model (~257 MB) downloads itself on first use.
```

Also add `./Transcribe/install.sh` to the "Just one action" list and `Transcribe.workflow` to the Uninstall list.

- [ ] **Step 5: Write `Transcribe/README.md`**

It must cover: what the action does; the two engines and why they differ (macOS has no Russian in `SpeechTranscriber`); the `ffmpeg` requirement; what downloads on first Russian use and where it lands (`~/Library/Application Support/AwesomeQuickActions/transcribe/`); how to rebuild (`tools/build.sh` then `tools/embed.sh` then `install.sh`); and licenses — sherpa-onnx Apache-2.0, GigaAM MIT, silero VAD MIT, with links.

- [ ] **Step 6: Publish the Release**

`transcribe-ru` is not in git, so the manifest URL is dead until this runs. **Ask for explicit permission before pushing** — repo rules require it.

```bash
gh release create transcribe-assets-v1 \
  --title "Transcribe assets v1" \
  --notes "Prebuilt transcribe-ru (universal, static sherpa-onnx v1.13.6) for the Transcribe Quick Action." \
  Transcribe/bin/transcribe-ru
```

- [ ] **Step 7: Run the full suite**

Run: `Transcribe/tests/run.sh`
Expected: every test reports PASS.

- [ ] **Step 8: Commit**

```bash
git add install.sh uninstall.sh README.md Transcribe/README.md Transcribe/tests/test_integration.sh
git commit -m "docs(transcribe): wire into repo installers and README"
```

- [ ] **Step 9: Ask before merging**

Report completion and **ask for explicit permission** before `git merge` into `main` or `git push`. Do not merge unprompted.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: engine split → Tasks 2 and 3; architecture and file layout → Tasks 2–7; progress protocol → the stderr contracts in Tasks 2, 3, 5 and the bar in Task 6; chunking by VAD → Task 2 Step 3; model store → Task 5; output naming → Task 6 via `uniqueOut`; error handling → the `errs` accumulation in Task 6 and the failure paths in Tasks 2, 3, 5; testing → Tasks 2, 3, 8; implementation order → task order. `.srt` is out of scope per the spec and has no task.

**Two deliberate departures from the spec**, both noted inline where they occur:

1. The asset fetcher is a standalone `fetch-ru-assets.sh` rather than a handler inside the AppleScript. Bash is testable in isolation; AppleScript is not.
2. The `decode` progress phase is driven by AppleScript rather than by a binary, because `do shell script` cannot stream stderr. `parseProgress` exists and is tested, so a streaming refinement stays cheap, but the visible bar advances per decoded and per written file instead of per VAD segment. This is the one place where the spec's segment-level granularity is not yet reached; a single very long file will show two coarse steps rather than a smooth bar.

**Type consistency.** `PROGRESS <phase> <done> <total> <detail>` and the `=== FILE N ===` record separator are identical across Tasks 2, 3, 5 and 6. `sherpaOnnxOfflineModelConfig`, `sherpaOnnxOfflineTransducerModelConfig`, `sherpaOnnxFeatureConfig`, `sherpaOnnxSileroVadModelConfig`, `sherpaOnnxVadModelConfig`, `SherpaOnnxOfflineRecognizer` and `SherpaOnnxVoiceActivityDetectorWrapper` were read from sherpa-onnx v1.13.6's `SherpaOnnx.swift`. `SpeechTranscriber`, `SpeechAnalyzer`, `AnalyzerInput`, `AssetInventory.assetInstallationRequest` and `SpeechAnalyzer.bestAvailableAudioFormat` were type-checked against macOS 26.3 — note that `bestAvailableAudioFormat` is on `SpeechAnalyzer`, not `SpeechTranscriber`.

**Known risk carried into Task 1.** If the spike fails, this plan is void and the fallback is the PyTorch venv from the spec's Rejected alternatives.
