import Foundation

/// "About me", used to recognise questions addressed to the user and to tailor suggestions.
public struct UserProfile: Codable, Sendable, Equatable {
    public var name: String
    /// Nicknames and spellings people use ("Isac", "Isaac", "Zac").
    public var aliases: [String]
    public var role: String
    public var team: String
    public var expertise: String
    public var communicationStyle: String
    /// BCP-47 code, or nil to answer in the meeting's language.
    public var answerLanguage: String?

    public init(
        name: String = NSFullUserName(),
        aliases: [String] = [],
        role: String = "",
        team: String = "",
        expertise: String = "",
        communicationStyle: String = "concise, friendly, direct",
        answerLanguage: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.role = role
        self.team = team
        self.expertise = expertise
        self.communicationStyle = communicationStyle
        self.answerLanguage = answerLanguage
    }

    /// First name plus aliases, lowercased and without diacritics.
    public var callNames: [String] {
        let first = name.split(separator: " ").first.map(String.init)
        return ([first, name] + aliases.map(Optional.some))
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .map { $0.lowercased().folding(options: .diacriticInsensitive, locale: nil) }
    }

    var promptDescription: String {
        var lines = ["Name: \(name)"]
        if !aliases.isEmpty { lines.append("Also called: \(aliases.joined(separator: ", "))") }
        if !role.isEmpty { lines.append("Role: \(role)") }
        if !team.isEmpty { lines.append("Team: \(team)") }
        if !expertise.isEmpty { lines.append("Expertise: \(expertise)") }
        if !communicationStyle.isEmpty { lines.append("Preferred style: \(communicationStyle)") }
        return lines.joined(separator: "\n")
    }
}

public enum MeetingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case grooming
    case planning
    case oneOnOne
    case standup
    case designReview
    case client
    case interview
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .grooming: "Grooming / Refinement"
        case .planning: "Planning"
        case .oneOnOne: "1:1"
        case .standup: "Standup"
        case .designReview: "Design review"
        case .client: "Sales / Client"
        case .interview: "Interview"
        case .generic: "Generic"
        }
    }

    /// Default playbook; users can override it in Settings → Copilot.
    public var defaultPlaybook: String {
        switch self {
        case .grooming:
            """
            This is a backlog grooming / refinement session about a feature or ticket. Look for gaps in: acceptance \
            criteria, edge cases and error states, empty/loading states, dependencies (APIs, other teams, third parties), \
            data model and migrations, non-functional requirements (performance, security, privacy, accessibility, i18n), \
            analytics/telemetry, feature flags and rollout/rollback, backwards compatibility, test strategy, definition of \
            done, estimation risks, and scope that could be split into smaller deliverables.
            """
        case .planning:
            "This is a planning meeting. Focus on priorities, capacity, dependencies, sequencing, risks, owners and dates, and what is explicitly out of scope."
        case .oneOnOne:
            "This is a 1:1. Focus on feedback, blockers, growth, expectations, workload and concrete follow-ups. Keep a supportive tone."
        case .standup:
            "This is a standup. Focus on blockers, dependencies between people, and things that need a follow-up after the standup."
        case .designReview:
            "This is a design/architecture review. Focus on trade-offs, alternatives considered, failure modes, scalability, security, operability, migration path and testing."
        case .client:
            "This is a client/sales conversation. Focus on the client's goals, pain points, decision process, budget, timeline, objections and next steps. Never invent pricing or commitments."
        case .interview:
            "This is an interview. Focus on clarifying the question, structuring answers (situation, action, result), and good questions to ask about the role, team and expectations."
        case .generic:
            "Focus on clarifying goals, decisions, owners, deadlines, risks and open questions."
        }
    }

    /// Guesses a mode from the meeting title / early transcript.
    public static func guess(from text: String) -> MeetingMode {
        let t = text.lowercased()
        let rules: [(MeetingMode, [String])] = [
            (.grooming, ["grooming", "refinement", "refinamento", "backlog", "story", "ticket", "jira", "acceptance criteria"]),
            (.planning, ["planning", "planejamento", "sprint plan", "roadmap", "quarterly"]),
            (.standup, ["standup", "stand-up", "daily", "diária"]),
            (.oneOnOne, ["1:1", "1-1", "one on one", "one-on-one"]),
            (.designReview, ["design review", "architecture", "arquitetura", "rfc", "tech review"]),
            (.interview, ["interview", "entrevista"]),
            (.client, ["client", "cliente", "customer", "demo", "proposal", "proposta", "sales"]),
        ]
        return rules.first { _, keywords in keywords.contains { t.contains($0) } }?.0 ?? .generic
    }
}
