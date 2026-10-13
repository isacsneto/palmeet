@preconcurrency import AVFoundation
import Foundation
import SessionKit
import Testing
@testable import PalMeetCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImportTests {
    /// 44.1 kHz stereo file (like a phone recording) with two voices, imported and processed end to end.
    @Test func importsAnAudioRecording() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let url = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let samples = Voice.alpha.samples(seconds: 2, rate: rate) + silence(1, rate: rate) + Voice.bravo.samples(seconds: 2, rate: rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<2 { samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let session = try await h.manager.importRecording(from: url, title: "Phone recording")
        #expect(h.manager.library.first?.id == session.id)
        #expect(session.metadata.source.kind == .importedFile)
        #expect(!session.metadata.includesMicrophone)
        #expect(abs((session.metadata.duration ?? 0) - 5) < 0.2)
        let them = try readMono(session.folder.audioURL(for: .them))
        #expect(abs(Double(them.count) / 16_000 - 5) < 0.1, "resampled to 16 kHz mono without drift")

        await session.processImport()
        #expect(session.stage == .ready)
        let words = words(in: session.transcript)
        #expect(words.contains("alpha") && words.contains("bravo"))
        #expect(Set(session.transcript?.segments.map(\.speakerID) ?? []).count == 2)
        #expect(session.summary?.title == "Fake summary")
        #expect(FileManager.default.fileExists(atPath: session.folder.summaryMarkdownURL.path))
    }

    @Test func rejectsFilesWithoutAudio() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let url = FileManager.default.temporaryDirectory.appending(path: "not-media-\(UUID().uuidString).wav")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) { try await h.manager.importRecording(from: url) }
        #expect(h.manager.store.listSessions().isEmpty, "a failed import leaves nothing behind")
    }
}
