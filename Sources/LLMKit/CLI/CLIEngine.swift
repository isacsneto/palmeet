import Foundation
import Synchronization

// MARK: - Job

/// One CLI call, after the request has been rendered into a temporary working directory.
struct CLIJob: Sendable, Equatable {
    /// Rendered conversation (without the system prompt).
    var prompt: String
    var system: String?
    /// `nil` lets the CLI pick its default model.
    var model: String?
    /// Absolute paths of images written into `workingDirectory`.
    var imageFiles: [URL]
    var workingDirectory: URL
    /// `combinedPrompt` written to disk, for CLIs that read long prompts from a file.
    var promptFile: URL

    /// System prompt and conversation in one text, for CLIs without a system-prompt flag.
    var combinedPrompt: String {
        guard let system, !system.isEmpty else { return prompt }
        return "<instructions>\n\(system)\n</instructions>\n\n\(prompt)"
    }
}

/// Owns the per-call temporary directory: images are copied in so read-only tools confined to it can see them.
struct CLIWorkspace: Sendable {
    let directory: URL
    let job: CLIJob

    static var defaultRoot: URL { FileManager.default.temporaryDirectory.appending(path: "PalMeet-LLM", directoryHint: .isDirectory) }

    static func prepare(_ request: LLMRequest, model: String?, root: URL = defaultRoot) throws -> CLIWorkspace {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var imageFiles: [URL] = []
            let prompt = try CLIPromptRenderer.render(request) { data, fileExtension in
                let url = directory.appending(path: String(format: "image-%02d.%@", imageFiles.count + 1, fileExtension))
                try data.write(to: url)
                imageFiles.append(url)
                return url
            }
            let promptFile = directory.appending(path: "prompt.md")
            var job = CLIJob(
                prompt: prompt,
                system: request.system,
                model: model,
                imageFiles: imageFiles,
                workingDirectory: directory,
                promptFile: promptFile
            )
            try Data(job.combinedPrompt.utf8).write(to: promptFile)
            job.promptFile = promptFile
            return CLIWorkspace(directory: directory, job: job)
        } catch let error as LLMError {
            try? FileManager.default.removeItem(at: directory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw LLMError.invalidResponse("Could not prepare CLI working directory: \(error.localizedDescription)")
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Flattens a chat request into a single prompt for one-shot CLIs.
enum CLIPromptRenderer {
    /// - Parameter storeImage: writes image bytes and returns the file's URL.
    static func render(_ request: LLMRequest, storeImage: (Data, String) throws -> URL) throws -> String {
        var sections: [String] = []
        var imageCount = 0
        let multiTurn = request.messages.count > 1

        for message in request.messages {
            var pieces: [String] = []
            for part in message.parts {
                switch part {
                case .text(let text):
                    pieces.append(text)
                case .image(let data, let mediaType):
                    let image = ImageResolver.resolve(data: data, mediaType: mediaType)
                    let url = try storeImage(image.data, ImageResolver.fileExtension(forMediaType: image.mediaType))
                    imageCount += 1
                    pieces.append("[Image: \(url.path)]")
                case .imageFile(let source):
                    let image = try ImageResolver.resolve(file: source)
                    let url = try storeImage(image.data, ImageResolver.fileExtension(forMediaType: image.mediaType))
                    imageCount += 1
                    pieces.append("[Image: \(url.path)]")
                }
            }
            let body = pieces.joined(separator: "\n\n")
            if multiTurn {
                sections.append("\(message.role == .user ? "User" : "Assistant"):\n\(body)")
            } else {
                sections.append(body)
            }
        }

        if imageCount > 0 {
            sections.append("The [Image: …] references above are image files. Open each one with your file-reading tool to look at it before answering. Do not modify any files.")
        }
        if multiTurn {
            sections.append("Reply as the assistant to the last user message.")
        }
        if request.responseFormat == .json {
            sections.append(PromptSnippets.jsonOnly)
        }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Dialect

/// The CLI-specific parts of a provider: arguments, stdin, output parsing and login detection.
/// Kept free of I/O (except `checkLogin`) so it can be unit-tested.
protocol CLIDialect: Sendable {
    associatedtype StreamParser: CLIStreamParser

    var kind: LLMProviderKind { get }
    var binaryNames: [String] { get }
    var loginHint: String { get }
    /// Whether `stream` uses a native streaming output format; otherwise the full result is yielded once.
    var supportsStreaming: Bool { get }

    func arguments(for job: CLIJob, streaming: Bool) -> [String]
    func standardInput(for job: CLIJob) -> String?
    func parseOutput(_ stdout: String) throws -> LLMResponse
    func makeStreamParser() -> StreamParser
    func isAuthFailure(_ output: String) -> Bool
    /// Cheap, free login check. Never sends a prompt.
    func checkLogin(binary: URL, environment: [String: String]) async -> LLMAvailability
}

/// Incremental parser for a CLI's line-delimited streaming output.
protocol CLIStreamParser: Sendable {
    /// Returns text deltas found on `line`; throws `CLIReportedError` when the CLI reports a failure.
    mutating func consume(line: String) throws -> [String]
    /// Called after the process exits; returns any text that should still be emitted.
    mutating func finish() throws -> [String]
}

/// A failure reported inside the CLI's own output (e.g. `"is_error": true`).
struct CLIReportedError: Error, Equatable {
    var message: String
}

/// Parses one JSON object per line, ignoring blank/non-JSON lines.
enum JSONLines {
    static func object(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    static func objects(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { object(String($0)) }
    }

    /// Whole-output JSON object, falling back to the last JSON line, then to an embedded object.
    static func document(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] { return object }
        if let last = objects(trimmed).last { return last }
        if let data = JSONExtraction.extractObject(from: trimmed) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

extension CLIDialect {
    func standardInput(for job: CLIJob) -> String? { job.combinedPrompt }

    func isAuthFailure(_ output: String) -> Bool {
        CLIAuthPatterns.matches(output, extra: [])
    }
}

enum CLIAuthPatterns {
    static let common = [
        "not logged in", "not authenticated", "please log in", "please login", "log in again",
        "login required", "/login", "unauthorized", "authentication failed", "authentication required",
        "invalid api key", "invalid_api_key", "oauth token", "token has expired", "token expired",
    ]

    static func matches(_ output: String, extra: [String]) -> Bool {
        let lowered = output.lowercased()
        return (common + extra).contains { lowered.contains($0) }
    }
}

/// Stream parser for CLIs without incremental output.
struct NoStreamParser: CLIStreamParser {
    mutating func consume(line: String) throws -> [String] { [] }
    mutating func finish() throws -> [String] { [] }
}

// MARK: - Engine

/// Runs a dialect's CLI: locate, prepare workspace, spawn, parse, map errors.
struct CLIEngine<Dialect: CLIDialect>: Sendable {
    let dialect: Dialect
    let config: LLMProviderConfig
    let locator: CLILocator
    let workspaceRoot: URL

    init(dialect: Dialect, config: LLMProviderConfig, locator: CLILocator, workspaceRoot: URL = CLIWorkspace.defaultRoot) {
        self.dialect = dialect
        self.config = config
        self.locator = locator
        self.workspaceRoot = workspaceRoot
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await withInvocation(for: request, streaming: false) { invocation in
            let output = try await ProcessRunner.run(invocation, timeout: request.timeout)
            return try interpret(output)
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if dialect.supportsStreaming {
                        try await runStreaming(request) { continuation.yield($0) }
                    } else {
                        continuation.yield(try await complete(request).text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? LLMError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func checkAvailability() async -> LLMAvailability {
        guard let binary = await locator.locate(dialect.binaryNames, explicitPath: config.cliPath) else {
            return .notInstalled
        }
        return await dialect.checkLogin(binary: binary, environment: await locator.environment(for: binary))
    }

    // MARK: Internals

    private func runStreaming(_ request: LLMRequest, yield: @escaping @Sendable (String) -> Void) async throws {
        try await withInvocation(for: request, streaming: true) { invocation in
            let parser = LockedStreamParser(dialect.makeStreamParser())
            let output = try await ProcessRunner.run(invocation, timeout: request.timeout) { line in
                parser.consume(line).forEach(yield)
            }
            let (tail, reported, emittedText) = parser.finish()
            tail.forEach(yield)
            if let reported {
                throw failure(output, reported: reported.message)
            }
            if output.exitCode != 0, !emittedText {
                throw failure(output, reported: nil)
            }
        }
    }

    private func withInvocation<T: Sendable>(
        for request: LLMRequest,
        streaming: Bool,
        _ body: (CLIInvocation) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard let binary = await locator.locate(dialect.binaryNames, explicitPath: config.cliPath) else {
            throw LLMError.notInstalled(dialect.kind)
        }
        let environment = await locator.environment(for: binary)
        let model = request.model.flatMap { $0.isEmpty ? nil : $0 } ?? (config.model.isEmpty ? nil : config.model)
        let workspace = try CLIWorkspace.prepare(request, model: model, root: workspaceRoot)
        defer { workspace.cleanUp() }

        let invocation = CLIInvocation(
            executable: binary,
            arguments: dialect.arguments(for: workspace.job, streaming: streaming),
            standardInput: dialect.standardInput(for: workspace.job).map { Data($0.utf8) },
            workingDirectory: workspace.directory,
            environment: environment
        )
        return try await body(invocation)
    }

    func interpret(_ output: ProcessOutput) throws -> LLMResponse {
        do {
            let response = try dialect.parseOutput(output.stdoutText)
            if output.exitCode == 0 || !response.text.isEmpty { return response }
            throw failure(output, reported: nil)
        } catch let reported as CLIReportedError {
            throw failure(output, reported: reported.message)
        } catch let error as LLMError {
            if output.exitCode != 0 { throw failure(output, reported: nil) }
            throw error
        }
    }

    /// Maps a failed run to `notLoggedIn` when the output looks like an auth problem, else `process`.
    func failure(_ output: ProcessOutput, reported: String?) -> LLMError {
        let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutTail = String(output.stdoutText.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = [reported, stderr, stdoutTail].compactMap { $0 }.joined(separator: "\n")
        if dialect.isAuthFailure(diagnostic) {
            return .notLoggedIn(dialect.kind, hint: dialect.loginHint)
        }
        let detail = reported ?? (stderr.isEmpty ? stdoutTail : stderr)
        return .process(exitCode: output.exitCode, stderr: detail.isEmpty ? "no output" : detail)
    }
}

/// Lets the `@Sendable` stdout-line callback drive a mutable stream parser.
private final class LockedStreamParser<Parser: CLIStreamParser>: Sendable {
    private struct State {
        var parser: Parser
        var reported: CLIReportedError?
        var emittedText = false
    }

    private let state: Mutex<State>

    init(_ parser: Parser) {
        state = Mutex(State(parser: parser))
    }

    func consume(_ line: String) -> [String] {
        state.withLock { state in
            guard state.reported == nil else { return [] }
            do {
                let texts = try state.parser.consume(line: line).filter { !$0.isEmpty }
                if !texts.isEmpty { state.emittedText = true }
                return texts
            } catch let error as CLIReportedError {
                state.reported = error
                return []
            } catch {
                state.reported = CLIReportedError(message: "\(error)")
                return []
            }
        }
    }

    func finish() -> (texts: [String], reported: CLIReportedError?, emittedText: Bool) {
        state.withLock { state in
            guard state.reported == nil else { return ([], state.reported, state.emittedText) }
            do {
                let texts = try state.parser.finish().filter { !$0.isEmpty }
                if !texts.isEmpty { state.emittedText = true }
                return (texts, nil, state.emittedText)
            } catch let error as CLIReportedError {
                return ([], error, state.emittedText)
            } catch {
                return ([], CLIReportedError(message: "\(error)"), state.emittedText)
            }
        }
    }
}

/// Runs a short, free helper command (e.g. `--version`, `auth status`) for availability checks.
enum CLIProbe {
    static func run(_ binary: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 15) async -> ProcessOutput? {
        let invocation = CLIInvocation(
            executable: binary,
            arguments: arguments,
            standardInput: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: environment
        )
        return try? await ProcessRunner.run(invocation, timeout: timeout)
    }
}
