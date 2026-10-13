import Foundation
import SessionKit
import Testing
@testable import TranscriptKit

private func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.4) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { index, word in
        let s = start + Double(index) * step
        return TranscriptWord(text: String(word), start: s, end: s + step * 0.9)
    }
}

@Suite struct TranscriptAssemblerTests {
    @Test func attributesRemoteWordsToDiarizedSpeakersInOrderOfAppearance() {
        let them = words("Hello everyone welcome", from: 0) + words("Thanks Maria I have a question", from: 5)
        let spans = [DiarizedSpan(speakerKey: "7", start: 0, end: 2), DiarizedSpan(speakerKey: "3", start: 4.8, end: 8)]
        let transcript = TranscriptAssembler.assemble(
            sessionID: SessionID(),
            input: .init(themWords: them, meWords: [], diarization: spans, micRouting: nil, meName: "Isac")
        )
        #expect(transcript.segments.map(\.speakerID) == ["S1", "S2"])
        #expect(transcript.segments[0].text == "Hello everyone welcome")
        #expect(transcript.displayName(for: "S2") == "Speaker 2")
        #expect(transcript.displayName(for: "me") == "Isac")
    }

    @Test func meWordsOnlyCountWhileRoutedHere() {
        let me = words("first part", from: 1) + words("second part", from: 20)
        let transcript = TranscriptAssembler.assemble(
            sessionID: SessionID(),
            input: .init(themWords: [], meWords: me, diarization: [], micRouting: [MicRouteSpan(start: 0, end: 10)], meName: "Isac")
        )
        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].text == "first part")
    }

    @Test func dropsMicEchoOfRemoteSpeech() {
        let them = words("the deployment is scheduled for friday morning", from: 0)
        let me = words("deployment is scheduled for friday", from: 0.3)
        let transcript = TranscriptAssembler.assemble(
            sessionID: SessionID(),
            input: .init(themWords: them, meWords: me, diarization: [], micRouting: nil, meName: "Isac")
        )
        #expect(transcript.segments.allSatisfy { $0.track == .them })
        #expect(transcript.speaker("them")?.displayName == "Participants")
    }

    @Test func splitsOnLongPauses() {
        let them = words("one two", from: 0) + words("three four", from: 10)
        let transcript = TranscriptAssembler.assemble(
            sessionID: SessionID(),
            input: .init(themWords: them, meWords: [], diarization: [], micRouting: nil, meName: "Me")
        )
        #expect(transcript.segments.count == 2)
    }
}

@Suite struct UtteranceSegmenterTests {
    private func chunk(_ amplitude: Float, seconds: Double, at offset: TimeInterval) -> PCMChunk {
        let count = Int(seconds * 16_000)
        let samples = (0..<count).map { i in amplitude * sin(Float(i) * 0.3) }
        return PCMChunk(samples: samples, startOffset: offset)
    }

    @Test func cutsUtteranceAfterSilence() {
        var segmenter = UtteranceSegmenter()
        var utterances = segmenter.append(chunk(0.0005, seconds: 1, at: 0))
        utterances += segmenter.append(chunk(0.2, seconds: 2, at: 1))
        #expect(utterances.isEmpty)
        utterances += segmenter.append(chunk(0.0005, seconds: 1, at: 3))
        #expect(utterances.count == 1)
        let utterance = utterances[0]
        #expect(abs(utterance.startOffset - 1) < 0.35)
        #expect(utterance.duration > 2 && utterance.duration < 3.2)
    }

    @Test func forcesCutOnLongMonologue() {
        var segmenter = UtteranceSegmenter()
        let utterances = segmenter.append(chunk(0.2, seconds: 20, at: 0))
        #expect(utterances.count == 1)
        #expect(utterances[0].duration >= 13.9)
        let remainder = segmenter.finish()
        #expect(remainder != nil)
    }

    @Test func ignoresSilence() {
        var segmenter = UtteranceSegmenter()
        #expect(segmenter.append(chunk(0.001, seconds: 5, at: 0)).isEmpty)
        let remainder = segmenter.finish()
        #expect(remainder == nil)
    }
}

@Suite struct ASRSchedulerTests {
    actor Log {
        var order: [Int] = []
        func add(_ value: Int) { order.append(value) }
    }

    @Test func runsLowerPriorityValuesFirst() async throws {
        let scheduler = ASRScheduler()
        let log = Log()
        let gate = Task {
            try await scheduler.run(priority: 5) { try await Task.sleep(for: .milliseconds(150)); await log.add(-1) }
        }
        try await Task.sleep(for: .milliseconds(30))
        async let low: Void = scheduler.run(priority: 100) { await log.add(100) }
        try await Task.sleep(for: .milliseconds(20))
        async let high: Void = scheduler.run(priority: 0) { await log.add(0) }
        _ = try await (gate.value, low, high)
        #expect(await log.order == [-1, 0, 100])
    }
}

@Suite struct SpeakerNameInferenceTests {
    @Test func picksNamesThatAppearWhileTheSpeakerTalks() {
        let transcript = Transcript(sessionID: SessionID(), speakers: [], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 0, end: 30, text: "a"),
            TranscriptSegment(speakerID: "S2", track: .them, start: 30, end: 60, text: "b"),
        ])
        // Gallery name "Everyone Visible" is always there; speaker-view names follow the active speaker.
        let observations = stride(from: 1.0, to: 60, by: 5).map { t in
            SpeakerNameInference.Observation(offset: t, names: ["Everyone Visible", t < 30 ? "Maria Silva" : "John Park"])
        }
        let suggestions = SpeakerNameInference.suggest(transcript: transcript, observations: observations)
        let map = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.speakerID, $0.name) })
        #expect(map == ["S1": "Maria Silva", "S2": "John Park"])
    }
}

@Suite struct TextSimilarityTests {
    @Test func containmentIgnoresCaseAndAccents() {
        #expect(TextSimilarity.containment("Reunião amanhã", in: "a reuniao e amanha") == 1)
        #expect(TextSimilarity.containment("completely different", in: "nothing alike") == 0)
    }
}

@Suite struct SpeakerNameInferenceGreedyTests {
    @Test func speakerGetsNextBestNameWhenBestIsTaken() {
        let transcript = Transcript(sessionID: SessionID(), speakers: [], segments: [
            TranscriptSegment(speakerID: "S1", track: .them, start: 0, end: 30, text: "a"),
            TranscriptSegment(speakerID: "S2", track: .them, start: 30, end: 60, text: "b"),
            TranscriptSegment(speakerID: "S3", track: .them, start: 60, end: 120, text: "c"),
        ])
        // "Maria" shows mostly during S1 but also during S2; S2's own name "John" is weaker. Both should be named.
        var observations: [SpeakerNameInference.Observation] = []
        for t in stride(from: 1.0, to: 30, by: 3) { observations.append(.init(offset: t, names: ["Maria"])) }
        for t in stride(from: 31.0, to: 60, by: 3) { observations.append(.init(offset: t, names: t < 40 ? ["Maria", "John"] : ["John"])) }
        for t in stride(from: 61.0, to: 120, by: 3) { observations.append(.init(offset: t, names: ["Ana"])) }
        let map = Dictionary(uniqueKeysWithValues: SpeakerNameInference.suggest(transcript: transcript, observations: observations).map { ($0.speakerID, $0.name) })
        #expect(map["S1"] == "Maria")
        #expect(map["S2"] == "John")
        #expect(map["S3"] == "Ana")
    }
}
