import Foundation
import SessionKit

/// Builds the final speaker-attributed transcript from per-track words, diarization and mic routing.
public enum TranscriptAssembler {
    public struct Input: Sendable {
        /// Remote-track words, session-relative.
        public var themWords: [TranscriptWord]
        /// Microphone words, session-relative.
        public var meWords: [TranscriptWord]
        public var diarization: [DiarizedSpan]
        /// When the mic was routed to this session; `nil` means always.
        public var micRouting: [MicRouteSpan]?
        public var meName: String
        /// Captions / speaking indicators from the meeting app, when recorded.
        public var timeline: MeetingSpeakerTimeline?
        /// Diarizer speaker key → voiceprint.
        public var voiceprints: [String: [Float]]
        /// Voices learned in earlier meetings.
        public var knownVoices: [VoiceProfile]

        public init(
            themWords: [TranscriptWord],
            meWords: [TranscriptWord],
            diarization: [DiarizedSpan],
            micRouting: [MicRouteSpan]?,
            meName: String,
            timeline: MeetingSpeakerTimeline? = nil,
            voiceprints: [String: [Float]] = [:],
            knownVoices: [VoiceProfile] = []
        ) {
            self.themWords = themWords
            self.meWords = meWords
            self.diarization = diarization
            self.micRouting = micRouting
            self.meName = meName
            self.timeline = timeline
            self.voiceprints = voiceprints
            self.knownVoices = knownVoices
        }
    }

    public struct Output: Sendable {
        public var transcript: Transcript
        /// Voiceprint of each remote speaker in the transcript (merged speakers combined).
        public var voices: [String: SpeakerVoice]
        /// Speakers the meeting itself named whose voice is reliable to learn.
        public var learnableVoices: Set<String>
    }

    public struct Options: Sendable {
        /// Start a new segment after this much silence.
        public var maxGap: TimeInterval = 1.5
        /// Split long monologues at the next sentence end after this duration.
        public var softMaxDuration: TimeInterval = 30
        /// Mic segments this similar to simultaneous remote speech are treated as echo and dropped.
        public var echoSimilarity: Double = 0.6

        public init() {}
    }

    public static let unknownRemoteID = "them"

    public static func assemble(sessionID: SessionID, input: Input, options: Options = Options()) -> Transcript {
        assembleDetailed(sessionID: sessionID, input: input, options: options).transcript
    }

    public static func assembleDetailed(
        sessionID: SessionID,
        input: Input,
        options: Options = Options(),
        attribution: SpeakerAttribution.Options = SpeakerAttribution.Options()
    ) -> Output {
        // Remote words → diarized speakers.
        let keyOrder = firstAppearanceOrder(input.diarization)
        let speakerIDForKey = Dictionary(uniqueKeysWithValues: keyOrder.enumerated().map { ($1, "S\($0 + 1)") })
        var lastKey: String?
        let clustered: [(cluster: String, word: TranscriptWord)] = input.themWords.map { word in
            let key = speakerKey(for: word, in: input.diarization) ?? lastKey
            lastKey = key ?? lastKey
            return (key.flatMap { speakerIDForKey[$0] } ?? unknownRemoteID, word)
        }

        // Voiceprints per cluster, weighted by how long each spoke.
        var seconds: [String: Double] = [:]
        for span in input.diarization {
            if let id = speakerIDForKey[span.speakerKey] { seconds[id, default: 0] += span.end - span.start }
        }
        var clusterVoices: [String: SpeakerVoice] = [:]
        for (key, vector) in input.voiceprints {
            guard let id = speakerIDForKey[key], let normalized = Voiceprint.normalized(vector) else { continue }
            clusterVoices[id] = SpeakerVoice(vector: normalized, seconds: seconds[id] ?? 0)
        }

        // Mic words → "me", only while routed to this session.
        let routedMe = input.meWords.filter { word in
            guard let routing = input.micRouting else { return true }
            let mid = (word.start + word.end) / 2
            return routing.contains { $0.contains(mid) }
        }

        // Meeting captions, speaking indicators and known voices name (and merge/split) the clusters.
        let attributed = SpeakerAttribution.attribute(
            words: clustered, timeline: input.timeline, selfWords: routedMe, voices: clusterVoices,
            knownVoices: input.knownVoices, unknownID: unknownRemoteID, options: attribution
        )
        let themLabeled = zip(attributed.labels, clustered).map { ($0, $1.word) }
        let themSegments = group(themLabeled, track: .them, options: options)

        let meSegments = group(routedMe.map { (Speaker.meID, $0) }, track: .me, options: options)
            .filter { !isEcho($0, of: themSegments, threshold: options.echoSimilarity) }

        // Only speakers with lines are listed (an imported recording has no separate "me" track), in order of
        // first appearance; diarizer clusters keep their number ("Speaker 3") until something names them.
        var speakers = meSegments.isEmpty ? [] : [Speaker.me(named: input.meName)]
        var listed = Set<String>()
        for segment in themSegments.sorted(by: { $0.start < $1.start }) where listed.insert(segment.speakerID).inserted {
            let id = segment.speakerID
            if let named = attributed.names[id] {
                speakers.append(Speaker(id: id, displayName: named.name, nameSource: named.source.rawValue))
            } else if id == unknownRemoteID {
                speakers.append(Speaker(id: id, displayName: keyOrder.isEmpty ? "Participants" : "Unknown speaker"))
            } else {
                speakers.append(Speaker(id: id, displayName: "Speaker \(id.dropFirst())"))
            }
        }

        // Voices of the final speakers: merged clusters combine theirs.
        var voices: [String: SpeakerVoice] = [:]
        for (cluster, voice) in clusterVoices {
            let target = attributed.merged[cluster] ?? cluster
            guard listed.contains(target) else { continue }
            if let existing = voices[target],
               let combined = Voiceprint.mean([(existing.vector, existing.seconds), (voice.vector, voice.seconds)]) {
                voices[target] = SpeakerVoice(vector: combined, seconds: existing.seconds + voice.seconds)
            } else {
                voices[target] = voice
            }
        }

        var transcript = Transcript(sessionID: sessionID, speakers: speakers, segments: themSegments + meSegments)
        transcript.sortSegments()
        return Output(transcript: transcript, voices: voices, learnableVoices: attributed.learnable.intersection(listed))
    }

    // MARK: - Steps

    static func firstAppearanceOrder(_ spans: [DiarizedSpan]) -> [String] {
        var seen = Set<String>()
        return spans.sorted { $0.start < $1.start }.compactMap { seen.insert($0.speakerKey).inserted ? $0.speakerKey : nil }
    }

    /// The diarized speaker overlapping the word the most; words in gaps snap to the nearest span within 0.5 s.
    static func speakerKey(for word: TranscriptWord, in spans: [DiarizedSpan]) -> String? {
        var best: (key: String, overlap: TimeInterval)?
        for span in spans where span.end > word.start && span.start < word.end {
            let overlap = min(span.end, word.end) - max(span.start, word.start)
            if overlap > (best?.overlap ?? 0) { best = (span.speakerKey, overlap) }
        }
        if let best { return best.key }
        let mid = (word.start + word.end) / 2
        let nearest = spans.min { distance(mid, $0) < distance(mid, $1) }
        if let nearest, distance(mid, nearest) <= 0.5 { return nearest.speakerKey }
        return nil
    }

    private static func distance(_ time: TimeInterval, _ span: DiarizedSpan) -> TimeInterval {
        if time < span.start { return span.start - time }
        if time > span.end { return time - span.end }
        return 0
    }

    static func group(_ labeled: [(String, TranscriptWord)], track: Track, options: Options) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentSpeaker: String?
        var words: [TranscriptWord] = []

        func flush() {
            guard let speaker = currentSpeaker, let first = words.first, let last = words.last else { return }
            let text = words.map(\.text).joined(separator: " ")
            let confidence = words.map(\.confidence).reduce(0, +) / Float(words.count)
            segments.append(TranscriptSegment(speakerID: speaker, track: track, start: first.start, end: last.end, text: text, words: words, confidence: confidence))
            words.removeAll()
        }

        for (speaker, word) in labeled.sorted(by: { $0.1.start < $1.1.start }) {
            let gap = word.start - (words.last?.end ?? word.start)
            let duration = word.end - (words.first?.start ?? word.start)
            let endsSentence = words.last.map { endsWithSentencePunctuation($0.text) } ?? false
            if speaker != currentSpeaker || gap > options.maxGap || (duration > options.softMaxDuration && endsSentence) {
                flush()
                currentSpeaker = speaker
            }
            words.append(word)
        }
        flush()
        return segments
    }

    static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }

    /// Speaker-phone bleed: the mic picked up remote speech that echo cancellation missed.
    static func isEcho(_ segment: TranscriptSegment, of remote: [TranscriptSegment], threshold: Double) -> Bool {
        let overlapping = remote.filter { $0.start < segment.end + 1 && $0.end > segment.start - 1 }
        guard !overlapping.isEmpty else { return false }
        let remoteText = overlapping.map(\.text).joined(separator: " ")
        return TextSimilarity.containment(segment.text, in: remoteText) >= threshold
    }
}

public enum TextSimilarity {
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    /// Fraction of `text`'s tokens that also occur in `other` (0...1).
    public static func containment(_ text: String, in other: String) -> Double {
        let a = tokens(text)
        guard !a.isEmpty else { return 0 }
        let b = Set(tokens(other))
        return Double(a.filter { b.contains($0) }.count) / Double(a.count)
    }
}
