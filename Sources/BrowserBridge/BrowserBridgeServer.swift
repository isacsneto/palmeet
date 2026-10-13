import Foundation
import Network
import Synchronization

/// Localhost WebSocket server that the companion Chromium extension (one instance per browser
/// profile) connects to. See `Extension/chromium/PROTOCOL.md` for the wire protocol.
///
/// Thread-safe; all network callbacks run on one private serial queue and shared state is
/// guarded by a `Mutex`. Events are multicast: every call to `events()` returns a new stream.
public final class BrowserBridgeServer: Sendable {
    public struct Configuration: Sendable {
        /// Ports tried in order; the first free one wins. `0` means "any free port".
        public var portCandidates: [UInt16]
        /// Where `{port, token, pid}` is published for the native messaging host. `nil` = don't publish.
        public var bridgeInfoStore: BridgeInfoStore?
        /// Fixed token. `nil` = load from (or create in) `bridgeInfoStore`, else generate one.
        public var token: String?
        /// Connections that haven't authenticated with `hello` in time are closed (4408).
        public var helloTimeout: TimeInterval
        /// Largest accepted WebSocket message (JPEG frames are the biggest).
        public var maximumMessageSize: Int
        /// Reject WebSocket upgrades whose `Origin` is a web page (only extension origins or no
        /// origin are allowed). Defense in depth on top of the token.
        public var rejectWebOrigins: Bool

        public init(
            portCandidates: [UInt16] = Array(47821...47830),
            bridgeInfoStore: BridgeInfoStore? = BridgeInfoStore(),
            token: String? = nil,
            helloTimeout: TimeInterval = 10,
            maximumMessageSize: Int = 8 * 1024 * 1024,
            rejectWebOrigins: Bool = true
        ) {
            self.portCandidates = portCandidates
            self.bridgeInfoStore = bridgeInfoStore
            self.token = token
            self.helloTimeout = helloTimeout
            self.maximumMessageSize = maximumMessageSize
            self.rejectWebOrigins = rejectWebOrigins
        }

        public static let `default` = Configuration()
    }

    private struct SessionRoute: Sendable {
        var profileID: String
        var windowID: Int
        var tabID: Int
    }

    private struct ConnectionRecord: Sendable {
        let connection: BridgeConnection
        var role: ExtensionMessage.Hello.Role?
        var profile: BrowserProfile?
        var isAuthenticated: Bool { role != nil }
    }

    private struct State: Sendable {
        var listener: NWListener?
        var port: UInt16?
        var token: String?
        var connections: [UUID: ConnectionRecord] = [:]
        var sessions: [UUID: SessionRoute] = [:]
        /// Sessions the app stopped. If the extension was disconnected at the time, it re-announces them as
        /// `capturing` after reconnecting; they must be stopped again, never adopted as new captures.
        var stoppedByApp: [UUID] = []

        var profiles: [BrowserProfile] {
            connections.values.compactMap { $0.role == .control ? $0.profile : nil }
                .sorted { ($0.connectedAt, $0.id) < ($1.connectedAt, $1.id) }
        }

        func controlConnection(for profileID: String) -> BridgeConnection? {
            connections.values.first { $0.role == .control && $0.profile?.id == profileID }?.connection
        }
    }

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "app.palmeet.browser-bridge")
    private let state = Mutex(State())
    private let eventSubscribers = SubscriberSet<BrowserBridgeEvent>(bufferingPolicy: .bufferingNewest(256))
    private let audioSubscribers = KeyedSubscriberSet<UUID, BridgeAudioChunk>(bufferingPolicy: .bufferingNewest(600))
    private let videoSubscribers = KeyedSubscriberSet<UUID, BridgeVideoFrame>(bufferingPolicy: .bufferingNewest(30))

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    deinit {
        let (listener, connections) = state.withLock { ($0.listener, $0.connections.values.map(\.connection)) }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    // MARK: Lifecycle

    /// The port the server is listening on, or `nil` when stopped.
    public var port: UInt16? { state.withLock { $0.port } }

    public var isRunning: Bool { port != nil }

    /// Starts listening on 127.0.0.1 (first free port of `portCandidates`) and publishes
    /// `bridge.json`. Blocks briefly while the listener binds. No-op if already running.
    public func start() throws {
        if isRunning { return }
        let token = try resolveToken()
        var tried: [UInt16] = []
        for candidate in configuration.portCandidates {
            tried.append(candidate)
            guard let (listener, port) = try bind(port: candidate) else { continue }
            let alreadyStarted = state.withLock { s -> Bool in
                if s.listener != nil { return true }
                s.listener = listener
                s.port = port
                s.token = token
                return false
            }
            if alreadyStarted {
                listener.cancel()
                return
            }
            if let store = configuration.bridgeInfoStore {
                try? store.save(BridgeInfo(port: port, token: token, pid: getpid()))
            }
            return
        }
        throw BrowserBridgeError.noAvailablePort(tried)
    }

    /// Stops listening, disconnects every extension and finishes all audio/video streams.
    /// Event streams stay open (the server can be started again).
    public func stop() {
        let (listener, connections, token, port) = state.withLock { s in
            defer {
                s.listener = nil
                s.port = nil
                s.connections = [:]
                s.sessions = [:]
            }
            return (s.listener, s.connections.values.map(\.connection), s.token, s.port)
        }
        guard let listener else { return }
        listener.cancel()
        connections.forEach { $0.close(.goingAway) }
        audioSubscribers.finishAll()
        videoSubscribers.finishAll()
        // Only retract what this server published; another instance may own the file by now.
        if let store = configuration.bridgeInfoStore, let token,
           let info = store.load(), info.pid == getpid(), info.port == port {
            try? store.save(BridgeInfo(port: nil, token: token, pid: nil))
        }
        eventSubscribers.yield(.profilesChanged([]))
    }

    // MARK: Observation

    /// A new multicast stream of bridge events. Each call registers an independent subscriber.
    public func events() -> AsyncStream<BrowserBridgeEvent> {
        eventSubscribers.subscribe()
    }

    /// Currently connected profiles (one per extension instance), oldest first.
    public func profiles() -> [BrowserProfile] {
        state.withLock { $0.profiles }
    }

    /// Mono PCM for `sessionID`. Finishes when the capture stops/fails or the server stops.
    /// Chunks that arrive while nobody is subscribed are dropped.
    public func audioChunks(for sessionID: UUID) -> AsyncStream<BridgeAudioChunk> {
        audioSubscribers.subscribe(sessionID)
    }

    /// ~1 fps JPEG frames of the captured tab for `sessionID`. Same lifetime rules as audio.
    public func videoFrames(for sessionID: UUID) -> AsyncStream<BridgeVideoFrame> {
        videoSubscribers.subscribe(sessionID)
    }

    // MARK: Commands

    /// Asks the extension in `profileID` to capture `tabID` in `windowID`. The extension replies
    /// with `captureState(.awaitingGesture)` until the user clicks its toolbar icon in that window.
    public func startCapture(sessionID: UUID, profileID: String, windowID: Int, tabID: Int) throws {
        let connection = try state.withLock { s -> BridgeConnection in
            guard s.listener != nil else { throw BrowserBridgeError.notRunning }
            guard let connection = s.controlConnection(for: profileID) else {
                throw BrowserBridgeError.profileNotConnected(profileID)
            }
            s.sessions[sessionID] = SessionRoute(profileID: profileID, windowID: windowID, tabID: tabID)
            return connection
        }
        connection.send(.startCapture(sessionID: sessionID, windowID: windowID, tabID: tabID))
    }

    /// Stops a capture. Emits `captureState(.stopped)` and finishes the session's streams
    /// immediately, whether or not the extension is still connected.
    public func stopCapture(sessionID: UUID) {
        let (route, connection) = state.withLock { s -> (SessionRoute?, BridgeConnection?) in
            guard let route = s.sessions.removeValue(forKey: sessionID) else { return (nil, nil) }
            s.stoppedByApp.append(sessionID)
            if s.stoppedByApp.count > 200 { s.stoppedByApp.removeFirst(s.stoppedByApp.count - 200) }
            return (route, s.controlConnection(for: route.profileID))
        }
        guard route != nil else { return }
        connection?.send(.stopCapture(sessionID: sessionID))
        endSession(sessionID, state: .stopped("Stopped by PalMeet"))
    }

    // MARK: Listener

    private func resolveToken() throws -> String {
        if let token = configuration.token { return token }
        if let store = configuration.bridgeInfoStore { return try store.loadOrCreateToken() }
        return BridgeInfo.generateToken()
    }

    private func makeParameters(port: UInt16) -> NWParameters {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = configuration.maximumMessageSize
        if configuration.rejectWebOrigins {
            ws.setClientRequestHandler(queue) { _, headers in
                let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
                let allowed = origin.map(Self.isAllowedOrigin) ?? true
                return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
            }
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        return parameters
    }

    static func isAllowedOrigin(_ origin: String) -> Bool {
        // Web pages (including sandboxed frames, which send "null") are refused.
        origin.lowercased().hasPrefix("chrome-extension://")
    }

    /// Binds a listener on `port`. Returns `nil` if the port is in use.
    private func bind(port: UInt16) throws -> (NWListener, UInt16)? {
        let listener: NWListener
        do {
            listener = try NWListener(using: makeParameters(port: port))
        } catch {
            return nil
        }
        let latch = ReadyLatch()
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            switch newState {
            case .ready:
                latch.signal(.success(listener?.port?.rawValue ?? port))
            case .failed(let error):
                latch.signal(.failure(error))
                listener?.cancel()
                self?.listenerFailed(listener)
            case .cancelled:
                latch.signal(.failure(NWError.posix(.ECANCELED)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        switch latch.wait(timeout: 3) {
        case .success(let boundPort)?:
            return (listener, boundPort)
        case .failure(let error)?:
            listener.cancel()
            if case .posix(let code) = error as? NWError, code == .EADDRINUSE || code == .EACCES {
                return nil
            }
            if configuration.portCandidates.count > 1 { return nil }
            throw BrowserBridgeError.listenerFailed(String(describing: error))
        case nil:
            listener.cancel()
            return nil
        }
    }

    /// The listener died after start (e.g. network stack reset): drop to the stopped state.
    private func listenerFailed(_ listener: NWListener?) {
        guard let listener else { return }
        let isCurrent = state.withLock { $0.listener === listener }
        if isCurrent { stop() }
    }

    // MARK: Connections

    private func accept(_ nwConnection: NWConnection) {
        let connection = BridgeConnection(
            connection: nwConnection, queue: queue,
            onMessage: { [weak self] connection, message in self?.handle(message, from: connection) },
            onClose: { [weak self] connection in self?.connectionClosed(connection) }
        )
        guard connection.isLoopback else {
            connection.cancel()
            return
        }
        state.withLock { $0.connections[connection.id] = ConnectionRecord(connection: connection) }
        connection.start()
        queue.asyncAfter(deadline: .now() + configuration.helloTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            let pending = self.state.withLock { $0.connections[connection.id].map { !$0.isAuthenticated } ?? false }
            if pending { connection.close(.helloTimeout) }
        }
    }

    private func connectionClosed(_ connection: BridgeConnection) {
        let (removed, profiles) = state.withLock { s in
            (s.connections.removeValue(forKey: connection.id), s.profiles)
        }
        if removed?.role == .control {
            eventSubscribers.yield(.profilesChanged(profiles))
        }
    }

    private func handle(_ message: BridgeConnection.Message, from connection: BridgeConnection) {
        guard let record = state.withLock({ $0.connections[connection.id] }) else { return }
        switch message {
        case .text(let data):
            guard let decoded = try? ExtensionMessage.decode(data) else {
                if !record.isAuthenticated { connection.close(.protocolViolation) }
                return
            }
            handle(decoded, record: record)
        case .binary(let data):
            guard record.isAuthenticated, let profileID = record.profile?.id else { return }
            handleBinary(data, profileID: profileID)
        }
    }

    private func handle(_ message: ExtensionMessage, record: ConnectionRecord) {
        let connection = record.connection
        guard let profile = record.profile else {
            guard case .hello(let hello) = message else {
                connection.close(.protocolViolation)
                return
            }
            authenticate(hello, connection: connection)
            return
        }
        switch message {
        case .hello:
            break  // Already authenticated; ignore repeats.
        case .ping:
            connection.send(.pong)
        case .windows(let windows):
            guard record.role == .control else { return }
            let profiles = state.withLock { s -> [BrowserProfile]? in
                guard var rec = s.connections[connection.id], rec.profile?.windows != windows else { return nil }
                rec.profile?.windows = windows
                s.connections[connection.id] = rec
                return s.profiles
            }
            if let profiles { eventSubscribers.yield(.profilesChanged(profiles)) }
        case .captureState(let report):
            handleCaptureState(report, profileID: profile.id)
        case .meetingState(let report):
            let known = state.withLock { $0.sessions[report.sessionId]?.profileID == profile.id }
            if known {
                eventSubscribers.yield(.meetingState(
                    sessionID: report.sessionId, muted: report.muted, presenting: report.presenting
                ))
            }
        case .unknown:
            break
        }
    }

    private func authenticate(_ hello: ExtensionMessage.Hello, connection: BridgeConnection) {
        let expected = state.withLock { $0.token } ?? ""
        guard !expected.isEmpty, Self.constantTimeEquals(hello.token, expected), !hello.profileInstanceId.isEmpty else {
            connection.close(.unauthorized)
            return
        }
        let profile = BrowserProfile(
            id: hello.profileInstanceId,
            label: hello.profileLabel.isEmpty ? "Profile \(hello.profileInstanceId.prefix(6))" : hello.profileLabel,
            browser: hello.browser,
            extensionVersion: hello.extensionVersion,
            windows: [],
            connectedAt: Date()
        )
        let (replaced, profiles) = state.withLock { s -> ([BridgeConnection], [BrowserProfile]) in
            var replaced: [BridgeConnection] = []
            if hello.role == .control {
                // A profile has one control connection; a newer one supersedes a stale one.
                for (id, rec) in s.connections where id != connection.id
                    && rec.role == .control && rec.profile?.id == profile.id {
                    s.connections.removeValue(forKey: id)
                    replaced.append(rec.connection)
                }
            }
            s.connections[connection.id]?.role = hello.role
            s.connections[connection.id]?.profile = profile
            return (replaced, s.profiles)
        }
        replaced.forEach { $0.close(.replaced) }
        connection.send(.welcome(protocolVersion: browserBridgeProtocolVersion, profileInstanceId: profile.id))
        if hello.role == .control {
            eventSubscribers.yield(.profilesChanged(profiles))
        }
    }

    private func handleCaptureState(_ report: ExtensionMessage.CaptureStateReport, profileID: String) {
        let captureState = report.captureState
        enum Outcome { case known, adopted(windowID: Int, tabID: Int), stopAgain(BridgeConnection?), ignored }
        let outcome = state.withLock { s -> Outcome in
            if let route = s.sessions[report.sessionId] {
                guard route.profileID == profileID else { return .ignored }
                if captureState.isTerminal { s.sessions.removeValue(forKey: report.sessionId) }
                return .known
            }
            if s.stoppedByApp.contains(report.sessionId) {
                return captureState.isTerminal ? .ignored : .stopAgain(s.controlConnection(for: profileID))
            }
            // A capture the app doesn't know yet: started from the browser (icon click with no
            // pending request) or still running from before an app restart. Offer it for adoption.
            guard captureState == .capturing, let windowID = report.windowId, let tabID = report.tabId else {
                return .ignored
            }
            s.sessions[report.sessionId] = SessionRoute(profileID: profileID, windowID: windowID, tabID: tabID)
            return .adopted(windowID: windowID, tabID: tabID)
        }
        switch outcome {
        case .ignored:
            return
        case .stopAgain(let connection):
            connection?.send(.stopCapture(sessionID: report.sessionId))
        case .adopted(let windowID, let tabID):
            eventSubscribers.yield(.userInitiatedCapture(
                sessionID: report.sessionId, profileID: profileID, windowID: windowID, tabID: tabID
            ))
            eventSubscribers.yield(.captureState(sessionID: report.sessionId, captureState))
        case .known:
            if captureState.isTerminal {
                endSession(report.sessionId, state: captureState)
            } else {
                eventSubscribers.yield(.captureState(sessionID: report.sessionId, captureState))
            }
        }
    }

    private func endSession(_ sessionID: UUID, state captureState: BridgeCaptureState) {
        eventSubscribers.yield(.captureState(sessionID: sessionID, captureState))
        audioSubscribers.finish(sessionID)
        videoSubscribers.finish(sessionID)
    }

    private func handleBinary(_ data: Data, profileID: String) {
        guard let header = try? BinaryFrameHeader.decode(data) else { return }
        let routed = state.withLock { $0.sessions[header.sessionID]?.profileID == profileID }
        guard routed else { return }
        switch header.kind {
        case .audioPCM16:
            guard audioSubscribers.hasSubscribers(header.sessionID) else { return }
            if case .audio(let chunk)? = try? BinaryFrame.decode(data) {
                audioSubscribers.yield(chunk, to: header.sessionID)
            }
        case .videoJPEG:
            guard videoSubscribers.hasSubscribers(header.sessionID) else { return }
            if case .video(let frame)? = try? BinaryFrame.decode(data) {
                videoSubscribers.yield(frame, to: header.sessionID)
            }
        }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// One-shot result handoff from the listener's queue to the thread calling `start()`.
private final class ReadyLatch: Sendable {
    private let result = Mutex<Result<UInt16, any Error>?>(nil)
    private let semaphore = DispatchSemaphore(value: 0)

    func signal(_ value: Result<UInt16, any Error>) {
        let first = result.withLock { current in
            guard current == nil else { return false }
            current = value
            return true
        }
        if first { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Result<UInt16, any Error>? {
        _ = semaphore.wait(timeout: .now() + timeout)
        return result.withLock { $0 }
    }
}
