@preconcurrency import AVFoundation
import Foundation

/// Re-saves a finished meeting's audio track smaller: AAC (lossy) or Apple Lossless, both in .m4a.
///
/// Measured on a real 19-minute standup (16 kHz mono): AAC 48 kbit/s is 5.8× smaller, and transcribing it again
/// changes 3.3–3.8% of the words and can split speakers differently; 32 kbit/s changes 6%, Opus 8%+. Apple
/// Lossless is 2.2× smaller and transcribes identically. (AAC can't go above 48 kbit/s at 16 kHz.)
enum AudioCompression {
    static let bitRate = 48_000

    static func format(for storage: AudioStorage) -> AudioFormatID? {
        switch storage {
        case .original: nil
        case .lossless: kAudioFormatAppleLossless
        case .compressed: kAudioFormatMPEG4AAC
        }
    }

    enum Failure: Error {
        case lengthMismatch(expected: AVAudioFramePosition, got: AVAudioFramePosition)
    }

    /// Writes `destination` (.m4a), checks it reads back with the same length, then deletes `source`.
    /// On any failure the source is left untouched.
    @discardableResult
    static func compress(_ source: URL, to destination: URL, format formatID: AudioFormatID = kAudioFormatMPEG4AAC, bitRate: Int = bitRate) throws -> (before: Int64, after: Int64) {
        let before = fileSize(source)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let temp = destination.deletingLastPathComponent().appending(path: ".compress-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let output = try AVAudioFile(
                forWriting: temp,
                settings: formatID == kAudioFormatAppleLossless
                    ? [AVFormatIDKey: formatID, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitDepthHintKey: 16]
                    : [AVFormatIDKey: formatID, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: bitRate * Int(format.channelCount)],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let block = AVAudioFrameCount(format.sampleRate * 10)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { throw CocoaError(.fileWriteUnknown) }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: min(block, AVAudioFrameCount(input.length - input.framePosition)))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            if #available(macOS 15, *) { output.close() }
        }  // Older systems finish the file when `output` is released here.
        let check = try AVAudioFile(forReading: temp)
        // AAC adds a few priming frames; anything beyond a tenth of a second means a broken copy.
        guard abs(check.length - input.length) <= AVAudioFramePosition(format.sampleRate / 10) else {
            throw Failure.lengthMismatch(expected: input.length, got: check.length)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        try FileManager.default.removeItem(at: source)
        return (before, fileSize(destination))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
