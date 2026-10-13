import AVFoundation
import Foundation

enum AudioTestFiles {
    /// Concatenates mono files (same sample rate) with silence in between into a 16 kHz WAV.
    static func concatenate(_ inputs: [URL], silenceBetween: TimeInterval, to output: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        let out = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * silenceBetween))!
        silence.frameLength = silence.frameCapacity
        for url in inputs {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            try out.write(from: buffer)
            try out.write(from: silence)
        }
    }
}
