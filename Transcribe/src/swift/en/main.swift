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
  guard let rawBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length)) else {
    throw NSError(domain: "transcribe", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "cannot allocate buffer"])
  }
  try file.read(into: rawBuf)

  // SpeechAnalyzer asserts internally if fed audio that isn't in a format it
  // considers analyzer-compatible. Convert to its best available format for
  // this module set before handing the buffer over.
  let buf: AVAudioPCMBuffer
  if let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
     targetFormat != rawBuf.format {
    guard let converter = AVAudioConverter(from: rawBuf.format, to: targetFormat) else {
      throw NSError(domain: "transcribe", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "cannot create audio converter"])
    }
    let ratio = targetFormat.sampleRate / rawBuf.format.sampleRate
    let outCapacity = AVAudioFrameCount(Double(rawBuf.frameLength) * ratio) + 1024
    guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
      throw NSError(domain: "transcribe", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "cannot allocate converted buffer"])
    }
    var error: NSError?
    var fed = false
    converter.convert(to: converted, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return rawBuf
    }
    if let error { throw error }
    buf = converted
  } else {
    buf = rawBuf
  }

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
