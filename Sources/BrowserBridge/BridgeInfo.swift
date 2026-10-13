import Foundation

/// Contents of `~/Library/Application Support/PalMeet/bridge.json`.
///
/// Written by the running app's `BrowserBridgeServer`; read by the native messaging host
/// (`NativeMessagingHost`) to hand `{port, token}` to the extension.
public struct BridgeInfo: Sendable, Equatable, Codable {
    /// Listening port, or `nil` while the server is stopped.
    public var port: UInt16?
    /// Shared secret; 32 random bytes as lowercase hex. Persisted across launches.
    public var token: String
    /// PID of the app that owns `port` (used to detect a stale file after a crash).
    public var pid: Int32?
    public var updatedAt: Date

    public init(port: UInt16?, token: String, pid: Int32?, updatedAt: Date = Date()) {
        self.port = port
        self.token = token
        self.pid = pid
        self.updatedAt = updatedAt
    }

    /// True when a port is recorded and its owning process is still alive.
    public var isLive: Bool {
        guard port != nil else { return false }
        guard let pid else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// 32 cryptographically random bytes, hex encoded (64 chars).
    public static func generateToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
}

/// Reads and writes `bridge.json` atomically with 0600 permissions.
public struct BridgeInfoStore: Sendable {
    public var url: URL

    public init(url: URL = BridgeInfoStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/PalMeet/bridge.json", directoryHint: .notDirectory)
    }

    public func load() -> BridgeInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BridgeInfo.self, from: data)
    }

    public func save(_ info: BridgeInfo) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Returns the persisted token, creating (and saving) a new one if none exists.
    public func loadOrCreateToken() throws -> String {
        if let existing = load(), Self.isValidToken(existing.token) { return existing.token }
        let token = BridgeInfo.generateToken()
        try save(BridgeInfo(port: nil, token: token, pid: nil))
        return token
    }

    static func isValidToken(_ token: String) -> Bool {
        token.count == 64 && token.allSatisfy(\.isHexDigit)
    }
}
