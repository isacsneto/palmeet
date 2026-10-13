import Foundation
import LLMKit
import SessionKit
import Testing
@testable import CopilotKit

@Suite struct QuestionDetectorTests {
    let names = UserProfile(name: "Isac Santos", aliases: ["Zac"]).callNames

    @Test func englishQuestionToUser() {
        let result = QuestionDetector.analyze("Isac, can we ship this by Friday?", userCallNames: names)
        #expect(result.isQuestion && result.mentionsUser && result.shouldTrigger)
    }

    @Test func portugueseQuestionToListener() {
        let result = QuestionDetector.analyze("E você, o que acha dessa abordagem?", userCallNames: names)
        #expect(result.isQuestion && result.addressesListener && result.shouldTrigger)
    }

    @Test func statementsDoNotTrigger() {
        #expect(!QuestionDetector.analyze("We shipped the release yesterday.", userCallNames: names).shouldTrigger)
        #expect(!QuestionDetector.analyze("", userCallNames: names).isQuestion)
    }

    @Test func nameMatchingIsWordBasedAndAccentInsensitive() {
        #expect(QuestionDetector.analyze("ZAC, does that work for you?", userCallNames: names).mentionsUser)
        #expect(!QuestionDetector.analyze("Is the isacsantos repo ready?", userCallNames: names).mentionsUser)
    }
}

@Suite struct SuggestionLineParserTests {
    @Test func parsesStreamedAnswerLines() {
        var parser = SuggestionLineParser()
        parser.feed("FOR_ME|yes\nOPTION|high|We can ship Friday")
        #expect(parser.verdict == .forMe)
        #expect(parser.items.isEmpty)  // line not finished yet
        parser.feed(" if QA signs off.\nWARN|Commits you to Friday.\nFOLLOWUP|Which QA env?")
        parser.finish()
        #expect(parser.items.map(\.text) == ["We can ship Friday if QA signs off."])
        #expect(parser.items.first?.confidence == "high")
        #expect(parser.warnings == ["Commits you to Friday."])
        #expect(parser.followUps == ["Which QA env?"])
    }

    @Test func parsesQuestionsAndIgnoresNoise() {
        var parser = SuggestionLineParser()
        parser.feed("Here you go:\n- Q|high|What happens offline?|Not in acceptance criteria\n```\n")
        #expect(parser.items.count == 1)
        #expect(parser.items[0].detail == "Not in acceptance criteria")
    }

    @Test func notForMe() {
        var parser = SuggestionLineParser()
        parser.feed("FOR_ME|no\n")
        #expect(parser.verdict == .notForMe)
    }
}

@Suite struct MeetingModeTests {
    @Test func guessesFromTitle() {
        #expect(MeetingMode.guess(from: "Backlog Refinement – Payments") == .grooming)
        #expect(MeetingMode.guess(from: "Daily standup") == .standup)
        #expect(MeetingMode.guess(from: "Coffee") == .generic)
    }
}

/// Counts calls and replies with a canned stream.
final class MockProvider: LLMProvider, @unchecked Sendable {
    let kind = LLMProviderKind.anthropicAPI
    let capabilities: LLMCapabilities = [.streaming]
    let isSlow = false
    private let lock = NSLock()
    private var _calls = 0
    var reply: String
    var delay: Duration

    init(reply: String, delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { _calls += 1 }
        return LLMResponse(text: reply)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _calls += 1 }
        let reply = reply, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: delay)
                    for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(String(line) + "\n")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func checkAvailability() async -> LLMAvailability { .ready }
}

@Suite struct CopilotEngineTests {
    func question(_ text: String, at start: TimeInterval = 10) -> TranscriptSegment {
        TranscriptSegment(speakerID: "S1", track: .them, start: start, end: start + 2, text: text)
    }

    func makeEngine(_ provider: MockProvider) -> CopilotEngine {
        let config = CopilotConfiguration(profile: UserProfile(name: "Isac Santos"), proactiveQuestions: false, unansweredReminderDelay: 3600)
        return CopilotEngine(provider: provider, configuration: config, now: { 12 })
    }

    @Test func answersQuestionsAddressedToTheUser() async throws {
        let provider = MockProvider(reply: "FOR_ME|yes\nOPTION|high|Yes, if QA signs off by Thursday.")
        let engine = makeEngine(provider)
        await engine.start()
        await engine.ingest(question("Isac, can we ship Friday?"), speakerName: "Maria")
        var iterator = engine.events.makeAsyncIterator()
        var ready: Suggestion?
        while let event = await iterator.next() {
            if case .suggestion(let s) = event, s.status == .ready { ready = s; break }
        }
        #expect(ready?.kind == .answer)
        #expect(ready?.askedBy == "Maria")
        #expect(ready?.items.first?.text == "Yes, if QA signs off by Thursday.")
        await engine.shutdown()
    }

    @Test func notForMeProducesNoCard() async throws {
        let provider = MockProvider(reply: "FOR_ME|no")
        let engine = makeEngine(provider)
        await engine.start()
        await engine.ingest(question("Isac, can you hear John?"), speakerName: "Maria")
        try await Task.sleep(for: .milliseconds(200))
        await engine.shutdown()
        var cards = 0
        for await event in engine.events { if case .suggestion = event { cards += 1 } }
        #expect(provider.calls == 1)
        #expect(cards == 0)
    }

    /// The strict OFF contract: after shutdown nothing reaches the provider and in-flight work is dropped.
    @Test func noProviderCallsAfterShutdown() async throws {
        let provider = MockProvider(reply: "FOR_ME|yes\nOPTION|high|late", delay: .seconds(2))
        let engine = makeEngine(provider)
        await engine.start()
        await engine.ingest(question("Isac, what do you think?"), speakerName: "Maria")
        try await Task.sleep(for: .milliseconds(150))
        #expect(provider.calls == 1)
        await engine.shutdown()
        await engine.ingest(question("Isac, and now?", at: 20), speakerName: "Maria")
        await engine.helpNow()
        await engine.updateScreenText("lots of new slide text that changes everything on the screen right now")
        #expect(provider.calls == 1)
        var cards = 0
        for await event in engine.events { if case .suggestion = event { cards += 1 } }
        #expect(cards == 0)
    }

    @Test func rateLimitCapsCalls() async {
        let provider = MockProvider(reply: "FOR_ME|no")
        let config = CopilotConfiguration(profile: UserProfile(name: "Isac"), proactiveQuestions: false, maxCallsPerMinute: 2, unansweredReminderDelay: 3600)
        let engine = CopilotEngine(provider: provider, configuration: config, now: { 5 })
        await engine.start()
        for i in 0..<10 {
            await engine.ingest(question("Isac, question number \(i)?", at: Double(i)), speakerName: "Maria")
        }
        #expect(provider.calls <= 4)
        await engine.shutdown()
    }
}

/// Provider whose stream yields lines one by one, optionally failing after some of them.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let kind = LLMProviderKind.anthropicAPI
    let capabilities: LLMCapabilities = [.streaming]
    let isSlow = false
    private let lock = NSLock()
    private var _streams = 0, _completes = 0
    private var _requests: [LLMRequest] = []
    var streamLines: [String]
    var failAfterLines: Int?
    var completeText: String

    init(streamLines: [String], failAfterLines: Int? = nil, completeText: String = "") {
        self.streamLines = streamLines
        self.failAfterLines = failAfterLines
        self.completeText = completeText
    }

    var streams: Int { lock.withLock { _streams } }
    var completes: Int { lock.withLock { _completes } }
    var requests: [LLMRequest] { lock.withLock { _requests } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lock.withLock { _completes += 1; _requests.append(request) }
        return LLMResponse(text: completeText)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _streams += 1; _requests.append(request) }
        let lines = streamLines, failAfter = failAfterLines
        return AsyncThrowingStream { continuation in
            for (index, line) in lines.enumerated() {
                if let failAfter, index == failAfter {
                    continuation.finish(throwing: LLMError.http(status: 529, body: "overloaded"))
                    return
                }
                continuation.yield(line + "\n")
            }
            continuation.finish()
        }
    }

    func checkAvailability() async -> LLMAvailability { .ready }
}

func collect(_ engine: CopilotEngine, for duration: Duration) async -> [CopilotEvent] {
    var events: [CopilotEvent] = []
    let task = Task {
        var collected: [CopilotEvent] = []
        for await event in engine.events { collected.append(event) }
        return collected
    }
    try? await Task.sleep(for: duration)
    await engine.shutdown()
    events = await task.value
    return events
}

func suggestions(_ events: [CopilotEvent]) -> [Suggestion] {
    events.compactMap { if case .suggestion(let s) = $0 { s } else { nil } }
}

@Suite(.timeLimit(.minutes(1))) struct CopilotBehaviourTests {
    func segment(_ text: String, track: Track = .them, at start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speakerID: track == .me ? "me" : "S1", track: track, start: start, end: start + 2, text: text)
    }

    func config(remind: Bool = true, delay: TimeInterval = 0.3, proactive: Bool = false, interval: TimeInterval = 90) -> CopilotConfiguration {
        CopilotConfiguration(profile: UserProfile(name: "Isac Santos"), proactiveQuestions: proactive, proactiveInterval: interval, unansweredReminderDelay: delay, remindUnanswered: remind)
    }

    @Test func remindsOnlyForConfirmedQuestionsThatStayUnanswered() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|yes", "OPTION|high|Sure."])
        let engine = CopilotEngine(provider: provider, configuration: config(), now: { 10 })
        await engine.start()
        await engine.ingest(segment("Isac, can you take this?", at: 5), speakerName: "Maria")
        let events = await collect(engine, for: .milliseconds(700))
        let kinds = suggestions(events).map(\.kind)
        #expect(kinds.contains(.answer))
        #expect(kinds.contains(.reminder))
    }

    @Test func noReminderWhenTheModelSaysNotForMe() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|no"])
        let engine = CopilotEngine(provider: provider, configuration: config(), now: { 10 })
        await engine.start()
        await engine.ingest(segment("Isac, did John reply?", at: 5), speakerName: "Maria")
        #expect(suggestions(await collect(engine, for: .milliseconds(700))).isEmpty)
    }

    @Test func noReminderOnceTheUserSpoke() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|yes", "OPTION|high|Sure."])
        let engine = CopilotEngine(provider: provider, configuration: config(), now: { 10 })
        await engine.start()
        await engine.ingest(segment("Isac, can you take this?", at: 5), speakerName: "Maria")
        await engine.ingest(segment("Yes, I'll take it.", track: .me, at: 8), speakerName: "Isac")
        let kinds = suggestions(await collect(engine, for: .milliseconds(700))).map(\.kind)
        #expect(kinds.contains(.answer) && !kinds.contains(.reminder))
    }

    @Test func noRemindersWithoutTheMic() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|yes", "OPTION|high|Sure."])
        let engine = CopilotEngine(provider: provider, configuration: config(remind: false), now: { 10 })
        await engine.start()
        await engine.ingest(segment("Isac, can you take this?", at: 5), speakerName: "Maria")
        #expect(!suggestions(await collect(engine, for: .milliseconds(700))).map(\.kind).contains(.reminder))
    }

    @Test func liveRequestsAskForLowLatencyAndEnoughTokens() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|no"])
        let engine = CopilotEngine(provider: provider, configuration: config(), now: { 10 })
        await engine.start()
        await engine.ingest(segment("Isac, can you take this?", at: 5), speakerName: "Maria")
        _ = await collect(engine, for: .milliseconds(200))
        let request = provider.requests.first
        #expect(request?.preferLowLatency == true)
        #expect((request?.maxTokens ?? 0) >= 1_000)
        #expect(request?.cacheSystemPrompt == true)
        #expect(request?.system?.contains("Isac Santos") == true)
    }

    @Test func failedStreamMarksPartialCardFailed() async {
        let provider = ScriptedProvider(streamLines: ["Q|high|First question?|why", "Q|low|Second?|why"], failAfterLines: 1)
        let engine = CopilotEngine(provider: provider, configuration: config(), now: { 10 })
        await engine.start()
        await engine.helpNow()
        let events = await collect(engine, for: .milliseconds(300))
        let cards = suggestions(events)
        #expect(cards.last?.status == .failed)
        #expect(cards.last?.items.map(\.text) == ["First question?"])
        #expect(events.contains { if case .error = $0 { true } else { false } })
    }

    @Test func proactiveQuestionsNeedNewMaterialAndRespectTheInterval() async {
        let provider = ScriptedProvider(streamLines: ["Q|high|What about rollback?|risk"])
        let clock = ManualClock()
        let engine = CopilotEngine(provider: provider, configuration: config(proactive: true, interval: 60), tickInterval: .milliseconds(50), now: { clock.now })
        await engine.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(provider.streams == 0, "nothing said yet")
        let longText = Array(repeating: "we need to discuss the checkout migration plan", count: 20).joined(separator: " ")
        await engine.ingest(segment(longText, at: 1), speakerName: "Maria")
        clock.now = 100
        try? await Task.sleep(for: .milliseconds(300))
        #expect(provider.streams == 1)
        await engine.ingest(segment(longText, at: 101), speakerName: "Maria")
        clock.now = 120  // only 20 s later: under the 60 s interval
        try? await Task.sleep(for: .milliseconds(300))
        #expect(provider.streams == 1)
        await engine.shutdown()
    }

    @Test func emptyCompressionReplyKeepsContext() async {
        let provider = ScriptedProvider(streamLines: ["FOR_ME|no"], completeText: "   ")
        let clock = ManualClock()
        let engine = CopilotEngine(provider: provider, configuration: config(), tickInterval: .milliseconds(50), now: { clock.now })
        await engine.start()
        let longText = Array(repeating: "budget numbers for the quarter were discussed at length", count: 80).joined(separator: " ")
        await engine.ingest(segment(longText, at: 0), speakerName: "Maria")
        clock.now = 400  // older than the 5 minute window → compression attempt
        try? await Task.sleep(for: .milliseconds(300))
        #expect(provider.completes >= 1)
        // Context must still contain the old text for the next request.
        await engine.ingest(segment("Isac, what do you think?", at: 401), speakerName: "Maria")
        try? await Task.sleep(for: .milliseconds(200))
        let lastStream = provider.requests.last { $0.preferLowLatency && $0.messages.first.map { if case .text(let t) = $0.parts[0] { t.contains("Decide whether") } else { false } } == true }
        let text: String? = lastStream.flatMap { if case .text(let t) = $0.messages[0].parts[0] { t } else { nil } }
        #expect(text?.contains("budget numbers") == true)
        await engine.shutdown()
    }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
