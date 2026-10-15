import BrowserBridge
import Foundation
import SessionKit
import Testing
@testable import PalMeetCore

/// Stand-in for one Chrome profile's extension, speaking the real wire protocol.
final class FakeExtension: Sendable {
    let task: URLSessionWebSocketTask
    let profile: String

    init(port: UInt16, profile: String) {
        self.profile = profile
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        request.setValue("chrome-extension://lhchlhlaljhfimjelkfbcmgocleehfin", forHTTPHeaderField: "Origin")
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func connect(token: String, label: String, windowID: Int, tabID: Int, title: String) async throws {
        try await task.send(.string(#"{"type":"hello","token":"\#(token)","profileInstanceId":"\#(profile)","profileLabel":"\#(label)","browser":"Chrome","extensionVersion":"0.1.0","role":"control"}"#))
        _ = try await receiveJSON()  // welcome
        try await task.send(.string(#"""
        {"type":"windows","windows":[{"windowId":\#(windowID),"focused":true,"state":"normal","bounds":{"left":0,"top":0,"width":1200,"height":800},"activeTabId":\#(tabID),
          "tabs":[{"tabId":\#(tabID),"title":"\#(title)","url":"https://meet.google.com/abc-defg-hij","active":true,"audible":true,"isMeeting":true}]}]}
        """#))
    }

    func receiveJSON(timeout: Duration = .seconds(5)) async throws -> [String: Any]? {
        let task = self.task
        let text: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { if case .string(let s)? = try? await task.receive() { return s } else { return nil } }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        return text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func send(_ json: String) async throws { try await task.send(.string(json)) }

    /// Sends `samples` (16 kHz voice) as 48 kHz stereo Int16 frames, like the offscreen document.
    func sendAudio(_ samples16k: [Float], session: UUID) async throws {
        var interleaved: [Int16] = []
        interleaved.reserveCapacity(samples16k.count * 6)
        for sample in samples16k {
            let value = Int16(max(-1, min(1, sample)) * 32_767)
            for _ in 0..<3 { interleaved.append(value); interleaved.append(value) }  // naive 3x upsample, stereo
        }
        let chunk = 4_800 * 2
        var time = Date().timeIntervalSince1970 * 1_000
        for start in stride(from: 0, to: interleaved.count, by: chunk) {
            let part = Array(interleaved[start..<min(interleaved.count, start + chunk)])
            try await task.send(.data(BinaryFrame.encodeAudio(sessionID: session, captureTimeMs: time, sampleRate: 48_000, channels: 2, interleaved: part)))
            time += 100
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct BridgeSessionTests {
    /// The headline scenario: two Chrome windows in different profiles, one meeting tab each, recorded at once.
    @Test func twoProfilesTwoMeetingsStayIsolated() async throws {
        let token = "bridge-test-token"
        let h = Harness(bridgeToken: token)
        defer { h.cleanup() }
        h.manager.start()
        let port = try #require(h.manager.bridgePort)

        let work = FakeExtension(port: port, profile: "profile-work")
        let client = FakeExtension(port: port, profile: "profile-client")
        try await work.connect(token: token, label: "Work", windowID: 11, tabID: 101, title: "Weekly sync")
        try await client.connect(token: token, label: "Client X", windowID: 22, tabID: 202, title: "Client kickoff")
        #expect(await waitUntil { h.manager.browserProfiles.count == 2 && h.manager.browserProfiles.allSatisfy { !$0.windows.isEmpty } })

        let choices = h.manager.browserMeetingChoices(windows: [])
        #expect(choices.count == 2)
        for choice in choices { #expect(h.manager.isolationPreview(for: choice) == .isolated("browser extension (this tab only)")) }
        let workChoice = try #require(choices.first { if case .browserTab(let p, _, _, _) = $0 { p.id == "profile-work" } else { false } })
        let clientChoice = try #require(choices.first { if case .browserTab(let p, _, _, _) = $0 { p.id == "profile-client" } else { false } })

        let a = try await h.manager.startSession(workChoice, includeMicrophone: false)
        let startA = try #require(try await work.receiveJSON())
        #expect(startA["type"] as? String == "startCapture")
        #expect(startA["tabId"] as? Int == 101)
        #expect((startA["sessionId"] as? String)?.lowercased() == a.id.uuidString.lowercased())

        let b = try await h.manager.startSession(clientChoice, includeMicrophone: false)
        let startB = try #require(try await client.receiveJSON())
        #expect(startB["tabId"] as? Int == 202)
        #expect(a.metadata.isolation == .browserExtension && b.metadata.isolation == .browserExtension)
        #expect(a.metadata.source.browserProfileLabel == "Work")
        #expect(a.metadata.source.bundleID == "com.google.Chrome")

        for (ext, session) in [(work, a), (client, b)] {
            try await ext.send(#"{"type":"captureState","sessionId":"\#(session.id.uuidString.lowercased())","state":"capturing","windowId":0,"tabId":0}"#)
        }
        try await work.sendAudio(Voice.alpha.samples(seconds: 1.5), session: a.id)
        try await client.sendAudio(Voice.bravo.samples(seconds: 1.5), session: b.id)
        // A profile can't inject audio into another profile's meeting.
        try await client.sendAudio(Voice.november.samples(seconds: 1), session: a.id)

        try await work.send(#"{"type":"meetingState","sessionId":"\#(a.id.uuidString.lowercased())","muted":true,"presenting":true}"#)
        #expect(await waitUntil { a.knownMuted == true && a.isPresenting == true })
        #expect(h.manager.isPresentingAnywhere)
        try await Task.sleep(for: .milliseconds(500))

        await h.manager.stop(a)
        #expect(try await work.receiveJSON()?["type"] as? String == "stopCapture")
        await h.manager.stop(b)

        let wordsA = words(in: a.transcript), wordsB = words(in: b.transcript)
        #expect(wordsA.contains("alpha"), "A: \(wordsA)")
        #expect(!wordsA.contains("bravo") && !wordsA.contains("november"), "A leaked: \(wordsA)")
        #expect(wordsB.contains("bravo"), "B: \(wordsB)")
        #expect(!wordsB.contains("alpha"), "B leaked: \(wordsB)")
        work.close()
        client.close()
        await h.manager.shutdown()
    }

    /// One meeting is recorded once: pressing the record hotkey again, or picking the same tab, doesn't start a
    /// second recording, and a tab inside a window that's already recorded whole is refused.
    @Test func aMeetingIsNeverRecordedTwice() async throws {
        let token = "bridge-test-token-dup"
        let h = Harness(bridgeToken: token)
        defer { h.cleanup() }
        h.manager.start()
        let port = try #require(h.manager.bridgePort)
        let ext = FakeExtension(port: port, profile: "profile-work")
        try await ext.connect(token: token, label: "Work", windowID: 11, tabID: 101, title: "Daily")
        #expect(await waitUntil { h.manager.browserProfiles.first?.windows.isEmpty == false })
        let choice = try #require(h.manager.browserMeetingChoices(windows: []).first)

        let session = try await h.manager.startSession(choice, includeMicrophone: false)
        #expect(try await ext.receiveJSON()?["type"] as? String == "startCapture")
        let wire = session.id.uuidString.lowercased()
        try await ext.send(#"{"type":"captureState","sessionId":"\#(wire)","state":"awaitingGesture"}"#)
        #expect(await waitUntil { session.waitingForBrowserClick }, "the live view asks for the click")

        await #expect(throws: SessionError.self) { try await h.manager.startSession(choice, includeMicrophone: false) }
        #expect(h.manager.activeSessions.count == 1)
        #expect(h.manager.sessionRecording(choice)?.id == session.id)

        try await ext.send(#"{"type":"captureState","sessionId":"\#(wire)","state":"capturing","windowId":11,"tabId":101}"#)
        #expect(await waitUntil { !session.waitingForBrowserClick })
        await h.manager.stop(session)

        // A whole-window recording of the browser already contains the tab.
        let whole = try await h.manager.startSession(
            id: SessionID(),
            source: CaptureSourceDescriptor(kind: .window, appName: "Google Chrome", bundleID: "com.google.Chrome", processID: 624, windowID: 470, windowTitle: "Daily 🔊"),
            title: "Daily 🔊", remote: FakeRemoteAudio(), windowID: 470, frames: nil, includeMicrophone: false, preview: .isolated("test")
        )
        guard case .browserTab(let profile, let window, let tab, _) = choice else { Issue.record("not a tab"); return }
        let inThatWindow = SourceChoice.browserTab(profile: profile, window: window, tab: tab, scWindowID: 470)
        #expect(h.manager.sessionRecording(inThatWindow)?.id == whole.id)
        await #expect(throws: SessionError.self) { try await h.manager.startSession(inThatWindow, includeMicrophone: false) }
        await h.manager.stop(whole)
        ext.close()
        await h.manager.shutdown()
    }

    @Test func captureStartedFromTheBrowserIsAdoptedAndStopsWithTheTab() async throws {
        let token = "bridge-test-token-2"
        let h = Harness(bridgeToken: token)
        defer { h.cleanup() }
        h.manager.start()
        let port = try #require(h.manager.bridgePort)
        let ext = FakeExtension(port: port, profile: "solo")
        try await ext.connect(token: token, label: "Solo", windowID: 5, tabID: 55, title: "Standup")
        #expect(await waitUntil { h.manager.browserProfiles.first?.windows.isEmpty == false })

        let sessionID = UUID()
        try await ext.send(#"{"type":"captureState","sessionId":"\#(sessionID.uuidString.lowercased())","state":"capturing","userInitiated":true,"windowId":5,"tabId":55}"#)
        #expect(await waitUntil { h.manager.activeSessions.contains { $0.id == sessionID } })
        let session = try #require(h.manager.session(sessionID))
        #expect(session.title == "Standup")
        try await ext.sendAudio(Voice.alpha.samples(seconds: 1), session: sessionID)
        try await Task.sleep(for: .milliseconds(300))

        // The user closes the tab: the extension reports it and the meeting is finalized.
        try await ext.send(#"{"type":"captureState","sessionId":"\#(sessionID.uuidString.lowercased())","state":"stopped","message":"Tab closed"}"#)
        #expect(await waitUntil(timeout: .seconds(15)) { session.stage == .ready })
        #expect(h.manager.activeSessions.isEmpty)
        #expect(words(in: session.transcript).contains("alpha"))
        ext.close()
        await h.manager.shutdown()
    }

    @Test func unknownTabCaptureIsStoppedNotOrphaned() async throws {
        let token = "bridge-test-token-3"
        let h = Harness(bridgeToken: token)
        defer { h.cleanup() }
        h.manager.start()
        let port = try #require(h.manager.bridgePort)
        let ext = FakeExtension(port: port, profile: "solo")
        try await ext.connect(token: token, label: "Solo", windowID: 5, tabID: 55, title: "Standup")
        #expect(await waitUntil { h.manager.browserProfiles.first?.windows.isEmpty == false })
        // A capture for a tab the app doesn't know about (stale window list).
        let sessionID = UUID()
        try await ext.send(#"{"type":"captureState","sessionId":"\#(sessionID.uuidString.lowercased())","state":"capturing","windowId":999,"tabId":999}"#)
        let reply = try await ext.receiveJSON()
        #expect(reply?["type"] as? String == "stopCapture")
        #expect(h.manager.activeSessions.isEmpty)
        ext.close()
        await h.manager.shutdown()
    }
}
