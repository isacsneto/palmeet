import AVFoundation
import Foundation
import Testing
@testable import TranscriptKit

/// Measures how alike the same voice is across two independently diarized recordings, to tune `VoiceMatcher`.
/// Splits a real recording in two halves and prints the cross-half similarity of every speaker pair.
/// Run with: PALMEET_VOICE_FILE=<them.caf> swift test --filter VoiceCalibrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_VOICE_FILE"] != nil))
struct VoiceCalibrationTests {
    @Test(.timeLimit(.minutes(20))) func crossHalfSimilarity() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PALMEET_VOICE_FILE"]!)
        let dir = FileManager.default.temporaryDirectory.appending(path: "palmeet-voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let halves = try Self.split(source, into: dir)
        let diarizer = OfflineSpeakerDiarizer()
        var outputs: [DiarizationOutput] = []
        for half in halves { outputs.append(try await diarizer.diarizeWithVoiceprints(fileURL: half)) }
        for (index, output) in outputs.enumerated() {
            var seconds: [String: Double] = [:]
            for span in output.spans { seconds[span.speakerKey, default: 0] += span.end - span.start }
            print("half \(index): " + seconds.sorted { $0.value > $1.value }.map { "\($0.key)=\(Int($0.value))s" }.joined(separator: " "))
        }
        let a = outputs[0].voiceprints, b = outputs[1].voiceprints
        for (index, prints) in [a, b].enumerated() {
            print("within half \(index):")
            for (k1, v1) in prints.sorted(by: { $0.key < $1.key }) {
                print("  \(k1): " + prints.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", Voiceprint.similarity(v1, $0.value)))" }.joined(separator: " "))
            }
        }
        print("half 0 × half 1:")
        for (k1, v1) in a.sorted(by: { $0.key < $1.key }) {
            print("  \(k1): " + b.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", Voiceprint.similarity(v1, $0.value)))" }.joined(separator: " "))
        }
        #expect(!a.isEmpty && !b.isEmpty)
    }

    static func split(_ url: URL, into dir: URL) throws -> [URL] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let half = AVAudioFrameCount(file.length / 2)
        var result: [URL] = []
        for index in 0..<2 {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: half)!
            try file.read(into: buffer, frameCount: half)
            let out = dir.appending(path: "half\(index).wav")
            let writer = try AVAudioFile(forWriting: out, settings: file.processingFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
            result.append(out)
        }
        return result
    }
}
