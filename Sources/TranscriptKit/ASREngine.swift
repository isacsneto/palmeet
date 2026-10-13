import Foundation
import FluidAudio
import SessionKit

/// Words with timings relative to the start of the audio that was transcribed.
public struct ASRTranscription: Sendable {
    public var text: String
    public var words: [TranscriptWord]
    public var confidence: Float

    public init(text: String, words: [TranscriptWord], confidence: Float) {
        self.text = text
        self.words = words
        self.confidence = confidence
    }

    /// Shifts every word by `offset` seconds (chunk-relative → session-relative).
    public func shifted(by offset: TimeInterval) -> ASRTranscription {
        var copy = self
        copy.words = words.map { TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
        return copy
    }
}

public protocol ASREngine: Sendable {
    var id: String { get }
    /// Downloads/loads models. Idempotent; concurrent callers share one load.
    func prepare() async throws
    /// Transcribes 16 kHz mono samples.
    func transcribe(samples: [Float], language: String?) async throws -> ASRTranscription
    /// Transcribes a whole file (any format); long files are processed with bounded memory.
    func transcribe(fileURL: URL, language: String?) async throws -> ASRTranscription
}

/// On-device Parakeet TDT (FluidAudio, Core ML on the Neural Engine). 25 European languages incl. PT and EN.
public actor ParakeetEngine: ASREngine {
    public enum Model: String, Sendable, CaseIterable {
        case ultra
        case v3
        case v2English

        var version: AsrModelVersion {
            switch self {
            case .ultra: .ultra
            case .v3: .v3
            case .v2English: .v2
            }
        }
    }

    public nonisolated let id: String
    private let model: Model
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init(model: Model = .ultra) {
        self.model = model
        self.id = "parakeet-\(model.rawValue)"
    }

    public func prepare() async throws {
        _ = try await loadedManager()
    }

    public func transcribe(samples: [Float], language: String?) async throws -> ASRTranscription {
        let manager = try await loadedManager()
        // The model needs at least ~1 s of audio; pad short utterances with silence.
        let minimum = Int(AudioConstants.sampleRate)
        let padded = samples.count >= minimum ? samples : samples + [Float](repeating: 0, count: minimum - samples.count)
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &state, language: Self.language(language))
        return Self.convert(result)
    }

    public func transcribe(fileURL: URL, language: String?) async throws -> ASRTranscription {
        let manager = try await loadedManager()
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &state, language: Self.language(language))
        return Self.convert(result)
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = model.version
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            manager = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    static func language(_ code: String?) -> Language? {
        guard let code, let primary = code.split(separator: "-").first else { return nil }
        return Language(rawValue: String(primary).lowercased())
    }

    static func convert(_ result: ASRResult) -> ASRTranscription {
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TranscriptWord(text: $0.word, start: $0.startTime, end: $0.endTime, confidence: result.confidence)
        }
        return ASRTranscription(text: result.text, words: words, confidence: result.confidence)
    }
}

enum AudioConstants {
    static let sampleRate: Double = 16_000
}
