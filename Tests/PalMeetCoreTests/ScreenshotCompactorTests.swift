import CoreGraphics
import Foundation
import SessionKit
import Testing
import VisionContext
@testable import PalMeetCore

@Suite struct ScreenshotCompactorTests {
    static let grid = "Ana Costa Bruno Lima Carla Dias meet.google.com Turn off microphone Leave call"
    static let slide = "Quarterly revenue grew twelve percent while churn fell to three percent across regions"

    func shot(_ offset: TimeInterval, hash: UInt64, text: String, reason: ScreenshotRecord.Reason = .interval) -> ScreenshotRecord {
        ScreenshotRecord(index: Int(offset), offset: offset, relativePath: "screenshots/\(Int(offset)).jpg", reason: reason, ocrText: text, perceptualHash: hash)
    }

    @Test func repeatsAreDroppedAndNewScreensKept() {
        let gridHash: UInt64 = 0xF0F0_F0F0_0F0F_0F0F
        let slideHash: UInt64 = 0x1234_5678_9ABC_DEF0
        let shots = [
            shot(0, hash: gridHash, text: Self.grid),
            shot(30, hash: gridHash ^ 0b1, text: Self.grid),                          // same grid 30 s later
            shot(40, hash: slideHash, text: Self.slide, reason: .screenChange),       // a slide
            shot(60, hash: gridHash ^ 0b111, text: Self.grid + " Speaking"),           // back to the grid
            shot(70, hash: slideHash ^ 0b1111, text: Self.slide + " pricing tiers"),  // same slide, more text
            shot(90, hash: gridHash, text: Self.grid, reason: .manual),               // you marked it
            shot(100, hash: gridHash ^ 0b11, text: Self.grid),                        // shown in the summary
            shot(110, hash: 0, text: ""),                                             // video only
            shot(120, hash: 0b1, text: ""),                                           // same video frame
            shot(130, hash: ~UInt64(0), text: ""),                                    // different video frame
        ]
        let kept = ScreenshotCompactor.plan(shots, protected: ["screenshots/100.jpg"]).map(\.offset)
        #expect(kept == [0, 70, 90, 100, 110, 130], "kept: \(kept)")
    }

    @Test func noisyOCRStillCountsAsTheSameScreen() {
        // The real meeting's repeats: same picture (distance ≤ 3) and ~90% of the same OCR words.
        let a = ScreenshotCompactor.words("Transcenda | M All Ha | Workiva | My Al | M Inbox | Graph | Repol | Event | Planning board")
        let b = ScreenshotCompactor.words("Transcenda | M All Ha | Workiva | ) My Al | M Inbox | Graph | Repol | Event | Planning board")
        #expect(ScreenshotCompactor.isDuplicate(1, a, of: 0b111, b, .init()))
        // Same layout but different text (a new slide in the same place) is new content.
        let c = ScreenshotCompactor.words("Roadmap for the mobile release with beta dates and owners per milestone")
        #expect(!ScreenshotCompactor.isDuplicate(1, a, of: 1, c, .init()))
        // The same meeting view with a new chat message is new context.
        let chat = ScreenshotCompactor.words("Transcenda | M All Ha | Workiva | My Al | M Inbox | Graph | Repol | Event | Planning board | Zachary: repro is at this link https://dev.example.org/select_samples")
        #expect(!ScreenshotCompactor.isDuplicate(1, chat, of: 1, a, .init()))
    }

    @Test func filesAreDeletedAndTheRestRecompressed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "palmeet-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SessionFolder(url: root)
        try FileManager.default.createDirectory(at: root.appending(path: "screenshots"), withIntermediateDirectories: true)
        let image = try #require(Self.detailedImage(width: 2400, height: 1350))
        let big = try #require(ImageEncoding.jpegData(image, maxWidth: 2400, quality: 0.95))
        let shots = [
            shot(0, hash: 7, text: Self.grid),
            shot(30, hash: 7, text: Self.grid),
            shot(40, hash: 0xFFFF_0000, text: Self.slide),
        ]
        for s in shots { try big.write(to: root.appending(path: s.relativePath)) }
        try "![Slide](screenshots/40.jpg)".write(to: folder.summaryMarkdownURL, atomically: true, encoding: .utf8)
        #expect(ScreenshotCompactor.referencedPaths(in: folder) == ["screenshots/40.jpg"])

        let result = ScreenshotCompactor.compact(shots, in: folder, protected: ScreenshotCompactor.referencedPaths(in: folder))
        #expect(result.kept.map(\.offset) == [0, 40] && result.removed == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "screenshots/30.jpg").path))
        #expect(result.kept.allSatisfy { $0.compressed == true })
        #expect(result.bytesAfter < result.bytesBefore / 3, "\(result.bytesBefore) → \(result.bytesAfter)")
        let reread = try #require(ImageEncoding.cgImage(fromJPEG: try Data(contentsOf: root.appending(path: "screenshots/40.jpg"))))
        #expect(reread.width == ScreenshotCompactor.maxWidth)

        // Running again changes nothing (already compressed files aren't re-encoded).
        let again = ScreenshotCompactor.compact(result.kept, in: folder, protected: [])
        #expect(again.removed == 0 && again.bytesAfter == result.bytesAfter)
    }

    /// Text-like detail so JPEG sizes behave like a real screen.
    static func detailedImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed: UInt64 = 42
        for row in stride(from: 0, to: height, by: 14) {
            for col in stride(from: 0, to: width, by: 6) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                guard seed >> 61 != 0 else { continue }
                let shade = CGFloat(seed >> 56) / 255 * 0.6
                context.setFillColor(CGColor(red: shade, green: shade, blue: shade + 0.2, alpha: 1))
                context.fill(CGRect(x: col, y: row, width: 4, height: 9))
            }
        }
        return context.makeImage()
    }
}

/// Real screenshots: PALMEET_SCREENSHOT_DIR=<copy of a session folder> swift test --filter RealScreenshotCompaction
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PALMEET_SCREENSHOT_DIR"] != nil))
struct RealScreenshotCompaction {
    @Test func compactACopiedSession() throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PALMEET_SCREENSHOT_DIR"]))
        let folder = SessionFolder(url: url)
        let store = SessionStore(rootURL: url.deletingLastPathComponent())
        let shots = store.loadScreenshots(in: folder)
        let protected = ScreenshotCompactor.referencedPaths(in: folder)
        let result = ScreenshotCompactor.compact(shots, in: folder, protected: protected)
        try store.save(result.kept, in: folder)
        print("Kept \(result.kept.count) of \(shots.count): \(result.bytesBefore / 1024) KB → \(result.bytesAfter / 1024) KB")
        print("Kept:", result.kept.map { "\($0.relativePath) (\($0.reason.rawValue))" }.joined(separator: ", "))
        #expect(protected.allSatisfy { path in result.kept.contains { $0.relativePath == path } })
        #expect(result.kept.count < shots.count)
    }
}
