import Foundation

/// Cursor Agent CLI (`cursor-agent -p`, newer installs name it `agent`) using the user's Cursor login.
public struct CursorCLIProvider: LLMProvider {
    public let config: LLMProviderConfig
    let engine: CLIEngine<CursorCLIDialect>

    public var kind: LLMProviderKind { .cursorCLI }
    public var capabilities: LLMCapabilities { [.images, .streaming] }
    public var isSlow: Bool { true }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .cursorCLI), locator: CLILocator = .shared) {
        self.config = config
        self.engine = CLIEngine(dialect: CursorCLIDialect(), config: config, locator: locator)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse { try await engine.complete(request) }
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> { engine.stream(request) }
    public func checkAvailability() async -> LLMAvailability { await engine.checkAvailability() }
}

/// Flags per cursor.com/docs/cli/reference/parameters and .../output-format:
/// `-p/--print`, `--output-format json|stream-json`, `--model`, `--mode ask` (read-only),
/// `--trust` (headless workspace trust), `--workspace`. The prompt is a positional argument.
struct CursorCLIDialect: CLIDialect {
    /// Prompts longer than this are written to `prompt.md` and referenced instead of passed in argv.
    static let maxArgumentLength = 100_000
    static let filePrompt = "Read the file prompt.md in the current working directory and follow the instructions in it exactly. Reply with only the requested output and do not modify any files."

    var kind: LLMProviderKind { .cursorCLI }
    var binaryNames: [String] { ["cursor-agent", "agent"] }
    var loginHint: String { "Run `cursor-agent login` (or `agent login`) in Terminal." }
    var supportsStreaming: Bool { true }

    func arguments(for job: CLIJob, streaming: Bool) -> [String] {
        var args = [
            "-p",
            "--output-format", streaming ? "stream-json" : "json",
            "--mode", "ask",
            "--trust",
            "--workspace", job.workingDirectory.path,
        ]
        if let model = job.model, !model.isEmpty { args += ["--model", model] }
        args.append(promptArgument(for: job))
        return args
    }

    func promptArgument(for job: CLIJob) -> String {
        let prompt = job.combinedPrompt
        guard prompt.utf8.count <= Self.maxArgumentLength else { return Self.filePrompt }
        // A leading "-" would be parsed as an option.
        return prompt.hasPrefix("-") ? " " + prompt : prompt
    }

    func standardInput(for job: CLIJob) -> String? { nil }

    func parseOutput(_ stdout: String) throws -> LLMResponse {
        let objects = JSONLines.objects(stdout)
        guard let object = objects.last(where: { $0["type"] as? String == "result" }) ?? JSONLines.document(stdout) else {
            throw LLMError.invalidResponse("cursor-agent: output was not JSON: \(stdout.prefix(300))")
        }
        return try Self.response(fromResult: object)
    }

    static func response(fromResult object: [String: Any]) throws -> LLMResponse {
        let text = object["result"] as? String
        if object["is_error"] as? Bool == true {
            throw CLIReportedError(message: text ?? (object["subtype"] as? String) ?? "cursor-agent reported an error")
        }
        guard let text else { throw LLMError.invalidResponse("cursor-agent: JSON had no \"result\" field") }
        return LLMResponse(text: text, model: object["model"] as? String, usage: nil)
    }

    func makeStreamParser() -> StreamParser { StreamParser() }

    /// Parses `--output-format stream-json`: whole assistant messages, then a final `result`.
    struct StreamParser: CLIStreamParser {
        private var emitted = false

        mutating func consume(line: String) throws -> [String] {
            guard let object = JSONLines.object(line) else { return [] }
            switch object["type"] as? String {
            case "assistant":
                let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                if !texts.isEmpty { emitted = true }
                return texts
            case "result":
                let response = try CursorCLIDialect.response(fromResult: object)
                return emitted ? [] : [response.text]
            default:
                return []
            }
        }

        mutating func finish() throws -> [String] { [] }
    }

    func isAuthFailure(_ output: String) -> Bool {
        CLIAuthPatterns.matches(output, extra: ["cursor-agent login", "agent login", "cursor_api_key"])
    }

    func checkLogin(binary: URL, environment: [String: String]) async -> LLMAvailability {
        guard let output = await CLIProbe.run(binary, ["status"], environment: environment) else {
            return .error("\(binary.lastPathComponent) did not respond to `status`.")
        }
        let text = output.stdoutText + "\n" + output.stderrText
        if output.exitCode != 0 || isAuthFailure(text) { return .notLoggedIn(hint: loginHint) }
        return .ready
    }
}
