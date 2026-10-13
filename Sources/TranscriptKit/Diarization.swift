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

public protocol Diarizer: Sendable {
    func prepare() async throws
    func diarize(fileURL: URL) async throws -> [DiarizedSpan]
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
        let box = try await loadedManager()
        let result = try await Self.process(box, fileURL: fileURL)
        return result.segments
            .map { DiarizedSpan(speakerKey: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
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
