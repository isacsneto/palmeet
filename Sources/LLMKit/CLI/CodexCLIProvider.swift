import Foundation

/// OpenAI Codex CLI (`codex exec`) using the user's ChatGPT login.
public struct CodexCLIProvider: LLMProvider {
    public let config: LLMProviderConfig
    let engine: CLIEngine<CodexCLIDialect>

    public var kind: LLMProviderKind { .codexCLI }
    public var capabilities: LLMCapabilities { [.images, .streaming] }
    public var isSlow: Bool { true }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .codexCLI), locator: CLILocator = .shared) {
        self.config = config
        self.engine = CLIEngine(dialect: CodexCLIDialect(), config: config, locator: locator)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse { try await engine.complete(request) }
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> { engine.stream(request) }
    public func checkAvailability() async -> LLMAvailability { await engine.checkAvailability() }
}

/// Flags verified against `codex exec --help` (codex-cli 0.153) and the non-interactive docs
/// (learn.chatgpt.com/docs/non-interactive-mode): `--json` JSONL events, `--image`, `--sandbox read-only`,
/// `--skip-git-repo-check`, `--ephemeral`, `-m`, and `-` to read the whole prompt from stdin.
struct CodexCLIDialect: CLIDialect {
    var kind: LLMProviderKind { .codexCLI }
    var binaryNames: [String] { ["codex"] }
    var loginHint: String { "Run `codex login` in Terminal and sign in with ChatGPT." }
    var supportsStreaming: Bool { true }

    func arguments(for job: CLIJob, streaming: Bool) -> [String] {
        var args = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral"]
        if let model = job.model, !model.isEmpty { args += ["-m", model] }
        // `=` keeps each path a single value even though --image accepts several.
        args += job.imageFiles.map { "--image=\($0.path)" }
        args.append("-")
        return args
    }

    func parseOutput(_ stdout: String) throws -> LLMResponse {
        var parser = StreamParser()
        var messages: [String] = []
        for line in stdout.split(whereSeparator: \.isNewline) {
            messages += try parser.consume(line: String(line))
        }
        _ = try parser.finish()
        guard let last = messages.last else {
            if let error = parser.errors.last { throw CLIReportedError(message: error) }
            throw LLMError.invalidResponse("codex: no agent message in output: \(stdout.suffix(300))")
        }
        // Earlier agent messages are progress commentary; the final one is the answer.
        return LLMResponse(text: last, model: nil, usage: parser.usage)
    }

    func makeStreamParser() -> StreamParser { StreamParser() }

    /// Parses `codex exec --json` events. Each completed `agent_message` item is emitted whole.
    struct StreamParser: CLIStreamParser {
        private(set) var usage: LLMUsage?
        private(set) var errors: [String] = []
        private var emitted = false

        mutating func consume(line: String) throws -> [String] {
            guard let event = JSONLines.object(line) else { return [] }
            switch event["type"] as? String {
            case "item.completed":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let text = item["text"] as? String
                else { return [] }
                emitted = true
                return [text]
            case "turn.completed":
                if let raw = event["usage"] as? [String: Any] {
                    let cached = JSONLines.int(raw["cached_input_tokens"])
                    usage = LLMUsage(
                        inputTokens: max(0, JSONLines.int(raw["input_tokens"]) - cached),
                        outputTokens: JSONLines.int(raw["output_tokens"]),
                        cacheReadTokens: cached
                    )
                }
                return []
            case "turn.failed":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "codex turn failed"
                throw CLIReportedError(message: message)
            case "error":
                // May be transient (e.g. reconnecting); only fatal if no answer arrives.
                if let message = event["message"] as? String { errors.append(message) }
                return []
            default:
                // Legacy (pre-0.40) event shape: {"msg":{"type":"agent_message","message":"..."}}.
                if let msg = event["msg"] as? [String: Any], msg["type"] as? String == "agent_message",
                   let text = msg["message"] as? String {
                    emitted = true
                    return [text]
                }
                return []
            }
        }

        mutating func finish() throws -> [String] {
            if !emitted, let error = errors.last { throw CLIReportedError(message: error) }
            return []
        }
    }

    func isAuthFailure(_ output: String) -> Bool {
        CLIAuthPatterns.matches(output, extra: ["codex login", "401 unauthorized", "sign in with chatgpt"])
    }

    func checkLogin(binary: URL, environment: [String: String]) async -> LLMAvailability {
        // `codex login status` exits 0 when credentials are present.
        guard let output = await CLIProbe.run(binary, ["login", "status"], environment: environment) else {
            return .error("codex did not respond to `codex login status`.")
        }
        return output.exitCode == 0 ? .ready : .notLoggedIn(hint: loginHint)
    }
}
