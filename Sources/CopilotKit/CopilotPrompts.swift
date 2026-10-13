import Foundation

enum CopilotPrompts {
    static func system(profile: UserProfile, mode: MeetingMode, playbook: String, prepNotes: String, meetingTitle: String) -> String {
        let language = profile.answerLanguage.map { "Write in \($0)." } ?? "Write in the language the meeting is being held in."
        var prompt = """
        You are a discreet real-time meeting copilot for one participant (the user). You read the live transcript \
        and suggest what the user could say or ask. Only the user sees your output, in a small side panel, while \
        they are talking, so every line must be short enough to read in two seconds and natural to say out loud.

        Rules:
        - Ground everything in the transcript, screen text and notes provided. Never invent facts, numbers, dates, \
        names, code details or decisions. If the right answer depends on information you don't have, suggest an \
        honest holding answer (e.g. "I need to check X in the code; I'll get back to you by tomorrow") instead.
        - Never commit the user to dates, scope, effort or money without a WARN line pointing it out.
        - Each OPTION or question is at most ~25 words, first person, conversational, no preamble.
        - \(language)
        - Output ONLY the line protocol described in the task. No markdown, no extra commentary.

        About the user:
        \(profile.promptDescription)

        Meeting: \(meetingTitle)
        Meeting type: \(mode.displayName)
        Playbook for this meeting type:
        \(playbook)
        """
        let notes = prepNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            prompt += "\n\nPreparation notes from the user (ticket, spec, agenda):\n\(notes.prefix(12_000))"
        }
        return prompt
    }

    static func context(runningSummary: String, recentTranscript: String, screenText: String?) -> String {
        var parts: [String] = []
        if !runningSummary.isEmpty { parts.append("Summary of the meeting before the recent part:\n\(runningSummary)") }
        parts.append("Recent transcript ([time] speaker: text):\n\(recentTranscript.isEmpty ? "(nothing yet)" : recentTranscript)")
        if let screenText, !screenText.isEmpty {
            parts.append("Text currently visible on the shared screen / meeting window (OCR, may be noisy):\n\(screenText.prefix(4_000))")
        }
        return parts.joined(separator: "\n\n")
    }

    static func answerTask(userName: String, asker: String, question: String) -> String {
        """
        TASK: \(asker) just said: "\(question)"
        Decide whether this is a question or request directed at \(userName) that they are expected to answer now.
        First line exactly: FOR_ME|yes or FOR_ME|no. If no, stop there.
        If yes, write 1 to 3 lines: OPTION|<high|medium|low confidence>|<what \(userName) could say>
        Then a line WARN|<text> for any option that commits to dates, scope, effort or cost (omit otherwise).
        Optionally one line FOLLOWUP|<a clarifying question \(userName) could ask back>.
        """
    }

    static func questionsTask(userName: String, alreadySuggested: [String]) -> String {
        var task = """
        TASK: Suggest 3 to 5 high-impact questions \(userName) could ask right now, most important first, based on \
        what is being discussed and shown. Skip anything already asked or answered in the transcript.
        Write one per line: Q|<high|medium|low impact>|<the question>|<why it matters, max 12 words>
        """
        if !alreadySuggested.isEmpty {
            task += "\nAlready suggested earlier (don't repeat):\n" + alreadySuggested.suffix(15).map { "- \($0)" }.joined(separator: "\n")
        }
        return task
    }

    static func compressTask(previousSummary: String, transcript: String) -> String {
        """
        Update the running meeting summary with the transcript excerpt below. Keep it under 250 words, factual, \
        organised as short bullets: topics, decisions, open questions, who owns what. Output only the updated summary.

        Previous summary:
        \(previousSummary.isEmpty ? "(none)" : previousSummary)

        Transcript excerpt:
        \(transcript)
        """
    }
}
