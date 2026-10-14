import Foundation
import Testing
@testable import BrowserBridge

/// Waits for the first element of `stream` matching `predicate`, or `nil` after `timeout`.
func first<Element: Sendable>(
    _ stream: AsyncStream<Element>, timeout: Duration = .seconds(5),
    where predicate: @escaping @Sendable (Element) -> Bool = { _ in true }
) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream where predicate(element) { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Minimal test client standing in for the extension.
final class TestClient: Sendable {
    let task: URLSessionWebSocketTask

    init(port: UInt16, origin: String? = nil) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    func send(json: String) async throws { try await task.send(.string(json)) }
    func send(data: Data) async throws { try await task.send(.data(data)) }

    /// Next text message as a JSON object; `nil` on close/error/timeout.
    func receiveJSON(timeout: Duration = .seconds(5)) async -> [String: Any]? {
        let task = self.task
        let text: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard case .string(let text)? = try? await task.receive() else { return nil }
                return text
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            if result == nil { task.cancel(with: .goingAway, reason: nil) }  // unblocks receive()
            group.cancelAll()
            return result
        }
        guard let text else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    static func hello(token: String, profile: String, role: String = "control") -> String {
        """
        {"type":"hello","token":"\(token)","profileInstanceId":"\(profile)","profileLabel":"Work",
         "browser":"Chrome","extensionVersion":"0.1.0","role":"\(role)"}
        """
    }

    static let windows = """
    {"type":"windows","windows":[{"windowId":12,"focused":true,"state":"normal",
      "bounds":{"left":10,"top":20,"width":1280,"height":800},"activeTabId":99,
      "tabs":[{"tabId":99,"title":"Meet","url":"https://meet.google.com/abc-defg-hij",
               "active":true,"audible":true,"isMeeting":true}]}]}
    """
}

@Suite("Server integration", .serialized, .timeLimit(.minutes(1)))
struct ServerIntegrationTests {
    let token = BridgeInfo.generateToken()

    func makeServer() throws -> BrowserBridgeServer {
        let server = BrowserBridgeServer(configuration: .init(portCandidates: [0], bridgeInfoStore: nil, token: token))
        try server.start()
        return server
    }

    @Test func helloWindowsCaptureAndAudio() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let port = try #require(server.port)
        #expect(port != 0)

        let profileEvents = server.events()
        let client = TestClient(port: port)
        defer { client.close() }
        try await client.send(json: TestClient.hello(token: token, profile: "profile-A"))
        let welcome = await client.receiveJSON()
        #expect(welcome?["type"] as? String == "welcome")
        #expect(welcome?["profileInstanceId"] as? String == "profile-A")

        try await client.send(json: TestClient.windows)
        let changed = await first(profileEvents) { event in
            if case .profilesChanged(let profiles) = event { return profiles.first?.windows.count == 1 }
            return false
        }
        guard case .profilesChanged(let profiles)? = changed else {
            Issue.record("no profilesChanged event with windows")
            return
        }
        #expect(profiles.map(\.id) == ["profile-A"])
        #expect(profiles[0].label == "Work")
        #expect(profiles[0].browser == "Chrome")
        #expect(profiles[0].windows[0].tabs[0].isMeeting)
        #expect(server.profiles().map(\.id) == ["profile-A"])

        // App asks for a capture; the extension receives startCapture.
        let sessionID = UUID()
        let audio = server.audioChunks(for: sessionID)
        let video = server.videoFrames(for: sessionID)
        let captureEvents = server.events()
        try server.startCapture(sessionID: sessionID, profileID: "profile-A", windowID: 12, tabID: 99)
        let start = await client.receiveJSON()
        #expect(start?["type"] as? String == "startCapture")
        #expect(start?["sessionId"] as? String == sessionID.uuidString.lowercased())
        #expect(start?["windowId"] as? Int == 12)
        #expect(start?["tabId"] as? Int == 99)

        try await client.send(json: #"{"type":"captureState","sessionId":"\#(sessionID)","state":"capturing"}"#)
        let capturing = await first(captureEvents) { event in
            if case .captureState(_, .capturing) = event { return true }
            return false
        }
        #expect(capturing != nil)

        // Binary audio + video frames reach the per-session streams.
        let pcm: [Int16] = [16384, 16384, -8192, -8192]
        try await client.send(data: BinaryFrame.encodeAudio(
            sessionID: sessionID, captureTimeMs: 1_700_000_000_000, sampleRate: 48000, channels: 2, interleaved: pcm
        ))
        let chunk = try #require(await first(audio))
        #expect(chunk.sessionID == sessionID)
        #expect(chunk.sampleRate == 48000)
        #expect(chunk.channels == 2)
        #expect(chunk.samples == [0.5, -0.25])

        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        try await client.send(data: BinaryFrame.encodeVideo(sessionID: sessionID, captureTimeMs: 1, jpeg: jpeg))
        #expect(await first(video)?.jpegData == jpeg)

        // Mute state is forwarded for a known session.
        let meetingEvents = server.events()
        try await client.send(json: #"{"type":"meetingState","sessionId":"\#(sessionID)","muted":true,"presenting":null}"#)
        let meeting = await first(meetingEvents) { event in
            if case .meetingState = event { return true }
            return false
        }
        guard case .meetingState(let id, let muted, let presenting)? = meeting else {
            Issue.record("no meetingState")
            return
        }
        #expect(id == sessionID && muted == true && presenting == nil)

        // Extension reports the tab closed: stream finishes.
        try await client.send(json: #"{"type":"captureState","sessionId":"\#(sessionID)","state":"stopped","message":"Tab closed"}"#)
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in audio {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(finished)
    }

    @Test func badTokenIsRejected() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let client = TestClient(port: try #require(server.port))
        try await client.send(json: TestClient.hello(token: "wrong", profile: "intruder"))
        #expect(await client.receiveJSON() == nil)  // closed with 4401, no welcome
        #expect(server.profiles().isEmpty)
    }

    @Test func webOriginIsRejected() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let client = TestClient(port: try #require(server.port), origin: "https://evil.example")
        // The upgrade itself is refused (HTTP error), so nothing is ever received.
        #expect(await client.receiveJSON(timeout: .seconds(3)) == nil)
        #expect(server.profiles().isEmpty)
    }

    @Test func outdatedExtensionIsAskedToReloadOncePerRun() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.setLatestExtensionVersion("0.2.0")
        let port = try #require(server.port)
        for attempt in 0..<2 {
            let client = TestClient(port: port)
            try await client.send(json: TestClient.hello(token: token, profile: "old"))  // reports 0.1.0
            #expect(await client.receiveJSON()?["type"] as? String == "welcome")
            let next = await client.receiveJSON(timeout: .seconds(1))
            if attempt == 0 {
                #expect(next?["type"] as? String == "reloadExtension")
            } else {
                #expect(next == nil, "a reload that didn't help isn't requested again")
            }
            client.close()
        }
        // Up-to-date extensions are left alone.
        let current = TestClient(port: port)
        defer { current.close() }
        try await current.send(json: TestClient.hello(token: token, profile: "new").replacingOccurrences(of: "0.1.0", with: "0.2.0"))
        #expect(await current.receiveJSON()?["type"] as? String == "welcome")
        #expect(await current.receiveJSON(timeout: .seconds(1)) == nil)
    }

    @Test func extensionOriginIsAccepted() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let client = TestClient(port: try #require(server.port), origin: "chrome-extension://\(BrowserExtension.defaultExtensionID)")
        defer { client.close() }
        try await client.send(json: TestClient.hello(token: token, profile: "ext"))
        #expect(await client.receiveJSON()?["type"] as? String == "welcome")
    }

    @Test func userInitiatedCaptureOverMediaConnection() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let port = try #require(server.port)
        let control = TestClient(port: port)
        defer { control.close() }
        try await control.send(json: TestClient.hello(token: token, profile: "profile-B"))
        _ = await control.receiveJSON()

        let sessionID = UUID()
        let events = server.events()
        try await control.send(json: """
        {"type":"captureState","sessionId":"\(sessionID)","state":"capturing","userInitiated":true,"windowId":5,"tabId":6}
        """)
        let adopted = await first(events) { event in
            if case .userInitiatedCapture = event { return true }
            return false
        }
        guard case .userInitiatedCapture(let id, let profile, let window, let tab)? = adopted else {
            Issue.record("no userInitiatedCapture")
            return
        }
        #expect(id == sessionID && profile == "profile-B" && window == 5 && tab == 6)

        // The offscreen document's media socket streams audio for the same profile.
        let audio = server.audioChunks(for: sessionID)
        let media = TestClient(port: port)
        defer { media.close() }
        try await media.send(json: TestClient.hello(token: token, profile: "profile-B", role: "media"))
        #expect(await media.receiveJSON()?["type"] as? String == "welcome")
        #expect(server.profiles().count == 1)  // media connections are not profiles
        try await media.send(data: BinaryFrame.encodeAudio(
            sessionID: sessionID, captureTimeMs: 0, sampleRate: 16000, channels: 1, interleaved: [8192]
        ))
        #expect(await first(audio)?.samples == [0.25])

        // A different profile cannot inject audio into this session.
        let other = TestClient(port: port)
        defer { other.close() }
        try await other.send(json: TestClient.hello(token: token, profile: "profile-C", role: "media"))
        _ = await other.receiveJSON()
        let audio2 = server.audioChunks(for: sessionID)
        try await other.send(data: BinaryFrame.encodeAudio(
            sessionID: sessionID, captureTimeMs: 0, sampleRate: 16000, channels: 1, interleaved: [100]
        ))
        #expect(await first(audio2, timeout: .milliseconds(500)) == nil)

        // stopCapture: the extension is told, the stream ends, a stopped event is emitted.
        let stopEvents = server.events()
        server.stopCapture(sessionID: sessionID)
        #expect(await control.receiveJSON()?["type"] as? String == "stopCapture")
        let stopped = await first(stopEvents) { event in
            if case .captureState(_, .stopped) = event { return true }
            return false
        }
        #expect(stopped != nil)
    }

    @Test func startCaptureRequiresConnectedProfile() throws {
        let server = try makeServer()
        defer { server.stop() }
        #expect(throws: BrowserBridgeError.profileNotConnected("nobody")) {
            try server.startCapture(sessionID: UUID(), profileID: "nobody", windowID: 1, tabID: 1)
        }
        server.stop()
        #expect(throws: BrowserBridgeError.notRunning) {
            try server.startCapture(sessionID: UUID(), profileID: "nobody", windowID: 1, tabID: 1)
        }
    }

    @Test func fallsBackToNextPortAndPublishesBridgeInfo() throws {
        let first = try makeServer()
        defer { first.stop() }
        let busy = try #require(first.port)

        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BridgeInfoStore(url: dir.appending(path: "bridge.json"))
        let second = BrowserBridgeServer(configuration: .init(portCandidates: [busy, 0], bridgeInfoStore: store))
        try second.start()
        let port = try #require(second.port)
        #expect(port != busy)

        let info = try #require(store.load())
        #expect(info.port == port)
        #expect(info.pid == getpid())
        #expect(info.token.count == 64)
        second.stop()
        #expect(second.port == nil)
        let afterStop = try #require(store.load())
        #expect(afterStop.port == nil)
        #expect(afterStop.token == info.token)  // token persists across restarts
    }

    @Test func allPortsBusyThrows() throws {
        let first = try makeServer()
        defer { first.stop() }
        let busy = try #require(first.port)
        let second = BrowserBridgeServer(configuration: .init(portCandidates: [busy], bridgeInfoStore: nil, token: token))
        #expect(throws: BrowserBridgeError.noAvailablePort([busy])) { try second.start() }
    }
}

@Suite("Stop while disconnected", .serialized, .timeLimit(.minutes(1)))
struct StopWhileDisconnectedTests {
    @Test func reannouncedCaptureOfAStoppedSessionIsStoppedNotAdopted() async throws {
        let token = BridgeInfo.generateToken()
        let server = BrowserBridgeServer(configuration: .init(portCandidates: [0], bridgeInfoStore: nil, token: token))
        try server.start()
        defer { server.stop() }
        let port = try #require(server.port)
        let events = server.events()

        let client = TestClient(port: port, origin: "chrome-extension://abc/")
        try await client.send(json: TestClient.hello(token: token, profile: "p1"))
        _ = await client.receiveJSON()  // welcome
        try await client.send(json: TestClient.windows)
        let sessionID = UUID()
        try server.startCapture(sessionID: sessionID, profileID: "p1", windowID: 12, tabID: 99)
        _ = await client.receiveJSON()  // startCapture
        client.close()  // extension's service worker restarts…
        try await Task.sleep(for: .milliseconds(200))

        server.stopCapture(sessionID: sessionID)  // …while the user stops the meeting in PalMeet

        let reconnected = TestClient(port: port, origin: "chrome-extension://abc/")
        try await reconnected.send(json: TestClient.hello(token: token, profile: "p1"))
        _ = await reconnected.receiveJSON()
        try await reconnected.send(json: TestClient.windows)
        try await reconnected.send(json: #"{"type":"captureState","sessionId":"\#(sessionID.uuidString.lowercased())","state":"capturing","windowId":12,"tabId":99}"#)
        let reply = await reconnected.receiveJSON()
        #expect(reply?["type"] as? String == "stopCapture")
        let adopted = await first(events, timeout: .milliseconds(500)) { event in
            if case .userInitiatedCapture = event { true } else { false }
        }
        #expect(adopted == nil)
        reconnected.close()
    }
}
