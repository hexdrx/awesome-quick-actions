// Transcribe/src/swift/en/main.swift
// English transcription via Apple's on-device SpeechTranscriber (macOS 26+).
// Usage: transcribe-en <wav>...
//
// Exit codes (shared contract with transcribe-ru):
//   0 - every input file transcribed successfully
//   1 - ran, but at least one file failed (see stderr ERROR lines)
//   2 - could not start at all: malformed invocation, or the transcription
//       engine/asset could not be made available
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

  var parts: [String] = []
  for try await result in transcriber.results where result.isFinal {
    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { parts.append(text) }
  }
  return parts.joined(separator: " ")
}

@available(macOS 26.0, *)
func makeTranscriber() -> SpeechTranscriber {
  SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: [])
}

@available(macOS 26.0, *)
func run() async {
  let wavs = Array(CommandLine.arguments.dropFirst())
  if wavs.isEmpty { die("usage: transcribe-en <wav>...") }

  // The en-US asset is absent on a fresh machine; installedLocales is empty.
  // Requested once, up front, against a throwaway transcriber instance --
  // the asset itself is a one-time, Apple-side download keyed on the
  // locale, not on any particular SpeechTranscriber object, so this does
  // not need to (and must not) repeat per file below.
  do {
    let bootstrap = makeTranscriber()
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
      let text = try await transcribe(path, using: makeTranscriber())
      note("PROGRESS transcribe 1 1 \(base)")
      print("=== FILE \(i + 1) ===")
      print(text)
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
