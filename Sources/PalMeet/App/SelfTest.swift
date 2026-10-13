@preconcurrency import AVFoundation
import AppKit
import CaptureKit
import Foundation
import SessionKit
import TranscriptKit
import VisionContext

/// Hardware/permission checks that can't run in unit tests: real process taps (and their isolation), the
/// microphone, window capture + OCR, and screen-share invisibility. Runs inside PalMeet.app so macOS grants the
/// permissions to PalMeet itself.
///
///     open build/PalMeet.app --args --self-test /tmp/palmeet-self-test.json
@MainActor
enum SelfTest {
    struct Check: Codable {
        var name: String
        var passed: Bool
        var detail: String
    }

    static var reportPath: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--self-test") else { return nil }
        return index + 1 < args.count ? args[index + 1] : NSTemporaryDirectory() + "palmeet-self-test.json"
    }

    static func run(reportPath: String) async {
        var checks: [Check] = []
        func record(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(name: name, passed: passed, detail: detail))
            try? write(checks, to: reportPath, finished: false)
        }

        for kind in PermissionKind.allCases {
            record("permission.\(kind.rawValue)", true, "\(Permissions.state(of: kind))")
        }

        let work = FileManager.default.temporaryDirectory.appending(path: "palmeet-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Process tap isolation: two processes play different tones; tapping one must hear only its tone.
        do {
            let low = try playTone(440, in: work), high = try playTone(1_000, in: work)
            defer { low.terminate(); high.terminate() }
            try await Task.sleep(for: .milliseconds(800))
            let samples = try await capture(pid: low.processIdentifier, seconds: 3)
            let rms = rootMeanSquare(samples)
            let frequency = dominantFrequency(samples)
            record("tap.receivesAudio", rms > 0.001, String(format: "rms %.4f over %d samples", rms, samples.count))
            record("tap.isolatesProcess", abs(frequency - 440) < 40, String(format: "heard %.0f Hz (target 440 Hz, other process 1000 Hz)", frequency))
        } catch {
            record("tap.receivesAudio", false, "\(error.localizedDescription) (System Audio Recording permission?)")
        }

        // 2. Real speech through a tap into the on-device model.
        do {
            let speech = work.appending(path: "speech.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", "Samantha", "-o", speech.path, "The quarterly roadmap review starts on Monday morning."]
            try say.run()
            say.waitUntilExit()
            let player = try launch("/usr/bin/afplay", ["-v", "0.15", speech.path])
            defer { player.terminate() }
            try await Task.sleep(for: .milliseconds(300))
            let samples = try await capture(pid: player.processIdentifier, seconds: 5)
            let engine = ParakeetEngine(model: .ultra)
            let text = try await engine.transcribe(samples: samples, language: "en").text.lowercased()
            record("tap.speechToText", text.contains("roadmap") && text.contains("monday"), "transcribed: \(text)")
        } catch {
            record("tap.speechToText", false, error.localizedDescription)
        }

        // 3. Microphone delivers audio (content not checked).
        if MicrophoneCapture.authorizationStatus() == .notDetermined {
            _ = await MicrophoneCapture.requestAccess()
        }
        do {
            let mic = MicrophoneCapture()
            let stream = try mic.subscribe()
            var count = 0
            let deadline = Date().addingTimeInterval(4)
            for await chunk in stream {
                count += chunk.samples.count
                if count > 32_000 || Date() > deadline { break }
            }
            record("microphone.delivers", count > 16_000, "\(count) samples in ≤4 s; echo cancellation \(mic.isVoiceProcessingActive ? "on" : "unavailable (plain mic)")")
        } catch {
            record("microphone.delivers", false, "\(error.localizedDescription) (Microphone permission?)")
        }

        // 3b. Which voice-processing setup works on this Mac (diagnostic).
        for variant in VoiceProcessingProbe.Variant.allCases {
            record("diagnostic.voiceProcessing.\(variant.rawValue)", true, VoiceProcessingProbe.run(variant))
        }

        // 4. Window capture + OCR on a known window (shareable on purpose, unlike PalMeet's real windows).
        if !CGPreflightScreenCaptureAccess() {
            // Registers PalMeet in System Settings → Screen & System Audio Recording.
            _ = CGRequestScreenCaptureAccess()
        }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "PalMeet Self Test"
        window.sharingType = .readOnly
        let label = NSTextField(labelWithString: "PALMEET SELF TEST 4821")
        label.font = .systemFont(ofSize: 44, weight: .bold)
        label.frame = NSRect(x: 30, y: 70, width: 600, height: 60)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(600))
        do {
            let sampler = WindowFrameSampler(windowID: CGWindowID(window.windowNumber))
            try await sampler.start()
            let image = try await sampler.captureNow()
            await sampler.stop()
            let text = try TextRecognizer.recognize(image).text
            record("screen.windowCaptureAndOCR", text.contains("PALMEET SELF TEST 4821"), "OCR: \(text.prefix(80))")
        } catch {
            record("screen.windowCaptureAndOCR", false, "\(error.localizedDescription) (Screen Recording permission?)")
        }

        // 5. PalMeet windows hidden from screen capture.
        let outcome = await InvisibilityCheck.run(sharingType: .none)
        record("privacy.hiddenFromCapture", outcome == .hidden, outcome.message)

        try? write(checks, to: reportPath, finished: true)
    }

    // MARK: Helpers

    private static func write(_ checks: [Check], to path: String, finished: Bool) throws {
        struct Report: Codable { var finished: Bool; var passed: Int; var failed: Int; var checks: [Check] }
        let tests = checks.filter { !$0.name.hasPrefix("permission.") }
        let report = Report(finished: finished, passed: tests.filter(\.passed).count, failed: tests.filter { !$0.passed }.count, checks: checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func launch(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    private static func playTone(_ frequency: Double, in dir: URL) throws -> Process {
        let url = dir.appending(path: "tone-\(Int(frequency)).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let count = 48_000 * 8
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { buffer.floatChannelData![0][i] = 0.3 * Float(sin(2 * .pi * frequency * Double(i) / 48_000)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return try launch("/usr/bin/afplay", ["-v", "0.05", url.path])
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        let resampler = MonoResampler()
        func add(_ buffer: AVAudioPCMBuffer) {
            let converted = resampler.convert(buffer)
            lock.withLock { samples += converted }
        }
        var all: [Float] { lock.withLock { samples } }
    }

    private static func capture(pid: pid_t, seconds: Double) async throws -> [Float] {
        let tap = ProcessTapCapture(family: AppAudioFamily(bundlePrefixes: [], pids: [pid]), name: "self-test")
        let collector = Collector()
        try tap.start { buffer, _ in collector.add(buffer) }
        try await Task.sleep(for: .seconds(seconds))
        tap.stop()
        return collector.all
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private static func dominantFrequency(_ samples: [Float]) -> Double {
        let voiced = Array(samples.drop { abs($0) < 0.0005 }.prefix(16_000))
        guard voiced.count > 1_000 else { return 0 }
        var crossings = 0
        for i in 1..<voiced.count where (voiced[i - 1] < 0) != (voiced[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(voiced.count) / 16_000)
    }
}

/// Tries voice-processing (echo cancellation) engine setups and reports the outcome of each.
enum VoiceProcessingProbe {
    enum Variant: String, CaseIterable {
        case tapOnly          // enable VP on input, tap input, silent mixer (PalMeet's default)
        case connectedToMixer // also connect input → main mixer
        case outputFirst      // enable VP on the output node first, then input
    }

    static func run(_ variant: Variant) -> String {
        let engine = AVAudioEngine()
        do {
            switch variant {
            case .tapOnly:
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.mainMixerNode.outputVolume = 0
            case .connectedToMixer:
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
                engine.mainMixerNode.outputVolume = 0
            case .outputFirst:
                try engine.outputNode.setVoiceProcessingEnabled(true)
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.mainMixerNode.outputVolume = 0
            }
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return "no input format" }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
            engine.prepare()
            try engine.start()
            defer { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
            return "started OK (\(format.channelCount) ch @ \(Int(format.sampleRate)) Hz, VP \(engine.inputNode.isVoiceProcessingEnabled))"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }
}
