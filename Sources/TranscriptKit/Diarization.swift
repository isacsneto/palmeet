import Foundation
import FluidAudio

/// "Who spoke when" on the remote track. Keys are diarizer-internal ("1", "S2", …) and get mapped to
/// stable transcript speaker IDs by `TranscriptAssembler`.
public struct DiarizedSpan: Sendable, Hashable, Codable {
    public var speakerKey: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerKey: String, start: TimeInterval, end: TimeInterval) {
        self.speakerKey = speakerKey
        self.start = start
        self.end = end
    }
}

/// Diarization plus one voice fingerprint per speaker (L2-normalized mean of that speaker's segment embeddings).
public struct DiarizationOutput: Sendable {
    public var spans: [DiarizedSpan]
    /// Diarizer speaker key → voiceprint. Empty when the diarizer can't provide them.
    public var voiceprints: [String: [Float]]

    public init(spans: [DiarizedSpan], voiceprints: [String: [Float]] = [:]) {
        self.spans = spans
        self.voiceprints = voiceprints
    }
}

public protocol Diarizer: Sendable {
    func prepare() async throws
    func diarize(fileURL: URL) async throws -> [DiarizedSpan]
    func diarizeWithVoiceprints(fileURL: URL) async throws -> DiarizationOutput
}

extension Diarizer {
    public func diarizeWithVoiceprints(fileURL: URL) async throws -> DiarizationOutput {
        DiarizationOutput(spans: try await diarize(fileURL: fileURL))
    }
}

/// Offline pyannote-style pipeline (segmentation + WeSpeaker embeddings + VBx clustering) from FluidAudio.
public actor OfflineSpeakerDiarizer: Diarizer {
    /// OfflineDiarizerManager is a non-Sendable class. Callers run diarization through `ASRScheduler`, so it is
    /// never used concurrently; the box only lets it cross the actor boundary for the async call.
    private struct ManagerBox: @unchecked Sendable {
        let manager: OfflineDiarizerManager
    }

    private var box: ManagerBox?

    public init() {}

    public func prepare() async throws {
        _ = try await loadedManager()
    }

    public func diarize(fileURL: URL) async throws -> [DiarizedSpan] {
        try await diarizeWithVoiceprints(fileURL: fileURL).spans
    }

    public func diarizeWithVoiceprints(fileURL: URL) async throws -> DiarizationOutput {
        let box = try await loadedManager()
        let result = try await Self.process(box, fileURL: fileURL)
        let spans = result.segments
            .map { DiarizedSpan(speakerKey: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        // Duration-weighted mean of each speaker's segment embeddings: long, clean turns count more than short ones.
        var sums: [String: [Float]] = [:]
        for segment in result.segments where !segment.embedding.isEmpty && segment.embedding.allSatisfy(\.isFinite) {
            let weight = max(segment.durationSeconds, 0.1)
            var sum = sums[segment.speakerId] ?? [Float](repeating: 0, count: segment.embedding.count)
            guard sum.count == segment.embedding.count else { continue }
            for i in sum.indices { sum[i] += segment.embedding[i] * weight }
            sums[segment.speakerId] = sum
        }
        let voiceprints = sums.compactMapValues { Voiceprint.normalized($0) }
        return DiarizationOutput(spans: spans, voiceprints: voiceprints)
    }

    private nonisolated static func process(_ box: ManagerBox, fileURL: URL) async throws -> DiarizationResult {
        try await box.manager.process(fileURL)
    }

    private func loadedManager() async throws -> ManagerBox {
        if let box { return box }
        let created = ManagerBox(manager: OfflineDiarizerManager(config: .default))
        try await Self.prepare(created)
        box = created
        return created
    }

    private nonisolated static func prepare(_ box: ManagerBox) async throws {
        try await box.manager.prepareModels()
    }
}
