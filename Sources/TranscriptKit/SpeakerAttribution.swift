import Foundation
import SessionKit

/// Decides who said each remote word by combining three sources, most trusted first:
///
/// 1. **Meeting captions.** Teams/Meet/Zoom label captions with the speaker's name (they know who is talking
///    because every participant is a separate stream on their servers). Each caption is aligned to the words
///    PalMeet transcribed around that time; matching words take the caption's name.
/// 2. **Voice clusters** from the diarizer, named by majority vote of the caption-labelled words in them (or by
///    "is speaking" indicators), or by a voice PalMeet learned in earlier meetings.
/// 3. The diarizer's cluster alone ("Speaker 3") when nothing else is known.
///
/// Clusters that turn out to be the same person (same caption name or same known voice) are merged, which
/// fixes the diarizer splitting one voice in two; caption-labelled words fix it lumping several people together.
public enum SpeakerAttribution {
    public struct Options: Sendable {
        /// How far before a caption first appeared its words may have been spoken (captions stream while the
        /// person talks, so the first words come at most a few seconds earlier).
        public var captionLead: TimeInterval = 8
        /// How far after a caption last changed its words may end.
        public var captionLag: TimeInterval = 3
        /// A caption of N tokens must match at least this fraction of them (and at least 2) to label words.
        public var minimumCaptionMatch: Double = 0.4
        /// A cluster takes a name when this share of its labelled words carries it…
        public var clusterMajority: Double = 0.6
        /// …and at least this many words (or speaking-indicator votes) back it.
        public var clusterMinimumVotes: Double = 6
        /// Speaking indicators lag the audio by about this much.
        public var indicatorDelay: TimeInterval = 0.3

        public init() {}
    }

    public enum NameSource: String, Sendable {
        case meeting
        case voice
    }

    public struct Result: Sendable {
        /// Speaker ID for each input word, in input order.
        public var labels: [String]
        /// Names for speaker IDs, with where they came from.
        public var names: [String: (name: String, source: NameSource)]
        /// Cluster ID → the speaker ID it was merged into (only clusters that were merged away).
        public var merged: [String: String]
        /// Speakers whose voice cluster was named by the meeting itself: safe to learn their voice from.
        public var learnable: Set<String>
    }

    /// - Parameters:
    ///   - words: remote words with the diarizer cluster each was assigned (`"S1"`… or the unknown bucket).
    ///   - voices: voiceprint per cluster ID.
    ///   - knownVoices: people learned in earlier meetings.
    public static func attribute(
        words: [(cluster: String, word: TranscriptWord)],
        timeline: MeetingSpeakerTimeline?,
        selfWords: [TranscriptWord] = [],
        voices: [String: SpeakerVoice],
        knownVoices: [VoiceProfile],
        unknownID: String,
        options: Options = Options(),
        thresholds: VoiceMatcher.Thresholds = VoiceMatcher.Thresholds()
    ) -> Result {
        let captionNames = timeline.map { alignCaptions($0.captions, to: words.map(\.word), selfWords: selfWords, options: options) }
            ?? Array(repeating: nil, count: words.count)

        // Votes per cluster: caption-labelled words count 1, speaking indicators 0.5.
        var votes: [String: [String: Double]] = [:]
        for (index, item) in words.enumerated() where item.cluster != unknownID {
            if let name = captionNames[index] {
                votes[item.cluster, default: [:]][name, default: 0] += 1
            } else if let name = timeline.flatMap({ soleSpeaker(at: item.word, in: $0.speaking, delay: options.indicatorDelay) }) {
                votes[item.cluster, default: [:]][name, default: 0] += 0.5
            }
        }
        var clusterName: [String: (name: String, source: NameSource)] = [:]
        for (cluster, tally) in votes {
            let total = tally.values.reduce(0, +)
            guard let best = tally.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  best.value >= options.clusterMinimumVotes, best.value / total >= options.clusterMajority
            else { continue }
            clusterName[cluster] = (best.key, .meeting)
        }
        let learnable = Set(clusterName.keys)

        // Clusters the meeting didn't name: known voices.
        let unnamedVoices = voices.filter { clusterName[$0.key] == nil && $0.key != unknownID }
        for match in VoiceMatcher.match(unnamedVoices, against: knownVoices, thresholds: thresholds) {
            clusterName[match.speakerID] = (match.name, .voice)
        }

        // One speaker ID per name: the cluster with the most words keeps its ID, the others merge into it.
        var wordCount: [String: Int] = [:]
        for item in words { wordCount[item.cluster, default: 0] += 1 }
        var idForName: [String: String] = [:]
        for (cluster, named) in clusterName.sorted(by: { (wordCount[$0.key] ?? 0, $1.key) > (wordCount[$1.key] ?? 0, $0.key) }) {
            let key = nameKey(named.name)
            if idForName[key] == nil { idForName[key] = cluster }
        }
        var merged: [String: String] = [:]
        for (cluster, named) in clusterName {
            if let target = idForName[nameKey(named.name)], target != cluster { merged[cluster] = target }
        }

        // Names only captions know (the diarizer never separated that voice) get new IDs.
        var usedIDs = Set(words.map(\.cluster)).union(voices.keys)
        func newID() -> String {
            var n = usedIDs.count + 1
            while usedIDs.contains("S\(n)") { n += 1 }
            usedIDs.insert("S\(n)")
            return "S\(n)"
        }
        var names: [String: (name: String, source: NameSource)] = [:]
        for (cluster, named) in clusterName where merged[cluster] == nil {
            names[cluster] = named
        }
        // Meeting names beat voice names for the same person.
        for (cluster, named) in clusterName where merged[cluster] != nil && named.source == .meeting {
            names[merged[cluster]!] = named
        }

        var labels: [String] = []
        labels.reserveCapacity(words.count)
        for (index, item) in words.enumerated() {
            if let name = captionNames[index] {
                let key = nameKey(name)
                if let id = idForName[key] {
                    labels.append(id)
                } else {
                    let id = newID()
                    idForName[key] = id
                    names[id] = (name, .meeting)
                    labels.append(id)
                }
            } else {
                labels.append(merged[item.cluster] ?? item.cluster)
            }
        }
        return Result(labels: labels, names: names, merged: merged, learnable: learnable.filter { merged[$0] == nil })
    }

    static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The one name shown as speaking during the word, if exactly one was.
    static func soleSpeaker(at word: TranscriptWord, in spans: [MeetingSpeakerTimeline.SpeakingSpan], delay: TimeInterval) -> String? {
        let mid = (word.start + word.end) / 2 + delay
        var found: String?
        for span in spans where span.start <= mid && mid <= span.end {
            if let existing = found, existing != span.name { return nil }
            found = span.name
        }
        return found
    }

    // MARK: - Caption alignment

    /// The caption name for each word, where a caption matches the words spoken around its time. Captions that
    /// match the user's own microphone better are the user's and are skipped (their voice isn't on this track).
    static func alignCaptions(
        _ captions: [MeetingSpeakerTimeline.Caption],
        to words: [TranscriptWord],
        selfWords: [TranscriptWord] = [],
        options: Options
    ) -> [String?] {
        var names = [String?](repeating: nil, count: words.count)
        var scores = [Int](repeating: 0, count: words.count)
        guard !words.isEmpty else { return names }
        let wordTokens = words.map { normalize($0.text) }
        let starts = words.map(\.start)
        let selfTokens = selfWords.map { normalize($0.text) }
        let selfStarts = selfWords.map(\.start)

        for caption in captions.sorted(by: { $0.firstSeen < $1.firstSeen }) {
            let tokens = caption.text.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { continue }
            let short = tokens.count < 3
            let windowStart = caption.firstSeen - (short ? 5 : options.captionLead)
            let windowEnd = caption.lastSeen + options.captionLag
            let window = indices(starts, from: windowStart, to: windowEnd)
            guard !window.isEmpty else { continue }
            let selfWindow = indices(selfStarts, from: windowStart, to: windowEnd)

            let matched: [Int]
            if short {
                // "Yes." / "Okay, thanks.": only an exact run, the one nearest to when the caption appeared.
                matched = nearestExactRun(tokens, in: window, tokens: wordTokens, words: words, target: caption.firstSeen - 0.5, taken: scores)
            } else {
                matched = densestRun(longestCommonSubsequence(tokens, window.map { wordTokens[$0] })).map { window[$0] }
                let needed = max(2, Int((Double(tokens.count) * options.minimumCaptionMatch).rounded(.up)))
                guard matched.count >= needed else { continue }
            }
            guard let first = matched.first, let last = matched.last else { continue }
            if !selfWindow.isEmpty {
                let selfMatch = longestCommonSubsequence(tokens, selfWindow.map { selfTokens[$0] }).count
                if selfMatch >= matched.count { continue }
            }
            let score = matched.count
            for index in first...last where score > scores[index] {
                names[index] = caption.name
                scores[index] = score
            }
        }
        return names
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func indices(_ starts: [TimeInterval], from: TimeInterval, to: TimeInterval) -> [Int] {
        let lower = lowerBound(starts, from)
        var upper = lower
        while upper < starts.count, starts[upper] <= to { upper += 1 }
        return Array(lower..<upper)
    }

    private static func lowerBound(_ values: [TimeInterval], _ target: TimeInterval) -> Int {
        var low = 0, high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static let minimumReplyPause: TimeInterval = 0.25

    private static func nearestExactRun(_ needle: [String], in window: [Int], tokens: [String], words: [TranscriptWord], target: TimeInterval, taken: [Int]) -> [Int] {
        guard window.count >= needle.count else { return [] }
        var best: (indices: [Int], distance: TimeInterval)?
        for offset in 0...(window.count - needle.count) {
            let run = Array(window[offset..<(offset + needle.count)])
            guard zip(run, needle).allSatisfy({ similar(tokens[$0.0], $0.1) }) else { continue }
            if run.contains(where: { taken[$0] > needle.count }) { continue }
            // A reply on its own ("Yes." between pauses), not the same word inside someone's sentence.
            let first = run.first!, last = run.last!
            let pauseBefore = first == 0 || words[first].start - words[first - 1].end >= minimumReplyPause
            let pauseAfter = last == words.count - 1 || words[last + 1].start - words[last].end >= minimumReplyPause
            guard pauseBefore, pauseAfter else { continue }
            let distance = abs(words[run.last!].end - target)
            if best == nil || distance < best!.distance { best = (run, distance) }
        }
        return best?.indices ?? []
    }

    /// The matches that belong together: common words ("the", "and") also match stray words of the people
    /// talking before and after, so matches separated by more than `maxGap` unmatched words are split off and
    /// only the group with the most matches is kept.
    static func densestRun(_ positions: [Int], maxGap: Int = 4) -> [Int] {
        var groups: [[Int]] = []
        for position in positions {
            if let last = groups.last?.last, position - last <= maxGap + 1 {
                groups[groups.count - 1].append(position)
            } else {
                groups.append([position])
            }
        }
        return groups.max { $0.count < $1.count } ?? []
    }

    /// Indices into `b` of an LCS between `a` and `b` (tokens compared with `similar`).
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [Int] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = [[Int16]](repeating: [Int16](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                table[i][j] = similar(a[i - 1], b[j - 1]) ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        var result: [Int] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if similar(a[i - 1], b[j - 1]), table[i][j] == table[i - 1][j - 1] + 1 {
                result.append(j - 1)
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    /// Same word, allowing one typo in longer words (two recognizers rarely spell names identically).
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        guard a.count >= 5, b.count >= 5, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(a, b, limit: 1) <= 1
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
