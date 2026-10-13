import Foundation
import PalMeetCore
import SessionKit

/// `PalMeet --import <file>`: imports and processes a recording without UI, printing where the results are.
@MainActor
enum CommandLineImport {
    static var file: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--import"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    static func run(_ file: URL) async {
        let manager = AppState.shared.manager
        let started = Date()
        do {
            print("Importing \(file.lastPathComponent)…")
            let session = try await manager.importRecording(from: file)
            print("Extracted audio + \(session.screenshots.count) screenshot(s) in \(Int(Date().timeIntervalSince(started))) s")
            let task = Task { await session.processImport() }
            var lastStage = ""
            while !task.isCancelled {
                let label = session.stage.label
                if label != lastStage { print("  \(label)"); lastStage = label }
                if session.stage == .ready { break }
                if case .failed = session.stage { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await task.value
            print("Done in \(Int(Date().timeIntervalSince(started))) s → \(session.folder.url.path)")
            if let error = session.metadata.lastError { print("Note: \(error)") }
            session.warnings.forEach { print("Warning: \($0)") }
        } catch {
            print("Import failed: \(error.localizedDescription)")
        }
    }
}
