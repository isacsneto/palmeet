import CopilotKit
import Foundation
import LLMKit

public enum MicRoutingMode: String, Codable, Sendable, CaseIterable {
    /// Mute state, mic usage and window focus decide where the mic goes.
    case auto
    /// Only the per-session toggles decide.
    case manual
}

public struct CopilotSettings: Codable, Sendable, Equatable {
    /// Meeting modes for which the copilot turns on by itself when a session starts. Empty by default.
    public var autoEnableModes: [MeetingMode] = []
    public var proactiveQuestions = true
    public var proactiveInterval: TimeInterval = 90
    public var maxCallsPerMinute = 6
    /// User-edited playbooks keyed by `MeetingMode.rawValue`.
    public var playbookOverrides: [String: String] = [:]

    public init() {}

    public func playbook(for mode: MeetingMode) -> String {
        playbookOverrides[mode.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? mode.defaultPlaybook
    }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    /// `NSWindow.sharingType = .none` on every PalMeet window.
    public var hideFromScreenCapture = true
    /// Hide PalMeet windows while a session reports that you are presenting/sharing.
    public var autoHideWhileSharing = true
    public var showDockIcon = true
    public var showMenuBarIcon = true
    /// Keep the parts of the mic recording that were routed to another meeting (off: they are silenced on stop).
    public var keepUnroutedMicAudio = false
    /// Delete audio files (keeping text) after this many days; nil keeps forever.
    public var deleteAudioAfterDays: Int?

    public init() {}
}

public struct WindowAppearance: Codable, Sendable, Equatable {
    /// Whole-window alpha (text included), 0.2...1.
    public var contentOpacity: Double = 1
    /// Background material/tint alpha, 0...1.
    public var backgroundOpacity: Double = 0.85
    public var clickThrough = false
    public var alwaysOnTop = true
    /// Fade to `fadedOpacity` when the mouse isn't over the window.
    public var autoFade = false
    public var fadedOpacity: Double = 0.35

    public init() {}
}

public enum AppWindowRole: String, Codable, Sendable, CaseIterable {
    case copilotPanel
    case hud
    case main

    public var displayName: String {
        switch self {
        case .copilotPanel: "Copilot panel"
        case .hud: "Recording HUD"
        case .main: "Main window"
        }
    }
}

public struct AppearanceSettings: Codable, Sendable, Equatable {
    public var windows: [String: WindowAppearance] = [:]
    public var fontScale: Double = 1

    public init() {}

    public subscript(role: AppWindowRole) -> WindowAppearance {
        get {
            if let stored = windows[role.rawValue] { return stored }
            var defaults = WindowAppearance()
            if role == .main { defaults.alwaysOnTop = false; defaults.backgroundOpacity = 1 }
            return defaults
        }
        set { windows[role.rawValue] = newValue }
    }
}

/// How a meeting's audio is kept after processing. The transcript, speakers and voices always come from the
/// original recording; this only affects listening and transcribing the meeting again later.
public enum AudioStorage: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The 16-bit recording as is.
    case original
    /// Apple Lossless: about half the size, identical audio.
    case lossless
    /// AAC 48 kbit/s: about 6× smaller. Transcribing again can differ slightly (≈3% of words on real meetings).
    case compressed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: "Original (largest)"
        case .lossless: "Lossless (≈2× smaller)"
        case .compressed: "Compressed (≈6× smaller)"
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var profile = UserProfile()
    /// Model choices per provider kind (keyed by `LLMProviderKind.rawValue`).
    public var providerConfigs: [String: LLMProviderConfig] = [:]
    public var summaryProvider: LLMProviderKind = .claudeCLI
    public var copilotProvider: LLMProviderKind = .anthropicAPI
    public var asrModel = "ultra"
    /// BCP-47 hint like "pt" or "en"; nil = auto.
    public var language: String?
    public var liveTranscription = true
    public var includeMicByDefault = true
    public var screenshotInterval: TimeInterval = 30
    public var screenshotChangeThreshold = 10
    public var maxConcurrentSessions = 3
    public var micRouting: MicRoutingMode = .auto
    public var copilot = CopilotSettings()
    public var privacy = PrivacySettings()
    public var appearance = AppearanceSettings()
    /// Custom vocabulary: names, product terms, acronyms.
    public var glossary: [String] = []
    /// After a meeting, the summary provider proofreads the transcript for misheard words (names, jargon).
    public var aiTranscriptCorrection = true
    /// Learn the voices of people you name and recognize them in later meetings (voiceprints stay on this Mac).
    public var recognizeVoices = true
    /// While a browser meeting is recorded, note which page elements change (helps PalMeet improve detecting
    /// who is speaking on new meeting-site layouts). Saved only in the session folder.
    public var meetingPageDiagnostics = true
    /// After a meeting, delete screenshots that repeat another one and save the rest smaller.
    public var compactScreenshots = true
    /// How a meeting's audio is kept once it has been transcribed and summarized.
    public var audioStorage: AudioStorage = .compressed
    public var storageRoot: String?
    public var hasCompletedOnboarding = false

    public init() {}

    public func providerConfig(_ kind: LLMProviderKind) -> LLMProviderConfig {
        providerConfigs[kind.rawValue] ?? LLMProviderConfig(kind: kind)
    }

    public mutating func setProviderConfig(_ config: LLMProviderConfig) {
        providerConfigs[config.kind.rawValue] = config
    }

    /// Tried in this order when the chosen provider doesn't work.
    public static let providerFallbackOrder: [LLMProviderKind] = [
        .claudeCLI, .anthropicAPI, .codexCLI, .openAIAPI, .geminiCLI, .geminiAPI, .cursorCLI, .localOpenAICompatible,
    ]

    /// The provider actually used when `preferred` is chosen: `preferred` itself unless it's known not to work
    /// (no API key, CLI missing or logged out); then the first provider known to work; then the other chosen
    /// provider if it hasn't been checked yet. When nothing works, `preferred`, so its error says what to set up.
    /// `ready` answers true/false, or nil when not checked yet.
    public func workingProvider(_ preferred: LLMProviderKind, ready: (LLMProviderKind) -> Bool?) -> LLMProviderKind {
        if ready(preferred) != false { return preferred }
        let chosen = [summaryProvider, copilotProvider]
        return (chosen + Self.providerFallbackOrder).first { ready($0) == true }
            ?? chosen.first { ready($0) == nil }
            ?? preferred
    }

    // Decoding tolerates missing keys so new settings never wipe a user's existing ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        profile = try c.decodeIfPresent(UserProfile.self, forKey: .profile) ?? d.profile
        providerConfigs = try c.decodeIfPresent([String: LLMProviderConfig].self, forKey: .providerConfigs) ?? d.providerConfigs
        summaryProvider = try c.decodeIfPresent(LLMProviderKind.self, forKey: .summaryProvider) ?? d.summaryProvider
        copilotProvider = try c.decodeIfPresent(LLMProviderKind.self, forKey: .copilotProvider) ?? d.copilotProvider
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? d.asrModel
        language = try c.decodeIfPresent(String.self, forKey: .language)
        liveTranscription = try c.decodeIfPresent(Bool.self, forKey: .liveTranscription) ?? d.liveTranscription
        includeMicByDefault = try c.decodeIfPresent(Bool.self, forKey: .includeMicByDefault) ?? d.includeMicByDefault
        screenshotInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .screenshotInterval) ?? d.screenshotInterval
        screenshotChangeThreshold = try c.decodeIfPresent(Int.self, forKey: .screenshotChangeThreshold) ?? d.screenshotChangeThreshold
        maxConcurrentSessions = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions) ?? d.maxConcurrentSessions
        micRouting = try c.decodeIfPresent(MicRoutingMode.self, forKey: .micRouting) ?? d.micRouting
        copilot = (try? c.decodeIfPresent(CopilotSettings.self, forKey: .copilot)) ?? d.copilot
        privacy = (try? c.decodeIfPresent(PrivacySettings.self, forKey: .privacy)) ?? d.privacy
        appearance = (try? c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance)) ?? d.appearance
        glossary = try c.decodeIfPresent([String].self, forKey: .glossary) ?? d.glossary
        aiTranscriptCorrection = try c.decodeIfPresent(Bool.self, forKey: .aiTranscriptCorrection) ?? d.aiTranscriptCorrection
        recognizeVoices = try c.decodeIfPresent(Bool.self, forKey: .recognizeVoices) ?? d.recognizeVoices
        meetingPageDiagnostics = try c.decodeIfPresent(Bool.self, forKey: .meetingPageDiagnostics) ?? d.meetingPageDiagnostics
        compactScreenshots = try c.decodeIfPresent(Bool.self, forKey: .compactScreenshots) ?? d.compactScreenshots
        audioStorage = (try? c.decodeIfPresent(AudioStorage.self, forKey: .audioStorage)) ?? d.audioStorage
        storageRoot = try c.decodeIfPresent(String.self, forKey: .storageRoot)
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }
}

/// Persists settings as JSON in UserDefaults. Secrets never go here (see `KeychainSecretStore`).
public struct SettingsStore: Sendable {
    private let key = "app.palmeet.settings.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Loads settings, overlaying what's stored onto the current defaults so that settings added in a newer
    /// version (at any nesting level) get their default instead of making the whole decode fail.
    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(AppSettings()),
              let base = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: Self.merge(base, stored)),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: merged)
        else { return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings() }
        return settings
    }

    static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = merge(baseNested, nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}
