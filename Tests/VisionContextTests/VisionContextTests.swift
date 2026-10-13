import CoreGraphics
import Foundation
import Testing
@testable import VisionContext

/// Half bright / half dark, split left-right (vertical edge) or top-bottom (horizontal edge).
private func image(verticalEdge: Bool) -> CGImage {
    let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(verticalEdge ? CGRect(x: 0, y: 0, width: 32, height: 64) : CGRect(x: 0, y: 0, width: 64, height: 32))
    return context.makeImage()!
}

@Suite struct PerceptualHashTests {
    @Test func identicalImagesMatchAndDifferentOnesDiffer() {
        let a = PerceptualHash.dHash(image(verticalEdge: true))
        #expect(PerceptualHash.distance(a, PerceptualHash.dHash(image(verticalEdge: true))) == 0)
        let other = PerceptualHash.dHash(image(verticalEdge: false))
        #expect(PerceptualHash.distance(a, other) > 10)
    }
}

@Suite struct FrameKeepPolicyTests {
    let policy = FrameKeepPolicy(changeThreshold: 10, maxInterval: 30, minInterval: 3)

    @Test func keepsFirstFrame() {
        #expect(policy.decide(hash: 1, at: 0, lastKeptHash: nil, lastKeptTime: nil) == .keepInterval)
    }

    @Test func keepsOnChangeButNotTooOften() {
        let changed: UInt64 = 0xFFFF_FFFF
        #expect(policy.decide(hash: changed, at: 2, lastKeptHash: 0, lastKeptTime: 0) == .skip)
        #expect(policy.decide(hash: changed, at: 4, lastKeptHash: 0, lastKeptTime: 0) == .keepChange)
    }

    @Test func keepsOnIntervalWhenStatic() {
        #expect(policy.decide(hash: 0, at: 29, lastKeptHash: 0, lastKeptTime: 0) == .skip)
        #expect(policy.decide(hash: 0, at: 30, lastKeptHash: 0, lastKeptTime: 0) == .keepInterval)
    }
}

@Suite struct NameTagTests {
    func line(_ text: String) -> OCRLine { OCRLine(text: text, box: .zero, confidence: 1) }

    @Test func findsNamesAndSkipsUILabels() {
        let names = NameTagHeuristics.candidates(in: [
            line("Maria Silva"), line("John Park (Host)"), line("Mute"), line("Share Screen"),
            line("Q3 Roadmap 2026"), line("maria silva"), line("Participants (4)"),
        ])
        #expect(names == ["Maria Silva", "John Park"])
    }
}
