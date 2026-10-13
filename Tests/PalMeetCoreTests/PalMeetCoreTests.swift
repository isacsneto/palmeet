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

    @Test func prefersScreenChangesAndSpreadsSelection() {
        let shots = (0..<20).map { i in
            ScreenshotRecord(index: i, offset: Double(i * 30), relativePath: "s\(i).jpg", reason: i.isMultiple(of: 2) ? .screenChange : .interval)
        }
        let selected = summarizer.selectScreenshots(shots)
        #expect(selected.count == 4)
        #expect(selected.allSatisfy { $0.reason == .screenChange })
        #expect(selected.first?.index == 0 && (selected.last?.index ?? 0) >= 12)
    }

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

@Suite struct RenameInSummaryTests {
    @Test func replacesWholeNamesOnly() {
        let summary = MeetingSummary(title: "Sync", tldr: "Speaker 1 and Speaker 12 agreed.", actionItems: [.init(owner: "Speaker 1", task: "Book review")])
        let updated = MeetingSession.replacingName("Speaker 1", with: "John \"JP\" Park", in: summary)
        #expect(updated.tldr == "John \"JP\" Park and Speaker 12 agreed.")
        #expect(updated.actionItems.first?.owner == "John \"JP\" Park")
    }
}
