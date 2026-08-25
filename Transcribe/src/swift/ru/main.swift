// Transcribe/src/swift/ru/main.swift
// Russian transcription via sherpa-onnx + GigaAM v3 e2e RNN-T.
// Usage: transcribe-ru --models <dir> [--timestamps] <wav>...
//
// Exit codes (shared contract with transcribe-en):
//   0 - every input file transcribed successfully
//   1 - ran, but at least one file failed (see stderr ERROR lines)
//   2 - could not start at all: malformed invocation, or the transcription
//       engine/asset could not be made available
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

// Set to opt into "DEBUG CHUNK <start> <end>" lines on stderr, one per decode
// chunk per file, so tests can observe chunk bounds without touching the
// stdout contract.
let debugChunks = ProcessInfo.processInfo.environment["TRANSCRIBE_RU_DEBUG_CHUNKS"] == "1"

// ---- arguments ----
var modelsDir = ""
var wavs: [String] = []
var emitTimestamps = false
var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
  args.removeFirst()
  if a == "--models" {
    guard let v = args.first else { die("--models needs a value") }
    modelsDir = v
    args.removeFirst()
  } else if a == "--timestamps" {
    emitTimestamps = true
  } else {
    wavs.append(a)
  }
}
if modelsDir.isEmpty || wavs.isEmpty {
  die("usage: transcribe-ru --models <dir> [--timestamps] <wav>...")
}

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
// maxSpeechDuration must be raised well above the 5.0 default: at 5.0 the VAD chops
// speech mid-sentence every five seconds, which wrecks the punctuation the model
// exists to produce. 20.0 sits just under GigaAM's own max_duration of 22.0.
var silero = sherpaOnnxSileroVadModelConfig(
  model: "\(modelsDir)/silero_vad.onnx", threshold: 0.25, windowSize: windowSize,
  maxSpeechDuration: 20.0)
var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)

let sampleRate = 16000
let maxChunkSamples = sampleRate * 20  // keep chunks under GigaAM's own 22.0s max_duration

// VAD is used only to decide WHERE to cut, never what to keep: it locates the
// pauses between speech segments, and each cut lands on the MIDPOINT of a
// pause so that no audio is ever discarded. Chunks tile the file exactly —
// chunk n+1 always starts at the sample where chunk n ended — so there is no
// onset-clipping seam to pad around any more (that defect only existed
// because VAD segments used to be decoded in isolation, each missing the
// syllable straddling its own boundary).
func computeChunks(sampleCount: Int, speechBounds: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
  guard sampleCount > 0 else { return [] }

  // Candidate cut points: the midpoint of every real gap between consecutive
  // speech segments, in ascending order (VAD emits segments in file order).
  var candidates: [Int] = []
  for n in 1..<max(speechBounds.count, 1) where n < speechBounds.count {
    let gapStart = speechBounds[n - 1].end
    let gapEnd = speechBounds[n].start
    if gapEnd > gapStart {
      candidates.append((gapStart + gapEnd) / 2)
    }
  }

  var chunks: [(start: Int, end: Int)] = []
  var pos = 0
  while pos < sampleCount {
    let remaining = sampleCount - pos
    if remaining <= maxChunkSamples {
      // What's left already fits in one chunk: this is the final chunk, and
      // it runs to the last sample regardless of any candidate inside it.
      chunks.append((pos, sampleCount))
      break
    }
    let limit = pos + maxChunkSamples
    let inRange = candidates.filter { $0 > pos && $0 <= limit }
    let cut = inRange.max() ?? limit
    chunks.append((pos, cut))
    pos = cut
  }
  return chunks
}

// ---- --timestamps: group a chunk's tokens into sentences ----
// GigaAM's vocabulary is SentencePiece BPE: a token beginning with "▁" starts
// a new word (the marker becomes a space); any other token — including
// punctuation like "." "," "?" "!" — attaches directly to what precedes it.
// A sentence ends on ".", "!" or "?"; its reported time is its first token's
// timestamp (chunk-relative, from the recognizer) plus the chunk's start
// offset in seconds.
struct TimedSentence { let time: Float; let text: String }

func isTerminalPunct(_ tok: String) -> Bool { tok == "." || tok == "!" || tok == "?" }

func sentences(from result: SherpaOnnxOfflineRecognitionResult, chunkOffsetSeconds: Float) -> [TimedSentence] {
  let n = result.count
  guard n > 0, let tokensArr = result.result.pointee.tokens_arr else { return [] }
  let ts = result.timestamps

  // Decode every token string up front so a terminal-punctuation token can
  // peek at its successor (needed to keep a run like "..." — three separate
  // "." tokens — as one sentence-ending marker instead of splitting it into
  // spurious punctuation-only "sentences").
  var toks: [String] = []
  toks.reserveCapacity(n)
  for idx in 0..<n {
    toks.append(tokensArr[idx].map { String(cString: $0) } ?? "")
  }

  var out: [TimedSentence] = []
  var buffer = ""
  var sentenceStart: Float? = nil

  for idx in 0..<n {
    let tok = toks[idx]
    if tok.isEmpty { continue }
    let time = (idx < ts.count ? ts[idx] : 0) + chunkOffsetSeconds
    if sentenceStart == nil { sentenceStart = time }

    if tok == "▁" {
      buffer += " "
    } else if tok.hasPrefix("▁") {
      buffer += " " + tok.dropFirst()
    } else {
      buffer += tok
    }

    if isTerminalPunct(tok) {
      let nextIsTerminal = idx + 1 < n && isTerminalPunct(toks[idx + 1])
      if !nextIsTerminal {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A punctuation-only buffer (no letter or digit) is not a real
        // sentence — drop it rather than emit a line like "[00:13] .".
        if !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil, let start = sentenceStart {
          out.append(TimedSentence(time: start, text: text))
        }
        buffer = ""
        sentenceStart = nil
      }
    }
  }
  let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
  if !rest.isEmpty, rest.rangeOfCharacter(from: .alphanumerics) != nil, let start = sentenceStart {
    out.append(TimedSentence(time: start, text: rest))
  }
  return out
}

func formatTimestamp(_ seconds: Float) -> String {
  let total = Int(seconds.rounded(.down))
  let mm = max(0, total) / 60
  let ss = max(0, total) % 60
  return String(format: "%02d:%02d", mm, ss)
}

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

    for off in stride(from: 0, to: samples.count, by: windowSize) {
      let end = min(off + windowSize, samples.count)
      vad.acceptWaveform(samples: [Float](samples[off..<end]))
    }
    vad.flush()

    var speechBounds: [(start: Int, end: Int)] = []
    while !vad.isEmpty() {
      let seg = vad.front()
      speechBounds.append((seg.start, seg.start + seg.n))
      vad.pop()
    }

    let chunks = computeChunks(sampleCount: samples.count, speechBounds: speechBounds)

    var parts: [String] = []
    var timedSentences: [TimedSentence] = []

    for (n, chunk) in chunks.enumerated() {
      let result = recognizer.decode(samples: [Float](samples[chunk.start..<chunk.end]))
      if emitTimestamps {
        timedSentences.append(
          contentsOf: sentences(from: result, chunkOffsetSeconds: Float(chunk.start) / Float(sampleRate)))
      } else {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(text) }
      }
      if debugChunks { note("DEBUG CHUNK \(chunk.start) \(chunk.end)") }
      note("PROGRESS transcribe \(n + 1) \(chunks.count) \(base)")
    }
    if chunks.isEmpty { note("PROGRESS transcribe 1 1 \(base)") }

    print("=== FILE \(i + 1) ===")
    if emitTimestamps {
      for s in timedSentences {
        print("[\(formatTimestamp(s.time))] \(s.text)")
      }
    } else {
      print(parts.joined(separator: " "))
    }
    print("")
  } catch {
    failed = true
    note("ERROR \(base): \(error.localizedDescription)")
    note("PROGRESS transcribe 1 1 \(base)")
    print("=== FILE \(i + 1) ===")
    print("")
    print("")
  }
}

exit(failed ? 1 : 0)
