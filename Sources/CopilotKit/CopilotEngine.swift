import Foundation
import LLMKit
import SessionKit

public struct CopilotConfiguration: Sendable, Equatable {
    public var profile: UserProfile
    public var mode: MeetingMode
    public var playbook: String
    public var prepNotes: String
    public var meetingTitle: String
    /// Fast model override; nil uses the provider's configured fast model.
    public var model: String?
    public var proactiveQuestions: Bool
    /// Minimum time between two proactive "questions to ask" cards.
    public var proactiveInterval: TimeInterval
    public var maxCallsPerMinute: Int
    /// Seconds after a question to the user before reminding them it's unanswered.
    public var unansweredReminderDelay: TimeInterval
    /// Reminders need to know whether the user spoke, so they're off when this meeting doesn't get the mic.
    public var remindUnanswered: Bool

    public init(
        profile: UserProfile,
        mode: MeetingMode = .generic,
        playbook: String? = nil,
        prepNotes: String = "",
        meetingTitle: String = "Meeting",
        model: String? = nil,
        proactiveQuestions: Bool = true,
        proactiveInterval: TimeInterval = 90,
        maxCallsPerMinute: Int = 6,
        unansweredReminderDelay: TimeInterval = 25,
        remindUnanswered: Bool = true
    ) {
        self.profile = profile
        self.mode = mode
        self.playbook = playbook ?? mode.defaultPlaybook
        self.prepNotes = prepNotes
        self.meetingTitle = meetingTitle
        self.model = model
        self.proactiveQuestions = proactiveQuestions
        self.proactiveInterval = proactiveInterval
        self.maxCallsPerMinute = maxCallsPerMinute
        self.unansweredReminderDelay = unansweredReminderDelay
        self.remindUnanswered = remindUnanswered
    }
}

public enum CopilotEvent: Sendable {
    /// A card was created or changed (streaming text, ready, failed).
    case suggestion(Suggestion)
    case usage(LLMUsage)
    case error(String)
}

/// Live copilot for ONE session. It exists only while the user's toggle is ON: the owner creates it on enable and
/// calls `shutdown()` on disable, which cancels in-flight requests. It only ever sees the transcript and screen
/// context fed to it, so sessions can't leak into each other.
public actor CopilotEngine {
    struct Entry: Sendable {
        var offset: TimeInterval
        var speaker: String
        var text: String
        var track: Track
    }

    public nonisolated let events: AsyncStream<CopilotEvent>
    private let continuation: AsyncStream<CopilotEvent>.Continuation
    private let provider: any LLMProvider
    private var configuration: CopilotConfiguration
    private let now: @Sendable () -> TimeInterval

    private var entries: [Entry] = []
    private var runningSummary = ""
    private var screenText: String?
    private var screenChangedSinceLastCard = false
    private var wordsSinceLastCard = 0
    private var lastProactiveAt: TimeInterval = -.infinity
    private var callTimes: [TimeInterval] = []
    private var suggestedQuestions: [String] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var loop: Task<Void, Never>?
    private var isShutDown = false
    private var compressing = false

    /// Total provider calls made, for tests and the usage meter.
    public private(set) var callCount = 0

    /// Keep this much transcript verbatim; older text is folded into the running summary.
    private let recentWindow: TimeInterval = 300
    private let recentTranscriptLimit = 16_000

    private let tickInterval: Duration

    public init(
        provider: any LLMProvider,
        configuration: CopilotConfiguration,
        tickInterval: Duration = .seconds(15),
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.provider = provider
        self.configuration = configuration
        self.tickInterval = tickInterval
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: CopilotEvent.self, bufferingPolicy: .bufferingNewest(100))
    }

    /// Starts the proactive loop and primes the context with what was said before the copilot was turned on.
    public func start(priming segments: [(speaker: String, segment: TranscriptSegment)] = []) {
        guard !isShutDown, loop == nil else { return }
        for item in segments { append(item.segment, speaker: item.speaker) }
        wordsSinceLastCard = 0
        let interval = tickInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    public func update(configuration: CopilotConfiguration) {
        self.configuration = configuration
    }

    /// Cancels everything in flight and goes inert. After this no provider call can happen.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        loop?.cancel()
        loop = nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        continuation.finish()
    }

    // MARK: - Inputs

    public func ingest(_ segment: TranscriptSegment, speakerName: String) {
        guard !isShutDown else { return }
        append(segment, speaker: speakerName)
        guard segment.track == .them else { return }

        let detection = QuestionDetector.analyze(segment.text, userCallNames: configuration.profile.callNames)
        if detection.shouldTrigger {
            requestAnswer(question: segment.text, asker: speakerName, offset: segment.end)
        }
    }

    public func updateScreenText(_ text: String) {
        guard !isShutDown else { return }
        let changed = TextChange.isSignificant(from: screenText ?? "", to: text)
        screenText = text
        if changed { screenChangedSinceLastCard = true }
    }

    /// "Help me now": answer the latest question (if any, within 2 minutes) and suggest questions immediately.
    public func helpNow() {
        guard !isShutDown else { return }
        let current = now()
        if let lastQuestion = entries.last(where: { $0.track == .them && current - $0.offset < 120 && QuestionDetector.analyze($0.text, userCallNames: configuration.profile.callNames).isQuestion }) {
            requestAnswer(question: lastQuestion.text, asker: lastQuestion.speaker, offset: lastQuestion.offset, force: true)
        }
        requestQuestions(force: true)
    }

    // MARK: - Context

    private func append(_ segment: TranscriptSegment, speaker: String) {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(Entry(offset: segment.start, speaker: speaker, text: text, track: segment.track))
        wordsSinceLastCard += text.split(separator: " ").count
    }

    /// Everything not yet folded into the running summary, newest last, capped by size (not time) so text that
    /// couldn't be compressed yet is never silently lost.
    private var recentTranscript: String {
        var lines: [String] = []
        var size = 0
        for entry in entries.reversed() {
            let line = "[\(Timecode.format(entry.offset))] \(entry.speaker): \(entry.text)"
            size += line.count + 1
            if size > recentTranscriptLimit, !lines.isEmpty { break }
            lines.append(line)
        }
        return lines.reversed().joined(separator: "\n")
    }

    private func baseMessages(task: String) -> (system: String, user: String) {
        let system = CopilotPrompts.system(
            profile: configuration.profile,
            mode: configuration.mode,
            playbook: configuration.playbook,
            prepNotes: configuration.prepNotes,
            meetingTitle: configuration.meetingTitle
        )
        let context = CopilotPrompts.context(runningSummary: runningSummary, recentTranscript: recentTranscript, screenText: screenText)
        return (system, context + "\n\n" + task)
    }

    // MARK: - Rate limiting

    private func allowCall(force: Bool) -> Bool {
        let current = now()
        callTimes.removeAll { current - $0 > 60 }
        let limit = configuration.maxCallsPerMinute + (force ? 2 : 0)
        guard callTimes.count < limit else { return false }
        callTimes.append(current)
        return true
    }

    // MARK: - Triggers

    private func tick() async {
        guard !isShutDown else { return }
        await compressOldTranscriptIfNeeded()
        guard configuration.proactiveQuestions else { return }
        let elapsed = now() - lastProactiveAt
        let hasNewMaterial = wordsSinceLastCard >= 120 || screenChangedSinceLastCard
        if elapsed >= configuration.proactiveInterval, hasNewMaterial {
            requestQuestions(force: false)
        }
    }

    private func requestAnswer(question: String, asker: String, offset: TimeInterval, force: Bool = false) {
        guard allowCall(force: true) else { return }
        let userName = configuration.profile.name.split(separator: " ").first.map(String.init) ?? configuration.profile.name
        let prompt = baseMessages(task: CopilotPrompts.answerTask(userName: userName, asker: asker, question: question))
        let suggestion = Suggestion(kind: .answer, offset: offset, triggerText: question, askedBy: asker)
        run(suggestion: suggestion, system: prompt.system, user: prompt.user, maxTokens: 1_200, requiresForMe: !force)
    }

    private func requestQuestions(force: Bool) {
        guard allowCall(force: force) else { return }
        lastProactiveAt = now()
        wordsSinceLastCard = 0
        screenChangedSinceLastCard = false
        let userName = configuration.profile.name.split(separator: " ").first.map(String.init) ?? configuration.profile.name
        let prompt = baseMessages(task: CopilotPrompts.questionsTask(userName: userName, alreadySuggested: suggestedQuestions))
        run(suggestion: Suggestion(kind: .questions, offset: now()), system: prompt.system, user: prompt.user, maxTokens: 1_200, requiresForMe: false)
    }

    private func scheduleUnansweredReminder(question: String, asker: String, offset: TimeInterval) {
        guard configuration.remindUnanswered, !isShutDown else { return }
        let id = UUID()
        let delay = configuration.unansweredReminderDelay
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.remindIfUnanswered(question: question, asker: asker, offset: offset, taskID: id)
        }
    }

    private func remindIfUnanswered(question: String, asker: String, offset: TimeInterval, taskID: UUID) {
        tasks[taskID] = nil
        guard !isShutDown else { return }
        let answered = entries.contains { $0.track == .me && $0.offset >= offset - 1 }
        guard !answered else { return }
        let reminder = Suggestion(kind: .reminder, status: .ready, offset: offset, triggerText: question, askedBy: asker, items: [Suggestion.Item(text: question)])
        continuation.yield(.suggestion(reminder))
    }

    // MARK: - Provider calls

    private func run(suggestion initial: Suggestion, system: String, user: String, maxTokens: Int, requiresForMe: Bool) {
        let request = LLMRequest(
            system: system,
            messages: [.user(user)],
            model: configuration.model,
            maxTokens: maxTokens,
            temperature: 0.3,
            responseFormat: .text,
            cacheSystemPrompt: true,
            timeout: 45,
            preferLowLatency: true
        )
        callCount += 1
        let id = initial.id
        let provider = self.provider
        tasks[id] = Task { [weak self] in
            var suggestion = initial
            var parser = SuggestionLineParser()
            do {
                // Shut down before the task got scheduled: never reach the provider.
                try Task.checkCancellation()
                for try await delta in provider.stream(request) {
                    try Task.checkCancellation()
                    if parser.feed(delta) {
                        await self?.publish(&suggestion, parser: parser, requiresForMe: requiresForMe)
                    }
                }
                parser.finish()
                suggestion.status = .ready
                await self?.publish(&suggestion, parser: parser, requiresForMe: requiresForMe, final: true)
                // Remind about unanswered questions only when the model confirmed the question was for the user.
                if initial.kind == .answer, parser.verdict == .forMe || !requiresForMe {
                    await self?.scheduleUnansweredReminder(question: initial.triggerText ?? "", asker: initial.askedBy ?? "", offset: initial.offset)
                }
            } catch is CancellationError {
                // Toggle turned off or engine shut down: drop silently.
            } catch {
                guard !Task.isCancelled else { return }
                suggestion.status = .failed
                suggestion.errorMessage = error.localizedDescription
                await self?.emitFailure(suggestion, parser: parser, requiresForMe: requiresForMe)
            }
            await self?.finishTask(id)
        }
    }

    private func publish(_ suggestion: inout Suggestion, parser: SuggestionLineParser, requiresForMe: Bool, final: Bool = false) {
        guard !isShutDown else { return }
        if requiresForMe && parser.verdict != .forMe { return }
        if parser.items.isEmpty && !final { return }
        if final && parser.items.isEmpty { return }
        suggestion.items = parser.items
        suggestion.warnings = parser.warnings
        suggestion.followUps = parser.followUps
        if final, suggestion.kind == .questions {
            suggestedQuestions += parser.items.map(\.text)
        }
        continuation.yield(.suggestion(suggestion))
    }

    /// Reports the error and, if the card was already showing partial items, marks it failed instead of
    /// leaving it "streaming" forever.
    private func emitFailure(_ suggestion: Suggestion, parser: SuggestionLineParser, requiresForMe: Bool) {
        guard !isShutDown else { return }
        if !parser.items.isEmpty, !requiresForMe || parser.verdict == .forMe {
            var failed = suggestion
            failed.items = parser.items
            failed.warnings = parser.warnings
            failed.followUps = parser.followUps
            continuation.yield(.suggestion(failed))
        }
        continuation.yield(.error(suggestion.errorMessage ?? "Copilot request failed"))
    }

    private func finishTask(_ id: UUID) {
        tasks[id] = nil
    }

    /// Folds transcript older than the recent window into the running summary (one cheap call).
    private func compressOldTranscriptIfNeeded() async {
        guard !compressing else { return }
        let cutoff = now() - recentWindow
        let old = entries.filter { $0.offset < cutoff }
        let words = old.reduce(0) { $0 + $1.text.split(separator: " ").count }
        guard words >= 600, allowCall(force: false) else { return }
        compressing = true
        defer { compressing = false }
        let excerpt = old.map { "[\(Timecode.format($0.offset))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        let request = LLMRequest(
            messages: [.user(CopilotPrompts.compressTask(previousSummary: runningSummary, transcript: excerpt))],
            model: configuration.model,
            maxTokens: 1_000,
            temperature: 0.2,
            timeout: 60,
            preferLowLatency: true
        )
        callCount += 1
        do {
            let response = try await provider.complete(request)
            let summary = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty reply (e.g. reasoning tokens used up the budget) must not wipe the context.
            guard !isShutDown, !summary.isEmpty else { return }
            runningSummary = summary
            entries.removeAll { $0.offset < cutoff }
            if let usage = response.usage { continuation.yield(.usage(usage)) }
        } catch {
            // Keep the verbatim text; try again on a later tick.
        }
    }
}

enum TextChange {
    /// True when less than ~60% of the new text's words were already on screen (new slide, new ticket).
    static func isSignificant(from old: String, to new: String) -> Bool {
        let oldWords = Set(old.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let newWords = new.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard newWords.count >= 8 else { return false }
        let shared = newWords.filter { oldWords.contains($0) }.count
        return Double(shared) / Double(newWords.count) < 0.6
    }
}
