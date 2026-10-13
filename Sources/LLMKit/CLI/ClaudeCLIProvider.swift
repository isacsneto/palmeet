import Foundation

/// Claude Code (`claude -p`) using the user's existing Claude login.
public struct ClaudeCLIProvider: LLMProvider {
    public let config: LLMProviderConfig
    let engine: CLIEngine<ClaudeCLIDialect>

    public var kind: LLMProviderKind { .claudeCLI }
    public var capabilities: LLMCapabilities { [.images, .streaming] }
    public var isSlow: Bool { true }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .claudeCLI), locator: CLILocator = .shared) {
        self.config = config
        self.engine = CLIEngine(dialect: ClaudeCLIDialect(), config: config, locator: locator)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse { try await engine.complete(request) }
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> { engine.stream(request) }
    public func checkAvailability() async -> LLMAvailability { await engine.checkAvailability() }
}

/// Flags verified against `claude --help` (Claude Code 2.1.x).
struct ClaudeCLIDialect: CLIDialect {
    /// Replaces Claude Code's agentic default system prompt when the request has none.
    static let defaultSystemPrompt = "You are a helpful assistant. Follow the user's instructions exactly and reply with only the requested output."
    /// Longer system prompts go through stdin instead of argv.
    static let maxArgumentLength = 100_000

    var kind: LLMProviderKind { .claudeCLI }
    var binaryNames: [String] { ["claude"] }
    var loginHint: String { "Run `claude` in Terminal and log in." }
    var supportsStreaming: Bool { true }

    func arguments(for job: CLIJob, streaming: Bool) -> [String] {
        var args = ["-p", "--output-format", streaming ? "stream-json" : "json"]
        if streaming { args += ["--verbose", "--include-partial-messages"] }
        if let model = job.model, !model.isEmpty { args += ["--model", model] }
        if job.imageFiles.isEmpty {
            args += ["--tools", ""]
        } else {
            args += ["--tools", "Read", "--allowedTools", "Read"]
        }
        args += [
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--system-prompt", systemPromptArgument(for: job),
        ]
        return args
    }

    func standardInput(for job: CLIJob) -> String? {
        systemFitsInArguments(job) ? job.prompt : job.combinedPrompt
    }

    private func systemFitsInArguments(_ job: CLIJob) -> Bool {
        (job.system?.utf8.count ?? 0) <= Self.maxArgumentLength
    }

    private func systemPromptArgument(for job: CLIJob) -> String {
        guard let system = job.system, !system.isEmpty, systemFitsInArguments(job) else { return Self.defaultSystemPrompt }
        return system
    }

    func parseOutput(_ stdout: String) throws -> LLMResponse {
        guard let object = JSONLines.document(stdout) else {
            throw LLMError.invalidResponse("claude: output was not JSON: \(stdout.prefix(300))")
        }
        return try Self.response(fromResult: object)
    }

    /// Interprets a `{"type":"result", ...}` object (the `json` output, or the last `stream-json` line).
    static func response(fromResult object: [String: Any]) throws -> LLMResponse {
        let text = object["result"] as? String
        if object["is_error"] as? Bool == true {
            let subtype = object["subtype"] as? String
            throw CLIReportedError(message: text ?? subtype ?? "claude reported an error")
        }
        guard let text else {
            throw LLMError.invalidResponse("claude: JSON had no \"result\" field")
        }

        var usage: LLMUsage?
        if let raw = object["usage"] as? [String: Any] {
            usage = LLMUsage(
                inputTokens: JSONLines.int(raw["input_tokens"]) + JSONLines.int(raw["cache_creation_input_tokens"]),
                outputTokens: JSONLines.int(raw["output_tokens"]),
                cacheReadTokens: JSONLines.int(raw["cache_read_input_tokens"])
            )
        }
        // The model that produced most output (subagents/fallbacks can add entries).
        let model = (object["modelUsage"] as? [String: Any])?
            .max { JSONLines.int(($0.value as? [String: Any])?["outputTokens"]) < JSONLines.int(($1.value as? [String: Any])?["outputTokens"]) }?
            .key
        return LLMResponse(text: text, model: model, usage: usage)
    }

    func makeStreamParser() -> StreamParser { StreamParser() }

    /// Parses `--output-format stream-json --verbose --include-partial-messages`.
    struct StreamParser: CLIStreamParser {
        private var sawPartialEvents = false
        private var emitted = false

        mutating func consume(line: String) throws -> [String] {
            guard let object = JSONLines.object(line) else { return [] }
            switch object["type"] as? String {
            case "stream_event":
                sawPartialEvents = true
                guard let event = object["event"] as? [String: Any],
                      event["type"] as? String == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String
                else { return [] }
                emitted = true
                return [text]
            case "assistant" where !sawPartialEvents:
                // Older CLIs without partial messages: emit whole assistant messages.
                let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                if !texts.isEmpty { emitted = true }
                return texts
            case "result":
                let response = try ClaudeCLIDialect.response(fromResult: object)
                return emitted ? [] : [response.text]
            default:
                return []
            }
        }

        mutating func finish() throws -> [String] { [] }
    }

    func isAuthFailure(_ output: String) -> Bool {
        CLIAuthPatterns.matches(output, extra: ["run /login", "claude login", "credit balance is too low"])
    }

    func checkLogin(binary: URL, environment: [String: String]) async -> LLMAvailability {
        if let output = await CLIProbe.run(binary, ["auth", "status", "--json"], environment: environment),
           let status = JSONLines.document(output.stdoutText),
           let loggedIn = status["loggedIn"] as? Bool {
            return loggedIn ? .ready : .notLoggedIn(hint: loginHint)
        }
        // Older CLIs without `auth status`: an installed, runnable binary is the best free signal.
        guard let version = await CLIProbe.run(binary, ["--version"], environment: environment) else {
            return .error("claude did not respond to --version.")
        }
        return version.exitCode == 0 ? .ready : .error("claude --version failed: \(version.stderrText.prefix(200))")
    }
}
