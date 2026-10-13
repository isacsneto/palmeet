@preconcurrency import AVFoundation
import Foundation
import SessionKit

/// Post-recording edits to track files.
enum AudioRedaction {
    /// Seconds of audio in a file, 0 if it can't be read.
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Silences everything outside `keeping` spans (e.g. mic audio that was routed to another meeting), streaming
    /// in 10 s blocks so long meetings don't load into memory. Replaces the file atomically.
    static func silence(_ url: URL, keeping spans: [MicRouteSpan]) throws {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let rate = format.sampleRate
        let temp = url.deletingLastPathComponent().appending(path: ".redact-\(UUID().uuidString).caf")
        do {
            let output = try AVAudioFile(forWriting: temp, settings: input.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let blockFrames = AVAudioFrameCount(rate * 10)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { return }
            var position: AVAudioFramePosition = 0
            while position < input.length {
                try input.read(into: buffer, frameCount: min(blockFrames, AVAudioFrameCount(input.length - position)))
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { break }
                for channel in 0..<Int(format.channelCount) {
                    guard let data = buffer.floatChannelData?[channel] else { continue }
                    for i in 0..<frames {
                        let time = Double(position + AVAudioFramePosition(i)) / rate
                        if !spans.contains(where: { $0.contains(time) }) { data[i] = 0 }
                    }
                }
                try output.write(from: buffer)
                position += AVAudioFramePosition(frames)
            }
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
