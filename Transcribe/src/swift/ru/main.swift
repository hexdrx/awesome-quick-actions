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
// maxSpeechDuration must be raised well above the 5.0 default: at 5.0 the VAD chops
// speech mid-sentence every five seconds, which wrecks the punctuation the model
// exists to produce. 20.0 sits just under GigaAM's own max_duration of 22.0.
var silero = sherpaOnnxSileroVadModelConfig(
  model: "\(modelsDir)/silero_vad.onnx", threshold: 0.25, windowSize: windowSize,
  maxSpeechDuration: 20.0)
var vadConfig = sherpaOnnxVadModelConfig(sileroVad: silero)

// Padding applied around each VAD segment before decoding. silero reports speech
// onset 0.1-0.3s late and swallows the first syllable of every segment; unpadded,
// the fixture transcribes as "чьих не требуя похвал" instead of "Ничьих не требуя
// похвал". Lead/tail pads are clamped against neighbouring segment bounds so that
// padded windows never overlap and duplicate words.
let leadPad = 4800  // 0.30s @ 16kHz
let tailPad = 3200  // 0.20s @ 16kHz

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

    // Drain raw segment bounds first (sample indices), so padding for each segment
    // can be clamped against its neighbours before any decoding happens.
    var bounds: [(start: Int, end: Int)] = []
    while !vad.isEmpty() {
      let seg = vad.front()
      bounds.append((seg.start, seg.start + seg.n))
      vad.pop()
    }

    // Silence, or audio the VAD rejected wholesale: fall back to the whole file
    // rather than emitting nothing.
    if bounds.isEmpty && !samples.isEmpty { bounds = [(0, samples.count)] }

    var parts: [String] = []
    for (n, b) in bounds.enumerated() {
      let prevEnd = n > 0 ? bounds[n - 1].end : 0
      let nextStart = n + 1 < bounds.count ? bounds[n + 1].start : samples.count
      let a = max(prevEnd, max(0, b.start - leadPad))
      let z = min(nextStart, min(samples.count, b.end + tailPad))
      let text = recognizer.decode(samples: [Float](samples[a..<z])).text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { parts.append(text) }
      note("PROGRESS transcribe \(n + 1) \(bounds.count) \(base)")
    }
    if bounds.isEmpty { note("PROGRESS transcribe 1 1 \(base)") }

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
