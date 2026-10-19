import Foundation
import SessionKit

/// Speaker-embedding math. Voiceprints are L2-normalized WeSpeaker embeddings from the diarizer.
public enum Voiceprint {
    public static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity of two voiceprints (-1...1); 0 when they can't be compared.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = (na * nb).squareRoot()
        return denominator > 1e-9 ? dot / denominator : 0
    }

    /// Weighted mean of voiceprints, normalized.
    public static func mean(_ items: [(vector: [Float], weight: Double)]) -> [Float]? {
        guard let first = items.first(where: { !$0.vector.isEmpty }) else { return nil }
        var sum = [Float](repeating: 0, count: first.vector.count)
        for item in items where item.vector.count == sum.count {
            let weight = Float(max(item.weight, 0.001))
            for i in sum.indices { sum[i] += item.vector[i] * weight }
        }
        return normalized(sum)
    }
}

/// One remote speaker of a finished meeting and their voiceprint, saved next to the transcript so that naming
/// them later (in Review) can teach PalMeet their voice.
public struct SpeakerVoice: Codable, Sendable, Equatable {
    public var vector: [Float]
    /// Seconds of speech the voiceprint was built from.
    public var seconds: Double

    public init(vector: [Float], seconds: Double) {
        self.vector = vector
        self.seconds = seconds
    }
}

/// A person PalMeet has learned to recognize by voice.
public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable {
    public struct Sample: Codable, Sendable, Equatable {
        public var vector: [Float]
        public var seconds: Double
        public var sessionID: SessionIDString
        public var addedAt: Date

        public init(vector: [Float], seconds: Double, sessionID: SessionIDString, addedAt: Date = Date()) {
            self.vector = vector
            self.seconds = seconds
            self.sessionID = sessionID
            self.addedAt = addedAt
        }
    }

    public var id: UUID
    public var name: String
    /// One sample per meeting the person was named in (newest last, capped).
    public var samples: [Sample]

    public init(id: UUID = UUID(), name: String, samples: [Sample] = []) {
        self.id = id
        self.name = name
        self.samples = samples
    }

    public var updatedAt: Date? { samples.map(\.addedAt).max() }
    public var meetingCount: Int { Set(samples.map(\.sessionID)).count }

    /// Best similarity to any sample (voices vary by microphone and connection, so samples aren't averaged away).
    public func similarity(to vector: [Float]) -> Float {
        samples.map { Voiceprint.similarity($0.vector, vector) }.max() ?? 0
    }
}

public typealias SessionIDString = String

/// Matches a meeting's speakers to known voices.
public enum VoiceMatcher {
    public struct Thresholds: Sendable {
        /// Minimum cosine similarity to accept a match.
        public var accept: Float = 0.65
        /// The best profile must beat the second best by this much.
        public var margin: Float = 0.08
        /// Speakers with less speech than this give unreliable voiceprints.
        public var minimumSeconds: Double = 8

        public init() {}
    }

    public struct Match: Sendable, Equatable {
        public var speakerID: String
        public var profileID: UUID
        public var name: String
        public var similarity: Float
    }

    /// Speaker ID → best matching profile, for speakers that clear the thresholds. Two speakers may match the same
    /// person: the diarizer sometimes splits one voice into two clusters, and the caller merges them.
    public static func match(
        _ voices: [String: SpeakerVoice],
        against profiles: [VoiceProfile],
        thresholds: Thresholds = Thresholds()
    ) -> [Match] {
        voices.compactMap { speakerID, voice -> Match? in
            guard voice.seconds >= thresholds.minimumSeconds else { return nil }
            let ranked = profiles
                .map { ($0, $0.similarity(to: voice.vector)) }
                .sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= thresholds.accept else { return nil }
            if ranked.count > 1, best.1 - ranked[1].1 < thresholds.margin { return nil }
            return Match(speakerID: speakerID, profileID: best.0.id, name: best.0.name, similarity: best.1)
        }
        .sorted { $0.speakerID < $1.speakerID }
    }
}

/// The voice library, `Voices.json` in PalMeet's Application Support folder. Voiceprints never leave the Mac.
public struct VoiceProfileStore: Sendable {
    public let url: URL
    /// Samples kept per person.
    public var maxSamples = 12

    public init(url: URL = URL.applicationSupportDirectory.appending(path: "PalMeet/Voices.json")) {
        self.url = url
    }

    private struct File: Codable {
        var version = 1
        var profiles: [VoiceProfile]
    }

    /// People in the library. Names that are a page notice, not a person (learned before PalMeet 0.2.6 told them
    /// apart, e.g. "Are you"), are left out and dropped at the next save.
    public func load() -> [VoiceProfile] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder.voiceStore.decode(File.self, from: data)
        else { return [] }
        return file.profiles.filter { MeetingSpeakerTimeline.isPersonName($0.name) }
    }

    public func save(_ profiles: [VoiceProfile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.voiceStore.encode(File(profiles: profiles))
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Adds a meeting's voiceprint to the person called `name` (created if new). A later sample from the same
    /// meeting replaces the earlier one, so renaming a speaker twice doesn't count twice.
    @discardableResult
    public func learn(name: String, voice: SpeakerVoice, sessionID: SessionIDString, at date: Date = Date()) throws -> VoiceProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profiles = load()
        // Forget this meeting's sample under any other name first (the user corrected a wrong name).
        for index in profiles.indices {
            profiles[index].samples.removeAll { $0.sessionID == sessionID && $0.vector == voice.vector }
        }
        let index = profiles.firstIndex { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? { profiles.append(VoiceProfile(name: trimmed)); return profiles.count - 1 }()
        profiles[index].samples.removeAll { $0.sessionID == sessionID }
        profiles[index].samples.append(.init(vector: voice.vector, seconds: voice.seconds, sessionID: sessionID, addedAt: date))
        if profiles[index].samples.count > maxSamples {
            profiles[index].samples.removeFirst(profiles[index].samples.count - maxSamples)
        }
        profiles.removeAll { $0.samples.isEmpty }
        try save(profiles)
        return profiles.first { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }!
    }

    /// Removes a meeting's sample for one voice (the user un-named or renamed a speaker to someone else).
    public func forget(voice: SpeakerVoice, sessionID: SessionIDString) throws {
        var profiles = load()
        let before = profiles.map(\.samples.count).reduce(0, +)
        for index in profiles.indices {
            profiles[index].samples.removeAll { $0.sessionID == sessionID && $0.vector == voice.vector }
        }
        profiles.removeAll { $0.samples.isEmpty }
        if profiles.map(\.samples.count).reduce(0, +) != before { try save(profiles) }
    }

    public func delete(_ id: UUID) throws {
        try save(load().filter { $0.id != id })
    }

    public func rename(_ id: UUID, to name: String) throws {
        var profiles = load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        try save(profiles)
    }

    public func deleteAll() throws {
        try? FileManager.default.removeItem(at: url)
    }
}

extension JSONEncoder {
    static var voiceStore: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var voiceStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
