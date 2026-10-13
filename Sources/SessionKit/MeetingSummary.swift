import Foundation

/// Structured summary returned by the LLM (as JSON) and rendered to `summary.md` by `SummaryMarkdownRenderer`.
/// Every field is optional/defaulted on decode so a partially compliant model response still renders.
public struct MeetingSummary: Codable, Sendable, Equatable {
    public struct Participant: Codable, Sendable, Equatable {
        public var name: String
        public var role: String?

        public init(name: String, role: String? = nil) {
            self.name = name
            self.role = role
        }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: text)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: c.lenientString(.name) ?? "", role: c.lenientString(.role))
        }
    }

    public struct Topic: Codable, Sendable, Equatable {
        public var title: String
        public var start: String?
        public var summary: String

        public init(title: String, start: String? = nil, summary: String) {
            self.title = title
            self.start = start
            self.summary = summary
        }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(title: text, summary: "")
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(title: c.lenientString(.title) ?? "Topic", start: c.lenientString(.start), summary: c.lenientString(.summary) ?? "")
        }
    }

    public struct Decision: Codable, Sendable, Equatable {
        public var text: String
        public var ref: String?

        public init(text: String, ref: String? = nil) {
            self.text = text
            self.ref = ref
        }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(text: text)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(text: c.lenientString(.text) ?? "", ref: c.lenientString(.ref))
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        public var owner: String?
        public var task: String
        public var due: String?
        public var ref: String?

        public init(owner: String? = nil, task: String, due: String? = nil, ref: String? = nil) {
            self.owner = owner
            self.task = task
            self.due = due
            self.ref = ref
        }

        public init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.init(task: text)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(owner: c.lenientString(.owner), task: c.lenientString(.task) ?? "", due: c.lenientString(.due), ref: c.lenientString(.ref))
        }
    }

    public struct Quote: Codable, Sendable, Equatable {
        public var speaker: String
        public var quote: String
        public var ref: String?

        public init(speaker: String, quote: String, ref: String? = nil) {
            self.speaker = speaker
            self.quote = quote
            self.ref = ref
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(speaker: c.lenientString(.speaker) ?? "", quote: c.lenientString(.quote) ?? "", ref: c.lenientString(.ref))
        }
    }

    public struct VisualContext: Codable, Sendable, Equatable {
        public var ref: String?
        public var screenshot: String?
        public var description: String

        public init(ref: String? = nil, screenshot: String? = nil, description: String) {
            self.ref = ref
            self.screenshot = screenshot
            self.description = description
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(ref: c.lenientString(.ref), screenshot: c.lenientString(.screenshot), description: c.lenientString(.description) ?? "")
        }
    }

    public var title: String
    public var tldr: String
    public var participants: [Participant]
    public var topics: [Topic]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var keyTakeaways: [String]
    public var openQuestions: [String]
    public var risks: [String]
    public var notableQuotes: [Quote]
    public var visualContext: [VisualContext]
    /// Questions the user raised and commitments they made (from the "Me" track).
    public var myQuestionsAndCommitments: [String]

    enum CodingKeys: String, CodingKey {
        case title, tldr, participants, topics, decisions
        case actionItems = "action_items"
        case keyTakeaways = "key_takeaways"
        case openQuestions = "open_questions"
        case risks
        case notableQuotes = "notable_quotes"
        case visualContext = "visual_context"
        case myQuestionsAndCommitments = "my_questions_and_commitments"
    }

    public init(
        title: String,
        tldr: String,
        participants: [Participant] = [],
        topics: [Topic] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        keyTakeaways: [String] = [],
        openQuestions: [String] = [],
        risks: [String] = [],
        notableQuotes: [Quote] = [],
        visualContext: [VisualContext] = [],
        myQuestionsAndCommitments: [String] = []
    ) {
        self.title = title
        self.tldr = tldr
        self.participants = participants
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.keyTakeaways = keyTakeaways
        self.openQuestions = openQuestions
        self.risks = risks
        self.notableQuotes = notableQuotes
        self.visualContext = visualContext
        self.myQuestionsAndCommitments = myQuestionsAndCommitments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenientString(.title) ?? "Meeting"
        tldr = c.lenientString(.tldr) ?? ""
        participants = c.lenientArray(Participant.self, .participants)
        topics = c.lenientArray(Topic.self, .topics)
        decisions = c.lenientArray(Decision.self, .decisions)
        actionItems = c.lenientArray(ActionItem.self, .actionItems).filter { !$0.task.isEmpty }
        keyTakeaways = c.lenientStrings(.keyTakeaways)
        openQuestions = c.lenientStrings(.openQuestions)
        risks = c.lenientStrings(.risks)
        notableQuotes = c.lenientArray(Quote.self, .notableQuotes)
        visualContext = c.lenientArray(VisualContext.self, .visualContext)
        myQuestionsAndCommitments = c.lenientStrings(.myQuestionsAndCommitments)
    }

    /// JSON skeleton included in prompts so models know the exact shape.
    public static let jsonSchemaExample = """
    {
      "title": "short meeting title",
      "tldr": "2-4 sentence overview",
      "participants": [{"name": "Name", "role": "role if known"}],
      "topics": [{"title": "Topic", "start": "00:03:10", "summary": "what was discussed"}],
      "decisions": [{"text": "what was decided", "ref": "00:21:05"}],
      "action_items": [{"owner": "Name", "task": "what", "due": "when, if said", "ref": "00:40:12"}],
      "key_takeaways": ["..."],
      "open_questions": ["..."],
      "risks": ["..."],
      "notable_quotes": [{"speaker": "Name", "quote": "verbatim", "ref": "00:10:00"}],
      "visual_context": [{"ref": "00:12:00", "screenshot": "screenshots/0007_00-12-00.jpg", "description": "what the screen showed"}],
      "my_questions_and_commitments": ["questions I asked or things I committed to"]
    }
    """
}

// MARK: - Lenient decoding (models don't always follow the schema exactly)

private struct AnyDecodable: Decodable {}

extension KeyedDecodingContainer {
    /// A string, or a number/bool rendered as text; nil when missing or another type.
    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    /// Decodes each element independently, skipping malformed ones instead of failing the whole array.
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                result.append(value)
            } else if (try? container.decode(AnyDecodable.self)) == nil {
                break
            }
        }
        return result
    }

    /// Strings, accepting objects with a "text" field and skipping anything else.
    func lenientStrings(_ key: Key) -> [String] {
        lenientArray(LenientText.self, key).map(\.text).filter { !$0.isEmpty }
    }
}

private struct LenientText: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            text = value
            return
        }
        struct Keys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let candidates = ["text", "question", "takeaway", "risk", "item", "description"]
        text = candidates.lazy.compactMap { key in Keys(stringValue: key).flatMap { try? c.decode(String.self, forKey: $0) } }.first ?? ""
    }
}

extension MeetingSummary {
    /// Applies `transform` to every free-text field (used to propagate speaker renames).
    public func mapText(_ transform: (String) -> String) -> MeetingSummary {
        var copy = self
        copy.title = transform(title)
        copy.tldr = transform(tldr)
        copy.participants = participants.map { Participant(name: transform($0.name), role: $0.role.map(transform)) }
        copy.topics = topics.map { Topic(title: transform($0.title), start: $0.start, summary: transform($0.summary)) }
        copy.decisions = decisions.map { Decision(text: transform($0.text), ref: $0.ref) }
        copy.actionItems = actionItems.map { ActionItem(owner: $0.owner.map(transform), task: transform($0.task), due: $0.due, ref: $0.ref) }
        copy.keyTakeaways = keyTakeaways.map(transform)
        copy.openQuestions = openQuestions.map(transform)
        copy.risks = risks.map(transform)
        copy.notableQuotes = notableQuotes.map { Quote(speaker: transform($0.speaker), quote: transform($0.quote), ref: $0.ref) }
        copy.visualContext = visualContext.map { VisualContext(ref: $0.ref, screenshot: $0.screenshot, description: transform($0.description)) }
        copy.myQuestionsAndCommitments = myQuestionsAndCommitments.map(transform)
        return copy
    }

    /// Replaces a speaker label as a whole word ("Speaker 1" never touches "Speaker 12").
    public func replacingName(_ old: String, with new: String) -> MeetingSummary {
        guard !old.isEmpty, old != new else { return self }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let template = NSRegularExpression.escapedTemplate(for: new)
        return mapText { text in
            regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }
}
