import Foundation
import SessionKit
import VisionContext

/// Ties what was on screen to what was being said, for the summary:
/// - every screenshot becomes a line in the transcript at its time, carrying only the on-screen text that is new
///   since the previous screens (ticket numbers, links, file names, names spelled right), so nothing is repeated;
/// - the screenshots sent as images are the ones that best show what people were talking about.
enum ScreenContext {
    /// A screenshot placed in the transcript.
    struct Line: Equatable {
        var offset: TimeInterval
        var text: String
    }

    /// On-screen text per screenshot, new text only. A screenshot with nothing new is listed only when it's one
    /// of the attached images (the model needs its path).
    static func lines(
        for shots: [ScreenshotRecord], attached: Set<String>, maxCharactersPerShot: Int = 500, budget: Int = 30_000
    ) -> [Line] {
        var seenLines = Set<String>()
        var seenWords = Set<String>()
        var used = 0
        var result: [Line] = []
        for shot in shots.sorted(by: { $0.offset < $1.offset }) {
            var fresh: [String] = []
            for raw in shot.ocrText.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let key = line.lowercased()
                guard line.count >= 3, seenLines.insert(key).inserted else { continue }
                let words = ScreenshotCompactor.words(line)
                // A line of known words in a new order (OCR noise, a re-wrapped paragraph) adds nothing.
                if words.isEmpty || !words.isSubset(of: seenWords) { fresh.append(line) }
                seenWords.formUnion(words)
            }
            let isAttached = attached.contains(shot.relativePath)
            guard !fresh.isEmpty || isAttached, used < budget || isAttached else { continue }
            var text = fresh.joined(separator: " | ")
            if text.count > maxCharactersPerShot { text = String(text.prefix(maxCharactersPerShot)) + "…" }
            let label = isAttached ? "📷 \(shot.relativePath) (image attached)" : "📷 \(shot.relativePath)"
            let line = text.isEmpty ? "\(label): same screen as before" : "\(label) new on screen: \(text)"
            used += line.count
            result.append(Line(offset: shot.offset, text: line))
        }
        return result
    }

    // MARK: Choosing the images

    struct Weights {
        /// Seconds of speech around a screenshot compared with its text.
        var speechWindow: TimeInterval = 60
        /// Seconds around a screenshot searched for "look at this"-style phrases.
        var pointingWindow: TimeInterval = 20
        /// Screenshots closer than this (a share of the meeting) compete for one slot.
        var minimumSpacingShare = 0.6
        /// Words on more than this share of the screenshots are the app's own text (meeting title, names on the
        /// tiles, buttons) and say nothing about the moment.
        var everywhereShare = 0.4
        /// Below this a screenshot shows nothing new or discussed; it only fills a slot nobody else wants.
        var minimumFillScore = 3.0
    }

    /// The screenshots worth showing the model: ones you marked, ones whose text people were talking about,
    /// ones with new content or that someone pointed at, spread over the meeting and not repeating each other.
    static func choose(_ shots: [ScreenshotRecord], transcript: Transcript, count: Int, weights: Weights = Weights()) -> [ScreenshotRecord] {
        guard shots.count > count else { return shots.sorted { $0.offset < $1.offset } }
        let ordered = shots.sorted { $0.offset < $1.offset }
        let wordsPerShot = ordered.map { meaningful(ScreenshotCompactor.words($0.ocrText)) }
        var frequency: [String: Int] = [:]
        for words in wordsPerShot { for word in words { frequency[word, default: 0] += 1 } }
        let everywhere = Set(frequency.filter { Double($0.value) > Double(ordered.count) * weights.everywhereShare }.keys)
        var seen = Set<String>()
        var scored: [(shot: ScreenshotRecord, score: Double)] = []
        for (shot, all) in zip(ordered, wordsPerShot) {
            let words = all.subtracting(everywhere)
            let new = words.subtracting(seen)
            seen.formUnion(words)
            let spoken = Set(spokenWords(in: transcript, around: shot.offset, within: weights.speechWindow).map(stem))
            let talkedAbout = Set(words.map(stem)).intersection(spoken).count
            var score = Double(min(new.count, 30)) * 0.3 + Double(min(talkedAbout, 10)) * 3
            if shot.reason == .manual { score += 100 }
            if shot.reason == .screenChange { score += 3 }
            if pointedAt(in: transcript, around: shot.offset, within: weights.pointingWindow) { score += 6 }
            scored.append((shot, score))
        }
        let duration = max(transcript.duration, ordered.last?.offset ?? 0, 1)
        let spacing = duration / Double(count) * weights.minimumSpacingShare
        let ranked = scored.sorted { ($0.score, -$0.shot.offset) > ($1.score, -$1.shot.offset) }
        let words = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, ScreenshotCompactor.words($0.ocrText)) })
        // Same picture and same text as one already chosen (a video grid with the same side panel).
        func repeats(_ shot: ScreenshotRecord, _ chosen: [ScreenshotRecord]) -> Bool {
            chosen.contains {
                ScreenshotCompactor.isDuplicate(shot.perceptualHash, words[shot.id] ?? [], of: $0.perceptualHash, words[$0.id] ?? [], .init())
            }
        }
        var chosen: [ScreenshotRecord] = []
        for (shot, _) in ranked where chosen.count < count {
            let crowded = shot.reason != .manual && chosen.contains { abs($0.offset - shot.offset) < spacing }
            if !crowded, !repeats(shot, chosen) { chosen.append(shot) }
        }
        // Fewer distinct moments than slots: the best of the rest that still show something.
        for (shot, score) in ranked where chosen.count < count && score >= weights.minimumFillScore {
            if !chosen.contains(where: { $0.id == shot.id }), !repeats(shot, chosen) { chosen.append(shot) }
        }
        return chosen.sorted { $0.offset < $1.offset }
    }

    /// Meaningful words spoken within `window` seconds of `offset`.
    static func spokenWords(in transcript: Transcript, around offset: TimeInterval, within window: TimeInterval) -> Set<String> {
        var words = Set<String>()
        for segment in transcript.segments where segment.end >= offset - window && segment.start <= offset + window {
            words.formUnion(meaningful(ScreenshotCompactor.words(segment.text)))
        }
        return words
    }

    /// Words of four or more letters that aren't everyday words.
    static func meaningful(_ words: Set<String>) -> Set<String> {
        words.filter { $0.count >= 4 && !commonWords.contains($0) }
    }

    /// "permission" and "permissions", "deploy" and "deployment" match.
    static func stem(_ word: String) -> String { String(word.prefix(6)) }

    static let commonWords: Set<String> = [
        "with", "only", "here", "there", "these", "those", "then", "than", "that", "this", "more", "have", "from", "what",
        "about", "they", "them", "their", "will", "would", "could", "should", "just", "like", "also", "some", "into",
        "your", "were", "been", "when", "which", "where", "very", "really", "going", "know", "think", "yeah", "okay",
        "right", "sure", "well", "want", "need", "make", "does", "doing", "done", "thing", "things", "something",
        "because", "maybe", "actually", "other", "over", "much", "many", "still", "even", "back", "good", "great",
        "para", "como", "mais", "isso", "esse", "essa", "este", "esta", "aqui", "então", "entao", "também", "tambem",
        "muito", "pode", "porque", "quando", "onde", "ainda", "mesmo", "sobre", "depois", "agora", "assim", "vamos",
        "gente", "tipo", "coisa", "acho", "está", "estou", "temos", "fazer", "vocês", "voces", "você", "voce", "pra",
        "tudo", "nada", "bem", "aí", "né", "certo", "beleza",
    ]

    /// Someone pointing at the screen ("as you can see", "olha aqui", "let me share") near the screenshot.
    static func pointedAt(in transcript: Transcript, around offset: TimeInterval, within window: TimeInterval) -> Bool {
        transcript.segments.contains { segment in
            guard segment.end >= offset - window, segment.start <= offset + window else { return false }
            let text = segment.text.lowercased()
            return pointingPhrases.contains { text.contains($0) }
        }
    }

    static let pointingPhrases = [
        "you can see", "as you see", "on the screen", "on my screen", "this screen", "look at this", "here you", "right here",
        "let me share", "sharing my screen", "share my screen", "this page", "this ticket", "this line", "this file",
        "dá pra ver", "da pra ver", "dá para ver", "vocês podem ver", "voces podem ver", "na tela", "minha tela", "essa tela",
        "esta tela", "olha aqui", "olhem aqui", "aqui ó", "vou compartilhar", "compartilhando", "esse ticket", "essa página",
        "essa linha", "esse arquivo",
    ]

    // MARK: Checking the model's answer

    /// Keeps only screenshot paths that exist in this meeting; a made-up path is dropped.
    static func validated(_ summary: MeetingSummary, paths: Set<String>) -> MeetingSummary {
        func check(_ path: String?) -> String? {
            guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
            return paths.contains(path) ? path : nil
        }
        var summary = summary
        for index in summary.topics.indices { summary.topics[index].screenshot = check(summary.topics[index].screenshot) }
        for index in summary.decisions.indices { summary.decisions[index].screenshot = check(summary.decisions[index].screenshot) }
        for index in summary.visualContext.indices { summary.visualContext[index].screenshot = check(summary.visualContext[index].screenshot) }
        return summary
    }
}
