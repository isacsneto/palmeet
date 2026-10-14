import Foundation
import SessionKit
import Testing
@testable import TranscriptKit

/// Words "spoken" from `start`, 0.4 s each.
private func words(_ text: String, from start: TimeInterval) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { index, word in
        TranscriptWord(text: String(word), start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.35)
    }
}

private func caption(_ id: String, _ name: String, _ text: String, _ first: TimeInterval, _ last: TimeInterval) -> MeetingSpeakerTimeline.Caption {
    .init(id: id, name: name, text: text, firstSeen: first, lastSeen: last)
}

private func voice(_ index: Int, seconds: Double = 60) -> SpeakerVoice {
    SpeakerVoice(vector: Voiceprint.normalized((0..<8).map { $0 == index ? 1 : 0.1 })!, seconds: seconds)
}

private func assemble(
    _ them: [TranscriptWord],
    spans: [DiarizedSpan],
    timeline: MeetingSpeakerTimeline? = nil,
    voiceprints: [String: [Float]] = [:],
    known: [VoiceProfile] = []
) -> TranscriptAssembler.Output {
    TranscriptAssembler.assembleDetailed(
        sessionID: SessionID(),
        input: .init(themWords: them, meWords: [], diarization: spans, micRouting: nil, meName: "Isac",
                     timeline: timeline, voiceprints: voiceprints, knownVoices: known)
    )
}

/// "Who said it" for every line, e.g. ["Alice: good morning everyone", …].
private func lines(_ transcript: Transcript) -> [String] {
    transcript.segments.map { "\(transcript.displayName(for: $0.speakerID)): \($0.text)" }
}

@Suite struct SpeakerAttributionTests {
    let alice = "Good morning everyone the deployment finished last night without problems"
    let bob = "Great news I will tell the support team to watch the dashboards today"
    /// About 20 s of speech: enough for a reliable voiceprint or indicator vote.
    let aliceLong = "Good morning everyone the deployment finished last night without problems and the error rate stayed flat all night so I think we can call the migration done and move on to the reporting work next"
    let bobLong = "Great news I will tell the support team to watch the dashboards today and I will ask them to report anything unusual in the channel before lunch so we can react quickly if something breaks"

    @Test func captionsSplitPeopleTheDiarizerLumpedTogether() {
        // One voice cluster for both (the diarizer couldn't tell them apart on the compressed call audio).
        let them = words(alice, from: 0) + words(bob, from: 6)
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Alice Smith", alice, 1, 5.5),
            caption("c2", "Bob Jones", bob, 7, 11.5),
        ])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 12)], timeline: timeline)
        #expect(lines(output.transcript) == ["Alice Smith: \(alice)", "Bob Jones: \(bob)"])
        #expect(output.transcript.speakers.map(\.nameSource) == ["meeting", "meeting"])
        #expect(Set(output.transcript.segments.map(\.speakerID)).count == 2)
    }

    @Test func captionsMergeOnePersonTheDiarizerSplit() {
        let them = words(alice, from: 0) + words(bob, from: 6) + words("And the database migration is scheduled for Thursday afternoon", from: 12)
        let spans = [
            DiarizedSpan(speakerKey: "A", start: 0, end: 5.6),
            DiarizedSpan(speakerKey: "B", start: 6, end: 11.6),
            DiarizedSpan(speakerKey: "C", start: 12, end: 16),  // Alice again, as a "new" voice
        ]
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Alice Smith", alice, 1, 5.5),
            caption("c2", "Bob Jones", bob, 7, 11.5),
            caption("c3", "Alice Smith", "and the database migration is scheduled for Thursday afternoon", 13, 16),
        ])
        let output = assemble(them, spans: spans, timeline: timeline, voiceprints: ["A": voice(0).vector, "B": voice(1).vector, "C": voice(2).vector])
        #expect(output.transcript.speakers.map(\.displayName) == ["Alice Smith", "Bob Jones"])
        let aliceIDs = Set(output.transcript.segments.filter { $0.text.contains("morning") || $0.text.contains("Thursday") }.map(\.speakerID))
        #expect(aliceIDs == ["S1"], "both of Alice's clusters became one speaker")
        // The merged speaker's voiceprint combines both clusters.
        #expect(output.voices.keys.sorted() == ["S1", "S2"])
        #expect(output.learnableVoices == ["S1", "S2"])
    }

    @Test func alignmentToleratesRecognitionDifferencesAndLag() {
        // Our recognizer misheard two words and dropped one; the caption arrived 2 s late and was refined.
        let heard = "Good morning every one the deployment finish last night without problem"
        let them = words("so", from: 0) + words(heard, from: 1) + words(bob, from: 8)
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Alice Smith", alice, 3, 7.5),
            caption("c2", "Bob Jones", bob, 9.5, 14),
        ])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 14)], timeline: timeline)
        let byName = Dictionary(grouping: output.transcript.segments, by: { output.transcript.displayName(for: $0.speakerID) })
        #expect(byName["Alice Smith"]?.map(\.text).joined(separator: " ") == heard)
        #expect(byName["Bob Jones"]?.map(\.text).joined(separator: " ") == bob)
    }

    @Test func shortRepliesTakeTheNearestMatch() {
        // "yes" appears twice; only the second one is Bob's (his caption appeared right after it).
        let them = words("Do you agree with the plan yes I mean the general plan", from: 0) + words("yes", from: 6)
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Alice Smith", "do you agree with the plan yes I mean the general plan", 1, 5),
            caption("c2", "Bob Jones", "Yes.", 7, 7),
        ])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 7)], timeline: timeline)
        #expect(lines(output.transcript) == ["Alice Smith: Do you agree with the plan yes I mean the general plan", "Bob Jones: yes"])
    }

    @Test func theUsersOwnCaptionsNeverLabelRemoteWords() {
        // Bob says "okay sounds good" right after the user said the same (heard on the mic track).
        let them = words(bob, from: 0) + words("okay sounds good", from: 9)
        let mine = words("okay sounds good", from: 7.5)
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Bob Jones", bob, 1, 5.5),
            caption("c2", "Isac Santos", "Okay, sounds good.", 8.5, 9),
        ])
        let output = TranscriptAssembler.assembleDetailed(
            sessionID: SessionID(),
            input: .init(themWords: them, meWords: mine, diarization: [DiarizedSpan(speakerKey: "A", start: 0, end: 11)], micRouting: nil, meName: "Isac", timeline: timeline)
        )
        #expect(!output.transcript.speakers.contains { $0.displayName == "Isac Santos" })
    }

    @Test func captionsOfWordsWeNeverHeardChangeNothing() {
        // The user's own captions (their voice isn't on the remote track) and unrelated text.
        let them = words(bob, from: 0)
        let timeline = MeetingSpeakerTimeline(captions: [
            caption("c1", "Isac Santos", "I think we should postpone the release by one week", 1, 4),
            caption("c2", "Isac Santos", "the", 2, 2),
        ])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 6)], timeline: timeline)
        #expect(output.transcript.speakers.map(\.displayName) == ["Speaker 1"])
        #expect(output.transcript.speakers.first?.nameSource == nil)
    }

    @Test func speakingIndicatorsNameClustersWithoutCaptions() {
        let them = words(aliceLong, from: 0) + words(bobLong, from: 20)
        let timeline = MeetingSpeakerTimeline(speaking: [
            .init(name: "Alice Smith", start: 0.2, end: 19.9),
            .init(name: "Bob Jones", start: 20.2, end: 40),
        ])
        let spans = [DiarizedSpan(speakerKey: "A", start: 0, end: 19.6), DiarizedSpan(speakerKey: "B", start: 20, end: 39.6)]
        let output = assemble(them, spans: spans, timeline: timeline)
        #expect(lines(output.transcript) == ["Alice Smith: \(aliceLong)", "Bob Jones: \(bobLong)"])
        // A few words under an indicator aren't enough to name a whole voice.
        let brief = assemble(words(alice, from: 0), spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 5.6)],
                             timeline: MeetingSpeakerTimeline(speaking: [.init(name: "Alice Smith", start: 0, end: 2)]))
        #expect(brief.transcript.speakers.map(\.displayName) == ["Speaker 1"])
    }

    @Test func overlappingIndicatorsAreNotTrusted() {
        let them = words(alice, from: 0)
        let timeline = MeetingSpeakerTimeline(speaking: [
            .init(name: "Alice Smith", start: 0, end: 6),
            .init(name: "Bob Jones", start: 0, end: 6),
        ])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 6)], timeline: timeline)
        #expect(output.transcript.speakers.map(\.displayName) == ["Speaker 1"])
    }

    @Test func knownVoicesNameSpeakers() {
        let them = words(aliceLong, from: 0) + words(bobLong, from: 20)
        let spans = [DiarizedSpan(speakerKey: "A", start: 0, end: 19.6), DiarizedSpan(speakerKey: "B", start: 20, end: 39.6)]
        let known = [
            VoiceProfile(name: "Alice Smith", samples: [.init(vector: voice(0).vector, seconds: 60, sessionID: "old")]),
            VoiceProfile(name: "Carol White", samples: [.init(vector: voice(5).vector, seconds: 60, sessionID: "old")]),
        ]
        // Bob's voice is unknown; his cluster stays numbered.
        let output = TranscriptAssembler.assembleDetailed(
            sessionID: SessionID(),
            input: .init(themWords: them, meWords: [], diarization: spans, micRouting: nil, meName: "Isac",
                         voiceprints: ["A": voice(0).vector, "B": voice(1).vector], knownVoices: known),
            attribution: .init()
        )
        #expect(output.transcript.speakers.map(\.displayName) == ["Alice Smith", "Speaker 2"])
        #expect(output.transcript.speakers.first?.nameSource == "voice")
        #expect(output.learnableVoices.isEmpty, "voice matches aren't fed back into the library")
    }

    @Test func voiceMatchingNeedsEnoughSpeechAndAClearWinner() {
        let alike = Voiceprint.normalized((0..<8).map { $0 == 0 ? 1 : ($0 == 1 ? 0.9 : 0.1) })!
        let profiles = [
            VoiceProfile(name: "Alice", samples: [.init(vector: voice(0).vector, seconds: 60, sessionID: "a")]),
            VoiceProfile(name: "Twin", samples: [.init(vector: voice(1).vector, seconds: 60, sessionID: "a")]),
        ]
        // Equally close to two people: no guess.
        #expect(VoiceMatcher.match(["S1": SpeakerVoice(vector: alike, seconds: 60)], against: profiles).isEmpty)
        // Too little speech to be sure.
        #expect(VoiceMatcher.match(["S1": voice(0, seconds: 3)], against: profiles).isEmpty)
        // Clear match.
        #expect(VoiceMatcher.match(["S1": voice(0)], against: profiles).map(\.name) == ["Alice"])
        // Nobody known.
        #expect(VoiceMatcher.match(["S1": voice(4)], against: profiles).isEmpty)
    }

    @Test func clustersWithTheSameKnownVoiceMerge() {
        let them = words(aliceLong, from: 0) + words(bobLong, from: 20)
        let spans = [DiarizedSpan(speakerKey: "A", start: 0, end: 19.6), DiarizedSpan(speakerKey: "B", start: 20, end: 39.6)]
        let known = [VoiceProfile(name: "Alice Smith", samples: [.init(vector: voice(0).vector, seconds: 60, sessionID: "old")])]
        let nearlyAlice = Voiceprint.normalized((0..<8).map { $0 == 0 ? 1 : ($0 == 3 ? 0.3 : 0.1) })!
        let output = assemble(them, spans: spans, voiceprints: ["A": voice(0).vector, "B": nearlyAlice], known: known)
        #expect(output.transcript.speakers.map(\.displayName) == ["Alice Smith"])
        #expect(Set(output.transcript.segments.map(\.speakerID)) == ["S1"], "one speaker once merged")
    }

    @Test func meetingNamesWinOverVoiceNames() {
        let them = words(alice, from: 0)
        let known = [VoiceProfile(name: "Someone Else", samples: [.init(vector: voice(0).vector, seconds: 60, sessionID: "old")])]
        let timeline = MeetingSpeakerTimeline(captions: [caption("c1", "Alice Smith", alice, 1, 5.5)])
        let output = assemble(them, spans: [DiarizedSpan(speakerKey: "A", start: 0, end: 5.6)], timeline: timeline,
                              voiceprints: ["A": voice(0).vector], known: known)
        #expect(output.transcript.speakers.map(\.displayName) == ["Alice Smith"])
        #expect(output.transcript.speakers.first?.nameSource == "meeting")
    }

    @Test func withoutSignalsTheTranscriptIsUnchanged() {
        let them = words(alice, from: 0) + words(bob, from: 6)
        let spans = [DiarizedSpan(speakerKey: "x", start: 0, end: 5.6), DiarizedSpan(speakerKey: "y", start: 6, end: 11.6)]
        let plain = TranscriptAssembler.assemble(
            sessionID: SessionID(), input: .init(themWords: them, meWords: [], diarization: spans, micRouting: nil, meName: "Isac")
        )
        #expect(lines(plain) == ["Speaker 1: \(alice)", "Speaker 2: \(bob)"])
        #expect(plain.speakers.map(\.id) == ["S1", "S2"])
    }

    @Test func densestRunDropsStrayMatches() {
        #expect(SpeakerAttribution.densestRun([0, 1, 20, 21, 22, 23, 40]) == [20, 21, 22, 23])
        #expect(SpeakerAttribution.densestRun([]) == [])
        #expect(SpeakerAttribution.similar("deployment", "deploymant"))
        #expect(!SpeakerAttribution.similar("the", "she"))
    }
}

@Suite struct MeetingSpeakerTimelineTests {
    @Test func captionsUpdateInPlaceAndSpeakingBecomesSpans() {
        var timeline = MeetingSpeakerTimeline()
        timeline.recordCaption(id: "1", name: "Ana", text: "Good", at: 10)
        timeline.recordCaption(id: "1", name: "Ana", text: "Good morning all", at: 12)
        timeline.recordCaption(id: "2", name: nil, text: "unnamed", at: 12)
        timeline.recordCaption(id: "3", name: "  ", text: "blank name", at: 12)
        #expect(timeline.captions == [.init(id: "1", name: "Ana", text: "Good morning all", firstSeen: 10, lastSeen: 12)])

        timeline.recordSpeaking(["Ana"], at: 10)
        timeline.recordSpeaking(["Ana", "Bo"], at: 11)
        timeline.recordSpeaking(["Bo"], at: 13)
        timeline.recordSpeaking(nil, at: 15)
        timeline.recordSpeaking(["Ana"], at: 20)
        timeline.finish(at: 21)
        #expect(timeline.speaking == [
            .init(name: "Ana", start: 10, end: 13),
            .init(name: "Bo", start: 11, end: 15),
            .init(name: "Ana", start: 20, end: 21),
        ])
        #expect(timeline.names.first == "Ana")
    }
}

@Suite struct VoiceProfileStoreTests {
    @Test func learnsRenamesForgetsAndCapsSamples() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "palmeet-voices-\(UUID().uuidString)/Voices.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = VoiceProfileStore(url: url)
        store.maxSamples = 3
        #expect(store.load().isEmpty)

        let v = voice(0)
        try store.learn(name: "Maria", voice: v, sessionID: "m1")
        try store.learn(name: "maria", voice: v, sessionID: "m1")  // same meeting again: replaced, not added
        #expect(store.load().map(\.samples.count) == [1])
        #expect(store.load().first?.name == "Maria", "names match case-insensitively")

        // The user corrects the name for that meeting: the sample moves.
        try store.learn(name: "Mariana", voice: v, sessionID: "m1")
        #expect(store.load().map(\.name) == ["Mariana"])

        for meeting in ["m2", "m3", "m4"] { try store.learn(name: "Mariana", voice: voice(0, seconds: 30), sessionID: meeting) }
        #expect(store.load().first?.samples.map(\.sessionID) == ["m2", "m3", "m4"], "oldest samples are dropped")
        #expect(store.load().first?.meetingCount == 3)

        let id = try #require(store.load().first?.id)
        try store.rename(id, to: "Mariana Costa")
        #expect(store.load().first?.name == "Mariana Costa")
        try store.learn(name: "Bob", voice: voice(1), sessionID: "m2")
        try store.delete(id)
        #expect(store.load().map(\.name) == ["Bob"])
        try store.forget(voice: voice(1), sessionID: "m2")
        #expect(store.load().isEmpty)
        try store.learn(name: "Bob", voice: voice(1), sessionID: "m5")
        try store.deleteAll()
        #expect(store.load().isEmpty)

        // Only the owner can read the file.
        try store.learn(name: "Bob", voice: voice(1), sessionID: "m6")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func voiceprintMath() {
        #expect(Voiceprint.normalized([0, 0]) == nil)
        #expect(abs(Voiceprint.similarity([1, 0], [1, 0]) - 1) < 1e-6)
        #expect(abs(Voiceprint.similarity([1, 0], [0, 1])) < 1e-6)
        #expect(Voiceprint.similarity([1], [1, 0]) == 0)
        let mean = Voiceprint.mean([([1, 0], 3), ([0, 1], 1)])!
        #expect(mean[0] > mean[1])
    }
}
