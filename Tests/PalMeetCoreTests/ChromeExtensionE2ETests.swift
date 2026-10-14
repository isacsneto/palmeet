import BrowserBridge
import Foundation
import SessionKit
import Testing
import TranscriptKit
@testable import PalMeetCore

/// Real Chrome (Chrome for Testing) + the real unpacked extension + native-messaging pairing through the built
/// PalMeet binary + per-tab capture + the app's bridge and sessions + the real speech model.
///
/// Run with:
///   scripts/build-app.sh debug
///   PALMEET_CHROME="/path/to/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
///     swift test --filter ChromeExtensionE2ETests
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PALMEET_CHROME"] != nil))
struct ChromeExtensionE2ETests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let debugPort = 9333

    enum Layout: String, CaseIterable, Sendable {
        /// Two windows of one Chrome profile.
        case twoWindows
        /// Two Chrome profiles (the user's setup): each profile runs its own copy of the extension.
        case twoProfiles
    }

    @Test(.timeLimit(.minutes(10)), arguments: Layout.allCases)
    func twoMeetingsInOneChromeAreCapturedIndependently(_ layout: Layout) async throws {
        let chrome = try #require(ProcessInfo.processInfo.environment["PALMEET_CHROME"])
        let hostBinary = Self.repo.appending(path: "build/PalMeet.app/Contents/MacOS/PalMeet")
        try #require(FileManager.default.fileExists(atPath: hostBinary.path), "run scripts/build-app.sh debug first")

        let work = FileManager.default.temporaryDirectory.appending(path: "palmeet-chrome-\(UUID().uuidString)")
        let site = work.appending(path: "site"), userData = work.appending(path: "profile")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Two "meetings": pages that loop different speech.
        let phraseA = "The alpha team will migrate the payments database on Tuesday."
        let phraseB = "The bravo team will redesign the onboarding screens next month."
        try Self.writeSpeech(phraseA, voice: "Samantha", to: site.appending(path: "a.wav"))
        try Self.writeSpeech(phraseB, voice: "Daniel", to: site.appending(path: "b.wav"))
        for (name, title, audio) in [("a.html", "Meeting Alpha", "a.wav"), ("b.html", "Meeting Bravo", "b.wav")] {
            try #"<!doctype html><title>\#(title)</title><h1>\#(title)</h1><audio src="\#(audio)" autoplay loop></audio><script>document.querySelector('audio').volume = 0.2</script>"#
                .write(to: site.appending(path: name), atomically: true, encoding: .utf8)
        }
        let server = try Self.run("/usr/bin/python3", ["-m", "http.server", "8765", "--bind", "127.0.0.1", "--directory", site.path])
        defer { server.terminate() }

        // Native-messaging host manifest: the extension pairs with the app through the built PalMeet binary.
        let manifest = #"{"name":"app.palmeet.bridge","description":"PalMeet","path":"\#(hostBinary.path)","type":"stdio","allowed_origins":["chrome-extension://\#(BrowserExtension.defaultExtensionID)/"]}"#
        let cftHosts = URL.applicationSupportDirectory.appending(path: "Google/Chrome for Testing/NativeMessagingHosts")
        for dir in [userData.appending(path: "NativeMessagingHosts"), cftHosts] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest.write(to: dir.appending(path: "app.palmeet.bridge.json"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: cftHosts.appending(path: "app.palmeet.bridge.json")) }

        // The app side, with the real bridge (publishes bridge.json for the host) and the real speech model.
        let h = Harness(settings: { $0.language = "en" }, asr: ParakeetEngine(model: .ultra), diarizer: FakeDiarizer(), bridge: BrowserBridgeServer())
        defer { h.cleanup() }
        h.manager.start()
        try #require(h.manager.bridgePort != nil)

        let browser = try Self.run(chrome, [
            "--user-data-dir=\(userData.path)",
            "--load-extension=\(Self.repo.appending(path: "Extension/chromium").path)",
            "--allowlisted-extension-id=\(BrowserExtension.defaultExtensionID)",
            "--autoplay-policy=no-user-gesture-required",
            "--remote-debugging-port=\(Self.debugPort)",
            "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
            "http://127.0.0.1:8765/a.html",
        ])
        defer { browser.terminate() }

        // Extension paired and reported the first window.
        let paired = await waitUntil(timeout: .seconds(40)) { h.manager.browserProfiles.first?.windows.contains { $0.tabs.contains { $0.title == "Meeting Alpha" } } == true }
        if !paired { await h.manager.shutdown() }
        try #require(paired, "extension never connected: check native messaging / bridge.json")

        // Second meeting in the same Chrome (same audio process): another window, or another profile's window.
        var secondInstance: Process?
        switch layout {
        case .twoWindows:
            let cdp = try await CDP.browser(port: Self.debugPort)
            _ = try await cdp.call("Target.createTarget", ["url": "http://127.0.0.1:8765/b.html", "newWindow": true])
        case .twoProfiles:
            // Like double-clicking another profile: the running Chrome opens a window for "Profile 2".
            secondInstance = try Self.run(chrome, ["--user-data-dir=\(userData.path)", "--profile-directory=Profile 2", "--no-first-run", "http://127.0.0.1:8765/b.html"])
        }
        defer { secondInstance?.terminate() }
        let both = await waitUntil(timeout: .seconds(40)) {
            let tabs = h.manager.browserProfiles.flatMap(\.windows).flatMap(\.tabs).map(\.title)
            return tabs.contains("Meeting Alpha") && tabs.contains("Meeting Bravo")
        }
        try #require(both, "profiles seen: \(h.manager.browserProfiles.map { "\($0.label): \($0.windows.flatMap(\.tabs).map(\.title))" })")
        if layout == .twoProfiles {
            #expect(h.manager.browserProfiles.count == 2, "each profile's extension connects separately")
        }

        func choice(_ title: String) throws -> (SourceChoice, Int) {
            let profile = try #require(h.manager.browserProfiles.first { $0.windows.contains { $0.tabs.contains { $0.title == title } } })
            let window = try #require(profile.windows.first { $0.tabs.contains { $0.title == title } })
            let tab = try #require(window.tabs.first { $0.title == title })
            return (.browserTab(profile: profile, window: window, tab: tab, scWindowID: nil), tab.tabID)
        }
        let (choiceA, tabA) = try choice("Meeting Alpha")
        let (choiceB, tabB) = try choice("Meeting Bravo")
        let a = try await h.manager.startSession(choiceA, includeMicrophone: false)
        let b = try await h.manager.startSession(choiceB, includeMicrophone: false)

        // Stand in for the user's click on the extension icon, in whichever profile owns each tab.
        let workers = try await CDP.extensionWorkers(port: Self.debugPort, extensionID: BrowserExtension.defaultExtensionID, count: layout == .twoProfiles ? 2 : 1)
        for tabID in [tabA, tabB] {
            var clicked = false
            for worker in workers {
                let result = try await worker.evaluate("(async () => { let t; try { t = await chrome.tabs.get(\(tabID)); } catch { return 'not-here'; } await palmeetTest.handleGesture(t); return 'ok'; })()")
                if result == "ok" { clicked = true; break }
            }
            #expect(clicked, "no extension instance owns tab \(tabID)")
        }

        let capturing = await waitUntil(timeout: .seconds(20)) { a.themLevel > 0.001 && b.themLevel > 0.001 }
        #expect(capturing, "no tab audio arrived (levels \(a.themLevel), \(b.themLevel)); warnings: \(a.warnings + b.warnings)")
        try await Task.sleep(for: .seconds(10))  // each page loops its phrase
        #expect(a.screenshots.count + b.screenshots.count > 0, "tab video frames should produce screenshots")

        await h.manager.stop(a)
        await h.manager.stop(b)

        let textA = (a.transcript?.segments.map(\.text).joined(separator: " ") ?? "").lowercased()
        let textB = (b.transcript?.segments.map(\.text).joined(separator: " ") ?? "").lowercased()
        print("A:", textA)
        print("B:", textB)
        #expect(textA.contains("payments"))
        #expect(!textA.contains("onboarding"), "Meeting A contains Meeting B's audio")
        #expect(textB.contains("onboarding"))
        #expect(!textB.contains("payments"), "Meeting B contains Meeting A's audio")
        await h.manager.shutdown()
        browser.terminate()
        browser.waitUntilExit()
    }

    /// A Teams-like meeting page (served as teams.microsoft.com) where two people talk with live captions on: the
    /// extension reads the captions, and the final transcript names each speaker from them.
    @Test(.timeLimit(.minutes(10)))
    func captionsOnTheMeetingPageNameTheSpeakers() async throws {
        let chrome = try #require(ProcessInfo.processInfo.environment["PALMEET_CHROME"])
        let hostBinary = Self.repo.appending(path: "build/PalMeet.app/Contents/MacOS/PalMeet")
        try #require(FileManager.default.fileExists(atPath: hostBinary.path), "run scripts/build-app.sh debug first")

        let work = FileManager.default.temporaryDirectory.appending(path: "palmeet-captions-\(UUID().uuidString)")
        let site = work.appending(path: "site"), userData = work.appending(path: "profile")
        try FileManager.default.createDirectory(at: site.appending(path: "v2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Three turns: Alice (Samantha), Bob (Daniel), Alice again.
        let turns = [
            ("Alice Smith", "Samantha", "Good morning everyone. The payments migration finished last night without any errors."),
            ("Bob Jones", "Daniel", "Great news. I will ask the support team to watch the dashboards today and tomorrow."),
            ("Alice Smith", "Samantha", "Perfect. Then we can close the migration ticket on Friday."),
        ]
        for (index, turn) in turns.enumerated() {
            try Self.writeSpeech(turn.2, voice: turn.1, to: site.appending(path: "v2/turn\(index).wav"))
        }
        let plan = turns.enumerated().map { #"{"name":"\#($1.0)","text":"\#($1.2)","src":"turn\#($0).wav"}"# }.joined(separator: ",")
        // Teams' caption markup: author + text per caption, text growing while the person talks.
        try #"""
        <!doctype html><title>Daily Standup | Microsoft Teams</title>
        <div data-tid="closed-caption-v2-window-wrapper" id="captions"></div>
        <script>
        const plan = [\#(plan)];
        window.meetingDone = false;
        window.startMeeting = async () => {
          for (const turn of plan) {
            const entry = document.createElement('div');
            entry.innerHTML = '<div><span data-tid="author"></span><span data-tid="closed-caption-text"></span></div>';
            entry.querySelector('[data-tid="author"]').textContent = turn.name;
            const text = entry.querySelector('[data-tid="closed-caption-text"]');
            document.getElementById('captions').append(entry);
            const audio = new Audio(turn.src);
            const words = turn.text.split(' ');
            const timer = setInterval(() => {
              if (!audio.duration) return;
              const shown = Math.ceil(words.length * Math.min(1, audio.currentTime / audio.duration));
              text.textContent = words.slice(0, Math.max(1, shown)).join(' ');
            }, 250);
            await audio.play();
            await new Promise((resolve) => audio.addEventListener('ended', resolve, { once: true }));
            clearInterval(timer);
            text.textContent = turn.text;
            await new Promise((resolve) => setTimeout(resolve, 900));
          }
          window.meetingDone = true;
        };
        </script>
        """#.write(to: site.appending(path: "v2/index.html"), atomically: true, encoding: .utf8)

        // HTTPS for teams.microsoft.com, answered locally (Chrome maps the host and accepts the test certificate).
        let key = work.appending(path: "key.pem"), cert = work.appending(path: "cert.pem")
        try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1",
                                          "-subj", "/CN=teams.microsoft.com", "-addext", "subjectAltName=DNS:teams.microsoft.com"]).waitUntilExit()
        let serverScript = work.appending(path: "serve.py")
        try """
        import functools, http.server, ssl, sys
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[2], sys.argv[3])
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
        """.write(to: serverScript, atomically: true, encoding: .utf8)
        let server = try Self.run("/usr/bin/python3", ["-I", serverScript.path, site.path, cert.path, key.path])
        defer { server.terminate() }

        let manifest = #"{"name":"app.palmeet.bridge","description":"PalMeet","path":"\#(hostBinary.path)","type":"stdio","allowed_origins":["chrome-extension://\#(BrowserExtension.defaultExtensionID)/"]}"#
        let cftHosts = URL.applicationSupportDirectory.appending(path: "Google/Chrome for Testing/NativeMessagingHosts")
        for dir in [userData.appending(path: "NativeMessagingHosts"), cftHosts] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest.write(to: dir.appending(path: "app.palmeet.bridge.json"), atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: cftHosts.appending(path: "app.palmeet.bridge.json")) }

        let h = Harness(settings: { $0.language = "en" }, asr: ParakeetEngine(model: .ultra), diarizer: OfflineSpeakerDiarizer(), bridge: BrowserBridgeServer())
        defer { h.cleanup() }
        h.manager.start()
        try #require(h.manager.bridgePort != nil)

        let browser = try Self.run(chrome, [
            "--user-data-dir=\(userData.path)",
            "--load-extension=\(Self.repo.appending(path: "Extension/chromium").path)",
            "--allowlisted-extension-id=\(BrowserExtension.defaultExtensionID)",
            "--autoplay-policy=no-user-gesture-required",
            "--host-resolver-rules=MAP teams.microsoft.com 127.0.0.1:8443",
            "--ignore-certificate-errors",
            "--remote-debugging-port=\(Self.debugPort)",
            "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
            "https://teams.microsoft.com/v2/",
        ])
        defer { browser.terminate() }

        let title = "Daily Standup | Microsoft Teams"
        let paired = await waitUntil(timeout: .seconds(40)) { h.manager.browserProfiles.first?.windows.contains { $0.tabs.contains { $0.title == title } } == true }
        if !paired { await h.manager.shutdown() }
        try #require(paired, "extension never reported the meeting tab")
        let profile = try #require(h.manager.browserProfiles.first)
        let window = try #require(profile.windows.first { $0.tabs.contains { $0.title == title } })
        let tab = try #require(window.tabs.first { $0.title == title })
        #expect(tab.isMeeting)
        let session = try await h.manager.startSession(.browserTab(profile: profile, window: window, tab: tab, scWindowID: nil), includeMicrophone: false)

        let worker = try #require(try await CDP.extensionWorkers(port: Self.debugPort, extensionID: BrowserExtension.defaultExtensionID, count: 1).first)
        #expect(try await worker.evaluate("(async () => { await palmeetTest.handleGesture(await chrome.tabs.get(\(tab.tabID))); return 'ok'; })()") == "ok")
        // The content script learns that its tab is recorded within a few seconds.
        try await Task.sleep(for: .seconds(4))

        let pageURL = try #require(try await CDP.targets(port: Self.debugPort).first { ($0["url"] as? String)?.hasPrefix("https://teams.microsoft.com/") == true }?["webSocketDebuggerUrl"] as? String)
        let page = CDP(url: try #require(URL(string: pageURL)))
        _ = try await page.evaluate("(startMeeting(), Promise.resolve('started'))")
        var finished = false
        for _ in 0..<120 where !finished {
            try await Task.sleep(for: .milliseconds(500))
            finished = (try? await page.evaluate("Promise.resolve(String(window.meetingDone))")) == "true"
        }
        #expect(finished)
        try await Task.sleep(for: .seconds(2))
        #expect(session.speakerTimeline.captions.count == 3, "captions seen: \(session.speakerTimeline.captions)")
        #expect(session.meetingSpeakerStatus?.contains("Alice Smith") == true)

        await h.manager.stop(session)
        let transcript = try #require(session.transcript)
        for segment in transcript.segments { print("\(Timecode.format(segment.start)) \(transcript.displayName(for: segment.speakerID)): \(segment.text)") }
        func speaker(saying word: String) -> Speaker? {
            transcript.segments.first { $0.text.lowercased().contains(word) }.flatMap { transcript.speaker($0.speakerID) }
        }
        #expect(speaker(saying: "payments")?.displayName == "Alice Smith")
        #expect(speaker(saying: "payments")?.nameSource == "meeting")
        #expect(speaker(saying: "dashboards")?.displayName == "Bob Jones")
        #expect(speaker(saying: "ticket")?.displayName == "Alice Smith")
        #expect(Set(transcript.speakers.map(\.displayName)) == ["Alice Smith", "Bob Jones"])
        await h.manager.shutdown()
        browser.terminate()
        browser.waitUntilExit()
    }

    // MARK: Helpers

    static func writeSpeech(_ text: String, voice: String, to url: URL) throws {
        let process = try run("/usr/bin/say", ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@22050", text])
        process.waitUntilExit()
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

/// Minimal Chrome DevTools Protocol client.
final class CDP: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private var nextID = 0

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    static func targets(port: Int) async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    static func browser(port: Int) async throws -> CDP {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/version")!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let ws = (json?["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { throw URLError(.badServerResponse) }
        return CDP(url: ws)
    }

    /// The extension's service workers (one per profile).
    static func extensionWorkers(port: Int, extensionID: String, count: Int) async throws -> [CDP] {
        for _ in 0..<100 {
            let urls = try await targets(port: port).filter {
                ($0["type"] as? String) == "service_worker" && (($0["url"] as? String)?.contains(extensionID) ?? false)
            }.compactMap { ($0["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) }
            if urls.count >= count { return urls.map(CDP.init(url:)) }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw URLError(.cannotFindHost)
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await task.send(.string(String(decoding: payload, as: UTF8.self)))
        while true {
            guard case .string(let text) = try await task.receive(),
                  let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            if message["id"] as? Int == id {
                if let error = message["error"] { throw NSError(domain: "CDP", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"]) }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }

    /// Evaluates a promise-returning expression and returns its string value (or the exception text).
    func evaluate(_ expression: String) async throws -> String {
        let result = try await call("Runtime.evaluate", ["expression": expression, "awaitPromise": true, "returnByValue": true])
        if let exception = result["exceptionDetails"] as? [String: Any] { return "exception: \(exception)" }
        return ((result["result"] as? [String: Any])?["value"] as? String) ?? "\(result)"
    }
}
