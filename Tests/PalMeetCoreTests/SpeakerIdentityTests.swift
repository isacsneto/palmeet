import BrowserBridge
import Foundation
import SessionKit
import Testing
import TranscriptKit
@testable import PalMeetCore

/// Who said what: names from the meeting's own captions, and voices learned across meetings.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SpeakerIdentityTests {
    /// Records one meeting where `voices` speak in turn for `seconds` each, starting 0.5 s in.
    private func record(_ h: Harness, title: String, voices: [Voice], seconds: Double = 9,
                        during: ((MeetingSession) async throws -> Void)? = nil) async throws -> MeetingSession {
        let remote = FakeRemoteAudio()
        let session = try await h.start(title: title, remote: remote, includeMic: false)
        var audio: [Float] = []
        for voice in voices { audio += voice.samples(seconds: seconds) + silence(1) }
        remote.push(audio, at: 0.5)
        try await during?(session)
        try await Task.sleep(for: .milliseconds(300))
        await h.manager.stop(session)
        #expect(session.stage == .ready)
        return session
    }

    private func speaker(saying word: String, in transcript: Transcript?) -> Speaker? {
        guard let transcript, let id = transcript.segments.first(where: { $0.text.contains(word) })?.speakerID else { return nil }
        return transcript.speaker(id)
    }

    @Test func namingSomeoneTeachesTheirVoiceForTheNextMeeting() async throws {
        let h = Harness()
        defer { h.cleanup() }

        // Meeting 1: the summarizer guesses S1 is "Maria Silva"; guesses are never learned.
        let first = try await record(h, title: "Standup Monday", voices: [.alpha, .bravo])
        #expect(speaker(saying: "alpha", in: first.transcript)?.displayName == "Maria Silva")
        #expect(h.manager.voiceProfiles().isEmpty, "an AI guess doesn't teach a voice")
        #expect(FileManager.default.fileExists(atPath: first.folder.speakerVoicesURL.path))

        // The user names both speakers in Review.
        first.renameSpeaker("S1", to: "Ana Costa")
        first.renameSpeaker("S2", to: "Bruno Lima")
        #expect(h.manager.voiceProfiles().map(\.name) == ["Ana Costa", "Bruno Lima"])

        // Meeting 2, other order: both are recognized by voice, and the summarizer's guess (S1 = "Maria Silva",
        // now Bruno's cluster) doesn't override it.
        let second = try await record(h, title: "Standup Tuesday", voices: [.bravo, .alpha])
        let bruno = try #require(speaker(saying: "bravo", in: second.transcript))
        let ana = try #require(speaker(saying: "alpha", in: second.transcript))
        #expect(bruno.displayName == "Bruno Lima" && bruno.nameSource == "voice")
        #expect(ana.displayName == "Ana Costa" && ana.nameSource == "voice")
        #expect(h.llm.lastSummaryPrompt.contains("Bruno Lima"), "the summary is written with the real names")

        // A wrong recognition fixed by the user moves that meeting's sample to the right person.
        second.renameSpeaker(ana.id, to: "Ana Paula Costa")
        let profiles = h.manager.voiceProfiles()
        #expect(profiles.map(\.name) == ["Ana Costa", "Ana Paula Costa", "Bruno Lima"])
        #expect(profiles.first { $0.name == "Ana Costa" }?.meetingCount == 1)
        #expect(profiles.first { $0.name == "Bruno Lima" }?.meetingCount == 1, "recognitions aren't fed back automatically")
    }

    @Test func voiceRecognitionCanBeTurnedOff() async throws {
        let h = Harness(settings: { $0.recognizeVoices = false })
        defer { h.cleanup() }
        let first = try await record(h, title: "One", voices: [.alpha])
        first.renameSpeaker("S1", to: "Ana Costa")
        #expect(h.manager.voiceProfiles().isEmpty, "nothing learned while off")

        h.manager.updateSettings { $0.recognizeVoices = true }
        let second = try await record(h, title: "Two", voices: [.alpha])
        second.renameSpeaker("S1", to: "Ana Costa")
        #expect(h.manager.voiceProfiles().count == 1)
        h.manager.updateSettings { $0.recognizeVoices = false }
        let third = try await record(h, title: "Three", voices: [.alpha])
        #expect(speaker(saying: "alpha", in: third.transcript)?.nameSource != "voice")

        h.manager.forgetAllVoices()
        #expect(h.manager.voiceProfiles().isEmpty)
    }

    @Test func shortSpeakersAreNotLearned() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await record(h, title: "Quick", voices: [.alpha], seconds: 2)
        session.renameSpeaker("S1", to: "Ana Costa")
        #expect(h.manager.voiceProfiles().isEmpty, "2 s of speech is too little to recognize someone by")
    }

    @Test func meetingCaptionsNameSpeakersAndTeachVoices() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await record(h, title: "Teams call", voices: [.alpha, .bravo]) { session in
            let start = session.clock.startDate
            func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
            // Captions stream while people talk: they grow, then settle.
            session.recordSpeakerActivity(at: at(2), captions: [("c1", "Ana Costa", "alpha alpha alpha")], speaking: ["Ana Costa"])
            session.recordSpeakerActivity(at: at(9), captions: [("c1", "Ana Costa", String(repeating: "alpha ", count: 18))], speaking: ["Ana Costa"])
            session.recordSpeakerActivity(at: at(12), captions: [("c2", "Bruno Lima", "bravo bravo")], speaking: ["Bruno Lima"])
            session.recordSpeakerActivity(at: at(19.5), captions: [("c2", "Bruno Lima", String(repeating: "bravo ", count: 18))], speaking: nil)
        }
        let ana = try #require(speaker(saying: "alpha", in: session.transcript))
        let bruno = try #require(speaker(saying: "bravo", in: session.transcript))
        #expect(ana.displayName == "Ana Costa" && ana.nameSource == "meeting")
        #expect(bruno.displayName == "Bruno Lima" && bruno.nameSource == "meeting")
        #expect(ana.id != bruno.id)

        // Saved with the session, and the voices were learned from the meeting's own labels.
        let saved = try SessionStore.readJSON(MeetingSpeakerTimeline.self, from: session.folder.meetingSpeakersURL)
        #expect(saved.captions.map(\.name) == ["Ana Costa", "Bruno Lima"])
        #expect(saved.speaking.map(\.name) == ["Ana Costa", "Bruno Lima"])
        #expect(h.manager.voiceProfiles().map(\.name) == ["Ana Costa", "Bruno Lima"])

        // Reprocessing from disk gives the same names (the timeline is reloaded with the session).
        await session.reprocess()
        #expect(speaker(saying: "bravo", in: session.transcript)?.displayName == "Bruno Lima")
    }

    @Test func pageActivityIsIgnoredWhilePaused() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(title: "Paused", remote: FakeRemoteAudio(), includeMic: false)
        session.pause()
        session.recordSpeakerActivity(at: Date(), captions: [("c1", "Ana Costa", "secret")], speaking: ["Ana Costa"])
        #expect(session.speakerTimeline.isEmpty)
        session.resume()
        session.recordSpeakerActivity(at: Date(), captions: [("c1", "Ana Costa", "hello")], speaking: nil)
        #expect(session.speakerTimeline.captions.count == 1)
        await h.manager.stop(session)
    }

    /// The whole path: extension → bridge → session → transcript.
    @Test func captionsFromTheExtensionReachTheTranscript() async throws {
        let token = "speaker-bridge-token"
        let h = Harness(settings: { $0.meetingPageDiagnostics = true }, bridgeToken: token)
        defer { h.cleanup() }
        h.manager.start()
        let port = try #require(h.manager.bridgePort)
        let ext = FakeExtension(port: port, profile: "work")
        try await ext.send(#"{"type":"hello","token":"\#(token)","profileInstanceId":"work","profileLabel":"Work","browser":"Chrome","extensionVersion":"0.2.0","role":"control"}"#)
        let welcome = try #require(try await ext.receiveJSON())
        #expect((welcome["options"] as? [String: Any])?["pageDiagnostics"] as? Bool == true, "the app asks for page diagnostics")
        try await ext.send(#"""
        {"type":"windows","windows":[{"windowId":1,"focused":true,"state":"normal","bounds":{"left":0,"top":0,"width":1200,"height":800},"activeTabId":10,
          "tabs":[{"tabId":10,"title":"Daily","url":"https://teams.microsoft.com/v2/","active":true,"audible":true,"isMeeting":true}]}]}
        """#)
        #expect(await waitUntil { h.manager.browserProfiles.first?.windows.isEmpty == false })
        let choice = try #require(h.manager.browserMeetingChoices(windows: []).first)
        let session = try await h.manager.startSession(choice, includeMicrophone: false)
        _ = try await ext.receiveJSON()  // startCapture
        let wire = session.id.uuidString.lowercased()
        try await ext.send(#"{"type":"captureState","sessionId":"\#(wire)","state":"capturing","windowId":1,"tabId":10}"#)

        let t0 = Date().timeIntervalSince1970 * 1000
        try await ext.sendAudio(Voice.alpha.samples(seconds: 9) + silence(1) + Voice.bravo.samples(seconds: 9), session: session.id)
        let alpha = String(repeating: "alpha ", count: 18), bravo = String(repeating: "bravo ", count: 18)
        try await ext.send(#"{"type":"speakerActivity","sessionId":"\#(wire)","at":\#(t0 + 8_000),"captions":[{"id":"p-1","name":"Ana Costa","text":"\#(alpha)"}],"speaking":["Ana Costa"]}"#)
        try await ext.send(#"{"type":"speakerActivity","sessionId":"\#(wire)","at":\#(t0 + 18_500),"captions":[{"id":"p-2","name":"Bruno Lima","text":"\#(bravo)"}],"speaking":null}"#)
        try await ext.send(#"{"type":"pageDiagnostics","sessionId":"\#(wire)","at":\#(t0 + 1_000),"payload":{"top":[{"sig":"div[data-tid=\"voice-level-stream-outline\"]@class","count":42}]}}"#)
        // Another session ID (not this profile's capture) is ignored.
        try await ext.send(#"{"type":"speakerActivity","sessionId":"\#(UUID().uuidString.lowercased())","at":\#(t0),"captions":[{"id":"x","name":"Intruder","text":"alpha"}],"speaking":null}"#)
        #expect(await waitUntil { session.speakerTimeline.captions.count == 2 })
        #expect(session.meetingSpeakerStatus?.contains("Ana Costa") == true)
        try await Task.sleep(for: .milliseconds(300))

        await h.manager.stop(session)
        #expect(speaker(saying: "alpha", in: session.transcript)?.displayName == "Ana Costa")
        #expect(speaker(saying: "bravo", in: session.transcript)?.displayName == "Bruno Lima")
        #expect(!session.speakerTimeline.names.contains("Intruder"))
        let diagnostics = try String(contentsOf: session.folder.pageDiagnosticsURL, encoding: .utf8)
        #expect(diagnostics.contains("voice-level-stream-outline"))
        ext.close()
        await h.manager.shutdown()
    }
}
