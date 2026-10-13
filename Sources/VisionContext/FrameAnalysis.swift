import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 64-bit difference hash: robust to scaling/compression, sensitive to layout changes (new slide, screen share).
public enum PerceptualHash {
    public static func dHash(_ image: CGImage) -> UInt64 {
        // 9x8 grayscale thumbnail; each bit compares a pixel with its right neighbour.
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + col] > pixels[row * width + col + 1] { hash |= 1 }
            }
        }
        return hash
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

/// Decides which sampled frames are worth keeping as screenshots.
public struct FrameKeepPolicy: Sendable {
    /// Hamming distance above which the screen is considered changed.
    public var changeThreshold: Int
    /// Keep a frame at least this often even when nothing changes.
    public var maxInterval: TimeInterval
    /// Never keep change-triggered frames more often than this.
    public var minInterval: TimeInterval

    public init(changeThreshold: Int = 10, maxInterval: TimeInterval = 30, minInterval: TimeInterval = 3) {
        self.changeThreshold = changeThreshold
        self.maxInterval = maxInterval
        self.minInterval = minInterval
    }

    public enum Decision: Equatable, Sendable {
        case skip
        case keepInterval
        case keepChange
    }

    public func decide(hash: UInt64, at time: TimeInterval, lastKeptHash: UInt64?, lastKeptTime: TimeInterval?) -> Decision {
        guard let lastKeptHash, let lastKeptTime else { return .keepInterval }
        let elapsed = time - lastKeptTime
        if elapsed >= minInterval, PerceptualHash.distance(hash, lastKeptHash) > changeThreshold {
            return .keepChange
        }
        if elapsed >= maxInterval { return .keepInterval }
        return .skip
    }
}

public struct OCRLine: Sendable, Hashable {
    public var text: String
    /// Normalized bounding box (Vision coordinates: origin bottom-left, 0...1).
    public var box: CGRect
    public var confidence: Float
}

public struct OCRResult: Sendable {
    public var lines: [OCRLine]

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// Short lines that look like participant name tags ("Maria Silva", "John Park (Host)").
    public var nameCandidates: [String] { NameTagHeuristics.candidates(in: lines) }
}

public enum TextRecognizer {
    /// Runs accurate on-device OCR. Safe to call from any thread.
    public static func recognize(_ image: CGImage, languages: [String] = ["en-US", "pt-BR"]) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
        }
        return OCRResult(lines: lines)
    }
}

enum NameTagHeuristics {
    /// Words that appear in meeting UIs but are never names.
    static let uiWords: Set<String> = [
        "mute", "unmute", "share", "stop", "chat", "participants", "people", "leave", "end", "record",
        "recording", "reactions", "more", "camera", "video", "audio", "raise", "hand", "settings", "join",
        "meeting", "host", "presenting", "you", "apps", "view", "speaker", "gallery", "copilot", "whiteboard",
        "silenciar", "compartilhar", "sair", "participantes", "reunião", "gravando", "apresentando",
    ]

    static func candidates(in lines: [OCRLine]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let cleaned = line.text
                .replacingOccurrences(of: #"\s*\((host|co-host|guest|me|you|organizer|organizador|convidado)\)\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard looksLikeName(cleaned), seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count), text.count <= 40 else { return false }
        guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        for word in words {
            guard let first = word.first, first.isUppercase, first.isLetter else { return false }
            if uiWords.contains(word.lowercased()) { return false }
        }
        // Single words must be reasonably long to avoid UI labels like "OK".
        return words.count > 1 || text.count >= 3
    }
}

public enum ImageEncoding {
    /// JPEG-encodes an image, downscaling to `maxWidth` when needed.
    public static func jpegData(_ image: CGImage, maxWidth: Int = 1600, quality: Double = 0.75) -> Data? {
        let source = downscaled(image, maxWidth: maxWidth) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func cgImage(fromJPEG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return nil }
        let scale = Double(maxWidth) / Double(image.width)
        let width = maxWidth
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
