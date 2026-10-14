import Foundation

/// Who the meeting app itself showed as talking: live captions (labelled with the speaker's name by the
/// meeting service) and "is speaking" indicators on participant tiles. Times are session offsets in seconds.
public struct MeetingSpeakerTimeline: Codable, Sendable, Equatable {
    public struct Caption: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var text: String
        /// When the caption first appeared (shortly after the person started talking).
        public var firstSeen: TimeInterval
        /// When its text last changed (shortly after they stopped).
        public var lastSeen: TimeInterval

        public init(id: String, name: String, text: String, firstSeen: TimeInterval, lastSeen: TimeInterval) {
            self.id = id
            self.name = name
            self.text = text
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    public struct SpeakingSpan: Codable, Sendable, Equatable {
        public var name: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(name: String, start: TimeInterval, end: TimeInterval) {
            self.name = name
            self.start = start
            self.end = end
        }
    }

    public var captions: [Caption] = []
    public var speaking: [SpeakingSpan] = []
    /// Names shown as speaking at the last update, with when they started.
    public var openSpeaking: [String: TimeInterval] = [:]

    public init(captions: [Caption] = [], speaking: [SpeakingSpan] = []) {
        self.captions = captions
        self.speaking = speaking
    }

    public var isEmpty: Bool { captions.isEmpty && speaking.isEmpty && openSpeaking.isEmpty }

    /// Everyone the meeting named, most talkative first.
    public var names: [String] {
        var words: [String: Int] = [:]
        for caption in captions { words[caption.name, default: 0] += caption.text.split(separator: " ").count }
        for span in speaking { words[span.name, default: 0] += max(1, Int(span.end - span.start)) }
        return words.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// A caption appeared or changed. Unnamed captions are ignored (they can't tell who spoke).
    public mutating func recordCaption(id: String, name: String?, text: String, at offset: TimeInterval) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !text.isEmpty else { return }
        if let index = captions.lastIndex(where: { $0.id == id }) {
            captions[index].name = name
            captions[index].text = text
            captions[index].lastSeen = max(captions[index].lastSeen, offset)
        } else {
            captions.append(Caption(id: id, name: name, text: text, firstSeen: offset, lastSeen: offset))
        }
    }

    /// The names shown as speaking now (`nil`: the page has no indicator; treated as nobody).
    public mutating func recordSpeaking(_ names: [String]?, at offset: TimeInterval) {
        let current = Set(names ?? [])
        for (name, start) in openSpeaking where !current.contains(name) {
            speaking.append(SpeakingSpan(name: name, start: start, end: offset))
            openSpeaking[name] = nil
        }
        for name in current where openSpeaking[name] == nil {
            openSpeaking[name] = offset
        }
    }

    /// Closes open speaking spans at the end of the recording.
    public mutating func finish(at offset: TimeInterval) {
        recordSpeaking(nil, at: offset)
        speaking.sort { ($0.start, $0.name) < ($1.start, $1.name) }
    }
}
