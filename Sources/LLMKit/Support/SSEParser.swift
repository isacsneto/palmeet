import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Line-based Server-Sent Events parser (https://html.spec.whatwg.org/multipage/server-sent-events.html).
///
/// Feed it lines without their terminator; an empty line dispatches the pending event.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(line rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break // id, retry: unused
        }
        return nil
    }

    /// Flushes an event left pending when the stream ends without a trailing blank line.
    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    /// Parses a complete SSE payload. Convenient for tests and buffered responses.
    public static func parse(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        // `isNewline` treats "\r\n" (a single Character) as one separator.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let event = parser.consume(line: String(line)) { events.append(event) }
        }
        if let event = parser.finish() { events.append(event) }
        return events
    }

    /// Parses an async byte stream (e.g. `URLSession.AsyncBytes`), calling `body` for each event.
    ///
    /// Lines are split manually because `AsyncLineSequence` drops the blank lines that delimit events.
    public static func forEachEvent<Bytes: AsyncSequence>(
        in bytes: Bytes,
        _ body: (SSEEvent) throws -> Void
    ) async throws where Bytes.Element == UInt8 {
        var parser = SSEParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if let event = parser.consume(line: String(decoding: line, as: UTF8.self)) { try body(event) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty, let event = parser.consume(line: String(decoding: line, as: UTF8.self)) { try body(event) }
        if let event = parser.finish() { try body(event) }
    }
}
