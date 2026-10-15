@preconcurrency import AVFoundation
import Foundation
import Testing
import TranscriptKit
@testable import PalMeetCore

/// Transcribes a real recording before and after compression and compares the words.
/// PALMEET_COMPRESSION_FILE=<copy of a .caf track> swift test --filter CompressionQualityTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_COMPRESSION_FILE"] != nil), .timeLimit(.minutes(20)))
struct CompressionQualityTests {
    @Test func compareFormats() async throws {
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PALMEET_COMPRESSION_FILE"]))
        let dir = original.deletingLastPathComponent()
        let asr = ParakeetEngine(model: .ultra)
        try await asr.prepare()
        let diarizer = OfflineSpeakerDiarizer()
        let reference = try await asr.transcribe(fileURL: original, language: nil).words.map { $0.text.lowercased() }
        let referenceSpeakers = Set(try await diarizer.diarize(fileURL: original).map(\.speakerKey)).count
        let again = try await asr.transcribe(fileURL: original, language: nil).words.map { $0.text.lowercased() }
        print("Original: \(reference.count) words, \(referenceSpeakers) speakers; same file again: \(Self.editDistance(reference, again)) words differ")
        if let variants = ProcessInfo.processInfo.environment["PALMEET_COMPRESSION_VARIANTS"] {
            for url in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: variants), includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let words = try await asr.transcribe(fileURL: url, language: nil).words.map { $0.text.lowercased() }
                let speakers = Set(try await diarizer.diarize(fileURL: url).map(\.speakerKey)).count
                let diff = Double(Self.editDistance(reference, words)) / Double(max(1, reference.count)) * 100
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0) / 1024
                print("\(url.lastPathComponent): \(size) KB, words differ \(String(format: "%.1f", diff))%, speakers \(speakers)")
            }
            return
        }
        let options: [(String, AudioFormatID, Int, String)] = [
            ("AAC 32k", kAudioFormatMPEG4AAC, 32_000, "m4a"), ("AAC 48k", kAudioFormatMPEG4AAC, 48_000, "m4a"),
            ("AAC 64k", kAudioFormatMPEG4AAC, 64_000, "m4a"), ("Opus 24k", kAudioFormatOpus, 24_000, "caf"),
            ("Opus 32k", kAudioFormatOpus, 32_000, "caf"), ("ALAC", kAudioFormatAppleLossless, 0, "m4a"),
        ]
        for (name, format, rate, ext) in options {
            let copy = dir.appending(path: "q-\(UUID().uuidString).caf")
            let out = dir.appending(path: "q-out.\(ext)")
            try FileManager.default.copyItem(at: original, to: copy)
            do {
                let sizes = try AudioCompression.compress(copy, to: out, format: format, bitRate: rate)
                let words = try await asr.transcribe(fileURL: out, language: nil).words.map { $0.text.lowercased() }
                let speakers = Set(try await diarizer.diarize(fileURL: out).map(\.speakerKey)).count
                let diff = Double(Self.editDistance(reference, words)) / Double(max(1, reference.count)) * 100
                print("\(name): \(sizes.after / 1024) KB (\(sizes.before / max(1, sizes.after))x smaller), words differ \(String(format: "%.1f", diff))%, speakers \(speakers)")
            } catch {
                print("\(name): failed \(error)")
            }
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.removeItem(at: out)
        }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
