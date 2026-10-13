import Foundation
import Testing
@testable import SessionKit

@Suite struct TimecodeTests {
    @Test func formatsAndParses() {
        #expect(Timecode.format(0) == "00:00:00")
        #expect(Timecode.format(3_725.9) == "01:02:05")
        #expect(Timecode.parse("[01:02:05]") == 3_725)
        #expect(Timecode.parse("02:05") == 125)
        #expect(Timecode.parse("abc") == nil)
    }
}

@Suite struct TranscriptTests {
    func sample() -> Transcript {
        Transcript(
            sessionID: SessionID(),
            speakers: [.me(named: "Isac"), Speaker(id: "S1", displayName: "Speaker 1")],
            segments: [
                TranscriptSegment(speakerID: "S1", track: .them, start: 1, end: 3, text: "Can we ship Friday?"),
                TranscriptSegment(speakerID: "me", track: .me, start: 4, end: 6, text: "If QA signs off."),
                TranscriptSegment(speakerID: "S1", track: .them, start: 7, end: 8, text: "Great."),
            ]
        )
    }

    @Test func renameUpdatesDisplayNames() {
        var transcript = sample()
        let renamed = transcript.renameSpeaker("S1", to: "Maria")
        #expect(renamed)
        #expect(transcript.displayName(for: "S1") == "Maria")
        #expect(transcript.plainText().contains("[00:00:01] Maria: Can we ship Friday?"))
        let missing = transcript.renameSpeaker("S9", to: "Nobody")
        #expect(!missing)
    }

    @Test func reassignCreatesSpeaker() {
        var transcript = sample()
        let id = transcript.segments[2].id
        transcript.reassign(segment: id, to: "S2", displayName: "John")
        #expect(transcript.segments[2].speakerID == "S2")
        #expect(transcript.segments[2].isEdited)
        #expect(transcript.speaker("S2")?.displayName == "John")
    }

    @Test func markdownGroupsConsecutiveSpeakerLines() {
        var transcript = sample()
        transcript.segments.append(TranscriptSegment(speakerID: "S1", track: .them, start: 8.5, end: 9, text: "Thanks!"))
        let metadata = SessionMetadata(title: "Sync", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let markdown = TranscriptMarkdownRenderer.render(transcript, metadata: metadata)
        #expect(markdown.hasPrefix("# Transcript — Sync"))
        #expect(markdown.contains("**[00:00:07] Speaker 1:** Great. Thanks!"))
        #expect(markdown.contains("Isac (me)"))
    }
}

@Suite struct SummaryTests {
    @Test func decodesPartialModelOutput() throws {
        let json = #"{"title":"Roadmap","tldr":"We moved the beta.","action_items":[{"owner":"John","task":"Update checklist","ref":"00:40:12"}]}"#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.title == "Roadmap")
        #expect(summary.actionItems.first?.owner == "John")
        #expect(summary.decisions.isEmpty)
    }

    @Test func rendersActionTableAndEscapesPipes() {
        let summary = MeetingSummary(
            title: "Roadmap", tldr: "Short.",
            decisions: [.init(text: "Ship Nov 4", ref: "00:21:05")],
            actionItems: [.init(owner: "John", task: "Fix A | B", due: nil, ref: "00:40:12")]
        )
        let metadata = SessionMetadata(title: "Roadmap", source: CaptureSourceDescriptor(kind: .window, appName: "Teams"), isolation: .processTap)
        let md = SummaryMarkdownRenderer.render(summary, metadata: metadata, transcript: Transcript(sessionID: metadata.id))
        #expect(md.contains("- Ship Nov 4 [00:21:05]"))
        #expect(md.contains("| John | Fix A \\| B | — | 00:40:12 |"))
        #expect(md.contains("[transcript.md](transcript.md)"))
    }
}

@Suite struct SessionStoreTests {
    @Test func roundTripsAndListsSessions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "palmeet-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootURL: root)
        let metadata = SessionMetadata(title: "Weekly: sync/review", source: CaptureSourceDescriptor(kind: .window, appName: "Zoom"), isolation: .processTap)
        let folder = try store.createFolder(for: metadata)
        #expect(folder.url.lastPathComponent.hasSuffix("Weekly sync review"))
        #expect(FileManager.default.fileExists(atPath: folder.audioDirectory.path))

        let second = try store.createFolder(for: metadata)
        #expect(second.url != folder.url)

        let transcript = Transcript(sessionID: metadata.id, speakers: [.me(named: "Isac")], segments: [
            TranscriptSegment(speakerID: "me", track: .me, start: 0, end: 1, text: "Hello"),
        ])
        try store.save(transcript, metadata: metadata, in: folder)
        #expect(try store.loadTranscript(in: folder) == transcript)
        #expect(store.listSessions().count == 2)
    }

    @Test func screenshotPaths() {
        #expect(SessionFolder.screenshotRelativePath(index: 7, offset: 720) == "screenshots/0007_00-12-00.jpg")
    }

    @Test func micRouteSpan() {
        let open = MicRouteSpan(start: 10)
        #expect(open.contains(10) && open.contains(1_000) && !open.contains(9.9))
        let closed = MicRouteSpan(start: 10, end: 20)
        #expect(closed.contains(19.9) && !closed.contains(20))
    }
}

@Suite struct LenientSummaryDecodingTests {
    @Test func acceptsBareStringsNumbersAndSkipsGarbage() throws {
        let json = #"""
        {"title": "Sync", "tldr": "Short",
         "decisions": ["Ship v2", {"text": "Freeze API", "ref": 125}, 42],
         "action_items": [{"owner": "John", "task": "Book review", "due": null}, "Update checklist", {"owner": "x"}],
         "topics": [{"title": "Roadmap"}, "Hiring"],
         "key_takeaways": ["One", {"text": "Two"}, {"weird": true}],
         "participants": ["Maria", {"name": "John", "role": 7}],
         "notable_quotes": [{"speaker": "Maria", "quote": "Ship it"}]}
        """#
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(json.utf8))
        #expect(summary.decisions.map(\.text) == ["Ship v2", "Freeze API"])
        #expect(summary.decisions[1].ref == "125")
        #expect(summary.actionItems.map(\.task) == ["Book review", "Update checklist"])
        #expect(summary.topics.map(\.title) == ["Roadmap", "Hiring"])
        #expect(summary.keyTakeaways == ["One", "Two"])
        #expect(summary.participants.map(\.name) == ["Maria", "John"])
        #expect(summary.participants[1].role == "7")
        #expect(summary.notableQuotes.count == 1)
    }

    @Test func renameWalksTextFieldsIncludingAfterNewlines() {
        let summary = MeetingSummary(title: "Sync", tldr: "Intro.\nSpeaker 1 agreed; Speaker 12 did not.", actionItems: [.init(owner: "Speaker 1", task: "Ship")])
        let renamed = summary.replacingName("Speaker 1", with: "Maria \\ Silva $1")
        #expect(renamed.tldr == "Intro.\nMaria \\ Silva $1 agreed; Speaker 12 did not.")
        #expect(renamed.actionItems.first?.owner == "Maria \\ Silva $1")
        #expect(summary.replacingName("", with: "x") == summary)
    }
}
