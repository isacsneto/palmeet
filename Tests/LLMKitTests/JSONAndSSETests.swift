import Foundation
import Testing
@testable import LLMKit

@Suite struct JSONExtractionTests {
    struct Summary: Decodable, Equatable {
        var title: String
        var items: [String]
    }

    @Test func plainObject() throws {
        let value = try decodeJSON(Summary.self, from: #"{"title":"A","items":["x"]}"#)
        #expect(value == Summary(title: "A", items: ["x"]))
    }

    @Test func fencedWithProse() throws {
        let text = """
        Sure! Here is the summary:

        ```json
        {"title": "Weekly sync", "items": ["ship it"]}
        ```

        Let me know if you need anything else {really}.
        """
        let value = try decodeJSON(Summary.self, from: text)
        #expect(value.title == "Weekly sync")
    }

    @Test func bracesInsideStringsAndNesting() throws {
        let text = #"prefix {"title": "a } tricky \" { title", "items": [], "nested": {"k": {"v": 1}}} suffix"#
        let data = try #require(JSONExtraction.extractObject(from: text))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["title"] as? String == #"a } tricky " { title"#)
    }

    @Test func skipsInvalidCandidateBeforeValidObject() throws {
        let text = #"Use {placeholders} like this: {"title":"ok","items":[]}"#
        #expect(try decodeJSON(Summary.self, from: text).title == "ok")
    }

    @Test func noObject() {
        #expect(JSONExtraction.extractObject(from: "no json here [1,2]") == nil)
        #expect(JSONExtraction.extractObject(from: #"{"unterminated": true"#) == nil)
        #expect(throws: LLMError.self) { try decodeJSON(Summary.self, from: "nothing") }
    }

    @Test func typeMismatchThrowsInvalidResponse() {
        #expect(throws: LLMError.self) { try decodeJSON(Summary.self, from: #"{"title": 3}"#) }
    }
}

@Suite struct SSEParserTests {
    @Test func basicEvents() {
        let events = SSEParser.parse("""
        event: message_start
        data: {"a":1}

        : keep-alive comment

        data: first
        data: second

        data:no-space
        """)
        #expect(events == [
            SSEEvent(event: "message_start", data: #"{"a":1}"#),
            SSEEvent(event: nil, data: "first\nsecond"),
            SSEEvent(event: nil, data: "no-space"),
        ])
    }

    @Test func crlfLineEndings() {
        let events = SSEParser.parse("event: x\r\ndata: 1\r\n\r\ndata: 2\r\n\r\n")
        #expect(events == [SSEEvent(event: "x", data: "1"), SSEEvent(data: "2")])
    }

    @Test func eventNameResetsBetweenEvents() {
        var parser = SSEParser()
        #expect(parser.consume(line: "event: ping") == nil)
        #expect(parser.consume(line: "") == nil) // no data → no event
        #expect(parser.consume(line: "data: x") == nil)
        #expect(parser.consume(line: "") == SSEEvent(event: nil, data: "x"))
    }

    @Test func asyncBytes() async throws {
        let payload = Array("data: a\n\ndata: b\n\n".utf8)
        let bytes = AsyncStream<UInt8> { continuation in
            payload.forEach { continuation.yield($0) }
            continuation.finish()
        }
        var events: [SSEEvent] = []
        try await SSEParser.forEachEvent(in: bytes) { events.append($0) }
        #expect(events.map(\.data) == ["a", "b"])
    }
}

@Suite struct SecretStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(store.secret(for: "a") == nil)
        try store.setSecret("k1", for: "a")
        #expect(store.secret(for: "a") == "k1")
        try store.setSecret("k2", for: "a")
        #expect(store.secret(for: "a") == "k2")
        try store.deleteSecret(for: "a")
        #expect(store.secret(for: "a") == nil)
    }

    @Test func apiKeyTrimsAndIgnoresBlank() throws {
        let store = InMemorySecretStore([LLMProviderKind.openAIAPI.secretAccount: "  sk-1\n"])
        #expect(store.apiKey(for: .openAIAPI) == "sk-1")
        try store.setSecret("   ", for: LLMProviderKind.openAIAPI.secretAccount)
        #expect(store.apiKey(for: .openAIAPI) == nil)
    }
}

@Suite struct FactoryTests {
    @Test func makesMatchingProviderForEveryKind() {
        let secrets = InMemorySecretStore()
        for kind in LLMProviderKind.allCases {
            let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: kind), secrets: secrets)
            #expect(provider.kind == kind)
            #expect(provider.isSlow == kind.isCLI)
        }
    }

    @Test func apiProvidersReportMissingKey() async {
        let secrets = InMemorySecretStore()
        for kind in [LLMProviderKind.anthropicAPI, .openAIAPI, .geminiAPI] {
            let provider = LLMProviderFactory.make(config: LLMProviderConfig(kind: kind), secrets: secrets)
            #expect(await provider.checkAvailability() == .missingAPIKey)
            await #expect(throws: LLMError.self) { try await provider.complete(LLMRequest(messages: [.user("hi")])) }
        }
    }
}
