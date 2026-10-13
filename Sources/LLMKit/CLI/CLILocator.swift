import Foundation

/// Finds CLI binaries and builds the environment to run them with.
///
/// GUI apps don't inherit the login shell's `PATH`, so this checks the usual install locations and
/// falls back to asking the login shell, caching the answers.
public actor CLILocator {
    public static let shared = CLILocator()

    private let searchDirectories: [URL]
    private let useLoginShell: Bool
    private let shellPath: String
    private var located: [String: URL] = [:]
    private var shellPATH: String??

    /// - Parameters:
    ///   - searchDirectories: directories checked in order; `nil` uses `defaultSearchDirectories()`.
    ///   - useLoginShell: whether to ask `zsh -l` for `command -v` / `$PATH` as a fallback.
    public init(searchDirectories: [URL]? = nil, useLoginShell: Bool = true, shellPath: String = "/bin/zsh") {
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories()
        self.useLoginShell = useLoginShell
        self.shellPath = shellPath
    }

    public static func defaultSearchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var directories = [
            home.appending(path: ".local/bin"),
            URL(filePath: "/opt/homebrew/bin"),
            URL(filePath: "/usr/local/bin"),
            home.appending(path: ".npm-global/bin"),
        ]
        // Newest nvm-managed node first.
        let nvmRoot = home.appending(path: ".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot.path) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            directories += sorted.map { nvmRoot.appending(path: $0).appending(path: "bin") }
        }
        directories += [
            home.appending(path: ".bun/bin"),
            home.appending(path: ".volta/bin"),
        ]
        return directories
    }

    /// Returns the first executable found for any of `names`, honouring an explicit path first.
    public func locate(_ names: [String], explicitPath: String? = nil) async -> URL? {
        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(filePath: (explicitPath as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for name in names {
            if let cached = located[name], FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        }
        for name in names {
            if let url = searchDirectories
                .map({ $0.appending(path: name) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
                located[name] = url
                return url
            }
        }
        guard useLoginShell else { return nil }
        for name in names {
            if let url = await shellLookup(name) {
                located[name] = url
                return url
            }
        }
        return nil
    }

    /// Forgets cached locations (e.g. after the user installs a CLI).
    public func invalidate() {
        located.removeAll()
        shellPATH = nil
    }

    /// The login shell's `PATH`, computed once.
    public func loginShellPATH() async -> String? {
        if let cached = shellPATH { return cached }
        var result: String?
        if useLoginShell {
            result = await runShell("printf '%s' \"$PATH\"").flatMap(Self.lastLine)
        }
        shellPATH = .some(result)
        return result
    }

    /// Process environment for running `executable`: inherited env plus a PATH that contains the binary's
    /// directory, the login shell PATH and the common install locations (node-based CLIs need `node`).
    public func environment(for executable: URL) async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var components = [executable.deletingLastPathComponent().path]
        if let shell = await loginShellPATH() { components += shell.split(separator: ":").map(String.init) }
        components += searchDirectories.map(\.path)
        components += (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = components.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        // Running from inside a Claude Code session must not make the child think it is nested.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        environment["NO_COLOR"] = "1"
        return environment
    }

    private func shellLookup(_ name: String) async -> URL? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }),
              let output = await runShell("command -v \(name)"),
              let path = Self.lastLine(output), path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(filePath: path)
    }

    private func runShell(_ command: String) async -> String? {
        let invocation = CLIInvocation(
            executable: URL(filePath: shellPath),
            arguments: ["-lc", command],
            standardInput: nil,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: nil
        )
        guard let output = try? await ProcessRunner.run(invocation, timeout: 5), output.exitCode == 0 else { return nil }
        return output.stdoutText
    }

    /// Profiles can print banners; the answer is the last non-empty line.
    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
