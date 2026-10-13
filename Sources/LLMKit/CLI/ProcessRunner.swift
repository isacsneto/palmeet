import Foundation
import Synchronization

/// Everything needed to spawn one CLI process.
struct CLIInvocation: Sendable, Equatable {
    var executable: URL
    var arguments: [String]
    var standardInput: Data?
    var workingDirectory: URL?
    var environment: [String: String]?
}

struct ProcessOutput: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a process to completion with stdin/stdout/stderr pumped concurrently (no pipe-buffer deadlock),
/// a timeout, and Swift task cancellation (SIGTERM, then SIGKILL after a grace period).
enum ProcessRunner {
    static let killGracePeriod: TimeInterval = 2

    /// - Parameter onStdoutLine: called for each complete stdout line, in order, as it arrives.
    /// - Returns: the output even for a non-zero exit code; throws `LLMError.timeout` / `.cancelled` when stopped.
    static func run(
        _ invocation: CLIInvocation,
        timeout: TimeInterval,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let execution = ProcessExecution(invocation: invocation, onStdoutLine: onStdoutLine)
        return try await withTaskCancellationHandler {
            try await execution.run(timeout: timeout)
        } onCancel: {
            execution.stop(.cancelled)
        }
    }
}

private final class ProcessExecution: Sendable {
    enum StopReason: Sendable { case timeout, cancelled }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var pendingLine = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var launched = false
        var exitCode: Int32?
        var stopReason: StopReason?
        var continuation: CheckedContinuation<ProcessOutput, Error>?
    }

    private let invocation: CLIInvocation
    private let onStdoutLine: (@Sendable (String) -> Void)?
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let state = Mutex(State())

    init(invocation: CLIInvocation, onStdoutLine: (@Sendable (String) -> Void)?) {
        self.invocation = invocation
        self.onStdoutLine = onStdoutLine
    }

    func run(timeout: TimeInterval) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let cancelledEarly = state.withLock { state -> Bool in
                state.continuation = continuation
                return state.stopReason != nil
            }
            if cancelledEarly {
                finish(throwing: LLMError.cancelled)
                return
            }
            do {
                try launch()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                finish(throwing: LLMError.invalidResponse("Could not start \(invocation.executable.path): \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout)) { [self] in
                stop(.timeout)
            }
        }
    }

    /// Terminates the process (if running) and records why.
    func stop(_ reason: StopReason) {
        let shouldTerminate = state.withLock { state -> Bool in
            guard state.exitCode == nil, state.stopReason == nil else { return false }
            state.stopReason = reason
            return state.launched
        }
        guard shouldTerminate else { return }
        // Foundation makes the child a process-group leader, so signalling -pid also reaches
        // grandchildren (e.g. node workers) that would otherwise keep running and hold the pipes open.
        let pid = process.processIdentifier
        kill(-pid, SIGTERM)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGracePeriod) { [self] in
            if process.isRunning || kill(-pid, 0) == 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    private func launch() throws {
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let directory = invocation.workingDirectory { process.currentDirectoryURL = directory }
        if let environment = invocation.environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = invocation.standardInput == nil ? FileHandle.nullDevice : stdinPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                closeStdout()
            } else {
                appendStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.withLock { $0.stderrClosed = true }
                finishIfDone()
            } else {
                state.withLock { $0.stderr.append(data) }
            }
        }
        process.terminationHandler = { [self] process in
            let status = process.terminationStatus
            state.withLock { $0.exitCode = status }
            // Grandchildren that inherited the pipes can keep them open; don't wait for EOF forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGracePeriod) { [self] in
                forceCloseStreams()
            }
            finishIfDone()
        }

        // A child that exits without draining stdin must not SIGPIPE the app.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try process.run()
        let stopRequested = state.withLock { state -> Bool in
            state.launched = true
            return state.stopReason != nil
        }
        if stopRequested {
            kill(-process.processIdentifier, SIGTERM)
            process.terminate()
        }

        if let input = invocation.standardInput {
            let writer = stdinPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
    }

    private func appendStdout(_ data: Data) {
        let lines = state.withLock { state -> [String] in
            state.stdout.append(data)
            guard onStdoutLine != nil else { return [] }
            state.pendingLine.append(data)
            var lines: [String] = []
            while let newline = state.pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(String(decoding: state.pendingLine[state.pendingLine.startIndex..<newline], as: UTF8.self))
                state.pendingLine.removeSubrange(state.pendingLine.startIndex...newline)
            }
            return lines
        }
        lines.forEach { onStdoutLine?($0) }
    }

    private func closeStdout() {
        let remainder = state.withLock { state -> String? in
            guard !state.stdoutClosed else { return nil }
            state.stdoutClosed = true
            defer { state.pendingLine.removeAll() }
            return state.pendingLine.isEmpty ? nil : String(decoding: state.pendingLine, as: UTF8.self)
        }
        if let remainder { onStdoutLine?(remainder) }
        finishIfDone()
    }

    private func forceCloseStreams() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        closeStdout()
        state.withLock { $0.stderrClosed = true }
        finishIfDone()
    }

    private func finishIfDone() {
        let completion = state.withLock { state -> (CheckedContinuation<ProcessOutput, Error>, Result<ProcessOutput, Error>)? in
            guard let exitCode = state.exitCode, state.stdoutClosed, state.stderrClosed,
                  let continuation = state.continuation
            else { return nil }
            state.continuation = nil
            let result: Result<ProcessOutput, Error> = switch state.stopReason {
            case .timeout: .failure(LLMError.timeout)
            case .cancelled: .failure(LLMError.cancelled)
            case nil: .success(ProcessOutput(exitCode: exitCode, stdout: state.stdout, stderr: state.stderr))
            }
            return (continuation, result)
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }

    private func finish(throwing error: Error) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: error)
    }
}
