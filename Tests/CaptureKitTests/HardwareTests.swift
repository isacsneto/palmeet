@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit

/// Real Core Audio / ScreenCaptureKit / microphone checks. They need macOS privacy permissions for the process
/// running the tests (System Audio Recording, Microphone, Screen Recording), so they only run with
/// PALMEET_HARDWARE=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PALMEET_HARDWARE"] == "1"))
struct HardwareTests {
    /// Writes a tone WAV and plays it with afplay; returns the process.
    func play(frequency: Double, seconds: Double) throws -> Process {
        let url = tempURL("tone-\(Int(frequency)).wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let tone = sine(frequency: frequency, seconds: seconds, rate: 48_000, amplitude: 0.3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.count))!
        buffer.frameLength = AVAudioFrameCount(tone.count)
        tone.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: tone.count) }
        try file.write(from: buffer)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = ["-v", "0.05", url.path]  // quiet for whoever is at the desk
        try process.run()
        return process
    }

    /// Taps ONE of two simultaneously playing processes and checks that only its tone is captured.
    @Test(.timeLimit(.minutes(1))) func processTapCapturesOnlyTheTargetProcess() async throws {
        let target = try play(frequency: 440, seconds: 6)
        let other = try play(frequency: 1_000, seconds: 6)
        defer { target.terminate(); other.terminate() }
        try await Task.sleep(for: .milliseconds(700))  // let both register with the HAL

        let tap = ProcessTapCapture(family: AppAudioFamily(bundlePrefixes: [], pids: [target.processIdentifier]), name: "afplay-test")
        let resampler = MonoResampler()
        let collected = Collected()
        try tap.start { buffer, _ in collected.append(resampler.convert(buffer)) }
        try await Task.sleep(for: .seconds(3))
        tap.stop()

        let samples = collected.samples
        #expect(samples.count > 16_000 * 2)
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
        #expect(rms > 0.001, "Tap delivered silence: is System Audio Recording permission granted to the test runner?")
        let voiced = samples.filter { abs($0) > 0.0005 }
        if voiced.count > 8_000 {
            let frequency = zeroCrossingFrequency(Array(samples.drop { abs($0) < 0.0005 }.prefix(16_000)), rate: 16_000)
            #expect(abs(frequency - 440) < 40, "Captured \(frequency) Hz; expected only the 440 Hz process, not the 1 kHz one")
        }
    }

    @Test(.timeLimit(.minutes(1))) func microphoneDeliversChunks() async throws {
        guard MicrophoneCapture.authorizationStatus() == .authorized else {
            Issue.record("Microphone permission not granted to the test runner")
            return
        }
        let mic = MicrophoneCapture()
        let stream = try mic.subscribe()
        var received = 0
        for await chunk in stream {
            received += chunk.samples.count
            if received > 16_000 { break }
        }
        #expect(received > 16_000)
    }

    @Test(.timeLimit(.minutes(1))) func windowListingAndSampling() async throws {
        let windows = try await ShareableSources.windows()
        #expect(!windows.isEmpty)
        guard let window = windows.first(where: \.isOnScreen) else { return }
        let thumbnail = try await ShareableSources.thumbnail(windowID: window.id)
        #expect(thumbnail != nil)
        let sampler = WindowFrameSampler(windowID: window.id)
        try await sampler.start()
        let image = try await sampler.captureNow()
        #expect(image.width > 10)
        await sampler.stop()
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    func append(_ samples: [Float]) { lock.withLock { storage += samples } }
    var samples: [Float] { lock.withLock { storage } }
}
