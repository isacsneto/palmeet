import Foundation
import SessionKit

/// Suggests real names for diarized speakers from names visible in screenshots.
///
/// Gallery views show every participant's name all the time, so raw co-occurrence carries no signal. Instead each
/// name gets a *lift* per speaker: how much more often it is visible while that speaker talks than overall. Speaker
/// views and active-speaker highlights produce high lift; ever-present names cancel out.
public enum SpeakerNameInference {
    public struct Observation: Sendable {
        public var offset: TimeInterval
        public var names: [String]

        public init(offset: TimeInterval, names: [String]) {
            self.offset = offset
            self.names = names
        }
    }

    public struct Suggestion: Sendable, Equatable {
        public var speakerID: String
        public var name: String
        public var lift: Double
        public var support: Int
    }

    public static func suggest(
        transcript: Transcript,
        observations: [Observation],
        excluding excludedNames: Set<String> = [],
        minimumLift: Double = 1.5,
        minimumSupport: Int = 2
    ) -> [Suggestion] {
        guard !observations.isEmpty else { return [] }
        let excluded = Set(excludedNames.map { $0.lowercased() })
        let normalized = observations.map { obs in
            Observation(offset: obs.offset, names: Array(Set(obs.names.filter { !excluded.contains($0.lowercased()) })))
        }

        // Overall visibility rate per name.
        var overall: [String: Int] = [:]
        for obs in normalized { obs.names.forEach { overall[$0, default: 0] += 1 } }
        let total = Double(normalized.count)

        // Visibility while each remote speaker is talking.
        var perSpeaker: [String: [String: Int]] = [:]
        var speakerFrames: [String: Int] = [:]
        for obs in normalized {
            guard let speaker = activeRemoteSpeaker(at: obs.offset, in: transcript) else { continue }
            speakerFrames[speaker, default: 0] += 1
            obs.names.forEach { perSpeaker[speaker, default: [:]][$0, default: 0] += 1 }
        }

        var candidates: [Suggestion] = []
        for (speaker, counts) in perSpeaker {
            guard let frames = speakerFrames[speaker], frames > 0 else { continue }
            for (name, count) in counts where count >= minimumSupport {
                let pGivenSpeaker = Double(count) / Double(frames)
                let pOverall = Double(overall[name] ?? 0) / total
                guard pOverall > 0 else { continue }
                let lift = pGivenSpeaker / pOverall
                if lift >= minimumLift {
                    candidates.append(Suggestion(speakerID: speaker, name: name, lift: lift, support: count))
                }
            }
        }

        // Greedy one-to-one assignment, strongest evidence first.
        var usedSpeakers = Set<String>(), usedNames = Set<String>()
        var result: [Suggestion] = []
        for candidate in candidates.sorted(by: { ($0.lift, $0.support, $1.name) > ($1.lift, $1.support, $0.name) }) {
            // Check both before claiming either, so a speaker whose best name is taken can still get its next one.
            guard !usedSpeakers.contains(candidate.speakerID), !usedNames.contains(candidate.name.lowercased()) else { continue }
            usedSpeakers.insert(candidate.speakerID)
            usedNames.insert(candidate.name.lowercased())
            result.append(candidate)
        }
        return result
    }

    static func activeRemoteSpeaker(at offset: TimeInterval, in transcript: Transcript) -> String? {
        transcript.segments.first { $0.track == .them && $0.start - 0.5 <= offset && offset <= $0.end + 0.5 }?.speakerID
    }
}
