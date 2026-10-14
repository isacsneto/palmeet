import Foundation
import SessionKit
import Testing
import TranscriptKit
@testable import PalMeetCore

/// Reprocesses copies of real recorded sessions with the real on-device models (the originals are never touched)
/// and checks voice learning on them: a voice named in one meeting is recognized when that meeting is processed
/// again, and is not given to the people of a different meeting.
/// Run with: PALMEET_SESSION_DIRS="<session folder>:<other session folder>" swift test --filter RealSessionTests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PALMEET_SESSION_DIRS"] != nil))
struct RealSessionTests {
    @Test(.timeLimit(.minutes(30))) func voicesLearnedInOneMeetingAreRecognizedOnlyWhereTheyBelong() async throws {
        let sources = ProcessInfo.processInfo.environment["PALMEET_SESSION_DIRS"]!.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let h = Harness(asr: ParakeetEngine(model: .ultra), diarizer: OfflineSpeakerDiarizer())
        defer { h.cleanup() }
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        for source in sources {
            try FileManager.default.copyItem(at: source, to: h.root.appending(path: source.lastPathComponent))
        }
        h.manager.refreshLibrary()
        let sessions = sources.compactMap { source in h.manager.library.first { $0.folder.url.lastPathComponent == source.lastPathComponent } }
        try #require(sessions.count == sources.count)

        func describe(_ session: MeetingSession) -> String {
            guard let transcript = session.transcript else { return "no transcript" }
            var seconds: [String: Double] = [:]
            for segment in transcript.segments { seconds[segment.speakerID, default: 0] += segment.end - segment.start }
            return transcript.speakers.map { "\($0.id)=\($0.displayName)[\($0.nameSource ?? "-")] \(Int(seconds[$0.id] ?? 0))s" }.joined(separator: ", ")
        }

        // 1. Process the first meeting and name its most talkative remote speaker.
        let first = sessions[0]
        await first.reprocess()
        print("first:", describe(first))
        let transcript = try #require(first.transcript)
        var seconds: [String: Double] = [:]
        for segment in transcript.segments where segment.track == .them { seconds[segment.speakerID, default: 0] += segment.end - segment.start }
        let main = try #require(seconds.max { $0.value < $1.value }?.key)
        first.renameSpeaker(main, to: "Test Person")
        #expect(h.manager.voiceProfiles().map(\.name) == ["Test Person"])

        // 2. Processing it again recognizes them by voice.
        await first.reprocess()
        print("first again:", describe(first))
        let recognized = first.transcript?.speakers.filter { $0.displayName == "Test Person" } ?? []
        #expect(recognized.count == 1 && recognized.first?.nameSource == "voice")

        // 3. Other meetings (other people) don't get that name.
        for other in sessions.dropFirst() {
            await other.reprocess()
            print("\(other.title):", describe(other))
            #expect(other.transcript?.speakers.contains { $0.displayName == "Test Person" } == false)
        }
    }
}
