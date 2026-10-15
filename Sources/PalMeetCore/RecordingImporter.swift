@preconcurrency import AVFoundation
import CaptureKit
import CoreGraphics
import Foundation
import SessionKit
import UniformTypeIdentifiers
import VisionContext

public enum ImportError: Error, LocalizedError {
    case noAudio
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "The file has no audio track."
        case .unreadable(let detail): "Couldn't read the recording: \(detail)"
        }
    }
}

/// Turns an existing recording (any audio/video file AVFoundation can read: mp4, mov, m4a, mp3, wav…) into a
/// PalMeet session, then runs the normal pipeline: transcription, speaker separation, naming, summary.
///
/// All voices are on one track (there is no separate microphone), and screenshots come from the video frames
/// with the same change-detection policy as live capture.
public enum RecordingImporter {
    public static let supportedTypes: [UTType] = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .mp3, .wav, .aiff]

    struct Prepared: Sendable {
        var duration: TimeInterval
        var recordedAt: Date
        var screenshots: [ScreenshotRecord]
    }

    /// Writes `them.caf` (16 kHz mono) and screenshots into `folder`.
    static func prepare(_ url: URL, into folder: SessionFolder, settings: AppSettings) async throws -> Prepared {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudio }

        try folder.createDirectories()
        try await extractAudio(asset: asset, track: audioTrack, to: folder.recordingURL(for: .them))

        var screenshots: [ScreenshotRecord] = []
        if try await !asset.loadTracks(withMediaType: .video).isEmpty {
            screenshots = try await extractFrames(asset: asset, duration: duration, folder: folder, settings: settings)
        }

        return Prepared(duration: duration, recordedAt: await recordingDate(of: url), screenshots: screenshots)
    }

    /// When the recording was made: the media's creation date, else the file's.
    static func recordingDate(of url: URL) async -> Date {
        let creation = try? await AVURLAsset(url: url).load(.creationDate)?.load(.dateValue)
        let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return creation ?? fileDate ?? Date()
    }

    private static func extractAudio(asset: AVURLAsset, track: AVAssetTrack, to url: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw ImportError.unreadable(reader.error?.localizedDescription ?? "unknown") }
        let writer = try AudioTrackWriter(url: url, gapTolerance: .infinity)
        // The mono downmix sums channels at -3 dB, so identical stereo channels come out ~3 dB louder (and can
        // clip in the 16-bit file); scale back to the plain channel average.
        let descriptions = try await track.load(.formatDescriptions)
        let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let gain: Float = channels > 1 ? Float(1 / 2.0.squareRoot()) : 1
        var offset: TimeInterval = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if gain != 1 { for i in samples.indices { samples[i] *= gain } }
            writer.append(samples, at: offset)
            offset += Double(samples.count) / AudioChunk.sampleRate
        }
        writer.finish()
        if reader.status == .failed { throw ImportError.unreadable(reader.error?.localizedDescription ?? "unknown") }
    }

    /// Samples a frame every 2 s and keeps them with the live screenshot policy (screen changes + interval).
    private static func extractFrames(asset: AVURLAsset, duration: TimeInterval, folder: SessionFolder, settings: AppSettings) async throws -> [ScreenshotRecord] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let policy = FrameKeepPolicy(changeThreshold: settings.screenshotChangeThreshold, maxInterval: settings.screenshotInterval)
        let times = stride(from: 0.5, to: max(duration, 0.6), by: 2.0).map { CMTime(seconds: $0, preferredTimescale: 600) }

        var records: [ScreenshotRecord] = []
        var lastHash: UInt64?
        var lastOffset: TimeInterval?
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            let offset = result.requestedTime.seconds
            let hash = PerceptualHash.dHash(image)
            let decision = policy.decide(hash: hash, at: offset, lastKeptHash: lastHash, lastKeptTime: lastOffset)
            guard decision != .skip, let jpeg = ImageEncoding.jpegData(image) else { continue }
            let relativePath = SessionFolder.screenshotRelativePath(index: records.count + 1, offset: offset)
            try jpeg.write(to: folder.url.appending(path: relativePath), options: .atomic)
            let ocr = try? TextRecognizer.recognize(image)
            records.append(ScreenshotRecord(
                index: records.count + 1, offset: offset, relativePath: relativePath,
                reason: decision == .keepChange ? .screenChange : .interval,
                ocrText: ocr?.text ?? "", nameCandidates: ocr?.nameCandidates ?? [], perceptualHash: hash
            ))
            lastHash = hash
            lastOffset = offset
        }
        return records
    }
}

extension SessionManager {
    /// Imports a recording: extracts audio and screenshots and adds the session to the library. Call
    /// `processImport()` on the result to transcribe and summarize it (the UI shows progress meanwhile).
    @discardableResult
    public func importRecording(from url: URL, title: String? = nil) async throws -> MeetingSession {
        let name = title ?? url.deletingPathExtension().lastPathComponent
        var metadata = SessionMetadata(
            title: Self.cleanTitle(name, appName: "Recording"),
            createdAt: await RecordingImporter.recordingDate(of: url),
            source: CaptureSourceDescriptor(kind: .importedFile, appName: "Imported recording", windowTitle: url.lastPathComponent),
            isolation: .none,
            includesMicrophone: false,
            language: settings.language
        )
        metadata.status = .processing
        let folder = try services.store.createFolder(for: metadata)
        let prepared: RecordingImporter.Prepared
        do {
            prepared = try await RecordingImporter.prepare(url, into: folder, settings: settings)
        } catch {
            try? services.store.delete(folder)
            throw error
        }
        metadata.createdAt = prepared.recordedAt
        metadata.endedAt = prepared.recordedAt.addingTimeInterval(prepared.duration)
        try services.store.save(metadata, in: folder)
        try services.store.save(prepared.screenshots, in: folder)

        let session = MeetingSession(loadedFrom: folder, metadata: metadata, services: services, settings: { [settingsBox] in settingsBox.value })
        session.markQueued()
        library.insert(session, at: 0)
        return session
    }
}
