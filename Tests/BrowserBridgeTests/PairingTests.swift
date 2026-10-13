import Foundation
import Testing
@testable import BrowserBridge

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "BrowserBridgeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("bridge.json")
struct BridgeInfoTests {
    @Test func writeAndRead() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BridgeInfoStore(url: dir.appending(path: "nested/bridge.json"))
        #expect(store.load() == nil)
        let info = BridgeInfo(port: 47821, token: BridgeInfo.generateToken(), pid: getpid(),
                              updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(info)
        #expect(store.load() == info)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(info.isLive)
    }

    @Test func tokenIsCreatedOnceAndPersisted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BridgeInfoStore(url: dir.appending(path: "bridge.json"))
        let first = try store.loadOrCreateToken()
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(try store.loadOrCreateToken() == first)
        #expect(BridgeInfo.generateToken() != first)
    }

    @Test func staleInfoIsNotLive() {
        #expect(!BridgeInfo(port: nil, token: "t", pid: nil).isLive)
        // PID 0x7FFFFFF0 does not exist.
        #expect(!BridgeInfo(port: 1, token: "t", pid: 0x7FFF_FFF0).isLive)
    }
}

@Suite("Native messaging")
struct NativeMessagingTests {
    @Test func framingRoundTrip() throws {
        let json = Data(#"{"type":"getBridgeInfo"}"#.utf8)
        let framed = try NativeMessagingFraming.encode(json)
        #expect(framed.count == json.count + 4)
        #expect(Array(framed.prefix(4)) == [UInt8(json.count), 0, 0, 0])  // little-endian host
        let decoded = try #require(try NativeMessagingFraming.decode(framed + Data([9, 9])))
        #expect(decoded.message == json)
        #expect(decoded.consumed == framed.count)
        #expect(try NativeMessagingFraming.decode(framed.prefix(10)) == nil)
        #expect(try NativeMessagingFraming.decode(Data([1])) == nil)
    }

    @Test func framingRejectsOversized() {
        let huge = Data([0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: NativeMessagingFraming.FramingError.self) { try NativeMessagingFraming.decode(huge) }
    }

    @Test func callerOriginDetection() {
        #expect(NativeMessagingHost.callerOrigin(in: ["/Applications/PalMeet.app/Contents/MacOS/PalMeet"]) == nil)
        #expect(NativeMessagingHost.callerOrigin(in: ["PalMeet", "chrome-extension://abc/"]) == "chrome-extension://abc/")
        #expect(!NativeMessagingHost.runIfInvoked(arguments: ["PalMeet", "--foo"]))
    }

    @Test func responses() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BridgeInfoStore(url: dir.appending(path: "bridge.json"))
        let request = Data(#"{"type":"getBridgeInfo"}"#.utf8)

        #expect(try json(NativeMessagingHost.response(for: request, store: store))["error"] as? String == "notConfigured")
        try store.save(BridgeInfo(port: nil, token: "tok", pid: nil))
        #expect(try json(NativeMessagingHost.response(for: request, store: store))["error"] as? String == "notRunning")
        try store.save(BridgeInfo(port: 47822, token: "tok", pid: getpid()))
        let ok = try json(NativeMessagingHost.response(for: request, store: store))
        #expect(ok["type"] as? String == "bridgeInfo")
        #expect(ok["port"] as? Int == 47822)
        #expect(ok["token"] as? String == "tok")
        let bad = try json(NativeMessagingHost.response(for: Data(#"{"type":"other"}"#.utf8), store: store))
        #expect(bad["error"] as? String == "badRequest")
    }

    @Test func hostAnswersOverPipes() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BridgeInfoStore(url: dir.appending(path: "bridge.json"))
        try store.save(BridgeInfo(port: 47823, token: "secret", pid: getpid()))

        let stdin = Pipe(), stdout = Pipe()
        stdin.fileHandleForWriting.write(try NativeMessagingFraming.encode(Data(#"{"type":"getBridgeInfo"}"#.utf8)))
        try stdin.fileHandleForWriting.close()
        let handled = NativeMessagingHost.runIfInvoked(
            arguments: ["PalMeet", "chrome-extension://\(BrowserExtension.defaultExtensionID)/"],
            input: stdin.fileHandleForReading, output: stdout.fileHandleForWriting, store: store
        )
        try stdout.fileHandleForWriting.close()
        #expect(handled)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let reply = try #require(try NativeMessagingFraming.decode(output))
        let object = try json(reply.message)
        #expect(object["port"] as? Int == 47823)
        #expect(object["token"] as? String == "secret")
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("Extension identity & installer")
struct ExtensionIdentityTests {
    @Test func extensionIDFromPublicKey() {
        // Expected value computed with: openssl … -outform DER | shasum -a 256 | cut -c1-32 | tr 0-9a-f a-p
        #expect(BrowserExtension.extensionID(publicKeyBase64: BrowserExtension.publicKey) == "lhchlhlaljhfimjelkfbcmgocleehfin")
        #expect(BrowserExtension.defaultExtensionID == "lhchlhlaljhfimjelkfbcmgocleehfin")
        #expect(BrowserExtension.extensionID(publicKeyBase64: "%%%") == nil)
    }

    @Test func manifestKeyMatchesSwiftConstant() throws {
        let manifestURL = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Extension/chromium/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["key"] as? String == BrowserExtension.publicKey)
        #expect(manifest["manifest_version"] as? Int == 3)
    }

    @Test func installerWritesManifestOnlyForInstalledBrowsers() throws {
        let support = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        for dir in ["Google/Chrome", "Microsoft Edge", "Arc/User Data"] {
            try FileManager.default.createDirectory(at: support.appending(path: dir), withIntermediateDirectories: true)
        }
        #expect(NativeHostInstaller.installedBrowsers(applicationSupport: support).map(\.name) == ["Chrome", "Edge", "Arc"])

        let host = "/bin/sh"  // any executable file
        let written = try NativeHostInstaller.install(
            hostExecutablePath: host, extensionIDs: ["bbbb", "aaaa", "aaaa"], applicationSupport: support
        )
        #expect(written == ["Chrome", "Edge", "Arc"])

        let url = support.appending(path: "Google/Chrome/NativeMessagingHosts/app.palmeet.bridge.json")
        let manifest = try JSONDecoder().decode(NativeHostInstaller.Manifest.self, from: Data(contentsOf: url))
        #expect(manifest.name == "app.palmeet.bridge")
        #expect(manifest.path == host)
        #expect(manifest.type == "stdio")
        #expect(manifest.allowedOrigins == ["chrome-extension://aaaa/", "chrome-extension://bbbb/"])
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "Arc/User Data/NativeMessagingHosts/app.palmeet.bridge.json").path))
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Chromium").path))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"allowed_origins\""))
    }

    @Test func installerValidatesInput() throws {
        let support = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(throws: NativeHostInstaller.InstallError.hostExecutableNotFound("/nope")) {
            try NativeHostInstaller.install(hostExecutablePath: "/nope", extensionIDs: ["a"], applicationSupport: support)
        }
        #expect(throws: NativeHostInstaller.InstallError.noExtensionIDs) {
            try NativeHostInstaller.install(hostExecutablePath: "/bin/sh", extensionIDs: [], applicationSupport: support)
        }
    }
}
