import Foundation
import Testing
@testable import BrowserBridge

@Suite("JSON messages")
struct MessageTests {
    @Test func decodesHello() throws {
        let json = """
        {"type":"hello","token":"abc","profileInstanceId":"p-1","profileLabel":"Work",
         "browser":"Chrome","extensionVersion":"0.1.0"}
        """
        guard case .hello(let hello) = try ExtensionMessage.decode(Data(json.utf8)) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello == .init(token: "abc", profileInstanceId: "p-1", profileLabel: "Work", browser: "Chrome", extensionVersion: "0.1.0"))
        #expect(hello.role == .control)
    }

    @Test func decodesMediaHelloAndUnknownRoleFallsBack() throws {
        let media = #"{"type":"hello","token":"t","profileInstanceId":"p","role":"media"}"#
        guard case .hello(let hello) = try ExtensionMessage.decode(Data(media.utf8)) else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.role == .media)
        #expect(hello.browser == "Chromium")
        let weird = #"{"type":"hello","token":"t","profileInstanceId":"p","role":"bogus"}"#
        guard case .hello(let fallback) = try ExtensionMessage.decode(Data(weird.utf8)) else {
            Issue.record("expected hello")
            return
        }
        #expect(fallback.role == .control)
    }

    @Test func decodesWindows() throws {
        let json = """
        {"type":"windows","windows":[{"windowId":12,"focused":true,"state":"normal",
          "bounds":{"left":10,"top":20,"width":1280,"height":800},"activeTabId":99,
          "tabs":[{"tabId":99,"title":"Meet – abc-defg-hij","url":"https://meet.google.com/abc-defg-hij",
                   "active":true,"audible":true,"isMeeting":true},
                  {"tabId":100,"title":"Docs","url":"https://docs.google.com","active":false,"audible":false,"isMeeting":false}]},
          {"windowId":13,"focused":false,"state":"minimized","bounds":{"left":0,"top":0,"width":800,"height":600},
           "activeTabId":null,"tabs":[]}]}
        """
        guard case .windows(let windows) = try ExtensionMessage.decode(Data(json.utf8)) else {
            Issue.record("expected windows")
            return
        }
        #expect(windows.count == 2)
        #expect(windows[0].windowID == 12)
        #expect(windows[0].bounds.rect == CGRect(x: 10, y: 20, width: 1280, height: 800))
        #expect(windows[0].activeTabID == 99)
        #expect(windows[0].meetingTabs.map(\.tabID) == [99])
        #expect(windows[1].activeTabID == nil)
        #expect(windows[1].state == "minimized")
    }

    @Test func decodesCaptureStates() throws {
        let id = UUID()
        let json = """
        {"type":"captureState","sessionId":"\(id.uuidString.lowercased())","state":"capturing",
         "userInitiated":true,"windowId":3,"tabId":4}
        """
        guard case .captureState(let report) = try ExtensionMessage.decode(Data(json.utf8)) else {
            Issue.record("expected captureState")
            return
        }
        #expect(report.sessionId == id)
        #expect(report.captureState == .capturing)
        #expect(report.userInitiated == true)
        #expect(report.windowId == 3 && report.tabId == 4)

        func state(_ s: String, _ message: String?) -> BridgeCaptureState {
            ExtensionMessage.CaptureStateReport(sessionId: id, state: s, message: message).captureState
        }
        #expect(state("awaitingGesture", nil) == .awaitingGesture)
        #expect(state("stopped", "Tab closed") == .stopped("Tab closed"))
        #expect(state("error", "Permission denied") == .error("Permission denied"))
        #expect(state("nonsense", nil) == .error("Unknown capture state 'nonsense'"))
    }

    @Test func decodesMeetingStateWithNulls() throws {
        let id = UUID()
        let json = #"{"type":"meetingState","sessionId":"\#(id)","muted":true,"presenting":null}"#
        #expect(try ExtensionMessage.decode(Data(json.utf8)) == .meetingState(.init(sessionId: id, muted: true, presenting: nil)))
    }

    @Test func unknownAndInvalidMessages() throws {
        #expect(try ExtensionMessage.decode(Data(#"{"type":"futureThing","x":1}"#.utf8)) == .unknown(type: "futureThing"))
        #expect(try ExtensionMessage.decode(Data(#"{"type":"ping"}"#.utf8)) == .ping)
        #expect(throws: ExtensionMessage.DecodingError.missingType) {
            try ExtensionMessage.decode(Data(#"{"x":1}"#.utf8))
        }
        #expect(throws: (any Error).self) { try ExtensionMessage.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try ExtensionMessage.decode(Data(#"{"type":"hello"}"#.utf8)) }
    }

    @Test func encodesAppMessages() throws {
        let id = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B")!
        let start = String(decoding: try AppMessage.startCapture(sessionID: id, windowID: 7, tabID: 8).encoded(), as: UTF8.self)
        #expect(start == #"{"sessionId":"6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b","tabId":8,"type":"startCapture","windowId":7}"#)
        let stop = String(decoding: try AppMessage.stopCapture(sessionID: id).encoded(), as: UTF8.self)
        #expect(stop == #"{"sessionId":"6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b","type":"stopCapture"}"#)
        let welcome = String(decoding: try AppMessage.welcome(protocolVersion: 1, profileInstanceId: "p").encoded(), as: UTF8.self)
        #expect(welcome == #"{"options":{"pageDiagnostics":false},"profileInstanceId":"p","protocolVersion":1,"type":"welcome"}"#)
        let diagnostics = String(decoding: try AppMessage.welcome(protocolVersion: 1, profileInstanceId: "p", pageDiagnostics: true).encoded(), as: UTF8.self)
        #expect(diagnostics.contains(#""options":{"pageDiagnostics":true}"#))
    }

    @Test func versionsCompareNumerically() throws {
        #expect(isVersion("0.1.0", olderThan: "0.2.0"))
        #expect(isVersion("0.9.1", olderThan: "0.10.0"))
        #expect(isVersion("0.2", olderThan: "0.2.1"))
        #expect(!isVersion("0.2.0", olderThan: "0.2.0"))
        #expect(!isVersion("1.0.0", olderThan: "0.9.9"))
        #expect(String(decoding: try AppMessage.reloadExtension.encoded(), as: UTF8.self) == #"{"type":"reloadExtension"}"#)
    }

    @Test func decodesSpeakerActivityAndDiagnostics() throws {
        let id = UUID()
        let json = #"{"type":"speakerActivity","sessionId":"\#(id.uuidString.lowercased())","at":1700000000123.5,"captions":[{"id":"x-1","name":"Maria Silva","text":"Good morning"},{"id":"x-2","name":null,"text":"hm"}],"speaking":["Maria Silva"]}"#
        let message = try ExtensionMessage.decode(Data(json.utf8))
        #expect(message == .speakerActivity(.init(
            sessionId: id, at: 1700000000123.5,
            captions: [.init(id: "x-1", name: "Maria Silva", text: "Good morning"), .init(id: "x-2", name: nil, text: "hm")],
            speaking: ["Maria Silva"]
        )))
        let noIndicator = #"{"type":"speakerActivity","sessionId":"\#(id)","at":1,"captions":[],"speaking":null}"#
        guard case .speakerActivity(let report) = try ExtensionMessage.decode(Data(noIndicator.utf8)) else { Issue.record("not decoded"); return }
        #expect(report.speaking == nil)

        let diag = #"{"type":"pageDiagnostics","sessionId":"\#(id)","at":5000,"payload":{"top":[{"sig":"div@class","count":3}],"mutations":3}}"#
        guard case .pageDiagnostics(let session, let at, let payload) = try ExtensionMessage.decode(Data(diag.utf8)) else { Issue.record("not decoded"); return }
        #expect(session == id && at == 5000)
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(object["mutations"] as? Int == 3)
        #expect(throws: (any Error).self) { try ExtensionMessage.decode(Data(#"{"type":"pageDiagnostics","sessionId":"nope","payload":{}}"#.utf8)) }
    }

    @Test func originPolicy() {
        #expect(BrowserBridgeServer.isAllowedOrigin("chrome-extension://lhchlhlaljhfimjelkfbcmgocleehfin"))
        #expect(!BrowserBridgeServer.isAllowedOrigin("https://evil.example"))
        #expect(!BrowserBridgeServer.isAllowedOrigin("http://localhost:3000"))
        #expect(BrowserBridgeServer.constantTimeEquals("abc", "abc"))
        #expect(!BrowserBridgeServer.constantTimeEquals("abc", "abd"))
        #expect(!BrowserBridgeServer.constantTimeEquals("abc", "abcd"))
    }
}
