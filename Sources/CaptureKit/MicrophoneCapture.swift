@preconcurrency import AVFoundation
import Foundation
import os

/// A shared microphone that any number of sessions can subscribe to.
public protocol MicrophoneSource: AnyObject, Sendable {
    /// Starts capture if needed and returns a new subscriber stream of 16 kHz mono chunks.
    func subscribe() throws -> AsyncStream<MicrophoneCapture.Chunk>
}

public enum MicrophoneError: Error, LocalizedError {
    case noInputDevice

    public var errorDescription: String? {
        "No microphone input is available. Connect a microphone or pick an input device in System Settings → Sound."
    }
}

/// One microphone stream for the whole app, fanned out to every active session.
///
/// Voice processing (echo cancellation) is enabled so meeting audio played through speakers doesn't leak into
/// the "Me" track. Other-audio ducking is minimized so meetings keep their normal volume. Engine start/stop and
/// subscriber bookkeeping are serialized on one queue, so a session subscribing while another unsubscribes can't
/// lose its stream.
public final class MicrophoneCapture: MicrophoneSource, @unchecked Sendable {
    public struct Chunk: Sendable {
        public var samples: [Float]
        /// Wall-clock time of the first sample.
        public var time: Date

        public init(samples: [Float], time: Date) {
            self.samples = samples
            self.time = time
        }
    }

    private var engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private let control = DispatchQueue(label: "app.palmeet.mic.control")
    private let subscribersLock = NSLock()
    // Guarded by `subscribersLock` (read on the audio thread).
    private var subscribers: [UUID: AsyncStream<Chunk>.Continuation] = [:]
    // Only touched on `control`.
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var restartAttempts = 0
    private let logger = Logger(subsystem: "app.palmeet", category: "Microphone")

    public var voiceProcessingEnabled = true
    // Only touched on `control`.
    private var voiceProcessingActive = false

    public init() {}

    public var isRunning: Bool { control.sync { running } }

    /// Whether echo cancellation is actually running (it falls back to the plain mic when the audio
    /// hardware/routing doesn't support voice processing).
    public var isVoiceProcessingActive: Bool { control.sync { voiceProcessingActive } }

    public func subscribe() throws -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: Chunk.self, bufferingPolicy: .bufferingNewest(400))
        let id = UUID()
        try control.sync {
            subscribersLock.withLock { subscribers[id] = continuation }
            do {
                try startIfNeededLocked()
            } catch {
                _ = subscribersLock.withLock { subscribers.removeValue(forKey: id) }
                continuation.finish()
                throw error
            }
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        return stream
    }

    public static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Engine (control queue)

    private func removeSubscriber(_ id: UUID) {
        control.async { [self] in
            let empty = subscribersLock.withLock { () -> Bool in
                subscribers.removeValue(forKey: id)
                return subscribers.isEmpty
            }
            // Re-checked on the control queue, so a subscriber added meanwhile keeps the engine running.
            if empty && running { stopEngineLocked() }
        }
    }

    private func startIfNeededLocked() throws {
        guard !running else { return }
        if voiceProcessingEnabled {
            do {
                try startEngineLocked(voiceProcessing: true)
                return
            } catch {
                // Voice processing fails to initialize on some routes (e.g. kAudioUnitErr_FailedInitialization
                // -10875 with certain devices). Recording without echo cancellation beats not recording.
                logger.warning("Voice processing start failed (\(error.localizedDescription, privacy: .public)); using the plain microphone")
                resetEngineLocked()
            }
        }
        try startEngineLocked(voiceProcessing: false)
    }

    private func startEngineLocked(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // The output must be part of the graph for voice processing to run; keep it silent.
            engine.mainMixerNode.outputVolume = 0
        }

        let format = input.outputFormat(forBus: 0)
        // installTap raises an Objective-C exception (uncatchable) on a 0 Hz / 0-channel format: no input device.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInputDevice }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.handle(buffer, hostTime: when.isHostTimeValid ? when.hostTime : 0)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
        voiceProcessingActive = voiceProcessing
        restartAttempts = 0

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                self.control.async {
                    // Only our current engine (it's replaced when falling back from voice processing).
                    guard sender == ObjectIdentifier(self.engine) else { return }
                    self.restartAfterDeviceChangeLocked()
                }
            }
        }
    }

    /// A fresh engine: voice processing can't be reliably turned off on an engine whose start failed.
    private func resetEngineLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        running = false
        voiceProcessingActive = false
    }

    private func handle(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let time = hostTime > 0 ? HostTime.date(for: hostTime) : Date().addingTimeInterval(-duration)
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        let chunk = Chunk(samples: samples, time: time)
        let targets = subscribersLock.withLock { Array(subscribers.values) }
        targets.forEach { $0.yield(chunk) }
    }

    /// AirPods connecting, default input changing, etc. reconfigure the engine and stop it. Retries with backoff
    /// (the new device may not be ready yet) while anyone is subscribed.
    private func restartAfterDeviceChangeLocked() {
        let hasSubscribers = subscribersLock.withLock { !subscribers.isEmpty }
        guard hasSubscribers else { return }
        logger.info("Audio configuration changed; restarting microphone")
        teardownEngineLocked()
        do {
            try startIfNeededLocked()
        } catch {
            restartAttempts += 1
            logger.error("Microphone restart \(self.restartAttempts) failed: \(error.localizedDescription, privacy: .public)")
            guard restartAttempts <= 10 else { return }
            let delay = min(5.0, 0.5 * Double(restartAttempts))
            control.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restartAfterDeviceChangeLocked() }
        }
    }

    private func teardownEngineLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func stopEngineLocked() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        teardownEngineLocked()
    }
}
