@preconcurrency import AVFoundation
import Foundation
import LLMKit
import SessionKit
import Testing
import TranscriptKit
@testable import PalMeetCore

/// Whole-session runs with the real on-device models (and, if logged in, the Claude Code CLI) on synthetic
/// speech. Run with: PALMEET_INTEGRATION=1 swift test --filter RealPipelineTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PALMEET_INTEGRATION"] == "1"))
struct RealPipelineTests {
    static let asr = ParakeetEngine(model: .ultra)
    static let diarizer = OfflineSpeakerDiarizer()

    /// 16 kHz mono samples of `text` spoken by a macOS voice.
    static func speech(_ text: String, voice: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "palmeet-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "speech.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        return try readMono(url)
    }

    func claudeIfAvailable() async -> (any LLMProvider)? {
        let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: .claudeCLI, model: "haiku"), secrets: InMemorySecretStore())
        return await provider.checkAvailability().isReady ? provider : nil
    }

    @Test(.timeLimit(.minutes(15))) func englishMeetingEndToEnd() async throws {
        let claude = await claudeIfAvailable()
        let h = Harness(settings: { $0.language = "en" }, asr: Self.asr, diarizer: Self.diarizer, provider: claude)
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(title: "Mobile release sync", remote: remote)

        var them: [Float] = []
        them += try Self.speech("Hi everyone, Maria here. Today we review the release plan for the mobile app.", voice: "Samantha")
        them += silence(0.8)
        them += try Self.speech("Thanks Maria. I think the beta should ship on November fourth, after the security review.", voice: "Daniel")
        them += silence(0.8)
        them += try Self.speech("Great. John, can you book the security review this week?", voice: "Samantha")
        them += silence(0.8)
        them += try Self.speech("Sure, I will book it tomorrow morning.", voice: "Daniel")
        remote.push(them, at: 0.3)

        await h.mic.pushRealtime(try Self.speech("I will update the release checklist by Friday.", voice: "Fred") + silence(0.5))
        try await Task.sleep(for: .milliseconds(300))
        await h.manager.stop(session)

        let transcript = try #require(session.transcript)
        print(transcript.plainText())
        let remoteText = transcript.segments.filter { $0.track == .them }.map(\.text).joined(separator: " ").lowercased()
        let myText = transcript.segments.filter { $0.track == .me }.map(\.text).joined(separator: " ").lowercased()
        #expect(remoteText.contains("release plan"))
        #expect(remoteText.contains("security review"))
        #expect(remoteText.contains("november"))
        #expect(myText.contains("checklist"), "my mic line: \(myText)")
        #expect(!remoteText.contains("checklist by friday"), "my words must not be attributed to remote speakers")
        let remoteSpeakers = Set(transcript.segments.filter { $0.track == .them }.map(\.speakerID))
        #expect(remoteSpeakers.count == 2, "two remote voices → two speakers, got \(remoteSpeakers)")

        if claude != nil {
            let summary = try #require(session.summary, "summary failed: \(session.metadata.lastError ?? "?")")
            print(try String(contentsOf: session.folder.summaryMarkdownURL, encoding: .utf8))
            #expect(!summary.tldr.isEmpty)
            #expect(summary.actionItems.count >= 2)
            #expect(summary.actionItems.contains { ($0.owner ?? "").localizedCaseInsensitiveContains("Isac") || $0.task.localizedCaseInsensitiveContains("checklist") })
        }
    }

    /// No API key saved: the live copilot answers through the Claude Code login.
    @Test(.timeLimit(.minutes(5))) func copilotAnswersThroughTheClaudeLogin() async throws {
        let claude = try #require(await claudeIfAvailable(), "log in with `claude` first")
        let h = Harness(settings: { $0.language = "en" }, asr: Self.asr, diarizer: Self.diarizer, provider: claude, apiKeys: [])
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(title: "Code review sync", remote: remote, includeMic: false)
        session.setCopilot(enabled: true)
        #expect(h.requestedProviders.withLock { $0 } == [.claudeCLI])

        remote.push(try Self.speech("Isac, can you review the payment pull request today?", voice: "Samantha") + silence(1.5), at: 0.3)
        let answered = await waitUntil(timeout: .seconds(120)) {
            session.suggestions.contains { $0.kind == .answer && $0.status == .ready && !$0.items.isEmpty }
        }
        #expect(answered, "warnings: \(session.warnings)")
        if let card = session.suggestions.first(where: { $0.kind == .answer }) { print("Copilot:", card.items.map(\.text)) }
        session.setCopilot(enabled: false)
        await h.manager.stop(session)
    }

    @Test(.timeLimit(.minutes(15))) func portugueseMeetingIsTranscribed() async throws {
        let h = Harness(settings: { $0.language = "pt" }, asr: Self.asr, diarizer: Self.diarizer)
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(title: "Reunião de planejamento", remote: remote, includeMic: false)
        var them = try Self.speech("Bom dia a todos. Hoje vamos revisar o planejamento da próxima sprint.", voice: "Flo (Portuguese (Brazil))")
        them += silence(0.8)
        them += try Self.speech("Precisamos terminar a integração com o sistema de pagamentos até sexta-feira.", voice: "Eddy (Portuguese (Brazil))")
        remote.push(them, at: 0.3)
        await h.manager.stop(session)
        let text = (session.transcript?.segments.map(\.text).joined(separator: " ") ?? "").lowercased()
        print(text)
        #expect(text.contains("planejamento"))
        #expect(text.contains("pagamentos"))
        #expect(text.contains("sexta"))
    }
}
