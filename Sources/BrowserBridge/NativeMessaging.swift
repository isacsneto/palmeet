import Foundation

/// Chrome native messaging framing: each message is UTF-8 JSON prefixed by its length as a
/// 32-bit unsigned integer in native byte order.
public enum NativeMessagingFraming {
    /// Chrome caps host → browser messages at 1 MB; we apply the same cap in both directions.
    public static let maxMessageSize = 1024 * 1024

    public enum FramingError: Error, Equatable {
        case messageTooLarge(Int)
        case truncated
    }

    public static func encode(_ json: Data) throws -> Data {
        guard json.count <= maxMessageSize else { throw FramingError.messageTooLarge(json.count) }
        var data = Data(capacity: 4 + json.count)
        withUnsafeBytes(of: UInt32(json.count)) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    /// Decodes the first framed message in `buffer`.
    /// Returns `nil` when the buffer doesn't yet hold a complete message.
    public static func decode(_ buffer: Data) throws -> (message: Data, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(lengthPrefix(buffer.prefix(4)))
        guard length <= maxMessageSize else { throw FramingError.messageTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        return (Data(buffer[start..<start + length]), 4 + length)
    }

    /// Blocking read of one message from a file handle. Returns `nil` on clean EOF.
    public static func readMessage(from handle: FileHandle) throws -> Data? {
        let prefix = handle.readData(ofLength: 4)
        if prefix.isEmpty { return nil }
        guard prefix.count == 4 else { throw FramingError.truncated }
        let length = Int(lengthPrefix(prefix))
        guard length <= maxMessageSize else { throw FramingError.messageTooLarge(length) }
        let body = handle.readData(ofLength: length)
        guard body.count == length else { throw FramingError.truncated }
        return body
    }

    private static func lengthPrefix(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dst in
            for (i, byte) in bytes.prefix(4).enumerated() { dst[i] = byte }
        }
        return value  // native byte order, as Chrome writes it
    }
}

/// The PalMeet executable doubles as the native messaging host `app.palmeet.bridge`.
///
/// Chrome launches the host with the caller's origin (`chrome-extension://<id>/`) as an argument.
/// The host answers a single `{"type":"getBridgeInfo"}` request with
/// `{"type":"bridgeInfo","port":…,"token":…}` read from `bridge.json`, then exits.
public enum NativeMessagingHost {
    /// Call first thing in `main`. Returns `true` if this process was launched as a native
    /// messaging host and the request was handled; the caller should then exit immediately.
    public static func runIfInvoked(arguments: [String]) -> Bool {
        runIfInvoked(
            arguments: arguments, input: .standardInput, output: .standardOutput, store: BridgeInfoStore()
        )
    }

    static func runIfInvoked(
        arguments: [String], input: FileHandle, output: FileHandle, store: BridgeInfoStore
    ) -> Bool {
        guard callerOrigin(in: arguments) != nil else { return false }
        // Chrome sends one request per `sendNativeMessage`; answer every message until EOF
        // (normally exactly one) so a `connectNative` port also works.
        while true {
            let request: Data
            do {
                guard let message = try NativeMessagingFraming.readMessage(from: input) else { break }
                request = message
            } catch {
                break
            }
            let reply = response(for: request, store: store)
            guard let framed = try? NativeMessagingFraming.encode(reply) else { break }
            output.write(framed)
        }
        return true
    }

    /// The `chrome-extension://…/` origin argument, if present.
    public static func callerOrigin(in arguments: [String]) -> String? {
        arguments.dropFirst().first { $0.hasPrefix("chrome-extension://") }
    }

    private struct Request: Decodable { var type: String? }

    private struct InfoReply: Encodable {
        let type = "bridgeInfo"
        var port: UInt16
        var token: String
        var protocolVersion: Int
    }

    private struct ErrorReply: Encodable {
        let type = "error"
        var error: String
        var message: String
    }

    /// Pure request → reply mapping (JSON in, JSON out).
    static func response(for request: Data, store: BridgeInfoStore) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func error(_ code: String, _ message: String) -> Data {
            (try? encoder.encode(ErrorReply(error: code, message: message))) ?? Data("{\"type\":\"error\"}".utf8)
        }
        guard let parsed = try? JSONDecoder().decode(Request.self, from: request), parsed.type == "getBridgeInfo"
        else {
            return error("badRequest", "Expected {\"type\":\"getBridgeInfo\"}.")
        }
        guard let info = store.load() else {
            return error("notConfigured", "PalMeet has not started its browser bridge yet.")
        }
        guard info.isLive, let port = info.port else {
            return error("notRunning", "PalMeet is not running.")
        }
        return (try? encoder.encode(
            InfoReply(port: port, token: info.token, protocolVersion: browserBridgeProtocolVersion)
        )) ?? error("internal", "Encoding failed.")
    }
}
