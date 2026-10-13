@preconcurrency import AVFoundation
import Foundation
import os

/// Session-relative time that excludes paused spans, shared by every capture component of one session
/// so audio, screenshots and notes line up.
public final class SessionClock: @unchecked Sendable {
    private struct State {
        var start: Date
        var pausedAt: Date?
        var pausedTotal: TimeInterval = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(start: Date = Date()) {
        state = OSAllocatedUnfairLock(initialState: State(start: start))
    }

    public var startDate: Date { state.withLock { $0.start } }
    public var isPaused: Bool { state.withLock { $0.pausedAt != nil } }

    /// Seconds of recorded (non-paused) time at `date`.
    public func offset(at date: Date = Date()) -> TimeInterval {
        state.withLock { s in
            let reference = s.pausedAt ?? date
            return max(0, reference.timeIntervalSince(s.start) - s.pausedTotal)
        }
    }

    public func pause(at date: Date = Date()) {
        state.withLock { s in
            if s.pausedAt == nil { s.pausedAt = date }
        }
    }

    public func resume(at date: Date = Date()) {
        state.withLock { s in
            guard let pausedAt = s.pausedAt else { return }
            s.pausedTotal += date.timeIntervalSince(pausedAt)
            s.pausedAt = nil
        }
    }
}

/// A block of 16 kHz mono samples positioned on the session timeline.
public struct AudioChunk: Sendable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]
    /// Session offset (seconds) of the first sample.
    public var startOffset: TimeInterval

    public init(samples: [Float], startOffset: TimeInterval) {
        self.samples = samples
        self.startOffset = startOffset
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var endOffset: TimeInterval { startOffset + duration }

    /// Root-mean-square level, used for meters and cheap voice-activity checks.
    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Streaming converter from any PCM format to 16 kHz mono Float32.
public final class MonoResampler: @unchecked Sendable {
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init() {}

    /// Converts synchronously; the input buffer may be a no-copy buffer that's only valid during this call.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            // Downmix all channels instead of taking only the first one.
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return [] }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }

        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Writes one track (16 kHz mono, Int16 CAF) and fans the same samples out to live subscribers (ASR, meters).
///
/// Chunks carry their session offset; gaps (e.g. browser capture hiccups, pauses) are filled with silence so the
/// file stays aligned with the session timeline and the other track.
public final class AudioTrackWriter: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: Int64 = 0
    private var subscribers: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]
    private var lastLevel: Float = 0
    private let logger = Logger(subsystem: "app.palmeet", category: "TrackWriter")

    /// Gaps shorter than this are ignored (normal scheduling jitter).
    private let gapTolerance: TimeInterval

    public init(url: URL, gapTolerance: TimeInterval = 0.25) throws {
        self.url = url
        self.gapTolerance = gapTolerance
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Seconds of audio written so far.
    public var writtenDuration: TimeInterval {
        lock.withLock { Double(framesWritten) / AudioChunk.sampleRate }
    }

    /// Most recent RMS level (0...1), for UI meters.
    public var level: Float { lock.withLock { lastLevel } }

    public func append(_ samples: [Float], at offset: TimeInterval) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }

        var startOffset = Double(framesWritten) / AudioChunk.sampleRate
        let gap = offset - startOffset
        // The first chunk is always placed at its real offset (capture start-up lag), so the "Me" and "Them"
        // tracks stay aligned; later gaps are padded only beyond the jitter tolerance.
        let threshold = framesWritten == 0 ? 0.02 : gapTolerance
        if gap > threshold {
            let silence = [Float](repeating: 0, count: Int(gap * AudioChunk.sampleRate))
            write(silence, to: file)
            publish(AudioChunk(samples: silence, startOffset: startOffset))
            startOffset = Double(framesWritten) / AudioChunk.sampleRate
        }

        // Writer ahead of the clock (timestamps ran slow): drop the overlap so the track doesn't drift late.
        var samples = samples
        if gap < -gapTolerance, framesWritten > 0 {
            let overlap = min(samples.count, Int(-gap * AudioChunk.sampleRate))
            samples.removeFirst(overlap)
            guard !samples.isEmpty else { return }
        }

        write(samples, to: file)
        let chunk = AudioChunk(samples: samples, startOffset: startOffset)
        lastLevel = chunk.rms
        publish(chunk)
    }

    /// Live 16 kHz chunks from now on. Each call creates an independent subscriber.
    public func chunks() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(400))
        let id = UUID()
        lock.withLock { subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Closes the file and finishes all subscribers. Safe to call more than once.
    public func finish() {
        let continuations = lock.withLock { () -> [AsyncStream<AudioChunk>.Continuation] in
            file = nil  // AVAudioFile finalizes the header on deinit.
            let all = Array(subscribers.values)
            subscribers.removeAll()
            return all
        }
        continuations.forEach { $0.finish() }
    }

    private func write(_ samples: [Float], to file: AVAudioFile) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: MonoResampler.targetFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(samples.count)
        } catch {
            logger.error("Write failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish(_ chunk: AudioChunk) {
        for continuation in subscribers.values {
            continuation.yield(chunk)
        }
    }
}
