import Foundation
import LLMKit
import SessionKit
import Testing
@testable import PalMeetCore

@Suite struct SettingsMergeTests {
    @Test func storedValuesOverlayNewDefaults() throws {
        let suite = "palmeet-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        // Simulates settings saved by an older version: nested struct missing newer keys.
        let old = #"{"profile":{"name":"Isac","aliases":[],"role":"","team":"","expertise":"","communicationStyle":""},"privacy":{"hideFromScreenCapture":false},"maxConcurrentSessions":2}"#
        UserDefaults(suiteName: suite)?.set(Data(old.utf8), forKey: "app.palmeet.settings.v1")
        let settings = SettingsStore(suiteName: suite).load()
        #expect(settings.profile.name == "Isac")
        #expect(settings.maxConcurrentSessions == 2)
        #expect(settings.privacy.hideFromScreenCapture == false)
        #expect(settings.privacy.autoHideWhileSharing == true)  // default filled in
        #expect(settings.copilot.maxCallsPerMinute == 6)
    }

    @Test func appearanceDefaultsPerRole() {
        let appearance = AppearanceSettings()
        #expect(appearance[.main].alwaysOnTop == false)
        #expect(appearance[.copilotPanel].alwaysOnTop == true)
    }
}

@Suite struct SummarizerHelperTests {
    let summarizer = Summarizer(provider: StubProvider(text: "{}"), model: nil, maxImages: 4)

    @Test func linesCarrySpeakerIDsForNameMapping() {
        let transcript = Transcript(sessionID: SessionID(), speakers: [.me(named: "Isac"), Speaker(id: "S1", displayName: "Speaker 1")], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 3, end: 5, text: "Hi, I'm Maria."),
        ])
        #expect(summarizer.transcriptLines(transcript) == "[00:00:03] Speaker 1 (S1): Hi, I'm Maria.")
    }

    @Test func parsesSummaryAndSpeakerNames() async throws {
        let json = #"Sure! {"title":"Sync","tldr":"Short","speaker_names":{"S1":"Maria Silva","S9":"Ghost"}}"#
        let summarizer = Summarizer(provider: StubProvider(text: json), model: nil)
        let metadata = SessionMetadata(title: "Sync", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let transcript = Transcript(sessionID: metadata.id, speakers: [.me(named: "Isac"), Speaker(id: "S1", displayName: "Speaker 1")], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 0, end: 2, text: "Hello"),
        ])
        let folder = SessionFolder(url: FileManager.default.temporaryDirectory)
        let output = try await summarizer.summarize(metadata: metadata, transcript: transcript, screenshots: [], notes: [], folder: folder, glossary: [])
        #expect(output.summary.title == "Sync")
        #expect(output.speakerNames == ["S1": "Maria Silva"])  // unknown IDs dropped
    }
}

@Suite struct ScreenContextTests {
    private func shot(_ i: Int, at offset: TimeInterval, _ text: String, reason: ScreenshotRecord.Reason = .interval, hash: UInt64 = 0) -> ScreenshotRecord {
        ScreenshotRecord(index: i, offset: offset, relativePath: "screenshots/\(i).jpg", reason: reason, ocrText: text, perceptualHash: hash)
    }

    private func transcript(_ lines: [(TimeInterval, String)]) -> Transcript {
        Transcript(sessionID: SessionID(), speakers: [Speaker(id: "S1", displayName: "Ryan")], segments: lines.map {
            TranscriptSegment(speakerID: "S1", track: .them, start: $0.0, end: $0.0 + 4, text: $0.1)
        })
    }

    @Test func screenLinesCarryOnlyNewText() {
        let shots = [
            shot(1, at: 10, "Meet\nRyan Jackson\nYegor Kluban"),
            shot(2, at: 40, "Meet\nRyan Jackson\nYegor Kluban"),                       // nothing new
            shot(3, at: 70, "Meet\nRyan Jackson\npermissions_constants.dart\nVTX-1423 Remove legacy flags"),
            shot(4, at: 100, "Yegor Kluban Ryan Jackson"),                                // known words re-wrapped
        ]
        let lines = ScreenContext.lines(for: shots, attached: ["screenshots/2.jpg"])
        #expect(lines.map(\.offset) == [10, 40, 70])
        #expect(lines[0].text == "📷 screenshots/1.jpg new on screen: Meet | Ryan Jackson | Yegor Kluban")
        #expect(lines[1].text == "📷 screenshots/2.jpg (image attached): same screen as before")
        #expect(lines[2].text == "📷 screenshots/3.jpg new on screen: permissions_constants.dart | VTX-1423 Remove legacy flags")
        // The budget keeps long meetings' screen text bounded (attached images are always listed).
        let many = (0..<50).map { shot($0, at: Double($0 * 30), "Slide \($0) unique words alpha\($0) beta\($0) gamma\($0)") }
        #expect(ScreenContext.lines(for: many, attached: [], budget: 500).count < 15)
    }

    @Test func choosesTheScreensPeopleWereTalkingAbout() {
        // 20 screens of a static video grid with a little OCR noise, one ticket people discuss, one manual mark.
        var shots = (0..<20).map { shot($0, at: Double($0 * 30), "Ryan Jackson Yegor Kluban noise\($0)", hash: UInt64($0) << 40) }
        shots[7] = shot(7, at: 210, "VTX-1423 Remove legacy permission flags from graph panel\nAcceptance criteria", hash: 1 << 20)
        shots[15] = shot(15, at: 450, "Ryan Jackson Yegor Kluban", reason: .manual, hash: 1 << 59)
        let talk = transcript([
            (205, "So this ticket removes the legacy permission flags from the graph panel"),
            (300, "Any questions?"),
        ])
        let chosen = ScreenContext.choose(shots, transcript: talk, count: 3)
        #expect(chosen.count == 2, "the rest of the grid shows nothing new, so it doesn't fill the last slot")
        #expect(chosen.contains { $0.index == 7 }, "the ticket being discussed")
        #expect(chosen.contains { $0.index == 15 }, "the screen you marked")
        #expect(chosen.map(\.offset) == chosen.map(\.offset).sorted())
        // Near-identical pictures don't take two slots.
        let same = (0..<6).map { shot($0, at: Double($0 * 60), "Slide \($0) words\($0)", hash: 0xFFFF) }
            + [shot(9, at: 400, "Other slide entirely different", hash: 0xFFFF_0000_0000_0000)]
        let picked = ScreenContext.choose(same, transcript: transcript([]), count: 2)
        #expect(picked.contains { $0.index == 9 })
    }

    @Test func screensSitInTheTranscriptAtTheirTime() {
        let summarizer = Summarizer(provider: StubProvider(text: "{}"), model: nil)
        let talk = transcript([(3, "Hi all."), (12, "Look at this ticket.")])
        let text = summarizer.transcriptLines(talk, screens: [.init(offset: 12, text: "📷 screenshots/1.jpg new on screen: VTX-1")])
        #expect(text == """
        [00:00:03] Ryan (S1): Hi all.
        [00:00:12] Ryan (S1): Look at this ticket.
        [00:00:12] 📷 screenshots/1.jpg new on screen: VTX-1
        """)
    }

    @Test func madeUpScreenshotPathsAreDropped() {
        let summary = MeetingSummary(
            title: "Sync", tldr: "",
            topics: [.init(title: "Flags", summary: "…", screenshot: "screenshots/7.jpg"), .init(title: "Other", summary: "…", screenshot: "screenshots/99.jpg")],
            decisions: [.init(text: "Ship", screenshot: " ")]
        )
        let checked = ScreenContext.validated(summary, paths: ["screenshots/7.jpg"])
        #expect(checked.topics.map(\.screenshot) == ["screenshots/7.jpg", nil])
        #expect(checked.decisions.first?.screenshot == nil)
    }

    @Test func imagesSitUnderTheirTopicAndAreNotRepeated() {
        let metadata = SessionMetadata(title: "Sync", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let summary = MeetingSummary(
            title: "Sync", tldr: "Short",
            topics: [.init(title: "Legacy flags", start: "00:03:30", summary: "Ryan walked through VTX-1423.", screenshot: "screenshots/0007 x.jpg")],
            decisions: [.init(text: "Remove the flags", ref: "00:04:00", screenshot: "screenshots/0008.jpg")],
            visualContext: [
                .init(ref: "00:03:30", screenshot: "screenshots/0007 x.jpg", description: "The ticket"),
                .init(ref: "00:09:00", screenshot: "screenshots/0012.jpg", description: "Chat with the Jira link"),
            ]
        )
        let md = SummaryMarkdownRenderer.render(summary, metadata: metadata, transcript: Transcript(sessionID: metadata.id, speakers: [], segments: []))
        #expect(md.contains("Ryan walked through VTX-1423.\n\n![Legacy flags](screenshots/0007%20x.jpg)"))
        #expect(md.contains("- Remove the flags [00:04:00]\n  ![Remove the flags](screenshots/0008.jpg)") || md.contains("![Remove the flags](screenshots/0008.jpg)"))
        #expect(md.components(separatedBy: "0007%20x.jpg").count == 2, "shown once, with its topic")
        #expect(md.contains("Chat with the Jira link"))
    }

    @Test func theModelSeesScreensInTheTranscriptAndTheChosenImages() async throws {
        let provider = CapturingProvider(text: #"{"title":"Sync","tldr":"x","topics":[{"title":"Flags","summary":"y","screenshot":"screenshots/1.jpg"}]}"#)
        let summarizer = Summarizer(provider: provider, model: nil, maxImages: 1)
        let metadata = SessionMetadata(title: "Sync", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let talk = transcript([(0, "Hello"), (60, "This ticket removes the legacy flags")])
        let shots = [shot(0, at: 5, "Ryan Jackson"), shot(1, at: 61, "VTX-1423 legacy flags ticket")]
        let output = try await summarizer.summarize(
            metadata: metadata, transcript: talk, screenshots: shots, notes: [],
            folder: SessionFolder(url: FileManager.default.temporaryDirectory), glossary: []
        )
        let parts = try #require(provider.lastRequest?.messages.first?.parts)
        let text = parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        #expect(text.contains("[00:00:05] 📷 screenshots/0.jpg new on screen: Ryan Jackson"))
        #expect(text.contains("[00:01:01] 📷 screenshots/1.jpg (image attached) new on screen: VTX-1423 legacy flags ticket"))
        #expect(parts.filter { if case .imageFile = $0 { true } else { false } }.count == 1)
        #expect(output.summary.topics.first?.screenshot == "screenshots/1.jpg")
    }
}

final class CapturingProvider: LLMProvider, @unchecked Sendable {
    let text: String
    private let lock = NSLock()
    private var request: LLMRequest?
    init(text: String) { self.text = text }
    var lastRequest: LLMRequest? { lock.withLock { request } }
    var kind: LLMProviderKind { .anthropicAPI }
    var capabilities: LLMCapabilities { [.images] }
    var isSlow: Bool { false }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { self.request = request }
        return LLMResponse(text: text)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(text); $0.finish() }
    }
    func checkAvailability() async -> LLMAvailability { .ready }
}

@Suite struct TitleCleanupTests {
    @Test func stripsBrowserSuffixes() {
        #expect(SessionManager.cleanTitle("Meet – abc-defg-hij - Google Chrome", appName: "Chrome") == "Meet – abc-defg-hij")
        #expect(SessionManager.cleanTitle("  ", appName: "Zoom") == "Zoom meeting")
    }
}

struct StubProvider: LLMProvider {
    let text: String
    var kind: LLMProviderKind { .anthropicAPI }
    var capabilities: LLMCapabilities { [] }
    var isSlow: Bool { false }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { LLMResponse(text: text) }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(text); $0.finish() }
    }
    func checkAvailability() async -> LLMAvailability { .ready }
}

/// Real summary through the locally logged-in Claude Code CLI.
/// Run with: PALMEET_INTEGRATION=1 swift test --filter LiveSummaryTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_INTEGRATION"] == "1"))
struct LiveSummaryTests {
    @Test(.timeLimit(.minutes(5))) func summarizesWithClaudeCLI() async throws {
        let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: .claudeCLI, model: "haiku"), secrets: InMemorySecretStore())
        guard await provider.checkAvailability().isReady else { return }
        let metadata = SessionMetadata(title: "Release sync", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let transcript = Transcript(sessionID: metadata.id, speakers: [.me(named: "Isac"), Speaker(id: "S1", displayName: "Speaker 1"), Speaker(id: "S2", displayName: "Speaker 2")], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 0, end: 4, text: "Hi all, Maria here. Today we review the mobile release plan."),
            TranscriptSegment(speakerID: "S2", track: .them, start: 5, end: 10, text: "I think the beta should ship on November 4th, after the security review."),
            TranscriptSegment(speakerID: "me", track: .me, start: 11, end: 14, text: "Agreed. I'll update the release checklist by Friday."),
            TranscriptSegment(speakerID: "S1", track: .them, start: 15, end: 18, text: "Great, thanks Isac. John, can you book the security review?"),
            TranscriptSegment(speakerID: "S2", track: .them, start: 19, end: 21, text: "Sure, I'll book it today."),
        ])
        let folder = try SessionStore(rootURL: FileManager.default.temporaryDirectory.appending(path: "palmeet-live-\(UUID().uuidString)")).createFolder(for: metadata)
        let output = try await Summarizer(provider: provider, model: "haiku").summarize(
            metadata: metadata, transcript: transcript, screenshots: [], notes: [], folder: folder, glossary: []
        )
        print(SummaryMarkdownRenderer.render(output.summary, metadata: metadata, transcript: transcript))
        print("speaker_names:", output.speakerNames)
        #expect(!output.summary.tldr.isEmpty)
        #expect(output.summary.actionItems.count >= 2)
        #expect(output.speakerNames["S1"]?.contains("Maria") == true)
    }
}

/// Regenerates a real meeting's summary (a copy of its folder) with the Claude Code CLI and writes it next to the
/// original as summary-new.md, to compare. Run with:
///   PALMEET_INTEGRATION=1 PALMEET_SUMMARY_SESSION="<copied session folder>" swift test --filter LiveSessionSummaryTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_SUMMARY_SESSION"] != nil))
struct LiveSessionSummaryTests {
    @Test(.timeLimit(.minutes(15))) func regeneratesARealSummary() async throws {
        let folder = SessionFolder(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PALMEET_SUMMARY_SESSION"]!))
        let store = SessionStore(rootURL: folder.url.deletingLastPathComponent())
        let metadata = try store.loadMetadata(in: folder)
        let transcript = try store.loadTranscript(in: folder)
        let screenshots = store.loadScreenshots(in: folder)
        let context = (try? String(contentsOf: folder.url.appending(path: "context.md"), encoding: .utf8)) ?? ""
        let model = ProcessInfo.processInfo.environment["PALMEET_SUMMARY_MODEL"] ?? "sonnet"
        let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: .claudeCLI, model: model), secrets: InMemorySecretStore())
        let summarizer = Summarizer(provider: provider, model: model)
        print("Images:", summarizer.selectScreenshots(screenshots, transcript: transcript).map(\.relativePath))
        let output = try await summarizer.summarize(
            metadata: metadata, transcript: transcript, screenshots: screenshots, notes: store.loadNotes(in: folder),
            folder: folder, glossary: [], context: context
        )
        let markdown = SummaryMarkdownRenderer.render(output.summary, metadata: metadata, transcript: transcript)
        try markdown.write(to: folder.url.appending(path: "summary-new.md"), atomically: true, encoding: .utf8)
        #expect(!output.summary.tldr.isEmpty)
    }
}

@Suite struct RenameInSummaryTests {
    @Test func replacesWholeNamesOnly() {
        let summary = MeetingSummary(title: "Sync", tldr: "Speaker 1 and Speaker 12 agreed.", actionItems: [.init(owner: "Speaker 1", task: "Book review")])
        let updated = MeetingSession.replacingName("Speaker 1", with: "John \"JP\" Park", in: summary)
        #expect(updated.tldr == "John \"JP\" Park and Speaker 12 agreed.")
        #expect(updated.actionItems.first?.owner == "John \"JP\" Park")
    }
}
