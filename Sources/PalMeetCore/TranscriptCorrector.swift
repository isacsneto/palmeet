import Foundation
import LLMKit
import SessionKit

/// Proofreads a finished transcript for speech-recognition errors (misheard names, jargon, homophones) using the
/// meeting's context. The model only proposes small, local replacements; each one is applied only where its exact
/// text appears at the stated time, and the recognizer's original text is kept on the segment.
struct TranscriptCorrector: Sendable {
    struct Fix: Codable, Sendable, Equatable {
        /// "HH:MM:SS" of the line, as given in the prompt.
        var t: String
        var from: String
        var to: String
    }

    let provider: any LLMProvider
    var model: String?
    var maxFixes = 120
    /// Longer transcripts are proofread in pieces of about this many characters.
    var chunkCharacters = 60_000

    func corrections(transcript: Transcript, glossary: [String], screenNames: [String], title: String, context userContext: String = "") async throws -> [Fix] {
        let lines = transcript.segments.filter { !$0.isEdited }.map { segment in
            "[\(Timecode.format(segment.start))] \(transcript.displayName(for: segment.speakerID)): \(segment.text)"
        }
        guard !lines.isEmpty else { return [] }
        var context = "Meeting: \(title)"
        let names = transcript.speakers.map(\.displayName).filter { !$0.hasPrefix("Speaker ") }
        if !names.isEmpty { context += "\nSpeakers: \(names.joined(separator: ", "))" }
        if !glossary.isEmpty { context += "\nGlossary (correct spellings): \(glossary.joined(separator: ", "))" }
        let userContext = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContext.isEmpty { context += "\nContext the user gave for this meeting (names and terms here are spelled correctly):\n\(userContext.prefix(6_000))" }
        if !screenNames.isEmpty { context += "\nNames seen on screen (may include UI text): \(screenNames.prefix(40).joined(separator: ", "))" }

        var fixes: [Fix] = []
        for chunk in Self.chunks(lines, maxCharacters: chunkCharacters) {
            let request = LLMRequest(
                system: Self.systemPrompt,
                messages: [.user(context + "\n\nTranscript:\n" + chunk.joined(separator: "\n"))],
                model: model,
                maxTokens: 4_000,
                temperature: 0,
                responseFormat: .json,
                timeout: 600
            )
            let response = try await provider.complete(request)
            guard let data = JSONExtraction.extractObject(from: response.text),
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
            else { continue }
            fixes += envelope.fixes ?? []
            if fixes.count >= maxFixes { break }
        }
        return Array(fixes.prefix(maxFixes))
    }

    /// Applies fixes to segments the user hasn't edited. Returns how many were applied.
    @discardableResult
    static func apply(_ fixes: [Fix], to transcript: inout Transcript) -> Int {
        var applied = 0
        for fix in fixes where isPlausible(fix) {
            guard let time = Timecode.parse(fix.t) else { continue }
            // The line stamped with that time (formatting truncates to whole seconds).
            let candidates = transcript.segments.indices.filter {
                !transcript.segments[$0].isEdited && Int(transcript.segments[$0].start) == Int(time)
            }
            for index in candidates {
                let text = transcript.segments[index].text
                guard let range = range(of: fix.from, in: text) else { continue }
                if transcript.segments[index].originalText == nil { transcript.segments[index].originalText = text }
                transcript.segments[index].text = text.replacingCharacters(in: range, with: fix.to)
                applied += 1
                break
            }
        }
        return applied
    }

    /// Small local edits only: no rewrites of whole sentences, no deletions of content.
    static func isPlausible(_ fix: Fix) -> Bool {
        let from = fix.from.trimmingCharacters(in: .whitespaces)
        let to = fix.to.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty, from != to else { return false }
        let fromWords = words(from), toWords = words(to)
        guard fromWords.count <= 6, toWords.count <= 6, to.count <= from.count * 3 + 12 else { return false }
        // Dropping words ("I and I expect" → "and I expect") is cleanup, not a recognition fix.
        var remaining = fromWords
        let onlyDeletes = toWords.allSatisfy { word in
            guard let index = remaining.firstIndex(of: word) else { return false }
            remaining.remove(at: index)
            return true
        }
        return !(onlyDeletes && toWords.count < fromWords.count)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Exact match on whole words first, then case-insensitive.
    static func range(of needle: String, in text: String) -> Range<String.Index>? {
        for options in [String.CompareOptions(), .caseInsensitive] {
            var searchStart = text.startIndex
            while let range = text.range(of: needle, options: options, range: searchStart..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let boundaryBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
                let boundaryAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
                if boundaryBefore && boundaryAfter { return range }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    static func chunks(_ lines: [String], maxCharacters: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > maxCharacters, !current.isEmpty {
                result.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private struct Envelope: Decodable {
        var fixes: [Fix]?
    }

    static let systemPrompt = """
    You proofread an automatic speech-recognition (ASR) transcript of a meeting. List ONLY clear recognition \
    errors: words the recognizer misheard (they make no sense in context but sound like the right word), \
    misspelled names of people, products, companies and technical terms (use the glossary, speaker names and \
    names on screen), and wrong homophones.

    The replacement must sound like the wrong text: it is what the recognizer misheard. Never delete words, \
    never rephrase, fix grammar, remove filler words, stutters or repetitions, translate, or change what someone \
    meant. Speakers may have accents and speak informally; that is not an error. If you are not sure, leave it.

    For each fix give the [HH:MM:SS] time of the line exactly as shown (without brackets), "from": the shortest \
    exact wrong text as it appears in that line, and "to": the replacement.

    Reply with ONE JSON object only, no prose: {"fixes": [{"t": "00:01:02", "from": "cooper netties", "to": "Kubernetes"}]}
    If there is nothing to fix: {"fixes": []}
    """
}
