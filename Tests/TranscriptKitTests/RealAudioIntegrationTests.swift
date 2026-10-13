import Foundation
import SessionKit
import Testing
@testable import TranscriptKit

/// End-to-end check with real models on synthetic speech (macOS `say`). Downloads ~1 GB of models on first run.
/// Run with: PALMEET_INTEGRATION=1 swift test --filter RealAudioIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_INTEGRATION"] == "1"))
struct RealAudioIntegrationTests {
    func say(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
    }

    @Test(.timeLimit(.minutes(20))) func transcribesAndSeparatesTwoVoices() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "palmeet-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appending(path: "a.wav"), b = dir.appending(path: "b.wav"), c = dir.appending(path: "c.wav")
        try say("Good morning everyone. Today we will review the release plan for the mobile app.", voice: "Samantha", to: a)
        try say("Thanks. I think the beta should ship on November fourth, after the security review.", voice: "Daniel", to: b)
        try say("Agreed. Please update the checklist and share it with the team by Friday.", voice: "Samantha", to: c)
        let mixed = dir.appending(path: "them.wav")
        try AudioTestFiles.concatenate([a, b, c], silenceBetween: 0.8, to: mixed)

        let engine = ParakeetEngine(model: .ultra)
        let result = try await engine.transcribe(fileURL: mixed, language: "en")
        let text = result.text.lowercased()
        print("ASR:", result.text)
        #expect(text.contains("release plan"))
        #expect(text.contains("november"))
        #expect(!result.words.isEmpty)

        let spans = try await OfflineSpeakerDiarizer().diarize(fileURL: mixed)
        print("Diarization:", spans.map { "\($0.speakerKey) \(String(format: "%.1f-%.1f", $0.start, $0.end))" })
        let transcript = TranscriptAssembler.assemble(
            sessionID: SessionID(),
            input: .init(themWords: result.words, meWords: [], diarization: spans, micRouting: nil, meName: "Me")
        )
        print(transcript.plainText())
        #expect(Set(transcript.segments.map(\.speakerID)).count >= 2)
    }
}
