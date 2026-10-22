@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureKit
import ObjCExceptions

func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "palmeet-capture-\(UUID().uuidString)").appending(path: name)
}

func sine(frequency: Double, seconds: Double, rate: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

func readSamples(_ url: URL) throws -> (samples: [Float], rate: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

/// Dominant frequency estimate from zero crossings (good enough for pure tones).
func zeroCrossingFrequency(_ samples: [Float], rate: Double) -> Double {
    var crossings = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
    return Double(crossings) / 2 / (Double(samples.count) / rate)
}

@Suite struct SessionClockTests {
    @Test func excludesPausedTime() {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = SessionClock(start: start)
        #expect(clock.offset(at: start.addingTimeInterval(10)) == 10)
        clock.pause(at: start.addingTimeInterval(10))
        #expect(clock.isPaused)
        // While paused, time stands still.
        #expect(clock.offset(at: start.addingTimeInterval(25)) == 10)
        clock.resume(at: start.addingTimeInterval(30))
        #expect(clock.offset(at: start.addingTimeInterval(35)) == 15)
        // Double pause/resume is harmless.
        clock.resume(at: start.addingTimeInterval(36))
        clock.pause(at: start.addingTimeInterval(40))
        clock.pause(at: start.addingTimeInterval(45))
        clock.resume(at: start.addingTimeInterval(50))
        #expect(clock.offset(at: start.addingTimeInterval(50)) == 20)
    }

    @Test func neverNegative() {
        let start = Date()
        #expect(SessionClock(start: start).offset(at: start.addingTimeInterval(-5)) == 0)
    }
}

@Suite struct MonoResamplerTests {
    @Test func downmixesStereo48kToMono16kPreservingPitch() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let tone = sine(frequency: 440, seconds: 1, rate: 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tone.count))!
        buffer.frameLength = AVAudioFrameCount(tone.count)
        for channel in 0..<2 { tone.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: tone.count) } }

        let resampler = MonoResampler()
        var output: [Float] = []
        // Streamed in 10 ms chunks like a real tap.
        let chunk = 480
        for start in stride(from: 0, to: tone.count, by: chunk) {
            let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))!
            part.frameLength = AVAudioFrameCount(min(chunk, tone.count - start))
            for channel in 0..<2 {
                part.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + start, count: Int(part.frameLength))
            }
            output += resampler.convert(part)
        }
        #expect(abs(output.count - 16_000) < 200)
        let frequency = zeroCrossingFrequency(Array(output.dropFirst(500)), rate: 16_000)
        #expect(abs(frequency - 440) < 10)
        let rms = (output.dropFirst(500).reduce(0) { $0 + $1 * $1 } / Float(output.count - 500)).squareRoot()
        #expect(rms > 0.25 && rms < 0.45)  // 0.5 amplitude sine ≈ 0.354 RMS
    }

    @Test func emptyBufferYieldsNothing() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        #expect(MonoResampler().convert(buffer).isEmpty)
    }
}

@Suite struct AudioTrackWriterTests {
    @Test func writesContiguousAudioAndReportsDuration() throws {
        let url = tempURL("track.caf")
        let writer = try AudioTrackWriter(url: url, gapTolerance: 0.25)
        let second = sine(frequency: 300, seconds: 1, rate: 16_000)
        writer.append(second, at: 0)
        writer.append(second, at: 1.05)  // jitter below tolerance: no padding
        #expect(abs(writer.writtenDuration - 2) < 0.001)
        #expect(writer.level > 0.2)
        writer.finish()
        let (samples, rate) = try readSamples(url)
        #expect(rate == 16_000)
        #expect(samples.count == 32_000)
    }

    @Test func fillsGapsWithSilenceToStayAligned() throws {
        let url = tempURL("gap.caf")
        let writer = try AudioTrackWriter(url: url, gapTolerance: 0.25)
        writer.append(sine(frequency: 300, seconds: 1, rate: 16_000), at: 0)
        writer.append(sine(frequency: 300, seconds: 1, rate: 16_000), at: 3)  // 2 s dropout
        writer.finish()
        let (samples, _) = try readSamples(url)
        #expect(abs(samples.count - 64_000) <= 1)
        let gap = samples[17_000..<47_000]
        #expect(gap.allSatisfy { $0 == 0 })
        #expect(samples[50_000..<51_000].contains { abs($0) > 0.1 })
    }

    @Test func publishesChunksToEverySubscriberWithOffsets() async throws {
        let writer = try AudioTrackWriter(url: tempURL("subs.caf"), gapTolerance: 0.25)
        let a = writer.chunks(), b = writer.chunks()
        writer.append([Float](repeating: 0.1, count: 1_600), at: 0)
        writer.append([Float](repeating: 0.1, count: 1_600), at: 1)  // gap → silence chunk then audio
        writer.finish()
        var offsetsA: [TimeInterval] = []
        for await chunk in a { offsetsA.append(chunk.startOffset) }
        var countB = 0
        for await _ in b { countB += 1 }
        #expect(offsetsA.count == 3)
        #expect(offsetsA[0] == 0)
        #expect(abs(offsetsA[1] - 0.1) < 0.001)   // silence starts where audio ended
        #expect(abs(offsetsA[2] - 1.0) < 0.001)   // next audio lands at its offset
        #expect(countB == 3)
    }

    @Test func appendAfterFinishIsIgnored() throws {
        let url = tempURL("finished.caf")
        let writer = try AudioTrackWriter(url: url)
        writer.append([0.1, 0.2], at: 0)
        writer.finish()
        writer.append([0.3], at: 0.1)
        writer.finish()
        #expect(try readSamples(url).samples.count == 2)
    }

    @Test func audioChunkMath() {
        let chunk = AudioChunk(samples: [Float](repeating: 0.5, count: 8_000), startOffset: 2)
        #expect(chunk.duration == 0.5 && chunk.endOffset == 2.5)
        #expect(abs(chunk.rms - 0.5) < 0.0001)
        #expect(AudioChunk(samples: [], startOffset: 0).rms == 0)
    }
}

@Suite struct AppAudioFamilyTests {
    func process(_ bundle: String?, pid: pid_t = 1) -> AudioProcessInfo {
        AudioProcessInfo(objectID: 1, pid: pid, bundleID: bundle, isRunningInput: false, isRunningOutput: true)
    }

    @Test func matchesHelpersButNotLookalikes() {
        let chrome = AppAudioFamily(bundlePrefixes: ["com.google.Chrome"])
        #expect(chrome.contains(process("com.google.Chrome")))
        #expect(chrome.contains(process("com.google.Chrome.helper")))
        #expect(chrome.contains(process("com.google.chrome.helper.renderer")))
        #expect(!chrome.contains(process("com.google.ChromeRemoteDesktop")))
        #expect(!chrome.contains(process(nil)))
        #expect(AppAudioFamily(bundlePrefixes: [], pids: [42]).contains(process(nil, pid: 42)))
    }

    @Test func overlapDetection() {
        let chrome = AppAudioFamily(bundlePrefixes: ["com.google.Chrome"])
        let chromeBeta = AppAudioFamily(bundlePrefixes: ["com.google.Chrome.beta"])
        let zoom = AppAudioFamily(bundlePrefixes: ["us.zoom"], pids: [7])
        #expect(chrome.overlaps(chromeBeta))  // Chrome's prefix also matches Beta's processes
        #expect(!chrome.overlaps(zoom))
        #expect(AppAudioFamily(bundlePrefixes: [], pids: [7]).overlaps(zoom))
    }

    @Test func meetingAppFamilies() {
        #expect(MeetingApp.lookup(bundleID: "US.ZOOM.XOS")?.name == "Zoom")
        #expect(MeetingApp.audioFamily(bundleID: "us.zoom.xos", pid: 5).bundlePrefixes == ["us.zoom"])
        #expect(MeetingApp.audioFamily(bundleID: "com.example.app", pid: 5) == AppAudioFamily(bundlePrefixes: ["com.example.app"], pids: [5]))
        #expect(MeetingApp.lookup(bundleID: "com.apple.Safari")?.isBrowser == true)
    }
}

@Suite struct SystemQueriesTests {
    @Test func audioProcessListingDoesNotCrash() {
        let processes = AudioProcessInspector.processes()
        #expect(processes.allSatisfy { $0.pid >= 0 })
    }

    @Test func permissionStatesAreQueryable() {
        for kind in PermissionKind.allCases {
            _ = Permissions.state(of: kind)
            #expect(!kind.title.isEmpty && !kind.purpose.isEmpty)
        }
        #expect(Permissions.state(of: .systemAudio) != .unknown, "System Audio permission must be queryable via TCC")
    }

    @Test func coreAudioErrorShowsFourCC() {
        let error = CoreAudioError("Create tap", OSStatus(bitPattern: 0x7768_6F3F))  // 'who?'
        #expect(error.localizedDescription.contains("'who?'"))
    }
}

@Suite struct TrackAlignmentTests {
    @Test func firstChunkIsPlacedAtItsRealOffset() throws {
        let url = tempURL("late-start.caf")
        let writer = try AudioTrackWriter(url: url, gapTolerance: 1.5)
        writer.append([Float](repeating: 0.5, count: 1_600), at: 0.4)  // capture started 400 ms late
        writer.append([Float](repeating: 0.5, count: 1_600), at: 0.5)
        writer.finish()
        let (samples, _) = try readSamples(url)
        #expect(samples.count == 6_400 + 3_200)
        #expect(samples[0..<6_400].allSatisfy { $0 == 0 })
        #expect(samples[6_400] != 0)
    }
}

@Suite struct TrackDriftTests {
    @Test func dropsOverlapWhenAheadOfTheClock() throws {
        let url = tempURL("ahead.caf")
        let writer = try AudioTrackWriter(url: url, gapTolerance: 0.25)
        writer.append([Float](repeating: 0.5, count: 16_000), at: 0)       // writer now at 1.0 s
        writer.append([Float](repeating: 0.5, count: 16_000), at: 0.5)     // claims 0.5 s: 0.5 s overlap
        writer.finish()
        #expect(try readSamples(url).samples.count == 16_000 + 8_000)
    }

    @Test func smallBackwardJitterIsKept() throws {
        let url = tempURL("jitter.caf")
        let writer = try AudioTrackWriter(url: url, gapTolerance: 0.25)
        writer.append([Float](repeating: 0.5, count: 16_000), at: 0)
        writer.append([Float](repeating: 0.5, count: 1_600), at: 0.9)
        writer.finish()
        #expect(try readSamples(url).samples.count == 17_600)
    }
}

@Suite struct HostTimeTests {
    @Test func convertsBufferAgeToWallClock() {
        let now = Date(timeIntervalSince1970: 1_000)
        let nowHost = mach_absolute_time()
        let halfSecond = AVAudioTime.hostTime(forSeconds: 0.5)
        let date = HostTime.date(for: nowHost - halfSecond, now: now, nowHostTime: nowHost)
        #expect(abs(date.timeIntervalSince(now) + 0.5) < 0.001)
        #expect(HostTime.date(for: 0, now: now) == now)
    }
}

@Suite struct ObjCExceptionTests {
    @Test func objectiveCExceptionsBecomeErrors() {
        var error: NSError?
        let ok = PMCatchObjCException({
            NSException(name: .invalidArgumentException, reason: "format mismatch", userInfo: nil).raise()
        }, &error)
        #expect(!ok)
        #expect(error?.localizedDescription == "format mismatch")
        #expect(PMCatchObjCException({}, nil))
    }
}
