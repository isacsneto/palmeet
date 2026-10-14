import AppKit
import Foundation

/// Keeps a copy of the companion extension at a stable path for Chrome's "Load unpacked".
///
/// The copy inside the app bundle can't be used: Finder won't open folders inside an .app, and updates replace
/// the bundle (Chrome would lose the extension). The stable copy is refreshed on every launch so an app update
/// also updates the extension's files. Chrome only reads them when the extension reloads, so the app asks an
/// outdated extension to reload itself when it connects (see `BrowserBridgeServer.setLatestExtensionVersion`).
enum ChromeExtensionFolder {
    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "PalMeet/Chrome Extension", directoryHint: .isDirectory)
    }

    private static var bundledURL: URL? {
        let candidates = ["chromium", "ChromeExtension"].compactMap { Bundle.main.resourceURL?.appending(path: $0) }
            + [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../Extension/chromium").standardized]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
    }

    /// Copies the bundled extension to the stable folder (only when its contents differ). Returns the folder.
    @discardableResult
    static func refresh() -> URL? {
        guard let source = bundledURL else { return nil }
        let fm = FileManager.default
        let destination = url
        if isUpToDate(destination, with: source) { return destination }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appending(path: ".extension-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: staging)
            try? fm.removeItem(at: staging.appending(path: "tests"))
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
            return destination
        } catch {
            return fm.fileExists(atPath: destination.path) ? destination : nil
        }
    }

    /// Every file the extension uses is identical in both folders (tests aren't copied).
    static func isUpToDate(_ destination: URL, with source: URL) -> Bool {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let file as URL in files {
            let relative = String(file.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1))
            if relative == "tests" || relative.hasPrefix("tests/") { continue }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if !fm.contentsEqual(atPath: file.path, andPath: destination.appending(path: relative).path) { return false }
        }
        return true
    }

    /// The bundled extension's version (manifest.json).
    static var bundledVersion: String? {
        guard let url = bundledURL?.appending(path: "manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return manifest["version"] as? String
    }

    /// Opens the folder in Finder (refreshing it first).
    @MainActor
    static func reveal() {
        guard let folder = refresh() else { return }
        NSWorkspace.shared.open(folder)
    }
}
