@testable import CaptureKit
import CopilotKit
import Foundation
import LLMKit
import SessionKit
import Testing
@testable import PalMeetCore

/// Full session lifecycle with fake capture/ASR/LLM: recording → files → final transcript → summary.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionPipelineTests {
    @Test func recordsTranscribesAndSummarizesOneMeeting() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote)
        #expect(session.stage == .recording)
        #expect(session.isMicRouted, "a single session always gets the mic")
        #expect(h.mic.subscriberCount == 1)

        remote.push(Voice.alpha.samples(seconds: 1.5) + silence(1) + Voice.bravo.samples(seconds: 1.5), at: 0.5)
        await h.mic.pushRealtime(Voice.mike.samples(seconds: 1.2))
        try await Task.sleep(for: .milliseconds(300))

        await h.manager.stop(session)
        #expect(session.stage == .ready)
        #expect(h.mic.subscriberCount == 0, "stopping releases the shared mic")
        #expect(h.manager.activeSessions.isEmpty)
        #expect(h.manager.library.first?.id == session.id)

        let transcript = try #require(session.transcript)
        let them = words(in: transcript, track: .them)
        #expect(them.contains("alpha") && them.contains("bravo"))
        #expect(!them.contains("mike"))
        #expect(words(in: transcript, track: .me).contains("mike"))
        #expect(!words(in: transcript, track: .me).contains("alpha"))

        // Diarization: each voice is its own speaker; the summary named S1.
        let alphaSpeaker = transcript.segments.first { $0.text.contains("alpha") }?.speakerID
        let bravoSpeaker = transcript.segments.first { $0.text.contains("bravo") }?.speakerID
        #expect(alphaSpeaker == "S1" && bravoSpeaker == "S2")
        #expect(transcript.displayName(for: "S1") == "Maria Silva")
        #expect(transcript.displayName(for: "me") == "Isac")

        // Files on disk.
        let folder = session.folder
        for url in [folder.audioURL(for: .them), folder.audioURL(for: .me), folder.transcriptMarkdownURL, folder.transcriptJSONURL, folder.summaryMarkdownURL, folder.summaryJSONURL, folder.metadataURL] {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        let transcriptMD = try String(contentsOf: folder.transcriptMarkdownURL, encoding: .utf8)
        #expect(transcriptMD.contains("Maria Silva:** alpha"))
        let summaryMD = try String(contentsOf: folder.summaryMarkdownURL, encoding: .utf8)
        #expect(summaryMD.contains("# Fake summary — Summary"))
        #expect(summaryMD.contains("| Speaker 1 | Ship it |"))

        let stored = try h.manager.store.loadMetadata(in: folder)
        #expect(stored.status == .ready)
        #expect(stored.endedAt != nil)
        #expect(stored.micRouting.count == 1 && stored.micRouting[0].end != nil)
        #expect(stored.summaryProvider == AppSettings().summaryProvider.rawValue)

        // The summary prompt carried the transcript with speaker IDs.
        #expect(h.llm.lastSummaryPrompt.contains("(S1): alpha"))
        #expect(h.llm.streamCalls.count == 0, "copilot was never turned on")
    }

    @Test func twoMeetingsStayIsolatedAndMicFollowsRouting() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remoteA = FakeRemoteAudio(), remoteB = FakeRemoteAudio()
        let a = try await h.start(title: "Meeting A", bundleID: "us.zoom.xos", pid: 1, remote: remoteA)
        let b = try await h.start(title: "Meeting B", bundleID: "com.microsoft.teams2", pid: 2, remote: remoteB)
        #expect(a.metadata.concurrentWith == [b.id])
        #expect(b.metadata.concurrentWith == [a.id])
        #expect(h.mic.subscriberCount == 2)

        h.manager.setMicOverride(a, routed: true)
        h.manager.setMicOverride(b, routed: false)
        #expect(a.isMicRouted && !b.isMicRouted)

        remoteA.push(Voice.alpha.samples(seconds: 2), at: 0.2)
        remoteB.push(Voice.bravo.samples(seconds: 2), at: 0.2)
        await h.mic.pushRealtime(Voice.mike.samples(seconds: 1.5))

        h.manager.setMicOverride(a, routed: false)
        h.manager.setMicOverride(b, routed: true)
        #expect(!a.isMicRouted && b.isMicRouted)
        await h.mic.pushRealtime(silence(0.3) + Voice.november.samples(seconds: 1.5))
        try await Task.sleep(for: .milliseconds(300))

        let switchOffset = try #require(a.metadata.micRouting.last?.end)
        await h.manager.stop(a)
        await h.manager.stop(b)

        let wordsA = words(in: a.transcript), wordsB = words(in: b.transcript)
        #expect(wordsA.contains("alpha") && wordsA.contains("mike"))
        #expect(!wordsA.contains("bravo") && !wordsA.contains("november"), "A leaked B's audio or my words for B: \(wordsA)")
        #expect(wordsB.contains("bravo") && wordsB.contains("november"))
        #expect(!wordsB.contains("alpha") && !wordsB.contains("mike"), "B leaked A's audio or my words for A: \(wordsB)")

        // Mic audio that belonged to the other meeting was silenced in each meeting's files.
        let meA = try readMono(a.folder.audioURL(for: .me))
        let afterSwitch = meA.dropFirst(Int((switchOffset + 0.2) * 16_000))
        #expect(!afterSwitch.isEmpty && afterSwitch.allSatisfy { $0 == 0 }, "A kept mic audio routed to B")
        #expect(meA.prefix(Int(switchOffset * 16_000)).contains { abs($0) > 0.02 }, "A lost its own mic audio")
        let meB = try readMono(b.folder.audioURL(for: .me))
        let routeStartB = try #require(b.metadata.micRouting.last?.start)
        let beforeB = meB.prefix(Int(routeStartB * 16_000)).dropFirst(Int(0.5 * 16_000))  // B briefly had the mic when it started
        #expect(beforeB.allSatisfy { $0 == 0 }, "B kept mic audio routed to A")
    }

    @Test func keepsUnroutedMicAudioWhenConfigured() async throws {
        let h = Harness { $0.privacy.keepUnroutedMicAudio = true }
        defer { h.cleanup() }
        let a = try await h.start(title: "A", pid: 1)
        let b = try await h.start(title: "B", bundleID: "com.microsoft.teams2", pid: 2)
        h.manager.setMicOverride(a, routed: false)
        h.manager.setMicOverride(b, routed: true)
        await h.mic.pushRealtime(Voice.mike.samples(seconds: 1))
        try await Task.sleep(for: .milliseconds(200))
        await h.manager.stop(a)
        await h.manager.stop(b)
        #expect(try readMono(a.folder.audioURL(for: .me)).contains { abs($0) > 0.02 })
        #expect(!words(in: a.transcript).contains("mike"), "transcript still respects routing")
    }

    @Test func pausedAudioIsDroppedAndPauseIsRecorded() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1), at: 0.1)
        session.pause()
        #expect(session.stage == .paused)
        remote.push(Voice.bravo.samples(seconds: 1), at: 1.5)
        try await Task.sleep(for: .milliseconds(200))
        session.resume()
        #expect(session.stage == .recording)
        remote.push(Voice.alpha.samples(seconds: 1), at: 3)
        await h.manager.stop(session)
        let them = words(in: session.transcript)
        #expect(them.contains("alpha"))
        #expect(!them.contains("bravo"), "audio captured while paused must be dropped")
        #expect(session.metadata.pausedSpans.count == 1 && session.metadata.pausedSpans[0].end != nil)
    }

    @Test func micOnlyAndRemoteOnlySessions() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let micOnly = try await h.start(title: "Voice memo", remote: nil, includeMic: true)
        #expect(micOnly.metadata.isolation == .none)
        await h.mic.pushRealtime(Voice.mike.samples(seconds: 1))
        try await Task.sleep(for: .milliseconds(200))
        await h.manager.stop(micOnly)
        #expect(words(in: micOnly.transcript) .contains("mike"))
        #expect(!FileManager.default.fileExists(atPath: micOnly.folder.audioURL(for: .them).path))

        let remoteOnly = try await h.start(title: "Listen only", includeMic: false)
        #expect(!remoteOnly.isMicRouted)
        await h.manager.stop(remoteOnly)
        #expect(remoteOnly.stage == .ready)
        #expect(remoteOnly.transcript?.segments.isEmpty == true)
    }

    @Test func quitWithoutProcessingThenReprocessFromLibrary() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1), at: 0.2)
        try await Task.sleep(for: .milliseconds(100))

        await h.manager.shutdown()
        #expect(h.manager.activeSessions.isEmpty)
        #expect(session.transcript == nil)
        if case .failed = session.stage {} else { Issue.record("expected a not-yet-transcribed state, got \(session.stage)") }
        #expect(try h.manager.store.loadMetadata(in: session.folder).status == .processing)

        h.manager.refreshLibrary()
        let loaded = try #require(h.manager.library.first { $0.id == session.id })
        if case .failed = loaded.stage {} else { Issue.record("loaded interrupted session should offer reprocessing") }
        await loaded.reprocess()
        #expect(loaded.stage == .ready)
        #expect(words(in: loaded.transcript).contains("alpha"))
        #expect(try h.manager.store.loadMetadata(in: session.folder).status == .ready)
    }

    @Test func summaryFailureKeepsTranscriptAndCanBeRegenerated() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.llm.failSummaries = true
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1), at: 0.2)
        await h.manager.stop(session)
        #expect(session.stage == .ready)
        #expect(session.summary == nil)
        #expect(session.metadata.lastError?.contains("Summary failed") == true)
        #expect(FileManager.default.fileExists(atPath: session.folder.transcriptMarkdownURL.path))
        #expect(!FileManager.default.fileExists(atPath: session.folder.summaryMarkdownURL.path))

        h.llm.failSummaries = false
        await session.summarize(using: .anthropicAPI)
        #expect(session.summary?.title == "Fake summary")
        #expect(session.metadata.lastError == nil)
        #expect(FileManager.default.fileExists(atPath: session.folder.summaryMarkdownURL.path))
    }

    @Test func reviewEditsPersistToDiskAndSummary() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.llm.summaryJSON = #"{"title":"Sync","tldr":"Speaker 2 will ship.","action_items":[{"owner":"Speaker 2","task":"Ship"}]}"#
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1) + silence(2) + Voice.bravo.samples(seconds: 1), at: 0.2)
        await h.manager.stop(session)

        session.renameSpeaker("S2", to: "John Park")
        #expect(session.summary?.tldr == "John Park will ship.")
        #expect(session.summary?.actionItems.first?.owner == "John Park")

        let segment = try #require(session.transcript?.segments.first { $0.speakerID == "S1" })
        session.editSegment(segment.id, text: "alpha corrected")
        session.reassignSegment(segment.id, to: "S2")

        let reloaded = try h.manager.store.loadTranscript(in: session.folder)
        #expect(reloaded.displayName(for: "S2") == "John Park")
        let edited = try #require(reloaded.segments.first { $0.id == segment.id })
        #expect(edited.text == "alpha corrected" && edited.speakerID == "S2" && edited.isEdited)
        let md = try String(contentsOf: session.folder.summaryMarkdownURL, encoding: .utf8)
        #expect(md.contains("John Park will ship."))
        #expect(try String(contentsOf: session.folder.transcriptMarkdownURL, encoding: .utf8).contains("John Park:** alpha corrected"))
    }

    @Test func notesAndMeetingModePersist() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(title: "Backlog refinement – payments", includeMic: false)
        #expect(session.meetingMode == .grooming, "mode guessed from the title")
        session.addNote("Ask about refunds")
        session.addNote("   ")
        session.setMeetingMode(.planning)
        await h.manager.stop(session)
        #expect(h.manager.store.loadNotes(in: session.folder).map(\.text) == ["Ask about refunds"])
        #expect(try h.manager.store.loadMetadata(in: session.folder).meetingMode == "planning")
    }
}

/// The copilot's strict on/off contract, end to end through a session's live transcription.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionCopilotTests {
    @Test func copilotOnlyRunsWhileToggledOn() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)

        // OFF: a question addressed to the user is transcribed live but never reaches an AI provider.
        remote.push(Voice.question.samples(seconds: 1) + silence(1.2), at: 0.2)
        #expect(await waitUntil { session.liveSegments.contains { $0.text.contains("review") } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.llm.streamCalls.count == 0)
        #expect(session.suggestions.isEmpty)

        // ON: the next question produces a suggested answer.
        session.setCopilot(enabled: true)
        #expect(session.copilotEnabled)
        remote.push(Voice.question.samples(seconds: 1) + silence(1.2), at: 3)
        #expect(await waitUntil { session.suggestions.contains { $0.kind == .answer && $0.status == .ready } })
        #expect(h.llm.streamCalls.count == 1)
        let card = try #require(session.suggestions.first { $0.kind == .answer })
        #expect(card.items.first?.text == "Yes, I'll review it today.")
        #expect(card.askedBy == "Participant")

        // OFF again: nothing more is sent.
        session.setCopilot(enabled: false)
        let segmentsBefore = session.liveSegments.count
        remote.push(Voice.question.samples(seconds: 1) + silence(1.2), at: 6)
        #expect(await waitUntil { session.liveSegments.count > segmentsBefore })
        try await Task.sleep(for: .milliseconds(500))
        #expect(h.llm.streamCalls.count == 1)

        // Feedback and persistence.
        session.updateSuggestion(card.id, status: .pinned, feedback: 1)
        await h.manager.stop(session)
        let saved = try SessionStore.readJSON([Suggestion].self, from: session.folder.copilotURL)
        #expect(saved.first?.status == .pinned && saved.first?.feedback == 1)
    }

    @Test func copilotUsesTheLoginWhenNoAPIKeyIsSaved() async throws {
        let h = Harness(apiKeys: [])
        defer { h.cleanup() }
        #expect(h.manager.settings.copilotProvider == .anthropicAPI && h.manager.settings.summaryProvider == .claudeCLI)
        #expect(h.manager.workingCopilotProvider == .claudeCLI, "the chosen login, even before it's checked")
        let session = try await h.start(includeMic: false)
        session.setCopilot(enabled: true)
        #expect(h.requestedProviders.withLock { $0 } == [.claudeCLI])
        #expect(session.copilotConfiguration().model == "haiku", "the login provider's fast model")
        session.setCopilot(enabled: false)
        await h.manager.stop(session)
        #expect(h.requestedProviders.withLock { $0 }.last == .claudeCLI, "and so does the summary")
    }

    @Test func summariesUseAProviderThatWorks() async throws {
        let h = Harness(settings: { $0.summaryProvider = .codexCLI }, apiKeys: [])
        defer { h.cleanup() }
        h.manager.services.providers.record(.codexCLI, ready: false)
        h.manager.services.providers.record(.claudeCLI, ready: true)
        #expect(h.manager.workingSummaryProvider == .claudeCLI)
        let session = try await h.start(includeMic: false)
        await h.manager.stop(session)
        #expect(h.requestedProviders.withLock { $0 }.last == .claudeCLI)
        #expect(session.metadata.summaryProvider == LLMProviderKind.claudeCLI.rawValue)
    }

    @Test func providerFallback() {
        var settings = AppSettings()
        settings.summaryProvider = .codexCLI
        settings.copilotProvider = .anthropicAPI
        let none: (LLMProviderKind) -> Bool? = { $0.needsAPIKey ? false : nil }
        #expect(settings.workingProvider(.anthropicAPI) { _ in true } == .anthropicAPI, "a working choice is used")
        #expect(settings.workingProvider(.codexCLI, ready: none) == .codexCLI, "unchecked CLIs are trusted")
        #expect(settings.workingProvider(.anthropicAPI, ready: none) == .codexCLI, "no key: the other choice, unchecked")
        #expect(settings.workingProvider(.anthropicAPI) { $0 == .geminiCLI ? true : ($0.needsAPIKey ? false : nil) } == .geminiCLI,
                "a provider known to work beats an unchecked one")
        #expect(settings.workingProvider(.codexCLI) { $0 == .openAIAPI } == .openAIAPI)
        #expect(settings.workingProvider(.anthropicAPI) { _ in false } == .anthropicAPI, "nothing works: the choice, whose error says what to set up")
    }

    @Test func helpNowAndAutoEnable() async throws {
        let h = Harness { $0.copilot.autoEnableModes = [.grooming] }
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(title: "Grooming: checkout", remote: remote, includeMic: false)
        #expect(session.copilotEnabled, "auto-enabled for grooming meetings")
        h.llm.copilotReply = "Q|high|What happens offline?|Not covered"
        session.copilotHelpNow()
        #expect(await waitUntil { session.suggestions.contains { $0.kind == .questions && $0.status == .ready } })
        await h.manager.stop(session)
        #expect(!session.copilotEnabled, "stopping the meeting turns the copilot off")
    }

    @Test func copilotCannotStartAfterTheMeetingEnded() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(includeMic: false)
        await h.manager.stop(session)
        session.setCopilot(enabled: true)
        #expect(!session.copilotEnabled)
    }
}

/// SessionManager policies: limits, conflicts, mic routing.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionManagerPolicyTests {
    func window(_ id: UInt32, app: String, bundle: String, pid: Int32) -> CapturableWindow {
        CapturableWindow(id: id, title: "\(app) window", appName: app, bundleID: bundle, pid: pid, frame: CGRect(x: 0, y: 0, width: 800, height: 600), isOnScreen: true)
    }

    @Test func enforcesMaxConcurrentSessions() async throws {
        let h = Harness { $0.maxConcurrentSessions = 1 }
        defer { h.cleanup() }
        let first = try await h.start(includeMic: false)
        await #expect(throws: SessionError.self) { try await h.start(title: "Second", pid: 9, includeMic: false) }
        await h.manager.stop(first)
    }

    @Test func isolationPreviewDetectsConflicts() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let zoom = try await h.start(bundleID: "us.zoom.xos", pid: 100, includeMic: false)
        let chromeSource = CaptureSourceDescriptor(kind: .window, appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 200)
        let chrome = try await h.manager.startSession(id: SessionID(), source: chromeSource, title: "Meet", remote: FakeRemoteAudio(), windowID: nil, frames: nil, includeMicrophone: false, preview: .isolated("test"))

        let anotherZoom = h.manager.isolationPreview(for: .window(window(1, app: "Zoom", bundle: "us.zoom.xos", pid: 101)))
        #expect(anotherZoom == .shared(conflictsWith: zoom.title))
        if case .needsExtension = h.manager.isolationPreview(for: .window(window(2, app: "Google Chrome", bundle: "com.google.Chrome", pid: 200))) {} else {
            Issue.record("second Chrome window should require the extension")
        }
        if case .isolated = h.manager.isolationPreview(for: .window(window(3, app: "Microsoft Teams", bundle: "com.microsoft.teams2", pid: 300))) {} else {
            Issue.record("a different app is isolated")
        }
        await h.manager.stop(zoom)
        await h.manager.stop(chrome)
    }

    /// Recording a Meet in a way that can't see its mute button, while talking in a Teams call that isn't recorded.
    @Test func talkingInAnotherCallKeepsYourMicOutOfThisMeeting() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let meet = try await h.start(title: "Meet", bundleID: "com.google.Chrome", pid: 1)
        #expect(meet.knownMuted == nil)
        h.manager.updateMicRouting()
        #expect(meet.isMicRouted, "nothing else going on: your mic is for this meeting")

        h.manager.otherCalls = [OtherCall(appName: "Microsoft Teams", muted: false)]
        h.manager.updateMicRouting()
        #expect(!meet.isMicRouted, "unmuted in Teams: you're talking there")
        #expect(meet.otherCallUsingMic?.appName == "Microsoft Teams")

        h.manager.otherCalls = [OtherCall(appName: "Microsoft Teams", muted: true)]
        h.manager.updateMicRouting()
        #expect(meet.isMicRouted, "muted in Teams: you're talking here")

        h.manager.otherCalls = [OtherCall(appName: "Microsoft Teams", muted: false)]
        meet.knownMuted = false
        h.manager.updateMicRouting()
        #expect(meet.isMicRouted, "unmuted in this meeting too: they hear you, so it's recorded")
        #expect(meet.otherCallUsingMic == nil)

        meet.knownMuted = nil
        h.manager.setMicOverride(meet, routed: true)
        #expect(meet.isMicRouted, "“On” always wins")

        // Two meetings that can't see their mute buttons, while you talk in Teams: neither gets your voice.
        h.manager.setMicOverride(meet, routed: nil)
        let other = try await h.start(title: "Other", bundleID: "us.zoom.xos", pid: 2)
        h.manager.updateMicRouting()
        #expect(!meet.isMicRouted && !other.isMicRouted)
        await h.manager.stop(other)
        await h.manager.stop(meet)
        let spans = meet.metadata.micRouting
        #expect(!spans.isEmpty && spans.allSatisfy { $0.end != nil })
    }

    @Test func micRoutingFollowsMuteStateAndCycling() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let a = try await h.start(title: "A", pid: 1)
        let b = try await h.start(title: "B", bundleID: "com.microsoft.teams2", pid: 2)

        a.knownMuted = true
        b.knownMuted = false
        h.manager.updateMicRouting()
        #expect(!a.isMicRouted && b.isMicRouted, "the unmuted meeting gets the mic")

        a.knownMuted = false
        b.knownMuted = true
        h.manager.updateMicRouting()
        #expect(a.isMicRouted && !b.isMicRouted)

        // Manual cycling: A → B → all → A …
        h.manager.cycleMicRouting()
        #expect(!a.isMicRouted && b.isMicRouted)
        h.manager.cycleMicRouting()
        #expect(a.isMicRouted && b.isMicRouted)
        h.manager.cycleMicRouting()
        #expect(a.isMicRouted && !b.isMicRouted)

        // Clearing overrides returns to automatic routing.
        h.manager.setMicOverride(a, routed: nil)
        h.manager.setMicOverride(b, routed: nil)
        #expect(a.isMicRouted && !b.isMicRouted)

        // Routing spans are well formed: alternating open/close, last one open while routed.
        #expect(a.metadata.micRouting.dropLast().allSatisfy { $0.end != nil })
        await h.manager.stop(a)
        await h.manager.stop(b)
        for session in [a, b] {
            #expect(session.metadata.micRouting.allSatisfy { $0.end != nil }, "stopping closes every span")
            let spans = session.metadata.micRouting
            #expect(zip(spans, spans.dropFirst()).allSatisfy { ($0.end ?? 0) <= $1.start })
        }
    }

    @Test func singleSessionCanBeManuallyUnrouted() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start()
        #expect(session.isMicRouted)
        h.manager.setMicOverride(session, routed: false)
        #expect(!session.isMicRouted)
        await h.mic.pushRealtime(Voice.mike.samples(seconds: 1))
        await h.manager.stop(session)
        #expect(!words(in: session.transcript).contains("mike"))
    }

    @Test func duplicateWindowIsRejected() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let source = CaptureSourceDescriptor(kind: .window, appName: "Zoom", bundleID: "us.zoom.xos", processID: 1, windowID: 77)
        let first = try await h.manager.startSession(id: SessionID(), source: source, title: "Z", remote: FakeRemoteAudio(), windowID: nil, frames: nil, includeMicrophone: false, preview: .isolated(""))
        await #expect(throws: SessionError.self) {
            try await h.manager.startSession(.window(window(77, app: "Zoom", bundle: "us.zoom.xos", pid: 1)))
        }
        await h.manager.stop(first)
    }

    @Test func libraryListsFinishedSessionsOnce() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let one = try await h.start(title: "One", includeMic: false)
        await h.manager.stop(one)
        let two = try await h.start(title: "Two", pid: 5, includeMic: false)
        await h.manager.stop(two)
        h.manager.refreshLibrary()
        h.manager.refreshLibrary()
        #expect(h.manager.library.count == 2)
        #expect(Set(h.manager.library.map(\.id)) == [one.id, two.id])
        h.manager.deleteFromLibrary(one)
        #expect(h.manager.library.map(\.id) == [two.id])
    }

    @Test func retentionDeletesOldAudioButKeepsText() async throws {
        let h = Harness { $0.privacy.deleteAudioAfterDays = 7 }
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1), at: 0.1)
        await h.manager.stop(session)
        var metadata = session.metadata
        metadata.createdAt = Date().addingTimeInterval(-10 * 86_400)
        try h.manager.store.save(metadata, in: session.folder)

        // An imported video carries its own (old) date but was saved just now: its audio stays.
        let relaunched = Harness(root: h.root) { $0.privacy.deleteAudioAfterDays = 7 }
        relaunched.manager.refreshLibrary()
        relaunched.manager.applyRetentionPolicy()
        #expect(FileManager.default.fileExists(atPath: session.folder.audioDirectory.path), "age counts from when PalMeet saved it")

        // Saved 10 days ago: a fresh app launch reads the library from disk and deletes the audio.
        var folderURL = session.folder.url
        var values = URLResourceValues()
        values.creationDate = metadata.createdAt
        try folderURL.setResourceValues(values)
        let later = Harness(root: h.root) { $0.privacy.deleteAudioAfterDays = 7 }
        later.manager.refreshLibrary()
        later.manager.applyRetentionPolicy()
        #expect(!FileManager.default.fileExists(atPath: session.folder.audioDirectory.path))
        #expect(FileManager.default.fileExists(atPath: session.folder.transcriptMarkdownURL.path))
    }
}
