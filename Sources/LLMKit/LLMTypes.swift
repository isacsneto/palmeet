import Foundation

// MARK: - Provider identity

/// Every way PalMeet can reach a model: HTTP APIs with a key, or CLIs that reuse the user's local login.
public enum LLMProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropicAPI
    case openAIAPI
    case geminiAPI
    case claudeCLI
    case codexCLI
    case geminiCLI
    case cursorCLI
    /// Any OpenAI-compatible local server (Ollama, LM Studio).
    case localOpenAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropicAPI: "Claude (API key)"
        case .openAIAPI: "OpenAI (API key)"
        case .geminiAPI: "Gemini (API key)"
        case .claudeCLI: "Claude Code (local login)"
        case .codexCLI: "Codex CLI (ChatGPT login)"
        case .geminiCLI: "Gemini CLI (Google login)"
        case .cursorCLI: "Cursor Agent (Cursor login)"
        case .localOpenAICompatible: "Local model (Ollama / LM Studio)"
        }
    }

    public var isCLI: Bool {
        switch self {
        case .claudeCLI, .codexCLI, .geminiCLI, .cursorCLI: true
        default: false
        }
    }

    public var needsAPIKey: Bool {
        switch self {
        case .anthropicAPI, .openAIAPI, .geminiAPI: true
        default: false
        }
    }

    /// Keychain account name for the provider's API key.
    public var secretAccount: String { "apikey.\(rawValue)" }

    /// Model used for summaries when the user has not picked one.
    public var defaultModel: String {
        switch self {
        case .anthropicAPI: "claude-sonnet-5-5"
        case .openAIAPI: "gpt-5"
        case .geminiAPI: "gemini-2.5-pro"
        case .claudeCLI: "sonnet"
        case .codexCLI: ""
        case .geminiCLI: ""
        case .cursorCLI: ""
        case .localOpenAICompatible: "llama3.1"
        }
    }

    /// Low-latency model used by the live copilot when the user has not picked one.
    public var defaultFastModel: String {
        switch self {
        case .anthropicAPI: "claude-haiku-5-5"
        case .openAIAPI: "gpt-5-mini"
        case .geminiAPI: "gemini-2.5-flash"
        case .claudeCLI: "haiku"
        default: defaultModel
        }
    }
}

public struct LLMCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let images = LLMCapabilities(rawValue: 1 << 0)
    public static let streaming = LLMCapabilities(rawValue: 1 << 1)
    public static let jsonMode = LLMCapabilities(rawValue: 1 << 2)
    public static let promptCaching = LLMCapabilities(rawValue: 1 << 3)
}

// MARK: - Requests

public enum LLMRole: String, Codable, Sendable {
    case user
    case assistant
}

public enum LLMContentPart: Sendable, Equatable {
    case text(String)
    /// Raw image bytes (JPEG/PNG). API providers send them inline; CLI providers write them to the sandbox dir.
    case image(data: Data, mediaType: String)
    /// Image already on disk. API providers read it; CLI providers reference the path.
    case imageFile(URL)
}

public struct LLMMessage: Sendable, Equatable {
    public var role: LLMRole
    public var parts: [LLMContentPart]

    public init(role: LLMRole, parts: [LLMContentPart]) {
        self.role = role
        self.parts = parts
    }

    public static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, parts: [.text(text)]) }
    public static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: .assistant, parts: [.text(text)]) }
}

public enum LLMResponseFormat: Sendable, Equatable {
    case text
    /// Ask for a single JSON object. Providers use native JSON mode when available, otherwise prompt instructions.
    case json
}

public struct LLMRequest: Sendable {
    public var system: String?
    public var messages: [LLMMessage]
    /// Overrides the provider's configured model. `nil` uses `LLMProviderConfig.model`.
    public var model: String?
    public var maxTokens: Int
    public var temperature: Double?
    public var responseFormat: LLMResponseFormat
    /// Hint that `system` is a stable prefix worth caching (Anthropic prompt caching).
    public var cacheSystemPrompt: Bool
    public var timeout: TimeInterval
    /// Live use (copilot): providers minimize hidden reasoning/thinking so tokens go to the visible answer.
    public var preferLowLatency: Bool

    public init(
        system: String? = nil,
        messages: [LLMMessage],
        model: String? = nil,
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat = .text,
        cacheSystemPrompt: Bool = false,
        timeout: TimeInterval = 300,
        preferLowLatency: Bool = false
    ) {
        self.system = system
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.cacheSystemPrompt = cacheSystemPrompt
        self.timeout = timeout
        self.preferLowLatency = preferLowLatency
    }
}

public struct LLMUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var model: String?
    public var usage: LLMUsage?

    public init(text: String, model: String? = nil, usage: LLMUsage? = nil) {
        self.text = text
        self.model = model
        self.usage = usage
    }
}

public enum LLMAvailability: Sendable, Equatable {
    case ready
    case missingAPIKey
    case notInstalled
    case notLoggedIn(hint: String)
    case error(String)

    public var isReady: Bool { self == .ready }

    public var userMessage: String {
        switch self {
        case .ready: "Ready"
        case .missingAPIKey: "Add an API key in Settings → AI Providers."
        case .notInstalled: "CLI not found on this Mac."
        case .notLoggedIn(let hint): hint
        case .error(let message): message
        }
    }
}

public enum LLMError: Error, LocalizedError, Sendable {
    case missingAPIKey(LLMProviderKind)
    case notInstalled(LLMProviderKind)
    case notLoggedIn(LLMProviderKind, hint: String)
    case http(status: Int, body: String)
    case invalidResponse(String)
    case process(exitCode: Int32, stderr: String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let kind): "\(kind.displayName): API key is missing."
        case .notInstalled(let kind): "\(kind.displayName): CLI is not installed or not on PATH."
        case .notLoggedIn(let kind, let hint): "\(kind.displayName): not logged in. \(hint)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(500))"
        case .invalidResponse(let detail): "Unexpected response: \(detail)"
        case .process(let code, let stderr): "CLI exited with code \(code): \(stderr.prefix(500))"
        case .timeout: "The request timed out."
        case .cancelled: "The request was cancelled."
        }
    }
}

// MARK: - Provider protocol

public protocol LLMProvider: Sendable {
    var kind: LLMProviderKind { get }
    var capabilities: LLMCapabilities { get }
    /// CLI providers pay process start-up cost on every call; the UI labels them "slower".
    var isSlow: Bool { get }

    func complete(_ request: LLMRequest) async throws -> LLMResponse
    /// Streams text deltas. Providers without native streaming yield the full completion once.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
    func checkAvailability() async -> LLMAvailability
}

/// User-facing configuration for one provider, persisted in settings (never contains secrets).
public struct LLMProviderConfig: Codable, Sendable, Equatable, Hashable {
    public var kind: LLMProviderKind
    /// Model for summaries and quality work. Empty means "CLI default".
    public var model: String
    /// Model for the live copilot.
    public var fastModel: String
    /// Override for API base URL (OpenAI-compatible local servers, proxies).
    public var baseURL: String?
    /// Explicit CLI path; `nil` means auto-detect.
    public var cliPath: String?

    public init(kind: LLMProviderKind, model: String? = nil, fastModel: String? = nil, baseURL: String? = nil, cliPath: String? = nil) {
        self.kind = kind
        self.model = model ?? kind.defaultModel
        self.fastModel = fastModel ?? kind.defaultFastModel
        self.baseURL = baseURL
        self.cliPath = cliPath
    }
}

/// Where API keys live. Production uses the Keychain; tests use an in-memory store.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(for account: String) throws
}
