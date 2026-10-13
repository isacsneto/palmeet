@preconcurrency import AVFoundation
import BrowserBridge
import CaptureKit
import Foundation
import SessionKit

/// Where a session's "Them" audio comes from. Implementations deliver 16 kHz mono samples with the wall-clock
/// time of their first sample.
protocol RemoteAudioSource: AnyObject, Sendable {
    var isolation: AudioIsolation { get }
    /// Gap (seconds) above which the track writer pads silence. Continuous sources use a large value so that
    /// scheduling jitter never shifts the timeline.
    var gapTolerance: TimeInterval { get }
    func start(onSamples: @escaping @Sendable ([Float], Date) -> Void) async throws
    func stop() async
}

/// Core Audio process tap on an app family (Zoom, Teams, Slack, a browser without the extension…).
final class ProcessTapRemoteAudio: RemoteAudioSource, @unchecked Sendable {
    let isolation: AudioIsolation
    /// Buffers carry hardware capture times, so real dropouts can be padded precisely.
    let gapTolerance: TimeInterval = 0.2
    private let tap: ProcessTapCapture
    private let resampler = MonoResampler()

    init(family: AppAudioFamily, name: String, shared: Bool) {
        tap = ProcessTapCapture(family: family, name: name)
        isolation = shared ? .sharedAudio : .processTap
    }

    func start(onSamples: @escaping @Sendable ([Float], Date) -> Void) async throws {
        let resampler = self.resampler
        try tap.start { buffer, time in
            let samples = resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            onSamples(samples, time)
        }
    }

    func stop() async {
        tap.stop()
    }
}

/// One browser tab captured by the companion extension; isolated even when several meetings share a browser.
final class BrowserTabRemoteAudio: RemoteAudioSource, @unchecked Sendable {
    let isolation: AudioIsolation = .browserExtension
    let gapTolerance: TimeInterval = 0.5
    private let bridge: BrowserBridgeServer
    private let sessionID: UUID
    private let profileID: String
    private let windowID: Int
    private let tabID: Int
    private let alreadyCapturing: Bool
    private var task: Task<Void, Never>?

    init(bridge: BrowserBridgeServer, sessionID: UUID, profileID: String, windowID: Int, tabID: Int, alreadyCapturing: Bool = false) {
        self.bridge = bridge
        self.sessionID = sessionID
        self.profileID = profileID
        self.windowID = windowID
        self.tabID = tabID
        self.alreadyCapturing = alreadyCapturing
    }

    func start(onSamples: @escaping @Sendable ([Float], Date) -> Void) async throws {
        let chunks = bridge.audioChunks(for: sessionID)
        task = Task.detached(priority: .userInitiated) {
            let resampler = FloatResampler()
            for await chunk in chunks {
                let samples = resampler.resample(chunk.samples, from: chunk.sampleRate)
                guard !samples.isEmpty else { continue }
                onSamples(samples, chunk.captureTime)
            }
        }
        if !alreadyCapturing {
            try bridge.startCapture(sessionID: sessionID, profileID: profileID, windowID: windowID, tabID: tabID)
        }
    }

    func stop() async {
        bridge.stopCapture(sessionID: sessionID)
        task?.cancel()
        task = nil
    }
}

/// Resamples mono Float32 arrays at any rate to 16 kHz via `MonoResampler`.
final class FloatResampler: @unchecked Sendable {
    private let resampler = MonoResampler()
    private var format: AVAudioFormat?

    func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        if sampleRate == AudioChunk.sampleRate { return samples }
        if format?.sampleRate != sampleRate {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        }
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData?[0].update(from: base, count: samples.count) }
        }
        return resampler.convert(buffer)
    }
}
