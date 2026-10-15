import Foundation
import LLMKit
import SessionKit
import TranscriptKit

/// Turns a finished transcript (+ screenshots, notes) into a `MeetingSummary`, and proposes real names for
/// diarized speakers when the conversation makes them clear.
struct Summarizer: Sendable {
    struct Output: Sendable {
        var summary: MeetingSummary
        /// Diarized speaker ID → real name, only where the model was confident.
        var speakerNames: [String: String]
        var usage: LLMUsage?
    }

    let provider: any LLMProvider
    var model: String?
    var maxImages = 10
    /// Above this many characters of transcript, summarize in chunks first (map-reduce).
    var singlePassLimit = 350_000
    var chunkDuration: TimeInterval = 15 * 60

    func summarize(
        metadata: SessionMetadata,
        transcript: Transcript,
        screenshots: [ScreenshotRecord],
        notes: [SessionNote],
        folder: SessionFolder,
        glossary: [String],
        context: String = ""
    ) async throws -> Output {
        let lines = transcriptLines(transcript)
        if lines.count <= singlePassLimit {
            return try await finalPass(
                metadata: metadata, transcript: transcript, body: "Transcript:\n" + lines,
                screenshots: screenshots, notes: notes, folder: folder, glossary: glossary, context: context
            )
        }

        // Map: summarize each chunk to compact notes. Reduce: final structured summary over the notes.
        var partials: [String] = []
        var start: TimeInterval = 0
        while start < transcript.duration {
            let range = start...(start + chunkDuration)
            let chunk = transcriptLines(transcript, range: range)
            start += chunkDuration
            guard !chunk.isEmpty else { continue }
            let request = LLMRequest(
                system: "You condense meeting transcript excerpts into dense factual notes. Keep every decision, action item (with owner), number, date, open question and risk, each with its [HH:MM:SS] reference. Keep speaker names. Write in the meeting's language.",
                messages: [.user("Excerpt \(Timecode.format(range.lowerBound))–\(Timecode.format(range.upperBound)):\n\(chunk)")],
                model: model,
                maxTokens: 2_000,
                temperature: 0.2,
                timeout: 600
            )
            let response = try await provider.complete(request)
            partials.append("Notes for \(Timecode.format(range.lowerBound))–\(Timecode.format(range.upperBound)):\n\(response.text)")
        }
        let body = "The meeting was long, so here are chronological notes covering the whole transcript:\n\n" + partials.joined(separator: "\n\n")
        return try await finalPass(metadata: metadata, transcript: transcript, body: body, screenshots: screenshots, notes: notes, folder: folder, glossary: glossary, context: context)
    }

    // MARK: - Prompting

    private func finalPass(
        metadata: SessionMetadata,
        transcript: Transcript,
        body: String,
        screenshots: [ScreenshotRecord],
        notes: [SessionNote],
        folder: SessionFolder,
        glossary: [String],
        context: String
    ) async throws -> Output {
        var header = """
        Meeting: \(metadata.title)
        App: \(metadata.source.displayName)
        Date: \(metadata.createdAt.formatted(date: .complete, time: .shortened))
        Duration: \(Timecode.format(transcript.duration))
        Speakers (id → current label): \(transcript.speakers.map { "\($0.id) → \($0.displayName)\($0.isMe ? " (the user)" : "")" }.joined(separator: ", "))
        """
        // Names seen on screen, most frequent first (participant tiles recur; OCR noise and app text rarely do).
        var frequency: [String: Int] = [:]
        for shot in screenshots { for name in Set(shot.nameCandidates) { frequency[name, default: 0] += 1 } }
        let visibleNames = frequency.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        if !visibleNames.isEmpty {
            header += "\nText that looks like names, seen on screen (most frequent first; may include app text/OCR noise): \(visibleNames.prefix(40).joined(separator: ", "))"
        }
        // Weak per-speaker hints: names visible notably more often while that speaker talks.
        let observations = screenshots.map { SpeakerNameInference.Observation(offset: $0.offset, names: $0.nameCandidates) }
        let hints = SpeakerNameInference.suggest(transcript: transcript, observations: observations, minimumLift: 2)
        if !hints.isEmpty {
            header += "\nWeak screen hints (use only if the conversation agrees): " + hints.map { "\($0.speakerID) often talks while “\($0.name)” is on screen" }.joined(separator: "; ")
        }
        if !glossary.isEmpty { header += "\nGlossary (correct spellings): \(glossary.joined(separator: ", "))" }
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            header += "\nContext the user gave for this meeting (agenda, ticket, who's who, terms; trust it for names and spellings):\n\(context.prefix(20_000))"
        }
        if !notes.isEmpty {
            header += "\nUser notes taken during the meeting:\n" + notes.map { "[\(Timecode.format($0.offset))] \($0.text)" }.joined(separator: "\n")
        }

        var parts: [LLMContentPart] = [.text(header + "\n\n" + body)]
        let selected = selectScreenshots(screenshots)
        if !selected.isEmpty, provider.capabilities.contains(.images) {
            parts.append(.text("\nKey screenshots of the meeting window (reference them in visual_context by their path):"))
            for shot in selected {
                let ocr = shot.ocrText.isEmpty ? "" : " OCR: \(shot.ocrText.prefix(600))"
                parts.append(.text("Screenshot \(shot.relativePath) at [\(Timecode.format(shot.offset))].\(ocr)"))
                parts.append(.imageFile(folder.url.appending(path: shot.relativePath)))
            }
        } else if !selected.isEmpty {
            let ocr = selected.map { "[\(Timecode.format($0.offset))] \($0.relativePath): \($0.ocrText.prefix(600))" }.joined(separator: "\n")
            parts.append(.text("\nText visible on screen at key moments (OCR):\n\(ocr)"))
        }

        let request = LLMRequest(
            system: Self.systemPrompt,
            messages: [LLMMessage(role: .user, parts: parts)],
            model: model,
            maxTokens: 8_000,
            temperature: 0.2,
            responseFormat: .json,
            timeout: 900
        )
        let response = try await provider.complete(request)
        guard let data = JSONExtraction.extractObject(from: response.text) else {
            throw LLMError.invalidResponse("The model did not return a JSON summary.")
        }
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)
        let names = (try? JSONDecoder().decode(SpeakerNamesEnvelope.self, from: data))?.speakerNames ?? [:]
        let validIDs = Set(transcript.speakers.filter { !$0.isMe }.map(\.id))
        return Output(summary: summary, speakerNames: names.filter { validIDs.contains($0.key) && !$0.value.isEmpty }, usage: response.usage)
    }

    /// Prefer screen changes and manual marks, spread across the meeting.
    func selectScreenshots(_ all: [ScreenshotRecord]) -> [ScreenshotRecord] {
        let preferred = all.filter { $0.reason != .interval }
        let pool = preferred.count >= maxImages / 2 ? preferred : all
        guard pool.count > maxImages else { return pool }
        let step = Double(pool.count) / Double(maxImages)
        return (0..<maxImages).map { pool[Int(Double($0) * step)] }
    }

    func transcriptLines(_ transcript: Transcript, range: ClosedRange<TimeInterval>? = nil) -> String {
        transcript.segments
            .filter { range?.contains($0.start) ?? true }
            .map { segment in
                let name = transcript.displayName(for: segment.speakerID)
                let label = name == segment.speakerID ? name : "\(name) (\(segment.speakerID))"
                return "[\(Timecode.format(segment.start))] \(label): \(segment.text)"
            }
            .joined(separator: "\n")
    }

    private struct SpeakerNamesEnvelope: Decodable {
        var speakerNames: [String: String]?
        enum CodingKeys: String, CodingKey { case speakerNames = "speaker_names" }
    }

    static let systemPrompt = """
    You are an expert meeting analyst. From the transcript (and screenshots, if any) produce an accurate, useful \
    summary of the meeting.

    Rules:
    - Use only what is in the provided material. Never invent decisions, owners, dates or numbers.
    - Every decision, action item, topic and quote gets a "ref" with the [HH:MM:SS] time where it happened, taken from the transcript.
    - Action items: concrete task, owner exactly as named in the meeting (or null), due date only if stated.
    - "my_questions_and_commitments": questions the user (speaker id "me") raised and things they committed to.
    - Write in the language the meeting was held in.
    - Speakers are labelled like "Speaker 2 (S2)". Name every speaker whose real name the material makes clear: \
    they introduce themselves, someone addresses them by name and they answer, or a name seen on screen matches \
    who is talking. Put them in "speaker_names" as {"S2": "Maria Silva"}, using the full name when it appears on \
    screen. Never use product, company, place or UI text as a name. Omit speakers you are not sure about. Use real \
    names in the rest of the summary once established.
    - Reply with ONE JSON object only, no prose and no code fences, with exactly these keys:

    \(MeetingSummary.jsonSchemaExample.dropLast(2))
      ,"speaker_names": {"S2": "Real Name"}
    }
    """
}
