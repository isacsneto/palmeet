@testable import CaptureKit
import BrowserBridge
import Foundation
import SessionKit
import Testing
@testable import PalMeetCore

/// Regressions for issues found in code review.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReviewRegressionTests {
    @Test func stopDuringStartTearsEverythingDown() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let slow = FakeRemoteAudio(startDelay: .milliseconds(400))
        let source = CaptureSourceDescriptor(kind: .window, appName: "Zoom", bundleID: "us.zoom.xos", processID: 1)
        async let started = h.manager.startSession(id: SessionID(), source: source, title: "Slow", remote: slow, windowID: nil, frames: nil, includeMicrophone: true, preview: .isolated(""))
        try await Task.sleep(for: .milliseconds(100))
        let session = try #require(h.manager.activeSessions.first)
        await h.manager.stop(session)  // user hits Stop while capture is still starting
        _ = try await started
        #expect(session.stage == .ready)
        #expect(slow.isStopped, "remote capture must be stopped even though it finished starting after Stop")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.mic.subscriberCount == 0, "the mic must not stay subscribed")
        #expect(!session.copilotEnabled)
    }

    @Test func doubleStopIsHarmless() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(includeMic: false)
        async let first: Void = session.stop()
        async let second: Void = session.stop()
        _ = await (first, second)
        #expect(session.stage == .ready)
        #expect(h.llm.completeCalls.count == 1, "summary generated once")
    }

    @Test func editsDuringSummarizingSurvive() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.llm.summaryJSON = #"{"title":"Sync","tldr":"Speaker 2 will ship.","speaker_names":{"S1":"Maria"}}"#
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        remote.push(Voice.alpha.samples(seconds: 1) + silence(2) + Voice.bravo.samples(seconds: 1), at: 0.2)
        await h.manager.stop(session)

        h.llm.summaryDelay = .milliseconds(400)
        async let regenerate: Void = session.summarize(using: .anthropicAPI)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.stage == .summarizing)
        session.renameSpeaker("S2", to: "John")
        let segment = try #require(session.transcript?.segments.first)
        session.editSegment(segment.id, text: "edited while summarizing")
        await regenerate

        #expect(session.transcript?.displayName(for: "S2") == "John")
        #expect(session.transcript?.segments.first { $0.id == segment.id }?.text == "edited while summarizing")
        #expect(session.summary?.tldr == "John will ship.", "user rename applied to the new summary")
        #expect(session.transcript?.displayName(for: "S1") == "Maria", "model names still applied to unnamed speakers")
        let onDisk = try h.manager.store.loadTranscript(in: session.folder)
        #expect(onDisk.displayName(for: "S2") == "John")
    }

    @Test func pausedMeetingDoesNotGetTheMicAutomatically() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let a = try await h.start(title: "A", pid: 1)
        let b = try await h.start(title: "B", bundleID: "com.microsoft.teams2", pid: 2)
        b.knownMuted = false
        a.knownMuted = nil
        b.pause()
        h.manager.updateMicRouting()
        #expect(!b.isMicRouted, "paused meeting must not receive my voice")
        b.resume()
        h.manager.updateMicRouting()
        #expect(b.isMicRouted)
        await h.manager.stop(a)
        await h.manager.stop(b)
    }

    @Test func browserTabAndWholeBrowserConflictBothWays() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let tabSource = CaptureSourceDescriptor(kind: .browserTab, appName: "Chrome", bundleID: "com.google.Chrome", browserProfileID: "p1", browserWindowID: 1, browserTabID: 2)
        let tab = try await h.manager.startSession(id: SessionID(), source: tabSource, title: "Tab meeting", remote: FakeRemoteAudio(isolation: .browserExtension), windowID: nil, frames: nil, includeMicrophone: false, preview: .isolated(""))
        let chromeWindow = CapturableWindow(id: 9, title: "Other", appName: "Google Chrome", bundleID: "com.google.Chrome", pid: 50, frame: .zero, isOnScreen: true)
        if case .needsExtension = h.manager.isolationPreview(for: .window(chromeWindow)) {} else {
            Issue.record("recording all of Chrome while a Chrome tab is recorded must warn")
        }
        await h.manager.stop(tab)

        let tap = try await h.start(title: "Whole Chrome", bundleID: "com.google.Chrome", pid: 50, includeMic: false)
        let profile = BrowserProfile(id: "p1", label: "Work", browser: "Chrome", extensionVersion: "1", windows: [], connectedAt: Date())
        let window = BrowserWindow(windowID: 1, focused: true, state: "normal", bounds: .init(left: 0, top: 0, width: 10, height: 10), activeTabID: 2, tabs: [])
        let tabChoice = SourceChoice.browserTab(profile: profile, window: window, tab: BrowserTab(tabID: 2, title: "Meet", url: "https://meet.google.com/a", active: true, audible: true, isMeeting: true), scWindowID: nil)
        #expect(h.manager.isolationPreview(for: tabChoice) == .shared(conflictsWith: tap.title))
        await h.manager.stop(tap)
    }

    @Test func browserNamesMapToBundleIDs() {
        #expect(SessionManager.bundleID(forBrowser: "Chrome") == "com.google.Chrome")
        #expect(SessionManager.bundleID(forBrowser: "Microsoft Edge") == "com.microsoft.edgemac")
        #expect(SessionManager.bundleID(forBrowser: "Brave") == "com.brave.Browser")
        #expect(SessionManager.bundleID(forBrowser: "Firefox") == nil)
    }

    @Test func settingsChangesReachARunningCopilot() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(includeMic: false)
        session.setCopilot(enabled: true)
        h.manager.updateSettings { $0.copilot.maxCallsPerMinute = 1 }
        #expect(session.copilotConfiguration().maxCallsPerMinute == 1)
        await h.manager.stop(session)
    }

    @Test func libraryShowsCopilotHistoryAfterRelaunch() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote, includeMic: false)
        session.setCopilot(enabled: true)
        session.copilotHelpNow()
        _ = await waitUntil { !session.suggestions.isEmpty }
        await h.manager.stop(session)
        let relaunched = Harness(root: h.root)
        relaunched.manager.refreshLibrary()
        let loaded = try #require(relaunched.manager.library.first { $0.id == session.id })
        #expect(!loaded.suggestions.isEmpty)
        #expect(loaded.suggestions.allSatisfy { $0.status != .streaming })
    }
}

@MainActor
@Suite(.serialized) struct CardOrderTests {
    @Test func copyTargetFollowsDisplayOrderAndSkipsReminders() async throws {
        let h = Harness()
        defer { h.cleanup() }
        let session = try await h.start(includeMic: false)
        session.setCopilot(enabled: true)
        h.llm.copilotReply = "Q|high|First?|why"
        session.copilotHelpNow()
        _ = await waitUntil { session.suggestions.count == 1 && session.suggestions[0].status == .ready }
        h.llm.copilotReply = "Q|high|Second?|why"
        session.copilotHelpNow()
        _ = await waitUntil { session.suggestions.count == 2 && session.suggestions[1].status == .ready }
        let first = session.suggestions[0], second = session.suggestions[1]
        #expect(session.visibleCards.map(\.id) == [second.id, first.id], "newest first")
        session.updateSuggestion(first.id, status: .pinned)
        #expect(session.visibleCards.map(\.id) == [first.id, second.id], "pinned on top")
        #expect(session.copyTarget(focusedIndex: 0)?.id == first.id)
        #expect(session.copyTarget(focusedIndex: 99)?.id == second.id, "index is clamped")
        session.updateSuggestion(second.id, status: .dismissed)
        #expect(session.visibleCards.map(\.id) == [first.id])
        await h.manager.stop(session)
    }
}

@MainActor
@Suite(.serialized) struct MicrophonePermissionTests {
    @Test func deniedMicrophoneWarnsAndRecordsRemoteOnly() async throws {
        let h = Harness(microphoneAllowed: false)
        defer { h.cleanup() }
        let remote = FakeRemoteAudio()
        let session = try await h.start(remote: remote)
        #expect(h.mic.subscriberCount == 0)
        #expect(session.warnings.contains { $0.contains("Microphone access is off") })
        remote.push(Voice.alpha.samples(seconds: 1), at: 0.2)
        await h.manager.stop(session)
        #expect(words(in: session.transcript).contains("alpha"))
    }
}
