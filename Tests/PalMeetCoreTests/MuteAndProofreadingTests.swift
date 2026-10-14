@testable import CaptureKit
import Foundation
import LLMKit
import SessionKit
import Testing
@testable import PalMeetCore

/// What you say while muted in the meeting stays out of that meeting's transcript and audio, also when it is the
/// only meeting being recorded; and the AI proofreading pass only makes small, verifiable fixes.
@MainActor
@Suite struct MuteAndProofreadingTests {
    @Test func singleMeetingDropsWhatYouSayWhileMuted() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start()
        #expect(session.isMicRouted)

        await h.mic.pushRealtime(Voice.alpha.samples(seconds: 1))
        session.knownMuted = true
        h.manager.updateMicRouting()
        #expect(!session.isMicRouted, "muted in the meeting → PalMeet stops using your mic for it")
        let muteStart = try #require(session.metadata.micRouting.last?.end)

        // Side talk while muted, then a pause long enough that the unmute lead-in can't reach it.
        await h.mic.pushRealtime(Voice.november.samples(seconds: 1) + silence(2.2))
        session.knownMuted = false
        h.manager.updateMicRouting()
        #expect(session.isMicRouted)
        let resumed = try #require(session.metadata.micRouting.last)
        #expect(resumed.start >= muteStart, "the lead-in never overlaps the muted span's start")
        #expect(session.clock.offset() - resumed.start > 1.0, "the span is back-dated to catch the first words after unmuting")
        await h.mic.pushRealtime(Voice.bravo.samples(seconds: 1))
        try await Task.sleep(for: .milliseconds(200))

        await h.manager.stop(session)
        let me = words(in: session.transcript, track: .me)
        #expect(me.contains("alpha") && me.contains("bravo"), "\(me)")
        #expect(!me.contains("november"), "what you said while muted leaked into the transcript: \(me)")

        // The muted stretch is silenced in the saved mic track too.
        let audio = try readMono(session.folder.audioURL(for: .me))
        let mutedSlice = audio.dropFirst(Int((muteStart + 0.1) * 16_000)).prefix(Int(0.9 * 16_000))
        #expect(!mutedSlice.isEmpty && mutedSlice.allSatisfy { $0 == 0 })
    }

    @Test func unknownMuteStateKeepsTheMicOn() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start()
        session.knownMuted = nil
        h.manager.updateMicRouting()
        #expect(session.isMicRouted, "no mute information must never silence you")
        await h.manager.stop(session)
    }

    @Test func hotkeyTogglesTheMicOfASingleMeeting() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start()
        #expect(session.isMicRouted)
        h.manager.cycleMicRouting()
        #expect(!session.isMicRouted && session.micOverride == false)
        h.manager.cycleMicRouting()
        #expect(session.isMicRouted && session.micOverride == nil, "second press returns to automatic")
        // Back to automatic means mute is honoured again.
        session.knownMuted = true
        h.manager.updateMicRouting()
        #expect(!session.isMicRouted)
        await h.manager.stop(session)
    }

    @Test func browserWindowWarnsThatItRecordsEveryProfile() {
        let h = Harness()
        defer { h.cleanup() }
        let chrome = CapturableWindow(id: 9, title: "Daily | Microsoft Teams", appName: "Google Chrome", bundleID: "com.google.Chrome", pid: 77, frame: .zero, isOnScreen: true)
        guard case .needsExtension(let detail) = h.manager.isolationPreview(for: .window(chrome)) else {
            Issue.record("a browser window must not be presented as isolated")
            return
        }
        #expect(detail.contains("every profile") && detail.contains("muted"))
        let zoom = CapturableWindow(id: 10, title: "Zoom Meeting", appName: "Zoom", bundleID: "us.zoom.xos", pid: 78, frame: .zero, isOnScreen: true)
        #expect(h.manager.isolationPreview(for: .window(zoom)) == .isolated("Zoom audio only"))
    }

    // MARK: - Proofreading

    @Test func proofreadingFixesMisheardWordsAfterTheMeeting() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote)
        remote.push(Voice.alpha.samples(seconds: 1.5) + silence(1) + Voice.bravo.samples(seconds: 1.5), at: 0.5)
        try await Task.sleep(for: .milliseconds(300))
        // The model says "alpha" was "Alfa Romeo", and tries to rewrite the "bravo" line (rejected).
        h.llm.proofreadResponder = { prompt in
            func time(of word: String) -> String {
                let line = prompt.split(separator: "\n").first { $0.hasPrefix("[") && $0.contains(": \(word)") } ?? ""
                return String(line.dropFirst().prefix(8))
            }
            return #"{"fixes":[{"t":"\#(time(of: "alpha"))","from":"alpha","to":"Alfa Romeo"},{"t":"\#(time(of: "bravo"))","from":"bravo bravo bravo","to":"a whole new sentence that rewrites what was said entirely"}]}"#
        }
        await h.manager.stop(session)

        #expect(h.llm.proofreadCalls.count == 1)
        #expect(h.llm.lastProofreadPrompt.contains("] Maria Silva: alpha") || h.llm.lastProofreadPrompt.contains("] Speaker 1: alpha"))
        let transcript = try #require(session.transcript)
        let fixed = try #require(transcript.segments.first { $0.text.contains("Alfa Romeo") }, "\(h.llm.lastProofreadPrompt)")
        #expect(fixed.originalText?.hasPrefix("alpha") == true, "the recognizer's text is kept")
        let bravo = try #require(transcript.segments.first { $0.text.contains("bravo") })
        #expect(bravo.originalText == nil, "rewrites are rejected")
        // Saved to disk.
        let md = try String(contentsOf: session.folder.transcriptMarkdownURL, encoding: .utf8)
        #expect(md.contains("Alfa Romeo"))
    }

    @Test func proofreadingCanBeTurnedOff() async throws {
        let h = Harness { $0.aiTranscriptCorrection = false }
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote)
        remote.push(Voice.alpha.samples(seconds: 1.5), at: 0.5)
        try await Task.sleep(for: .milliseconds(200))
        await h.manager.stop(session)
        #expect(h.llm.proofreadCalls.count == 0)
        #expect(session.transcript?.segments.allSatisfy { $0.originalText == nil } == true)
    }

    @Test func proofreadingNeverBlocksTheSummary() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.llm.proofreadJSON = "not json at all"
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote)
        remote.push(Voice.alpha.samples(seconds: 1.5), at: 0.5)
        try await Task.sleep(for: .milliseconds(200))
        await h.manager.stop(session)
        #expect(session.stage == .ready)
        #expect(session.summary?.title == "Fake summary")
    }

    @Test func applyOnlyTouchesTheRightLineAndWholeWords() {
        var transcript = Transcript(sessionID: SessionID(), speakers: [Speaker(id: "S1", displayName: "Speaker 1")], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 12.4, end: 15, text: "we use cooper netties and the cooper team"),
            TranscriptSegment(speakerID: "S1", track: .them, start: 30.2, end: 33, text: "ask the cooper netties guy"),
            TranscriptSegment(speakerID: "S1", track: .them, start: 40, end: 43, text: "Shadowan created tickets", isEdited: true),
            TranscriptSegment(speakerID: "S1", track: .them, start: 50, end: 53, text: "scooper is a word"),
        ])
        let applied = TranscriptCorrector.apply([
            .init(t: "00:00:12", from: "cooper netties", to: "Kubernetes"),
            .init(t: "00:00:40", from: "Shadowan", to: "Shadman"),          // user-edited line: untouched
            .init(t: "00:00:50", from: "cooper", to: "Cooper"),              // not a whole word in that line
            .init(t: "00:00:12", from: "", to: "x"),                          // empty
            .init(t: "bad", from: "the", to: "a"),                            // unparseable time
        ], to: &transcript)
        #expect(applied == 1)
        #expect(transcript.segments[0].text == "we use Kubernetes and the cooper team")
        #expect(transcript.segments[0].originalText == "we use cooper netties and the cooper team")
        #expect(transcript.segments[1].text == "ask the cooper netties guy", "a fix only applies at its own timestamp")
        #expect(transcript.segments[2].text == "Shadowan created tickets")
        #expect(transcript.segments[3].text == "scooper is a word")
    }

    @Test func plausibilityAndChunking() {
        #expect(TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "day stations", to: "seasons")))
        #expect(!TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "same", to: "same")))
        #expect(!TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "one two three four five six seven", to: "x")))
        #expect(!TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "uh", to: "a much longer invented replacement sentence")))
        // Pure deletions are cleanup, not recognition fixes.
        #expect(!TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "I and I expect", to: "and I expect")))
        #expect(!TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "well w volley or valley", to: "valley")))
        #expect(TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "mushro season", to: "mushroom season")))
        #expect(TranscriptCorrector.isPlausible(.init(t: "00:00:01", from: "Janaide", to: "Junaid")))
        let chunks = TranscriptCorrector.chunks(Array(repeating: String(repeating: "x", count: 99), count: 10), maxCharacters: 300)
        #expect(chunks.count == 4 && chunks.flatMap { $0 }.count == 10)
    }

    @Test func originalTextIsBackwardCompatible() throws {
        // Transcripts written by older versions (no originalText key) still load.
        let old = #"{"id":"6F2A6F3C-1B0B-4C4B-9C3A-2B1B0C1D2E3F","speakerID":"S1","track":"them","start":1,"end":2,"text":"hi","words":[],"confidence":1,"isEdited":false,"isLive":false}"#
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8))
        #expect(segment.originalText == nil && segment.text == "hi")
    }
}

/// Proofreads a real transcript with the Claude CLI and prints the proposed fixes (nothing is written).
/// Run with: PALMEET_PROOFREAD_FILE=/path/to/transcript.json swift test --filter LiveProofreadingTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_PROOFREAD_FILE"] != nil))
struct LiveProofreadingTests {
    @Test func proofreadsARealTranscript() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PALMEET_PROOFREAD_FILE"])
        var transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let model = ProcessInfo.processInfo.environment["PALMEET_PROOFREAD_MODEL"] ?? "sonnet"
        let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: .claudeCLI, model: model), secrets: InMemorySecretStore())
        let corrector = TranscriptCorrector(provider: provider, model: model)
        let started = Date()
        let fixes = try await corrector.corrections(transcript: transcript, glossary: [], screenNames: [], title: "Daily Standup")
        let before = transcript
        let applied = TranscriptCorrector.apply(fixes, to: &transcript)
        print("PROOFREAD \(fixes.count) proposed, \(applied) applied in \(Int(Date().timeIntervalSince(started))) s")
        for fix in fixes {
            let ok = TranscriptCorrector.isPlausible(fix) ? "" : " (rejected)"
            print("PROOFREAD [\(fix.t)] \(fix.from) → \(fix.to)\(ok)")
        }
        #expect(applied <= fixes.count)
        #expect(zip(before.segments, transcript.segments).allSatisfy { $0.id == $1.id })
    }
}
