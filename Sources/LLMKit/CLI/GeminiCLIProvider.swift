import Foundation

/// Google Gemini CLI (`gemini -p`) using the user's Google login.
public struct GeminiCLIProvider: LLMProvider {
    public let config: LLMProviderConfig
    let engine: CLIEngine<GeminiCLIDialect>

    public var kind: LLMProviderKind { .geminiCLI }
    public var capabilities: LLMCapabilities { [.images] }
    public var isSlow: Bool { true }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .geminiCLI), locator: CLILocator = .shared) {
        self.config = config
        self.engine = CLIEngine(dialect: GeminiCLIDialect(), config: config, locator: locator)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse { try await engine.complete(request) }
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> { engine.stream(request) }
    public func checkAvailability() async -> LLMAvailability { await engine.checkAvailability() }
}

/// Flags per google-gemini/gemini-cli docs (docs/cli/headless.md, docs/cli/cli-reference.md):
/// `-p/--prompt` (appended to stdin input, forces headless), `--output-format json`, `-m/--model`.
/// Headless runs without `--approval-mode yolo` exclude shell/edit/write tools, so it is read-only.
struct GeminiCLIDialect: CLIDialect {
    /// The full prompt goes through stdin; `--prompt` is appended to it.
    static let promptSuffix = "Follow the instructions above and reply with only the requested output."

    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var kind: LLMProviderKind { .geminiCLI }
    var binaryNames: [String] { ["gemini"] }
    var loginHint: String { "Run `gemini` in Terminal and sign in with Google." }
    var supportsStreaming: Bool { false }

    func arguments(for job: CLIJob, streaming: Bool) -> [String] {
        var args = ["--output-format", "json"]
        if let model = job.model, !model.isEmpty { args += ["--model", model] }
        args += ["--prompt", Self.promptSuffix]
        return args
    }

    func parseOutput(_ stdout: String) throws -> LLMResponse {
        guard let object = JSONLines.document(stdout) else {
            throw LLMError.invalidResponse("gemini: output was not JSON: \(stdout.prefix(300))")
        }
        if let error = object["error"] as? [String: Any] {
            throw CLIReportedError(message: (error["message"] as? String) ?? (error["type"] as? String) ?? "gemini reported an error")
        }
        guard let text = object["response"] as? String else {
            throw LLMError.invalidResponse("gemini: JSON had no \"response\" field")
        }

        // stats.models.<name>.tokens.{prompt,candidates,cached}
        var usage: LLMUsage?
        var model: String?
        if let models = (object["stats"] as? [String: Any])?["models"] as? [String: Any], !models.isEmpty {
            var total = LLMUsage()
            var mostOutput = -1
            for (name, value) in models {
                let tokens = (value as? [String: Any])?["tokens"] as? [String: Any] ?? [:]
                let cached = JSONLines.int(tokens["cached"])
                let output = JSONLines.int(tokens["candidates"])
                total.inputTokens += max(0, JSONLines.int(tokens["prompt"]) - cached)
                total.outputTokens += output
                total.cacheReadTokens += cached
                if output > mostOutput { mostOutput = output; model = name }
            }
            usage = total
        }
        return LLMResponse(text: text, model: model, usage: usage)
    }

    func makeStreamParser() -> NoStreamParser { NoStreamParser() }

    func isAuthFailure(_ output: String) -> Bool {
        CLIAuthPatterns.matches(output, extra: ["auth method", "gemini_api_key", "login with google", "credentials"])
    }

    /// The CLI has no free status command; look for stored OAuth credentials or API-key configuration.
    func checkLogin(binary: URL, environment: [String: String]) async -> LLMAvailability {
        let keys = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_CLOUD_PROJECT"]
        if keys.contains(where: { !(environment[$0] ?? "").isEmpty }) { return .ready }
        let geminiDirectory = home.appending(path: ".gemini")
        let markers = ["oauth_creds.json", "google_accounts.json", ".env"]
        if markers.contains(where: { FileManager.default.fileExists(atPath: geminiDirectory.appending(path: $0).path) }) {
            return .ready
        }
        if let settings = try? Data(contentsOf: geminiDirectory.appending(path: "settings.json")),
           String(decoding: settings, as: UTF8.self).contains("selectedType") {
            return .ready
        }
        return .notLoggedIn(hint: loginHint)
    }
}
