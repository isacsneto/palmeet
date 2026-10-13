import Foundation

/// Cheap, local first-pass detection of questions aimed at the user (English and Portuguese).
/// The LLM makes the final call; this only decides whether an LLM call is worth making.
public enum QuestionDetector {
    public struct Result: Sendable, Equatable {
        public var isQuestion: Bool
        public var mentionsUser: Bool
        public var addressesListener: Bool
        public var score: Double

        /// Worth asking the LLM to draft an answer.
        public var shouldTrigger: Bool { isQuestion && (mentionsUser || addressesListener || score >= 0.8) }
    }

    static let interrogativeStarts = [
        // English
        "what", "why", "how", "when", "where", "who", "which", "can", "could", "would", "will", "should", "do", "does",
        "did", "is", "are", "was", "were", "have", "has", "any", "shall", "may",
        // Portuguese
        "o que", "oque", "por que", "porque", "como", "quando", "onde", "quem", "qual", "quais", "quanto", "quantos",
        "será", "sera", "pode", "poderia", "consegue", "você", "voce", "vocês", "voces", "tem", "dá", "da pra", "dá pra",
    ]

    static let secondPerson = [
        "you", "your", "you've", "you're", "yourself", "do you think", "can you", "could you", "would you",
        "você", "voce", "vocês", "voces", "seu", "sua", "te", "contigo", "o que acha", "o que você acha", "consegue",
    ]

    static let tagQuestions = ["right?", "ok?", "okay?", "correct?", "né?", "certo?", "beleza?", "tá?", "ta?", "pode ser?"]

    public static func analyze(_ text: String, userCallNames: [String]) -> Result {
        let normalized = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(isQuestion: false, mentionsUser: false, addressesListener: false, score: 0) }

        // Look at the last sentence; that's what the speaker is waiting on.
        let lastSentence = trimmed.split(whereSeparator: { ".!".contains($0) }).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? trimmed
        let words = Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })

        var score = 0.0
        if trimmed.hasSuffix("?") { score += 0.7 }
        if interrogativeStarts.contains(where: { lastSentence.hasPrefix($0 + " ") }) { score += 0.35 }
        if tagQuestions.contains(where: { trimmed.hasSuffix($0) }) { score += 0.3 }

        let mentionsUser = userCallNames.contains { name in
            name.contains(" ") ? normalized.contains(name) : words.contains(name)
        }
        let addressesListener = secondPerson.contains { phrase in
            phrase.contains(" ") ? normalized.contains(phrase) : words.contains(phrase.folding(options: .diacriticInsensitive, locale: nil))
        }
        if mentionsUser { score += 0.3 }
        if addressesListener { score += 0.15 }

        return Result(isQuestion: score >= 0.6, mentionsUser: mentionsUser, addressesListener: addressesListener, score: min(score, 1.5))
    }
}
