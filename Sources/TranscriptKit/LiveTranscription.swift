import Foundation
import SessionKit

/// 16 kHz mono samples placed on the session timeline.
public struct PCMChunk: Sendable {
    public var samples: [Float]
    public var startOffset: TimeInterval

    public init(samples: [Float], startOffset: TimeInterval) {
        self.samples = samples
        self.startOffset = startOffset
    }
}

/// A complete utterance cut out of a live stream.
public struct Utterance: Sendable {
    public var samples: [Float]
    public var startOffset: TimeInterval
    public var duration: TimeInterval { Double(samples.count) / AudioConstants.sampleRate }
}

/// Energy-based voice activity segmentation with an adaptive noise floor.
///
/// Cuts at ~700 ms of silence (natural end of turn) or at `maxDuration` so live text never lags too far behind.
public struct UtteranceSegmenter: Sendable {
    public struct Config: Sendable {
        public var frameSize = 480  // 30 ms
        public var endSilence: TimeInterval = 0.7
        public var minSpeech: TimeInterval = 0.35
        public var maxDuration: TimeInterval = 14
        public var preRoll: TimeInterval = 0.25
        public var minimumThreshold: Float = 0.006
        public var noiseMultiplier: Float = 3

        public init() {}
    }

    private let config: Config
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var utterance: [Float] = []
    private var utteranceStart: TimeInterval = 0
    private var preRoll: [Float] = []
    private var voicedFrames = 0
    private var silentFrames = 0
    private var inSpeech = false
    private var noiseFloor: Float = 0.003

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds a chunk; returns utterances that ended inside it.
    public mutating func append(_ chunk: PCMChunk) -> [Utterance] {
        if pending.isEmpty { pendingStart = chunk.startOffset }
        pending += chunk.samples
        var finished: [Utterance] = []
        while pending.count >= config.frameSize {
            let frame = Array(pending.prefix(config.frameSize))
            pending.removeFirst(config.frameSize)
            let frameStart = pendingStart
            pendingStart += Double(config.frameSize) / AudioConstants.sampleRate
            if let utterance = process(frame, at: frameStart) { finished.append(utterance) }
        }
        return finished
    }

    /// Flushes whatever is in progress (end of session).
    public mutating func finish() -> Utterance? {
        defer { reset() }
        guard inSpeech, Double(utterance.count) / AudioConstants.sampleRate >= config.minSpeech else { return nil }
        return Utterance(samples: utterance, startOffset: utteranceStart)
    }

    private mutating func process(_ frame: [Float], at start: TimeInterval) -> Utterance? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let threshold = max(config.minimumThreshold, noiseFloor * config.noiseMultiplier)
        let voiced = rms > threshold
        let frameDuration = Double(config.frameSize) / AudioConstants.sampleRate

        if !inSpeech {
            // Track the noise floor only outside speech; rise slowly, fall quickly.
            noiseFloor = rms < noiseFloor ? rms * 0.5 + noiseFloor * 0.5 : noiseFloor * 0.995 + rms * 0.005
            preRoll += frame
            let maxPreRoll = Int(config.preRoll * AudioConstants.sampleRate)
            if preRoll.count > maxPreRoll { preRoll.removeFirst(preRoll.count - maxPreRoll) }
            voicedFrames = voiced ? voicedFrames + 1 : 0
            if voicedFrames >= 3 {
                inSpeech = true
                utterance = preRoll
                utteranceStart = start + frameDuration - Double(preRoll.count) / AudioConstants.sampleRate
                preRoll.removeAll()
                silentFrames = 0
            }
            return nil
        }

        utterance += frame
        silentFrames = voiced ? 0 : silentFrames + 1
        let duration = Double(utterance.count) / AudioConstants.sampleRate
        let silence = Double(silentFrames) * frameDuration
        guard silence >= config.endSilence || duration >= config.maxDuration else { return nil }

        let result = duration - silence >= config.minSpeech ? Utterance(samples: utterance, startOffset: utteranceStart) : nil
        let continuesSpeaking = silence < config.endSilence
        reset()
        if continuesSpeaking {
            // Forced cut mid-speech: keep listening without requiring a new onset.
            inSpeech = true
            utteranceStart = start + frameDuration
        }
        return result
    }

    private mutating func reset() {
        utterance.removeAll()
        preRoll.removeAll()
        voicedFrames = 0
        silentFrames = 0
        inSpeech = false
    }
}

/// Serializes ASR work across sessions. Lower `priority` values run first; ties run in arrival order.
/// Sessions with the copilot on get priority 0 so suggestions stay fast; final passes use a high value.
public actor ASRScheduler {
    private struct Waiter {
        let priority: Int
        let sequence: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var busy = false
    private var waiters: [Waiter] = []
    private var sequence = 0

    public init() {}

    public var queueDepth: Int { waiters.count }

    public func run<T: Sendable>(priority: Int, _ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire(priority: priority)
        defer { release() }
        return try await operation()
    }

    private func acquire(priority: Int) async {
        guard busy else {
            busy = true
            return
        }
        sequence += 1
        let seq = sequence
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(priority: priority, sequence: seq, continuation: continuation))
        }
    }

    private func release() {
        guard let next = waiters.indices.min(by: { (waiters[$0].priority, waiters[$0].sequence) < (waiters[$1].priority, waiters[$1].sequence) }) else {
            busy = false
            return
        }
        waiters.remove(at: next).continuation.resume()
    }
}

/// Events produced by a live transcriber.
public enum LiveTranscriptEvent: Sendable {
    /// A provisional segment (replaced by the final pass after the meeting).
    case segment(TranscriptSegment)
    /// Speech on this track ended (end of turn) at the given offset; the copilot uses it as a trigger.
    case turnEnded(track: Track, offset: TimeInterval)
}

/// Turns a live chunk stream into provisional transcript segments.
public final class LiveTranscriber: Sendable {
    public let track: Track
    private let engine: any ASREngine
    private let scheduler: ASRScheduler
    private let language: String?
    private let speakerID: String
    private let priority: @Sendable () -> Int

    public init(track: Track, speakerID: String, engine: any ASREngine, scheduler: ASRScheduler, language: String?, priority: @escaping @Sendable () -> Int) {
        self.track = track
        self.speakerID = speakerID
        self.engine = engine
        self.scheduler = scheduler
        self.language = language
        self.priority = priority
    }

    /// Consumes `chunks` until they finish (or the returned stream is cancelled).
    public func events(from chunks: AsyncStream<PCMChunk>) -> AsyncStream<LiveTranscriptEvent> {
        let (utterances, utteranceContinuation) = AsyncStream.makeStream(of: Utterance.self)
        let (events, eventContinuation) = AsyncStream.makeStream(of: LiveTranscriptEvent.self)
        let track = self.track

        // Stage 1: segmentation keeps up with real time and never waits on the model.
        let segmenting = Task {
            var segmenter = UtteranceSegmenter()
            for await chunk in chunks {
                for utterance in segmenter.append(chunk) {
                    eventContinuation.yield(.turnEnded(track: track, offset: utterance.startOffset + utterance.duration))
                    utteranceContinuation.yield(utterance)
                }
            }
            if let last = segmenter.finish() { utteranceContinuation.yield(last) }
            utteranceContinuation.finish()
        }

        // Stage 2: transcription, serialized through the shared scheduler.
        let transcribing = Task { [engine, scheduler, language, speakerID, priority] in
            for await utterance in utterances {
                guard !Task.isCancelled else { break }
                do {
                    let result = try await scheduler.run(priority: priority()) {
                        try await engine.transcribe(samples: utterance.samples, language: language)
                    }
                    let shifted = result.shifted(by: utterance.startOffset)
                    let text = shifted.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let segment = TranscriptSegment(
                        speakerID: speakerID,
                        track: track,
                        start: utterance.startOffset,
                        end: utterance.startOffset + utterance.duration,
                        text: text,
                        words: shifted.words,
                        confidence: shifted.confidence,
                        isLive: true
                    )
                    eventContinuation.yield(.segment(segment))
                } catch {
                    continue
                }
            }
            eventContinuation.finish()
        }

        eventContinuation.onTermination = { _ in
            segmenting.cancel()
            transcribing.cancel()
        }
        return events
    }
}
