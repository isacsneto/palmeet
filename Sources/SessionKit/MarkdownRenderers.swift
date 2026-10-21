import Foundation

enum MarkdownHeader {
    static func dateLine(_ metadata: SessionMetadata) -> String {
        let day = metadata.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        let start = metadata.createdAt.formatted(date: .omitted, time: .shortened)
        var line = "\(day) · \(start)"
        if let endedAt = metadata.endedAt {
            line += "–\(endedAt.formatted(date: .omitted, time: .shortened))"
            let minutes = Int((endedAt.timeIntervalSince(metadata.createdAt) / 60).rounded())
            line += " (\(minutes) min)"
        }
        return line + " · \(metadata.source.appName)"
    }

    static func participants(_ transcript: Transcript) -> String {
        let used = Set(transcript.segments.map(\.speakerID))
        return transcript.speakers
            .filter { used.contains($0.id) }
            .map { $0.isMe ? "\($0.displayName) (me)" : $0.displayName }
            .joined(separator: ", ")
    }

    /// Escapes characters that would break a Markdown table cell.
    static func cell(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func ref(_ ref: String?) -> String {
        guard let ref, !ref.isEmpty else { return "" }
        let trimmed = ref.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return " [\(trimmed)]"
    }
}

public enum TranscriptMarkdownRenderer {
    /// Renders consecutive segments of the same speaker as one paragraph so the transcript reads naturally.
    public static func render(_ transcript: Transcript, metadata: SessionMetadata) -> String {
        var lines: [String] = []
        lines.append("# Transcript — \(metadata.title)")
        var header = "*\(MarkdownHeader.dateLine(metadata))"
        let participants = MarkdownHeader.participants(transcript)
        if !participants.isEmpty { header += " · Participants: \(participants)" }
        lines.append(header + "*")
        lines.append("")

        var currentSpeaker: String?
        var buffer: [String] = []
        var blockStart: TimeInterval = 0

        func flush() {
            guard let speakerID = currentSpeaker, !buffer.isEmpty else { return }
            let name = transcript.displayName(for: speakerID)
            lines.append("**[\(Timecode.format(blockStart))] \(name):** \(buffer.joined(separator: " "))")
            lines.append("")
            buffer.removeAll()
        }

        for segment in transcript.segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if segment.speakerID != currentSpeaker {
                flush()
                currentSpeaker = segment.speakerID
                blockStart = segment.start
            }
            buffer.append(text)
        }
        flush()
        return lines.joined(separator: "\n")
    }
}

public enum SummaryMarkdownRenderer {
    public static func render(_ summary: MeetingSummary, metadata: SessionMetadata, transcript: Transcript) -> String {
        var md: [String] = []
        md.append("# \(summary.title.isEmpty ? metadata.title : summary.title) — Summary")
        md.append("**Date:** \(MarkdownHeader.dateLine(metadata))  ")
        let names = summary.participants.isEmpty
            ? MarkdownHeader.participants(transcript)
            : summary.participants.map { p in p.role.map { "\(p.name) (\($0))" } ?? p.name }.joined(separator: ", ")
        if !names.isEmpty { md.append("**Participants:** \(names)") }
        md.append("")

        md.append("## TL;DR")
        md.append(summary.tldr.isEmpty ? "_No overview generated._" : summary.tldr)
        md.append("")

        if !summary.decisions.isEmpty {
            md.append("## Decisions")
            for decision in summary.decisions {
                md.append("- \(decision.text)\(MarkdownHeader.ref(decision.ref))")
                if let image = image(decision.screenshot, alt: decision.text) { md.append("  \(image)") }
            }
            md.append("")
        }

        if !summary.actionItems.isEmpty {
            md.append("## Action items")
            md.append("| Owner | Task | Due | Ref |")
            md.append("|---|---|---|---|")
            md += summary.actionItems.map { item in
                "| \(MarkdownHeader.cell(item.owner ?? "—")) | \(MarkdownHeader.cell(item.task)) | \(MarkdownHeader.cell(item.due ?? "—")) | \(MarkdownHeader.cell(item.ref ?? "")) |"
            }
            md.append("")
        }

        appendList("Key takeaways", summary.keyTakeaways, to: &md)

        if !summary.topics.isEmpty {
            md.append("## Topics discussed")
            for topic in summary.topics {
                md.append("### \(topic.title)\(MarkdownHeader.ref(topic.start))")
                md.append(topic.summary)
                if let image = image(topic.screenshot, alt: topic.title) {
                    md.append("")
                    md.append(image)
                }
                md.append("")
            }
        }

        appendList("Open questions", summary.openQuestions, to: &md)
        appendList("Risks / blockers", summary.risks, to: &md)
        appendList("Questions I raised / commitments I made", summary.myQuestionsAndCommitments, to: &md)

        if !summary.notableQuotes.isEmpty {
            md.append("## Notable quotes")
            md += summary.notableQuotes.map { "> \"\($0.quote)\" — \($0.speaker)\(MarkdownHeader.ref($0.ref))\n" }
            md.append("")
        }

        // Other screens worth seeing; one already shown with its topic or decision isn't repeated.
        let shown = Set((summary.topics.map(\.screenshot) + summary.decisions.map(\.screenshot)).compactMap { $0 })
        let visual = summary.visualContext.filter { $0.screenshot.map { !shown.contains($0) } ?? true }
        if !visual.isEmpty {
            md.append("## Visual context")
            for item in visual {
                md.append("- \(item.description)\(MarkdownHeader.ref(item.ref))")
                if let image = image(item.screenshot, alt: item.description) { md.append("  \(image)") }
            }
            md.append("")
        }

        md.append("---")
        md.append("*Full transcript: [transcript.md](transcript.md)*")
        return md.joined(separator: "\n")
    }

    private static func image(_ path: String?, alt: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "![\(MarkdownHeader.cell(alt))](\(path.replacingOccurrences(of: " ", with: "%20")))"
    }

    private static func appendList(_ title: String, _ items: [String], to md: inout [String]) {
        guard !items.isEmpty else { return }
        md.append("## \(title)")
        md += items.map { "- \($0)" }
        md.append("")
    }
}
