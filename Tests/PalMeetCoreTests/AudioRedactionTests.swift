import CaptureKit
import Foundation
import SessionKit
import Testing
@testable import PalMeetCore

@Suite struct AudioRedactionTests {
    @Test func silencesOutsideRoutedSpans() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "redact-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioTrackWriter(url: url)
        writer.append([Float](repeating: 0.5, count: 48_000), at: 0)  // 3 s of signal
        writer.finish()

        try AudioRedaction.silence(url, keeping: [MicRouteSpan(start: 1, end: 2)])
        let samples = try readMono(url)
        #expect(samples.count == 48_000)
        #expect(samples[0..<15_900].allSatisfy { $0 == 0 })
        #expect(samples[16_100..<31_900].allSatisfy { abs($0 - 0.5) < 0.001 })
        #expect(samples[32_100...].allSatisfy { $0 == 0 })
        #expect(AudioRedaction.duration(of: url) == 3)
    }

    @Test func openSpanKeepsEverythingAfterStart() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "redact-open-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioTrackWriter(url: url)
        writer.append([Float](repeating: 0.5, count: 32_000), at: 0)
        writer.finish()
        try AudioRedaction.silence(url, keeping: [MicRouteSpan(start: 1)])
        let samples = try readMono(url)
        #expect(samples[0..<15_900].allSatisfy { $0 == 0 })
        #expect(samples[16_100...].allSatisfy { $0 != 0 })
    }
}
