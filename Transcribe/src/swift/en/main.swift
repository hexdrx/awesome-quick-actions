// Transcribe/src/swift/en/main.swift
// English transcription via Apple's on-device SpeechTranscriber (macOS 26+).
// Usage: transcribe-en [--timestamps] [--word-timestamps] <wav>...
//
// Exit codes (shared contract with transcribe-ru):
//   0 - every input file transcribed successfully
//   1 - ran, but at least one file failed (see stderr ERROR lines)
//   2 - could not start at all: malformed invocation, or the transcription
//       engine/asset could not be made available
import AVFoundation
import CoreMedia
import Foundation
import Speech

func note(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

func die(_ msg: String) -> Never {
  note("ERROR: \(msg)")
  exit(2)
}

// ---- --timestamps: group SpeechTranscriber's (roughly per-word) runs into
// sentences. A run's own text already carries its leading space (joining
// runs with "" reproduces normal prose), so a sentence's text is simply the
// concatenation of its runs' text, trimmed. A sentence ends on a run whose
// (trimmed) text ends with ".", "!" or "?"; its reported time is its first
// run's audioTimeRange.start, in seconds.
struct TimedSentence { let time: Float; let text: String }

// ---- --word-timestamps: one line per word, with a TRUE start and end.
// SpeechTranscriber's runs are per word, and each carries a real
// audioTimeRange (both .start and .duration) -- unlike the Russian engine,
// no end time needs to be inferred here. A run's own text already includes
// any leading space and trailing punctuation (e.g. " there."), so the word
// text is simply the run's text, trimmed.
struct TimedWord { let start: Float; let end: Float; let text: String }

func isTerminalPunct(_ s: String) -> Bool {
  guard let last = s.last else { return false }
  return last == "." || last == "!" || last == "?"
}

func formatTimestamp(_ seconds: Float) -> String {
  let total = Int(seconds.rounded(.down))
  let mm = max(0, total) / 60
  let ss = max(0, total) % 60
  return String(format: "%02d:%02d", mm, ss)
}

// "[MM:SS.cc-MM:SS.cc]" -- hundredths of a second, minutes never roll over
// into hours (a 75-minute file reads "75:03.10", not "1:15:03.10").
func formatWordTimestamp(_ seconds: Float) -> String {
  let totalCentis = Int((seconds * 100).rounded())
  let mm = max(0, totalCentis) / 6000
  let rem = max(0, totalCentis) % 6000
  let ss = rem / 100
  let cc = rem % 100
  return String(format: "%02d:%02d.%02d", mm, ss, cc)
}

struct TranscribeResult {
  var plainText: String = ""
  var sentences: [TimedSentence] = []
  var words: [TimedWord] = []
}

@available(macOS 26.0, *)
func transcribe(_ path: String, using transcriber: SpeechTranscriber, emitTimestamps: Bool, emitWordTimestamps: Bool) async throws -> TranscribeResult {
  let analyzer = SpeechAnalyzer(modules: [transcriber])

  let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
  guard let rawBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length)) else {
    throw NSError(domain: "transcribe", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "cannot allocate buffer"])
  }
  try file.read(into: rawBuf)

  // SpeechAnalyzer asserts internally if fed audio that isn't in a format it
  // considers analyzer-compatible. Convert to its best available format for
  // this module set before handing the buffer over. A nil result means no
  // compatible format could be determined at all -- that must fail loudly,
  // not silently fall through to feeding the analyzer the raw (crash-prone)
  // buffer.
  guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
    throw NSError(domain: "transcribe", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "no analyzer-compatible audio format available"])
  }

  let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
  try await analyzer.start(inputSequence: stream)

  if targetFormat == rawBuf.format {
    cont.yield(AnalyzerInput(buffer: rawBuf))
  } else {
    guard let converter = AVAudioConverter(from: rawBuf.format, to: targetFormat) else {
      throw NSError(domain: "transcribe", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "cannot create audio converter"])
    }

    // Each call to convert(to:) writes into its destination buffer starting
    // at frame 0 -- it does not append. Reusing one destination buffer
    // across multiple convert() calls silently discards everything written
    // by the previous call the moment the next call produces zero frames
    // (which the terminal .endOfStream call always does). So every call
    // gets its own fresh chunk buffer, and any non-empty chunk is streamed
    // to the analyzer immediately rather than accumulated locally.
    //
    // Loop until the converter itself reports .endOfStream (or .error) --
    // a single .haveData call only guarantees *some* output, not that the
    // input has been fully drained and flushed. The input block signals
    // end-of-input with .endOfStream (not .noDataNow, which means "none
    // available right now, ask again later" and can make the converter
    // withhold its final flush) once the one buffer of input has been
    // handed over.
    var fed = false
    var status: AVAudioConverterOutputStatus = .haveData
    while status == .haveData {
      guard let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16384) else {
        throw NSError(domain: "transcribe", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate converted buffer"])
      }
      var convertError: NSError?
      status = converter.convert(to: chunk, error: &convertError) { _, outStatus in
        if fed {
          outStatus.pointee = .endOfStream
          return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return rawBuf
      }
      if let convertError { throw convertError }
      if status == .error {
        throw NSError(domain: "transcribe", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "audio conversion failed"])
      }
      if chunk.frameLength > 0 {
        cont.yield(AnalyzerInput(buffer: chunk))
      }
    }
  }

  cont.finish()
  try await analyzer.finalizeAndFinishThroughEndOfInput()

  var out = TranscribeResult()
  if emitWordTimestamps {
    var words: [TimedWord] = []
    var lastKnownStart: Float = 0
    var lastKnownEnd: Float = 0
    for try await result in transcriber.results where result.isFinal {
      for run in result.text.runs {
        let runText = String(result.text[run.range].characters)
        if runText.isEmpty { continue }
        let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let start: Float
        let end: Float
        if let tr = run.audioTimeRange {
          start = Float(CMTimeGetSeconds(tr.start))
          end = start + Float(CMTimeGetSeconds(tr.duration))
          lastKnownStart = start
          lastKnownEnd = end
        } else {
          start = lastKnownStart
          end = lastKnownEnd
        }
        words.append(TimedWord(start: start, end: end, text: trimmed))
      }
    }
    out.words = words
  } else if emitTimestamps {
    var sents: [TimedSentence] = []
    var buffer = ""
    var sentenceStart: Float? = nil
    var lastKnownTime: Float = 0
    for try await result in transcriber.results where result.isFinal {
      for run in result.text.runs {
        let runText = String(result.text[run.range].characters)
        if runText.isEmpty { continue }
        let time: Float
        if let tr = run.audioTimeRange {
          time = Float(CMTimeGetSeconds(tr.start))
          lastKnownTime = time
        } else {
          time = lastKnownTime
        }
        if sentenceStart == nil { sentenceStart = time }
        buffer += runText

        let trimmedRun = runText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTerminalPunct(trimmedRun) {
          let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
          // A punctuation-only buffer (no letter or digit) is not a real
          // sentence -- drop it rather than emit a line like "[00:13] .".
          if !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil, let start = sentenceStart {
            sents.append(TimedSentence(time: start, text: text))
          }
          buffer = ""
          sentenceStart = nil
        }
      }
    }
    let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty, rest.rangeOfCharacter(from: .alphanumerics) != nil, let start = sentenceStart {
      sents.append(TimedSentence(time: start, text: rest))
    }
    out.sentences = sents
  } else {
    var parts: [String] = []
    for try await result in transcriber.results where result.isFinal {
      let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { parts.append(text) }
    }
    out.plainText = parts.joined(separator: " ")
  }
  return out
}

@available(macOS 26.0, *)
func makeTranscriber(withTimestamps: Bool) -> SpeechTranscriber {
  SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: withTimestamps ? [.audioTimeRange] : [])
}

@available(macOS 26.0, *)
func run() async {
  var wavs: [String] = []
  var emitTimestamps = false
  var emitWordTimestamps = false
  for a in CommandLine.arguments.dropFirst() {
    if a == "--timestamps" {
      emitTimestamps = true
    } else if a == "--word-timestamps" {
      emitWordTimestamps = true
    } else {
      wavs.append(a)
    }
  }
  if wavs.isEmpty { die("usage: transcribe-en [--timestamps] [--word-timestamps] <wav>...") }

  // The en-US asset is absent on a fresh machine; installedLocales is empty.
  // Requested once, up front, against a throwaway transcriber instance --
  // the asset itself is a one-time, Apple-side download keyed on the
  // locale, not on any particular SpeechTranscriber object, so this does
  // not need to (and must not) repeat per file below.
  do {
    let bootstrap = makeTranscriber(withTimestamps: false)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [bootstrap]) {
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
      // A FRESH SpeechTranscriber per file, not one reused across the whole
      // batch: a SpeechTranscriber instance cannot be driven by a second
      // SpeechAnalyzer run -- Speech.framework hits an internal
      // precondition and the process dies with SIGTRAP (exit 133) on the
      // second file, discarding every transcript already produced in the
      // batch (stdout is block-buffered on a pipe). Constructing the
      // transcriber is cheap; it does not re-touch the installed asset.
      let needsTiming = emitTimestamps || emitWordTimestamps
      let result = try await transcribe(path, using: makeTranscriber(withTimestamps: needsTiming), emitTimestamps: emitTimestamps, emitWordTimestamps: emitWordTimestamps)
      note("PROGRESS transcribe 1 1 \(base)")
      print("=== FILE \(i + 1) ===")
      if emitWordTimestamps {
        for w in result.words {
          print("[\(formatWordTimestamp(w.start))–\(formatWordTimestamp(w.end))] \(w.text)")
        }
      } else if emitTimestamps {
        for s in result.sentences {
          print("[\(formatTimestamp(s.time))] \(s.text)")
        }
      } else {
        print(result.plainText)
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
}

if #available(macOS 26.0, *) {
  await run()
} else {
  die("нужна macOS 26 или новее")
}
