import Foundation

/// Protocol version spoken by this server (sent in `welcome`).
public let browserBridgeProtocolVersion = 1

// MARK: - Extension → app

/// JSON text messages sent by the extension. See `Extension/chromium/PROTOCOL.md`.
public enum ExtensionMessage: Sendable, Equatable {
    case hello(Hello)
    case windows([BrowserWindow])
    case captureState(CaptureStateReport)
    case meetingState(MeetingStateReport)
    case ping
    /// A well-formed message with a `type` this version does not know (ignored).
    case unknown(type: String)

    public struct Hello: Sendable, Equatable, Codable {
        public enum Role: String, Sendable, Codable {
            /// The service worker's control connection (one per profile).
            case control
            /// The offscreen document's media connection (binary frames only).
            case media
        }

        public var token: String
        public var profileInstanceId: String
        public var profileLabel: String
        public var browser: String
        public var extensionVersion: String
        public var role: Role

        public init(
            token: String, profileInstanceId: String, profileLabel: String, browser: String,
            extensionVersion: String, role: Role = .control
        ) {
            self.token = token
            self.profileInstanceId = profileInstanceId
            self.profileLabel = profileLabel
            self.browser = browser
            self.extensionVersion = extensionVersion
            self.role = role
        }

        enum CodingKeys: String, CodingKey {
            case token, profileInstanceId, profileLabel, browser, extensionVersion, role
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            profileInstanceId = try c.decode(String.self, forKey: .profileInstanceId)
            profileLabel = try c.decodeIfPresent(String.self, forKey: .profileLabel) ?? ""
            browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? "Chromium"
            extensionVersion = try c.decodeIfPresent(String.self, forKey: .extensionVersion) ?? "?"
            role = (try? c.decodeIfPresent(Role.self, forKey: .role)) ?? .control
        }
    }

    public struct CaptureStateReport: Sendable, Equatable, Codable {
        public var sessionId: UUID
        public var state: String
        public var message: String?
        public var userInitiated: Bool?
        public var windowId: Int?
        public var tabId: Int?

        public init(
            sessionId: UUID, state: String, message: String? = nil, userInitiated: Bool? = nil,
            windowId: Int? = nil, tabId: Int? = nil
        ) {
            self.sessionId = sessionId
            self.state = state
            self.message = message
            self.userInitiated = userInitiated
            self.windowId = windowId
            self.tabId = tabId
        }

        /// Maps the wire state to the public enum; unknown strings become `.error`.
        public var captureState: BridgeCaptureState {
            switch state {
            case "awaitingGesture": .awaitingGesture
            case "capturing": .capturing
            case "stopped": .stopped(message)
            case "error": .error(message ?? "Unknown error")
            default: .error("Unknown capture state '\(state)'")
            }
        }
    }

    public struct MeetingStateReport: Sendable, Equatable, Codable {
        public var sessionId: UUID
        public var muted: Bool?
        public var presenting: Bool?

        public init(sessionId: UUID, muted: Bool?, presenting: Bool?) {
            self.sessionId = sessionId
            self.muted = muted
            self.presenting = presenting
        }
    }

    public enum DecodingError: Error, Equatable {
        case missingType
    }

    private struct Envelope: Decodable { var type: String? }
    private struct WindowsPayload: Decodable { var windows: [BrowserWindow] }

    /// Decodes one text frame. Throws for malformed JSON or a known type with a bad payload.
    public static func decode(_ data: Data) throws -> ExtensionMessage {
        let decoder = JSONDecoder()
        guard let type = try decoder.decode(Envelope.self, from: data).type else {
            throw DecodingError.missingType
        }
        switch type {
        case "hello": return .hello(try decoder.decode(Hello.self, from: data))
        case "windows": return .windows(try decoder.decode(WindowsPayload.self, from: data).windows)
        case "captureState": return .captureState(try decoder.decode(CaptureStateReport.self, from: data))
        case "meetingState": return .meetingState(try decoder.decode(MeetingStateReport.self, from: data))
        case "ping": return .ping
        default: return .unknown(type: type)
        }
    }
}

// MARK: - App → extension

/// JSON text messages sent by the app.
public enum AppMessage: Sendable, Equatable {
    case welcome(protocolVersion: Int, profileInstanceId: String)
    case startCapture(sessionID: UUID, windowID: Int, tabID: Int)
    case stopCapture(sessionID: UUID)
    case pong

    private struct Welcome: Encodable {
        let type = "welcome"
        var protocolVersion: Int
        var profileInstanceId: String
    }

    private struct StartCapture: Encodable {
        let type = "startCapture"
        var sessionId: String
        var windowId: Int
        var tabId: Int
    }

    private struct StopCapture: Encodable {
        let type = "stopCapture"
        var sessionId: String
    }

    private struct Pong: Encodable { let type = "pong" }

    /// Session IDs go on the wire as lowercase RFC 4122 strings (what `crypto.randomUUID()` emits).
    static func wireString(_ id: UUID) -> String { id.uuidString.lowercased() }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .welcome(let version, let profile):
            return try encoder.encode(Welcome(protocolVersion: version, profileInstanceId: profile))
        case .startCapture(let session, let window, let tab):
            return try encoder.encode(StartCapture(sessionId: Self.wireString(session), windowId: window, tabId: tab))
        case .stopCapture(let session):
            return try encoder.encode(StopCapture(sessionId: Self.wireString(session)))
        case .pong:
            return try encoder.encode(Pong())
        }
    }
}
