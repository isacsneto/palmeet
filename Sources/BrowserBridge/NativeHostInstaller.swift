import Foundation

/// Installs the native messaging host manifest (`app.palmeet.bridge.json`) for every
/// Chromium-based browser present on this Mac (per-user `NativeMessagingHosts` directories).
public enum NativeHostInstaller {
    public struct Browser: Sendable, Equatable {
        public var name: String
        /// Browser data directory, relative to `~/Library/Application Support`.
        public var dataDirectory: String

        public var hostsDirectory: String { dataDirectory + "/NativeMessagingHosts" }
    }

    public static let defaultExtensionID = BrowserExtension.defaultExtensionID

    public static let supportedBrowsers: [Browser] = [
        Browser(name: "Chrome", dataDirectory: "Google/Chrome"),
        Browser(name: "Chrome Beta", dataDirectory: "Google/Chrome Beta"),
        Browser(name: "Chrome Canary", dataDirectory: "Google/Chrome Canary"),
        Browser(name: "Chromium", dataDirectory: "Chromium"),
        Browser(name: "Edge", dataDirectory: "Microsoft Edge"),
        Browser(name: "Brave", dataDirectory: "BraveSoftware/Brave-Browser"),
        Browser(name: "Arc", dataDirectory: "Arc/User Data"),
        Browser(name: "Vivaldi", dataDirectory: "Vivaldi"),
    ]

    public enum InstallError: Error, Equatable {
        case hostExecutableNotFound(String)
        case noExtensionIDs
    }

    struct Manifest: Codable, Equatable {
        var name: String
        var description: String
        var path: String
        var type: String
        var allowedOrigins: [String]

        enum CodingKeys: String, CodingKey {
            case name, description, path, type, allowedOrigins = "allowed_origins"
        }
    }

    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    /// Names of supported browsers whose data directory exists.
    public static func installedBrowsers() -> [String] {
        installedBrowsers(applicationSupport: applicationSupport).map(\.name)
    }

    /// Writes the host manifest for each installed browser. Returns the browser names written.
    @discardableResult
    public static func install(
        hostExecutablePath: String, extensionIDs: [String] = [BrowserExtension.defaultExtensionID]
    ) throws -> [String] {
        try install(hostExecutablePath: hostExecutablePath, extensionIDs: extensionIDs, applicationSupport: applicationSupport)
    }

    /// Removes the host manifest from every supported browser.
    public static func uninstall() {
        for browser in supportedBrowsers {
            let url = manifestURL(for: browser, applicationSupport: applicationSupport)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func installedBrowsers(applicationSupport: URL) -> [Browser] {
        supportedBrowsers.filter { browser in
            var isDirectory: ObjCBool = false
            let path = applicationSupport.appending(path: browser.dataDirectory).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func manifestURL(for browser: Browser, applicationSupport: URL) -> URL {
        applicationSupport.appending(path: browser.hostsDirectory)
            .appending(path: "\(BrowserExtension.nativeHostName).json", directoryHint: .notDirectory)
    }

    static func manifest(hostExecutablePath: String, extensionIDs: [String]) -> Manifest {
        Manifest(
            name: BrowserExtension.nativeHostName,
            description: "PalMeet browser bridge pairing",
            path: hostExecutablePath,
            type: "stdio",
            allowedOrigins: Array(Set(extensionIDs)).sorted().map(BrowserExtension.origin(forExtensionID:))
        )
    }

    @discardableResult
    static func install(hostExecutablePath: String, extensionIDs: [String], applicationSupport: URL) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: hostExecutablePath) else {
            throw InstallError.hostExecutableNotFound(hostExecutablePath)
        }
        guard !extensionIDs.isEmpty else { throw InstallError.noExtensionIDs }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest(hostExecutablePath: hostExecutablePath, extensionIDs: extensionIDs))
        var written: [String] = []
        for browser in installedBrowsers(applicationSupport: applicationSupport) {
            let url = manifestURL(for: browser, applicationSupport: applicationSupport)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            written.append(browser.name)
        }
        return written
    }
}
