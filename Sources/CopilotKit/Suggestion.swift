import Foundation

public struct Suggestion: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// What to say in reply to a question addressed to the user.
        case answer
        /// Good questions to ask now.
        case questions
        /// A question to the user that hasn't been answered yet.
        case reminder
    }

    public enum Status: String, Codable, Sendable {
        case streaming
        case ready
        case used
        case dismissed
        case pinned
        case failed
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var text: String
        /// Why it matters (questions) or extra detail (answers).
        public var detail: String?
        public var confidence: String?

        public init(id: UUID = UUID(), text: String, detail: String? = nil, confidence: String? = nil) {
            self.id = id
            self.text = text
            self.detail = detail
            self.confidence = confidence
        }
    }

    public var id: UUID
    public var kind: Kind
    public var status: Status
    /// Session offset when the trigger happened.
    public var offset: TimeInterval
    public var createdAt: Date
    /// The question being answered, with who asked it.
    public var triggerText: String?
    public var askedBy: String?
    public var items: [Item]
    /// "This commits you to Friday", etc.
    public var warnings: [String]
    public var followUps: [String]
    public var feedback: Int?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        status: Status = .streaming,
        offset: TimeInterval,
        createdAt: Date = Date(),
        triggerText: String? = nil,
        askedBy: String? = nil,
        items: [Item] = [],
        warnings: [String] = [],
        followUps: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.offset = offset
        self.createdAt = createdAt
        self.triggerText = triggerText
        self.askedBy = askedBy
        self.items = items
        self.warnings = warnings
        self.followUps = followUps
    }
}

/// Parses the copilot's line protocol as it streams, so cards fill in while the model is still writing.
///
///     FOR_ME|yes
///     OPTION|high|We can ship Friday if QA signs off by Thursday.
///     WARN|This commits you to Friday.
///     FOLLOWUP|Which QA environment are we using?
///     Q|high|What happens when the user is offline?|Offline isn't covered by the acceptance criteria.
public struct SuggestionLineParser: Sendable {
    public enum Verdict: Sendable, Equatable {
        case undecided
        case forMe
        case notForMe
    }

    public private(set) var verdict: Verdict = .undecided
    public private(set) var items: [Suggestion.Item] = []
    public private(set) var warnings: [String] = []
    public private(set) var followUps: [String] = []
    private var buffer = ""

    public init() {}

    /// Feeds a streamed delta; returns true when a complete line changed the parsed state.
    @discardableResult
    public mutating func feed(_ delta: String) -> Bool {
        buffer += delta
        var changed = false
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            changed = parse(line) || changed
        }
        return changed
    }

    /// Parses the trailing line without a newline at end of stream.
    @discardableResult
    public mutating func finish() -> Bool {
        defer { buffer = "" }
        return parse(buffer)
    }

    private mutating func parse(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*` "))
        guard !line.isEmpty else { return false }
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let tag = fields.first?.uppercased() else { return false }

        switch tag {
        case "FOR_ME":
            verdict = fields.dropFirst().first?.lowercased().hasPrefix("y") == true ? .forMe : .notForMe
            return true
        case "OPTION" where fields.count >= 3:
            items.append(Suggestion.Item(text: fields[2...].joined(separator: " | "), confidence: fields[1].lowercased()))
            return true
        case "OPTION" where fields.count == 2:
            items.append(Suggestion.Item(text: fields[1]))
            return true
        case "Q" where fields.count >= 3:
            let detail = fields.count >= 4 ? fields[3...].joined(separator: " | ") : nil
            items.append(Suggestion.Item(text: fields[2], detail: detail, confidence: fields[1].lowercased()))
            return true
        case "Q" where fields.count == 2:
            items.append(Suggestion.Item(text: fields[1]))
            return true
        case "WARN" where fields.count >= 2:
            warnings.append(fields[1...].joined(separator: " | "))
            return true
        case "FOLLOWUP" where fields.count >= 2:
            followUps.append(fields[1...].joined(separator: " | "))
            return true
        default:
            return false
        }
    }
}
