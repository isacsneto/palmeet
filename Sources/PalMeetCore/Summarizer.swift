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
        // What was on screen goes into the transcript at its time; the best-matching screenshots go as images.
        let attached = provider.capabilities.contains(.images) ? selectScreenshots(screenshots, transcript: transcript) : []
        let screens = ScreenContext.lines(for: screenshots, attached: Set(attached.map(\.relativePath)))
        let lines = transcriptLines(transcript, screens: screens)
        if lines.count <= singlePassLimit {
            return try await finalPass(
                metadata: metadata, transcript: transcript, body: "Transcript:\n" + lines,
                screenshots: screenshots, attached: attached, notes: notes, folder: folder, glossary: glossary, context: context
            )
        }

        // Map: summarize each chunk to compact notes. Reduce: final structured summary over the notes.
        var partials: [String] = []
        var start: TimeInterval = 0
        while start < transcript.duration {
            let range = start...(start + chunkDuration)
            let chunk = transcriptLines(transcript, screens: screens, range: range)
            start += chunkDuration
            guard !chunk.isEmpty else { continue }
            let request = LLMRequest(
                system: "You condense meeting transcript excerpts into dense factual notes. Keep every decision, action item (with owner), number, date, open question and risk, each with its [HH:MM:SS] reference. Keep speaker names. Lines starting with 📷 are what was on screen then: keep what the people were discussing on screen (tickets, links, files, names) with the screenshot path. Write in the meeting's language.",
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
        return try await finalPass(
            metadata: metadata, transcript: transcript, body: body, screenshots: screenshots, attached: attached,
            notes: notes, folder: folder, glossary: glossary, context: context
        )
    }

    // MARK: - Prompting

    private func finalPass(
        metadata: SessionMetadata,
        transcript: Transcript,
        body: String,
        screenshots: [ScreenshotRecord],
        attached: [ScreenshotRecord],
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

        if !screenshots.isEmpty {
            header += "\nLines starting with 📷 are screenshots of the meeting window, placed at the moment they were taken, with only the text that was new on screen (OCR)."
        }

        var parts: [LLMContentPart] = [.text(header + "\n\n" + body)]
        if !attached.isEmpty {
            parts.append(.text("\nThe screenshots marked \"image attached\", in order (use their path in \"screenshot\" fields):"))
            for shot in attached {
                parts.append(.text("Screenshot \(shot.relativePath) at [\(Timecode.format(shot.offset))]:"))
                parts.append(.imageFile(folder.url.appending(path: shot.relativePath)))
            }
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
        let summary = ScreenContext.validated(
            try JSONDecoder().decode(MeetingSummary.self, from: data), paths: Set(attached.map(\.relativePath))
        )
        let names = (try? JSONDecoder().decode(SpeakerNamesEnvelope.self, from: data))?.speakerNames ?? [:]
        let validIDs = Set(transcript.speakers.filter { !$0.isMe }.map(\.id))
        return Output(summary: summary, speakerNames: names.filter { validIDs.contains($0.key) && !$0.value.isEmpty }, usage: response.usage)
    }

    /// The screenshots to send as images: the ones that best show what was being discussed (`ScreenContext`).
    func selectScreenshots(_ all: [ScreenshotRecord], transcript: Transcript) -> [ScreenshotRecord] {
        ScreenContext.choose(all, transcript: transcript, count: maxImages)
    }

    /// The transcript as timed lines, with what was on screen (`screens`) placed at its time.
    func transcriptLines(_ transcript: Transcript, screens: [ScreenContext.Line] = [], range: ClosedRange<TimeInterval>? = nil) -> String {
        var lines: [(offset: TimeInterval, text: String)] = transcript.segments
            .filter { range?.contains($0.start) ?? true }
            .map { segment in
                let name = transcript.displayName(for: segment.speakerID)
                let label = name == segment.speakerID ? name : "\(name) (\(segment.speakerID))"
                return (segment.start, "[\(Timecode.format(segment.start))] \(label): \(segment.text)")
            }
        for screen in screens where range?.contains(screen.offset) ?? true {
            lines.append((screen.offset, "[\(Timecode.format(screen.offset))] \(screen.text)"))
        }
        // Stable: a screenshot taken at the same second as a line comes after it.
        return lines.enumerated()
            .sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
            .map(\.element.text)
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
    - What was on screen (📷 lines and attached screenshots) is part of the meeting: use it to get names, ticket \
    numbers, links, file names and figures right, and to say what people were looking at when it matters.
    - For each topic and decision, set "screenshot" to the path of the attached screenshot that best shows it, \
    only when one clearly does (otherwise null). Use each screenshot at most once. "visual_context" lists other \
    screens worth seeing, each with its path if it was attached.
    - Reply with ONE JSON object only, no prose and no code fences, with exactly these keys:

    \(MeetingSummary.jsonSchemaExample.dropLast(2))
      ,"speaker_names": {"S2": "Real Name"}
    }
    """
}
