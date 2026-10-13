import Foundation
import Synchronization
import Testing
@testable import LLMKit

// MARK: - Captured / documented sample outputs

/// Real output of `claude -p --output-format json --model haiku --tools ""` (Claude Code 2.1.296), trimmed.
private let claudeJSONSample = """
{"duration_api_ms":1223,"stop_reason":"end_turn","session_id":"8e46b26d-c17e-4775-8fe3-f7923c373672","total_cost_usd":0.00060995,"usage":{"input_tokens":2,"cache_creation_input_tokens":3012,"cache_read_input_tokens":535,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0},"service_tier":"standard"},"modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":535,"cacheCreationInputTokens":3012,"costUSD":0.00060995}},"permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"OK","type":"result","duration_ms":1342}
"""

private let claudeAuthErrorSample = """
{"type":"result","subtype":"success","is_error":true,"duration_ms":120,"num_turns":1,"result":"Not logged in · Please run /login","session_id":"x","total_cost_usd":0}
"""

private let claudeStreamSample = """
{"type":"system","subtype":"init","session_id":"s","tools":[],"model":"claude-haiku-5-5"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"m"}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}
{"type":"result","subtype":"success","is_error":false,"result":"Hello","usage":{"input_tokens":1,"output_tokens":2}}
"""

/// Real output of `codex exec --json --sandbox read-only --skip-git-repo-check --ephemeral -` (codex-cli 0.153).
private let codexRealSample = """
{"type":"thread.started","thread_id":"01a13697-5d9d-7af3-8dd3-7c078f6a6c09"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}
{"type":"turn.completed","usage":{"input_tokens":15448,"cached_input_tokens":2816,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}
"""

/// Event shapes from the Codex non-interactive docs.
private let codexJSONLSample = """
{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Reading the slide**"}}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Let me look."}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Final answer."}}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}
"""

private let geminiJSONSample = """
{
  "response": "The capital of France is Paris.",
  "stats": {
    "models": {
      "gemini-2.5-pro": {
        "api": {"totalRequests": 1, "totalErrors": 0, "totalLatencyMs": 3200},
        "tokens": {"prompt": 1200, "candidates": 15, "total": 1300, "cached": 200, "thoughts": 85, "tool": 0}
      },
      "gemini-2.5-flash": {
        "tokens": {"prompt": 100, "candidates": 2, "total": 102, "cached": 0}
      }
    },
    "tools": {"totalCalls": 0}
  }
}
"""

private let cursorJSONSample = """
{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"duration_api_ms":1234,"result":"Here is the answer.","session_id":"c6b62c6f-7ead-4fd6-9922-e952131177ff","request_id":"10e11780-df2f-45dc-a1ff-4540af32e9c0"}
"""

private let cursorStreamSample = """
{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp","session_id":"s","model":"Claude 4 Sonnet","permissionMode":"default"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"session_id":"s"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Part one. "}]},"session_id":"s"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Part two."}]},"session_id":"s"}
{"type":"result","subtype":"success","is_error":false,"result":"Part one. Part two.","session_id":"s"}
"""

private func streamTexts<P: CLIStreamParser>(_ parser: P, _ text: String) throws -> [String] {
    var parser = parser
    var texts: [String] = []
    for line in text.split(separator: "\n") { texts += try parser.consume(line: String(line)) }
    return texts + (try parser.finish())
}

// MARK: - Argument builders

@Suite struct CLIArgumentTests {
    @Test func claudeTextOnly() {
        let args = ClaudeCLIDialect().arguments(for: sampleJob(system: "Be brief.", model: "haiku"), streaming: false)
        #expect(args == [
            "-p", "--output-format", "json",
            "--model", "haiku",
            "--tools", "",
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--system-prompt", "Be brief.",
        ])
        #expect(ClaudeCLIDialect().standardInput(for: sampleJob(system: "Be brief.")) == "Hello")
    }

    @Test func claudeWithImagesAndStreaming() {
        let job = sampleJob(images: [URL(filePath: "/tmp/palmeet-job/image-01.png")])
        let args = ClaudeCLIDialect().arguments(for: job, streaming: true)
        #expect(Array(args.prefix(5)) == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
        #expect(args.contains("--allowedTools"))
        let tools = args.firstIndex(of: "--tools").map { args[$0 + 1] }
        #expect(tools == "Read")
        #expect(!args.contains("--model"))
        let system = args.firstIndex(of: "--system-prompt").map { args[$0 + 1] }
        #expect(system == ClaudeCLIDialect.defaultSystemPrompt)
    }

    @Test func claudeHugeSystemPromptGoesToStdin() {
        let system = String(repeating: "x", count: ClaudeCLIDialect.maxArgumentLength + 1)
        let job = sampleJob(system: system)
        let args = ClaudeCLIDialect().arguments(for: job, streaming: false)
        #expect(!args.contains(system))
        #expect(ClaudeCLIDialect().standardInput(for: job)?.contains(system) == true)
    }

    @Test func codex() {
        let images = [URL(filePath: "/tmp/a,b.png"), URL(filePath: "/tmp/c.jpg")]
        let args = CodexCLIDialect().arguments(for: sampleJob(images: images, model: "gpt-5"), streaming: false)
        #expect(args == [
            "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
            "-m", "gpt-5",
            "--image=/tmp/a,b.png", "--image=/tmp/c.jpg",
            "-",
        ])
        let stdin = CodexCLIDialect().standardInput(for: sampleJob(system: "Sys"))
        #expect(stdin == "<instructions>\nSys\n</instructions>\n\nHello")
    }

    @Test func gemini() {
        let args = GeminiCLIDialect().arguments(for: sampleJob(model: "gemini-2.5-flash"), streaming: true)
        #expect(args == ["--output-format", "json", "--model", "gemini-2.5-flash", "--prompt", GeminiCLIDialect.promptSuffix])
        #expect(GeminiCLIDialect().arguments(for: sampleJob(), streaming: false) == ["--output-format", "json", "--prompt", GeminiCLIDialect.promptSuffix])
        #expect(GeminiCLIDialect().standardInput(for: sampleJob()) == "Hello")
    }

    @Test func cursor() {
        let job = sampleJob(model: "sonnet-4", prompt: "-starts with dash")
        let args = CursorCLIDialect().arguments(for: job, streaming: false)
        #expect(args == [
            "-p", "--output-format", "json", "--mode", "ask", "--trust",
            "--workspace", "/tmp/palmeet-job",
            "--model", "sonnet-4",
            " -starts with dash",
        ])
        #expect(CursorCLIDialect().standardInput(for: job) == nil)
        #expect(CursorCLIDialect().arguments(for: sampleJob(), streaming: true)[2] == "stream-json")

        let huge = sampleJob(prompt: String(repeating: "y", count: CursorCLIDialect.maxArgumentLength + 1))
        #expect(CursorCLIDialect().arguments(for: huge, streaming: false).last == CursorCLIDialect.filePrompt)
    }
}

// MARK: - Output parsers

@Suite struct CLIOutputParserTests {
    @Test func claudeJSON() throws {
        let response = try ClaudeCLIDialect().parseOutput(claudeJSONSample)
        #expect(response.text == "OK")
        #expect(response.model == "claude-haiku-5-5")
        #expect(response.usage == LLMUsage(inputTokens: 3014, outputTokens: 4, cacheReadTokens: 535))
    }

    @Test func claudeAuthError() {
        #expect(throws: CLIReportedError(message: "Not logged in · Please run /login")) {
            try ClaudeCLIDialect().parseOutput(claudeAuthErrorSample)
        }
        #expect(ClaudeCLIDialect().isAuthFailure("Not logged in · Please run /login"))
        #expect(ClaudeCLIDialect().isAuthFailure("Invalid API key · Please run /login"))
        #expect(!ClaudeCLIDialect().isAuthFailure("Rate limit reached"))
    }

    @Test func claudeStream() throws {
        #expect(try streamTexts(ClaudeCLIDialect.StreamParser(), claudeStreamSample) == ["Hel", "lo"])
        // Without partial messages: whole assistant messages.
        let noPartials = claudeStreamSample.split(separator: "\n").filter { !$0.contains("stream_event") }.joined(separator: "\n")
        #expect(try streamTexts(ClaudeCLIDialect.StreamParser(), noPartials) == ["Hello"])
        // Only a result line: emit the result.
        let resultOnly = #"{"type":"result","is_error":false,"result":"Just this"}"#
        #expect(try streamTexts(ClaudeCLIDialect.StreamParser(), resultOnly) == ["Just this"])
        #expect(throws: CLIReportedError.self) { try streamTexts(ClaudeCLIDialect.StreamParser(), claudeAuthErrorSample) }
    }

    @Test func codexJSONL() throws {
        let real = try CodexCLIDialect().parseOutput(codexRealSample)
        #expect(real.text == "OK")
        #expect(real.usage == LLMUsage(inputTokens: 12632, outputTokens: 5, cacheReadTokens: 2816))

        let response = try CodexCLIDialect().parseOutput(codexJSONLSample)
        #expect(response.text == "Final answer.")
        #expect(response.usage == LLMUsage(inputTokens: 315, outputTokens: 122, cacheReadTokens: 24448))
        #expect(try streamTexts(CodexCLIDialect.StreamParser(), codexJSONLSample) == ["Let me look.", "Final answer."])
    }

    @Test func codexFailures() throws {
        let failed = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.failed","error":{"message":"stream error: unexpected status 401 Unauthorized"}}
        """
        #expect(throws: CLIReportedError.self) { try CodexCLIDialect().parseOutput(failed) }
        #expect(CodexCLIDialect().isAuthFailure("stream error: unexpected status 401 Unauthorized"))

        let errorOnly = #"{"type":"error","message":"model not supported"}"#
        #expect(throws: CLIReportedError(message: "model not supported")) { try CodexCLIDialect().parseOutput(errorOnly) }

        let legacy = #"{"id":"0","msg":{"type":"agent_message","message":"legacy answer"}}"#
        #expect(try CodexCLIDialect().parseOutput(legacy).text == "legacy answer")
    }

    @Test func geminiJSON() throws {
        let response = try GeminiCLIDialect().parseOutput("Loaded cached credentials.\n" + geminiJSONSample)
        #expect(response.text == "The capital of France is Paris.")
        #expect(response.model == "gemini-2.5-pro")
        #expect(response.usage == LLMUsage(inputTokens: 1100, outputTokens: 17, cacheReadTokens: 200))

        let error = #"{"error":{"type":"FatalAuthenticationError","message":"Please set an Auth method in your settings.json","code":41}}"#
        #expect(throws: CLIReportedError.self) { try GeminiCLIDialect().parseOutput(error) }
        #expect(GeminiCLIDialect().isAuthFailure("Please set an Auth method in your settings.json"))
    }

    @Test func cursorJSONAndStream() throws {
        #expect(try CursorCLIDialect().parseOutput(cursorJSONSample).text == "Here is the answer.")
        #expect(try streamTexts(CursorCLIDialect.StreamParser(), cursorStreamSample) == ["Part one. ", "Part two."])
        let error = #"{"type":"result","subtype":"error","is_error":true,"result":"Authentication required. Please run 'cursor-agent login'"}"#
        #expect(throws: CLIReportedError.self) { try CursorCLIDialect().parseOutput(error) }
        #expect(CursorCLIDialect().isAuthFailure("Authentication required. Please run 'cursor-agent login'"))
    }

    @Test func geminiLoginDetection() async throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let dialect = GeminiCLIDialect(home: home)
        let binary = URL(filePath: "/usr/bin/true")
        #expect(await dialect.checkLogin(binary: binary, environment: [:]) == .notLoggedIn(hint: dialect.loginHint))
        #expect(await dialect.checkLogin(binary: binary, environment: ["GEMINI_API_KEY": "k"]) == .ready)
        try FileManager.default.createDirectory(at: home.appending(path: ".gemini"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: ".gemini/oauth_creds.json"))
        #expect(await dialect.checkLogin(binary: binary, environment: [:]) == .ready)
    }
}

// MARK: - Prompt rendering / workspace

@Suite struct CLIWorkspaceTests {
    @Test func rendersImagesAndJSONInstruction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "shot.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: source)

        let request = LLMRequest(
            system: "Sys",
            messages: [LLMMessage(role: .user, parts: [.text("Look:"), .image(data: pngBytes, mediaType: "image/png"), .imageFile(source)])],
            responseFormat: .json
        )
        let workspace = try CLIWorkspace.prepare(request, model: "m", root: root)
        let job = workspace.job
        #expect(job.imageFiles.map(\.lastPathComponent) == ["image-01.png", "image-02.jpg"])
        #expect(job.imageFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(job.prompt.contains("[Image: \(job.imageFiles[0].path)]"))
        #expect(job.prompt.contains("single valid JSON object"))
        #expect(job.system == "Sys")
        #expect(try String(contentsOf: job.promptFile, encoding: .utf8) == job.combinedPrompt)

        workspace.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    }

    @Test func multiTurnTranscript() throws {
        let prompt = try CLIPromptRenderer.render(LLMRequest(messages: [.user("Q1"), .assistant("A1"), .user("Q2")])) { _, _ in
            Issue.record("no images expected")
            return URL(filePath: "/dev/null")
        }
        #expect(prompt.hasPrefix("User:\nQ1\n\nAssistant:\nA1\n\nUser:\nQ2"))
    }
}

// MARK: - Process runner

@Suite struct ProcessRunnerTests {
    @Test func pipesStdinThroughWithoutDeadlock() async throws {
        // Larger than a pipe buffer (64 KB) in both directions.
        let input = String(repeating: "abcdefghij\n", count: 50_000)
        let invocation = CLIInvocation(executable: URL(filePath: "/bin/cat"), arguments: [], standardInput: Data(input.utf8))
        let output = try await ProcessRunner.run(invocation, timeout: 20)
        #expect(output.exitCode == 0)
        #expect(output.stdout.count == input.utf8.count)
    }

    @Test func streamsLinesAndCapturesStderr() async throws {
        let invocation = CLIInvocation(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'one\\ntwo\\nthree'; echo oops >&2; exit 3"]
        )
        let lines = LineCollector()
        let output = try await ProcessRunner.run(invocation, timeout: 10) { lines.append($0) }
        #expect(output.exitCode == 3)
        #expect(output.stderrText == "oops\n")
        #expect(lines.lines == ["one", "two", "three"])
    }

    @Test func timeout() async throws {
        let invocation = CLIInvocation(executable: URL(filePath: "/bin/sleep"), arguments: ["30"])
        let start = Date()
        await #expect(throws: LLMError.self) { try await ProcessRunner.run(invocation, timeout: 0.5) }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func cancellationKillsStubbornProcess() async throws {
        // Ignores SIGTERM (inherited by the grandchild), so the runner must escalate to SIGKILL on the group.
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "pid")
        let invocation = CLIInvocation(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; wait"]
        )
        let start = Date()
        let task = Task { try await ProcessRunner.run(invocation, timeout: 60) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect((error as? LLMError).map { if case .cancelled = $0 { true } else { false } } == true)
        }
        #expect(Date().timeIntervalSince(start) < 15)
        let grandchild = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Allow launchd a moment to reap the killed (zombie) grandchild.
        for _ in 0..<20 where kill(grandchild, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(kill(grandchild, 0) != 0, "grandchild should have been killed with the process group")
    }

    @Test func missingExecutable() async {
        let invocation = CLIInvocation(executable: URL(filePath: "/nonexistent/binary"), arguments: [])
        await #expect(throws: LLMError.self) { try await ProcessRunner.run(invocation, timeout: 5) }
    }
}

private final class LineCollector: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func append(_ line: String) { storage.withLock { $0.append(line) } }
}

// MARK: - Locator

@Suite struct CLILocatorTests {
    @Test func findsBinaryInSearchDirectories() async throws {
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        // Not executable → skipped.
        try Data("x".utf8).write(to: first.appending(path: "fakecli"))
        let binary = try writeScript("echo hi", named: "fakecli", in: second)

        let locator = CLILocator(searchDirectories: [first, second], useLoginShell: false)
        #expect(await locator.locate(["fakecli"]) == binary)
        #expect(await locator.locate(["missing-cli"]) == nil)
        #expect(await locator.locate(["missing-cli", "fakecli"]) == binary)

        // Explicit path wins; a bad explicit path is "not found" rather than falling back.
        let explicit = try writeScript("echo explicit", named: "custom", in: first)
        #expect(await locator.locate(["fakecli"], explicitPath: explicit.path) == explicit)
        #expect(await locator.locate(["fakecli"], explicitPath: "/nope/fakecli") == nil)

        let environment = await locator.environment(for: binary)
        let path = try #require(environment["PATH"])
        #expect(path.hasPrefix(second.path + ":"))
        #expect(path.contains("/usr/bin"))
        #expect(environment["CLAUDECODE"] == nil)
    }

    @Test func defaultDirectoriesIncludeCommonLocations() {
        let home = URL(filePath: "/Users/someone")
        let paths = CLILocator.defaultSearchDirectories(home: home).map(\.path)
        #expect(paths.prefix(4) == ["/Users/someone/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Users/someone/.npm-global/bin"])
        #expect(paths.contains("/Users/someone/.bun/bin"))
    }
}

// MARK: - Engine end-to-end with fake CLIs

@Suite struct CLIEngineTests {
    /// A fake `claude` that records its argv/stdin and prints a canned result.
    private func fakeClaude(in directory: URL, output: String, exitCode: Int = 0) throws {
        let escaped = output.replacingOccurrences(of: "'", with: "'\\''")
        try writeScript("""
        printf '%s\\n' "$@" > "\(directory.path)/argv.txt"
        cat > "\(directory.path)/stdin.txt"
        pwd > "\(directory.path)/cwd.txt"
        printf '%s' '\(escaped)'
        exit \(exitCode)
        """, named: "claude", in: directory)
    }

    @Test func completeRunsFakeCLI() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fakeClaude(in: directory, output: claudeJSONSample)

        let provider = ClaudeCLIProvider(locator: CLILocator(searchDirectories: [directory], useLoginShell: false))
        let request = LLMRequest(
            system: "Be terse.",
            messages: [LLMMessage(role: .user, parts: [.text("Describe"), .image(data: pngBytes, mediaType: "image/png")])],
            timeout: 20
        )
        let response = try await provider.complete(request)
        #expect(response.text == "OK")

        let argv = try String(contentsOf: directory.appending(path: "argv.txt"), encoding: .utf8)
        #expect(argv.contains("--model\nsonnet\n"))
        #expect(argv.contains("--tools\nRead\n"))
        #expect(argv.contains("--system-prompt\nBe terse.\n"))
        let stdin = try String(contentsOf: directory.appending(path: "stdin.txt"), encoding: .utf8)
        #expect(stdin.contains("Describe"))
        #expect(stdin.contains("image-01.png"))
        // The per-call working directory is removed afterwards.
        let cwd = try String(contentsOf: directory.appending(path: "cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(cwd.contains("PalMeet-LLM"))
        #expect(!FileManager.default.fileExists(atPath: cwd))
    }

    @Test func authFailureMapsToNotLoggedIn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fakeClaude(in: directory, output: claudeAuthErrorSample, exitCode: 1)

        let provider = ClaudeCLIProvider(locator: CLILocator(searchDirectories: [directory], useLoginShell: false))
        do {
            _ = try await provider.complete(LLMRequest(messages: [.user("hi")], timeout: 20))
            Issue.record("expected notLoggedIn")
        } catch let LLMError.notLoggedIn(kind, hint) {
            #expect(kind == .claudeCLI)
            #expect(hint.contains("claude"))
        }
    }

    @Test func nonAuthFailureMapsToProcessError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeScript("cat > /dev/null; echo 'boom: model overloaded' >&2; exit 2", named: "codex", in: directory)

        let provider = CodexCLIProvider(locator: CLILocator(searchDirectories: [directory], useLoginShell: false))
        do {
            _ = try await provider.complete(LLMRequest(messages: [.user("hi")], timeout: 20))
            Issue.record("expected process error")
        } catch let LLMError.process(code, stderr) {
            #expect(code == 2)
            #expect(stderr.contains("boom"))
        }
    }

    @Test func streamsFakeClaude() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try fakeClaude(in: directory, output: claudeStreamSample)

        let provider = ClaudeCLIProvider(locator: CLILocator(searchDirectories: [directory], useLoginShell: false))
        let parts = try await collect(provider.stream(LLMRequest(messages: [.user("hi")], timeout: 20)))
        #expect(parts == ["Hel", "lo"])
    }

    @Test func nonStreamingDialectYieldsOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let escaped = geminiJSONSample.replacingOccurrences(of: "'", with: "'\\''")
        try writeScript("cat > /dev/null; printf '%s' '\(escaped)'", named: "gemini", in: directory)

        let provider = GeminiCLIProvider(locator: CLILocator(searchDirectories: [directory], useLoginShell: false))
        let parts = try await collect(provider.stream(LLMRequest(messages: [.user("hi")], timeout: 20)))
        #expect(parts == ["The capital of France is Paris."])
    }

    @Test func availability() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let locator = CLILocator(searchDirectories: [directory], useLoginShell: false)
        #expect(await CodexCLIProvider(locator: locator).checkAvailability() == .notInstalled)

        try writeScript(#"[ "$1 $2" = "login status" ] && exit 1; exit 0"#, named: "codex", in: directory)
        await locator.invalidate()
        if case .notLoggedIn = await CodexCLIProvider(locator: locator).checkAvailability() {} else {
            Issue.record("expected notLoggedIn")
        }

        try writeScript(#"echo '{"loggedIn": true, "authMethod": "claude.ai"}'"#, named: "claude", in: directory)
        #expect(await ClaudeCLIProvider(locator: locator).checkAvailability() == .ready)
        try writeScript(#"echo '{"loggedIn": false}'; exit 1"#, named: "claude", in: directory)
        #expect(await ClaudeCLIProvider(locator: locator).checkAvailability() == .notLoggedIn(hint: ClaudeCLIDialect().loginHint))

        let explicit = LLMProviderConfig(kind: .claudeCLI, cliPath: "/definitely/not/here/claude")
        #expect(await ClaudeCLIProvider(config: explicit, locator: locator).checkAvailability() == .notInstalled)
    }
}
