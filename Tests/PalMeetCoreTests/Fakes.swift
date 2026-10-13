@preconcurrency import AVFoundation
import BrowserBridge
import CaptureKit
import Foundation
import LLMKit
import SessionKit
import TranscriptKit
@testable import PalMeetCore

// MARK: - Signal "vocabulary"

/// Test speech: a sine whose peak amplitude encodes a word, so fakes can "recognize" it and leaks between
/// sessions become visible as wrong words.
enum Voice: String, CaseIterable, Sendable {
    case mike, alpha, bravo, question, november

    var amplitude: Float {
        switch self {
        case .mike: 0.04
        case .alpha: 0.12
        case .bravo: 0.25
        case .question: 0.45
        case .november: 0.8
        }
    }

    /// What the fake ASR "hears". The question is a phrase the copilot's detector reacts to.
    var text: String {
        self == .question ? "Isac, can you review the plan?" : rawValue
    }

    static func classify(peak: Float) -> Voice? {
        switch peak {
        case 0.02..<0.07: .mike
        case 0.07..<0.18: .alpha
        case 0.18..<0.35: .bravo
        case 0.35..<0.6: .question
        case 0.6..<0.95: .november
        default: nil
        }
    }

    func samples(seconds: Double, rate: Double = 16_000, frequency: Double = 220) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }
}

func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * rate))
}

// MARK: - Fake ASR / diarization

/// Recognizes `Voice` signals: one word per 0.5 s window (phrases once per run), with real timings.
struct FakeASR: ASREngine {
    let id = "fake-asr"
    let calls = Counter()

    func prepare() async throws {}

    func transcribe(samples: [Float], language: String?) async throws -> ASRTranscription {
        calls.increment()
        return Self.recognize(samples)
    }

    func transcribe(fileURL: URL, language: String?) async throws -> ASRTranscription {
        calls.increment()
        return Self.recognize(try readMono(fileURL))
    }

    static func recognize(_ samples: [Float]) -> ASRTranscription {
        var words: [TranscriptWord] = []
        for run in voiceRuns(samples) {
            if run.voice == .question {
                for (i, word) in run.voice.text.split(separator: " ").enumerated() {
                    words.append(TranscriptWord(text: String(word), start: run.start + Double(i) * 0.05, end: run.start + Double(i) * 0.05 + 0.04))
                }
            } else {
                // One word per started half second of speech, timed where the speech is.
                var t = run.start
                while t < run.end - 0.05 {
                    words.append(TranscriptWord(text: run.voice.text, start: t, end: min(run.end, t + 0.4)))
                    t += 0.5
                }
            }
        }
        return ASRTranscription(text: words.map(\.text).joined(separator: " "), words: words, confidence: 1)
    }
}

struct VoiceRun {
    var voice: Voice
    var start: TimeInterval
    var end: TimeInterval
}

/// Splits audio into runs of one `Voice` using 20 ms frames (a run ends at silence or when the voice changes).
func voiceRuns(_ samples: [Float]) -> [VoiceRun] {
    let frame = 320
    var runs: [VoiceRun] = []
    for start in stride(from: 0, to: samples.count, by: frame) {
        let slice = samples[start..<min(samples.count, start + frame)]
        let voice = Voice.classify(peak: slice.map(abs).max() ?? 0)
        let s = Double(start) / 16_000, e = Double(start + slice.count) / 16_000
        if let voice, let last = runs.last, last.voice == voice, abs(last.end - s) < 0.001 {
            runs[runs.count - 1].end = e
        } else if let voice {
            runs.append(VoiceRun(voice: voice, start: s, end: e))
        }
    }
    return runs.filter { $0.end - $0.start >= 0.1 }
}

/// One span per contiguous voiced run, keyed by the voice, so each voice becomes its own speaker.
struct FakeDiarizer: Diarizer {
    func prepare() async throws {}

    func diarize(fileURL: URL) async throws -> [DiarizedSpan] {
        voiceRuns(try readMono(fileURL)).map { DiarizedSpan(speakerKey: $0.voice.rawValue, start: $0.start, end: $0.end) }
    }
}

func readMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.length > 0 else { return [] }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

// MARK: - Fake capture

/// Remote audio the test pushes on demand, stamped at session offsets.
final class FakeRemoteAudio: RemoteAudioSource, @unchecked Sendable {
    let isolation: AudioIsolation
    let gapTolerance: TimeInterval = 0.25
    private let lock = NSLock()
    private var onSamples: (@Sendable ([Float], Date) -> Void)?
    private var startDate = Date()
    private(set) var stopped = false
    private let startDelay: Duration

    init(isolation: AudioIsolation = .processTap, startDelay: Duration = .zero) {
        self.isolation = isolation
        self.startDelay = startDelay
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func start(onSamples: @escaping @Sendable ([Float], Date) -> Void) async throws {
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        lock.withLock {
            self.onSamples = onSamples
            self.startDate = Date()
        }
    }

    func stop() async {
        lock.withLock { stopped = true }
    }

    /// Delivers samples as if captured at `offset` seconds into the session (in 100 ms chunks).
    func push(_ samples: [Float], at offset: TimeInterval) {
        let (handler, start) = lock.withLock { (onSamples, startDate) }
        guard let handler else { return }
        for chunkStart in stride(from: 0, to: samples.count, by: 1_600) {
            let chunk = Array(samples[chunkStart..<min(samples.count, chunkStart + 1_600)])
            handler(chunk, start.addingTimeInterval(offset + Double(chunkStart) / 16_000))
        }
    }

    /// Delivers samples now, paced in real time (for tests that depend on wall-clock routing changes).
    func pushRealtime(_ samples: [Float]) async {
        let handler = lock.withLock { onSamples }
        guard let handler else { return }
        for chunkStart in stride(from: 0, to: samples.count, by: 1_600) {
            let chunk = Array(samples[chunkStart..<min(samples.count, chunkStart + 1_600)])
            handler(chunk, Date())
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Shared fake microphone with real multi-subscriber semantics.
final class FakeMicrophone: MicrophoneSource, @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<MicrophoneCapture.Chunk>.Continuation] = [:]

    func subscribe() throws -> AsyncStream<MicrophoneCapture.Chunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: MicrophoneCapture.Chunk.self)
        let id = UUID()
        lock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    var subscriberCount: Int { lock.withLock { subscribers.count } }

    func push(_ samples: [Float], time: Date) {
        let targets = lock.withLock { Array(subscribers.values) }
        for chunkStart in stride(from: 0, to: samples.count, by: 1_600) {
            let chunk = Array(samples[chunkStart..<min(samples.count, chunkStart + 1_600)])
            let chunkTime = time.addingTimeInterval(Double(chunkStart) / 16_000)
            targets.forEach { $0.yield(MicrophoneCapture.Chunk(samples: chunk, time: chunkTime)) }
        }
    }

    func pushRealtime(_ samples: [Float]) async {
        for chunkStart in stride(from: 0, to: samples.count, by: 1_600) {
            push(Array(samples[chunkStart..<min(samples.count, chunkStart + 1_600)]), time: Date())
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

// MARK: - Fake LLM

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Summaries via `complete`, copilot via `stream`; counts each separately.
final class FakeLLM: LLMProvider, @unchecked Sendable {
    let kind = LLMProviderKind.anthropicAPI
    let capabilities: LLMCapabilities = [.streaming, .images]
    let isSlow = false
    let completeCalls = Counter()
    let streamCalls = Counter()
    private let lock = NSLock()
    private var _lastSummaryPrompt = ""
    var failSummaries = false
    var summaryDelay: Duration = .zero
    var summaryJSON = #"{"title":"Fake summary","tldr":"Everything worked.","action_items":[{"owner":"Speaker 1","task":"Ship it","ref":"00:00:01"}],"speaker_names":{"S1":"Maria Silva"}}"#
    var copilotReply = "FOR_ME|yes\nOPTION|high|Yes, I'll review it today."

    var lastSummaryPrompt: String { lock.withLock { _lastSummaryPrompt } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        completeCalls.increment()
        let text = request.messages.flatMap(\.parts).compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined(separator: "\n")
        lock.withLock { _lastSummaryPrompt = text }
        if summaryDelay > .zero { try await Task.sleep(for: summaryDelay) }
        if failSummaries { throw LLMError.http(status: 500, body: "boom") }
        return LLMResponse(text: summaryJSON)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        streamCalls.increment()
        let reply = copilotReply
        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }

    func checkAvailability() async -> LLMAvailability { .ready }
}

// MARK: - Harness

@MainActor
struct Harness {
    let manager: SessionManager
    let root: URL
    let mic: FakeMicrophone
    let llm: FakeLLM
    let asr: FakeASR

    init(
        root existingRoot: URL? = nil,
        settings mutate: (inout AppSettings) -> Void = { _ in },
        bridgeToken: String = "test-token",
        asr realASR: (any ASREngine)? = nil,
        diarizer realDiarizer: (any Diarizer)? = nil,
        provider realProvider: (any LLMProvider)? = nil,
        bridge customBridge: BrowserBridgeServer? = nil,
        microphoneAllowed micAllowed: Bool = true
    ) {
        root = existingRoot ?? FileManager.default.temporaryDirectory.appending(path: "palmeet-core-\(UUID().uuidString)")
        var settings = AppSettings()
        settings.profile = .init(name: "Isac Santos")
        settings.storageRoot = root.path
        settings.hasCompletedOnboarding = true
        mutate(&settings)
        let suite = "palmeet-tests-\(UUID().uuidString)"
        let settingsStore = SettingsStore(suiteName: suite)
        settingsStore.save(settings)
        let box = SettingsBox(settings)
        let mic = FakeMicrophone()
        let llm = FakeLLM()
        let asr = FakeASR()
        let services = SessionServices(
            store: SessionStore(rootURL: root),
            microphone: mic,
            asr: realASR ?? asr,
            diarizer: realDiarizer ?? FakeDiarizer(),
            scheduler: ASRScheduler(),
            makeProvider: { _ in realProvider ?? llm },
            ensureMicrophoneAccess: { micAllowed }
        )
        let bridge = customBridge ?? BrowserBridgeServer(configuration: .init(portCandidates: [0], bridgeInfoStore: nil, token: bridgeToken))
        manager = SessionManager(settingsStore: settingsStore, secrets: InMemorySecretStore(), settingsBox: box, services: services, bridge: bridge)
        self.mic = mic
        self.llm = llm
        self.asr = asr
    }

    func start(
        title: String = "Weekly sync",
        bundleID: String = "us.zoom.xos",
        pid: Int32 = 4242,
        remote: FakeRemoteAudio? = FakeRemoteAudio(),
        includeMic: Bool = true
    ) async throws -> MeetingSession {
        let source = CaptureSourceDescriptor(kind: .window, appName: "Zoom", bundleID: bundleID, processID: pid)
        return try await manager.startSession(
            id: SessionID(), source: source, title: title, remote: remote, windowID: nil, frames: nil,
            includeMicrophone: includeMic, preview: .isolated("test")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Polls until `condition` holds or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

func words(in transcript: Transcript?, track: Track? = nil) -> [String] {
    (transcript?.segments ?? [])
        .filter { track == nil || $0.track == track }
        .flatMap { $0.text.lowercased().split(separator: " ").map(String.init) }
}
