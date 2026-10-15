import CoreGraphics
import Foundation
import ImageIO
import SessionKit
import UniformTypeIdentifiers
import VisionContext

/// Keeps a finished meeting's screenshots light: drops the ones that show what another kept screenshot already
/// shows (same picture and same on-screen text, e.g. a static video grid sampled every 30 s, or the same slide
/// seen again later), then recompresses the rest. Screenshots you marked and ones the summary shows are kept.
enum ScreenshotCompactor {
    /// Same picture (hash distance) and the same words on screen (word-set overlap, OCR is noisy).
    struct Similarity: Sendable {
        var nearHash = 6
        var nearHashText = 0.8
        var looseHash = 14
        var looseHashText = 0.92
        /// Screens with fewer words than this (video only) are compared by picture alone.
        var minimumWords = 5
        /// More new words than this (a new chat message, a field filled in) is new content, whatever the overlap.
        /// OCR noise between two captures of the same screen stays under it.
        var maximumNewWords = 5
    }

    /// Re-encoding settings for the kept screenshots.
    static let maxWidth = 1440
    static let quality = 0.62
    /// Replace a file only when re-encoding saves at least this fraction.
    static let minimumSaving = 0.15

    struct Result: Sendable {
        var kept: [ScreenshotRecord]
        var removed: Int
        var bytesBefore: Int64
        var bytesAfter: Int64
    }

    // MARK: Planning

    /// Which screenshots to keep, in their original order.
    static func plan(_ shots: [ScreenshotRecord], protected: Set<String>, similarity: Similarity = Similarity()) -> [ScreenshotRecord] {
        var kept: [(record: ScreenshotRecord, words: Set<String>)] = []
        for shot in shots.sorted(by: { $0.offset < $1.offset }) {
            let words = Self.words(shot.ocrText)
            let isProtected = shot.reason == .manual || protected.contains(shot.relativePath)
            guard let match = kept.firstIndex(where: { isDuplicate(shot.perceptualHash, words, of: $0.record.perceptualHash, $0.words, similarity) }) else {
                kept.append((shot, words))
                continue
            }
            if isProtected {
                kept.append((shot, words))
                continue
            }
            // Same content: keep whichever holds more readable text, unless the one already kept must stay.
            let current = kept[match]
            let currentProtected = current.record.reason == .manual || protected.contains(current.record.relativePath)
            if !currentProtected, Double(words.count) > Double(current.words.count) * 1.1 {
                kept[match] = (shot, words)
            }
        }
        return kept.map(\.record).sorted { $0.offset < $1.offset }
    }

    static func isDuplicate(_ hashA: UInt64, _ wordsA: Set<String>, of hashB: UInt64, _ wordsB: Set<String>, _ s: Similarity) -> Bool {
        let distance = PerceptualHash.distance(hashA, hashB)
        if wordsA.count < s.minimumWords || wordsB.count < s.minimumWords {
            return distance <= s.nearHash && abs(wordsA.count - wordsB.count) < s.minimumWords
        }
        guard wordsA.subtracting(wordsB).count <= s.maximumNewWords else { return false }
        let overlap = Double(wordsA.intersection(wordsB).count) / Double(wordsA.union(wordsB).count)
        return (distance <= s.nearHash && overlap >= s.nearHashText) || (distance <= s.looseHash && overlap >= s.looseHashText)
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init))
    }

    /// Screenshots the summary links to (they must stay).
    static func referencedPaths(in folder: SessionFolder) -> Set<String> {
        var paths = Set<String>()
        for url in [folder.summaryMarkdownURL, folder.summaryJSONURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let regex = /screenshots\/[^\s"')\]]+\.jpe?g/
            for match in text.matches(of: regex) { paths.insert(String(match.output)) }
        }
        return paths
    }

    // MARK: Files

    /// Deletes the repeated screenshots' files and recompresses the kept ones.
    static func compact(_ shots: [ScreenshotRecord], in folder: SessionFolder, protected: Set<String>) -> Result {
        let kept = plan(shots, protected: protected)
        let keptIDs = Set(kept.map(\.id))
        var result = Result(kept: [], removed: 0, bytesBefore: 0, bytesAfter: 0)
        for shot in shots {
            let url = folder.url.appending(path: shot.relativePath)
            let size = fileSize(url)
            result.bytesBefore += size
            if !keptIDs.contains(shot.id) {
                try? FileManager.default.removeItem(at: url)
                result.removed += 1
            }
        }
        for var shot in kept {
            let url = folder.url.appending(path: shot.relativePath)
            if shot.compressed != true {
                recompress(url)
                shot.compressed = true
            }
            result.bytesAfter += fileSize(url)
            result.kept.append(shot)
        }
        return result
    }

    /// Re-encodes a JPEG smaller (narrower and lower quality) when that saves enough; otherwise leaves it.
    @discardableResult
    static func recompress(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let smaller = ImageEncoding.jpegData(image, maxWidth: maxWidth, quality: quality),
              Double(smaller.count) <= Double(data.count) * (1 - minimumSaving)
        else { return false }
        return (try? smaller.write(to: url, options: .atomic)) != nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
