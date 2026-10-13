import Foundation
import Testing
@testable import LLMKit

private func secrets(_ kind: LLMProviderKind, _ key: String = "test-key") -> InMemorySecretStore {
    InMemorySecretStore([kind.secretAccount: key])
}

private let imageRequest = LLMRequest(
    system: "You summarize meetings.",
    messages: [
        LLMMessage(role: .user, parts: [.text("Describe this slide"), .image(data: pngBytes, mediaType: "image/png")]),
    ],
    maxTokens: 1000,
    temperature: 0.2
)

// MARK: - Anthropic

@Suite struct AnthropicProviderTests {
    let provider = AnthropicProvider(secrets: secrets(.anthropicAPI))

    @Test func requestShape() throws {
        let request = try provider.makeURLRequest(imageRequest, stream: false)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try jsonObject(request)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 1000)
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["stream"] == nil)

        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["type"] as? String == "text")
        #expect(system[0]["text"] as? String == "You summarize meetings.")
        #expect(system[0]["cache_control"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "image")
        let source = try #require(content[1]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == pngBytes.base64EncodedString())
    }

    @Test func cacheControlJSONModeAndStreaming() throws {
        var request = imageRequest
        request.cacheSystemPrompt = true
        request.responseFormat = .json
        request.model = "claude-haiku-5-5"
        let body = try jsonObject(try provider.makeURLRequest(request, stream: true))
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["stream"] as? Bool == true)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system[1]["text"] as? String)?.contains("single valid JSON object") == true)
        #expect(system[1]["cache_control"] == nil)
    }

    @Test func imageFileIsInlined() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "slide.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: file)
        let request = LLMRequest(messages: [LLMMessage(role: .user, parts: [.imageFile(file)])])
        let body = try jsonObject(try provider.makeURLRequest(request, stream: false))
        let content = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect((content[0]["source"] as? [String: Any])?["media_type"] as? String == "image/jpeg")
    }

    @Test func missingKeyThrows() {
        let provider = AnthropicProvider(secrets: InMemorySecretStore())
        #expect(throws: LLMError.self) { try provider.makeURLRequest(imageRequest, stream: false) }
    }

    @Test func parsesResponseWithUsage() throws {
        let json = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5",
         "content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}],
         "stop_reason":"end_turn",
         "usage":{"input_tokens":12,"cache_creation_input_tokens":3,"cache_read_input_tokens":900,"output_tokens":5}}
        """
        let response = try AnthropicProvider.parseResponse(Data(json.utf8))
        #expect(response.text == "Hello world")
        #expect(response.model == "claude-sonnet-5-5")
        #expect(response.usage == LLMUsage(inputTokens: 15, outputTokens: 5, cacheReadTokens: 900))
    }

    @Test func streamDeltas() throws {
        let events = SSEParser.parse("""
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":3}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}

        event: message_stop
        data: {"type":"message_stop"}
        """)
        let deltas = try events.compactMap(AnthropicProvider.textDelta(from:))
        #expect(deltas == ["Hi"])

        let error = SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(throws: LLMError.self) { try AnthropicProvider.textDelta(from: error) }
    }
}

// MARK: - OpenAI

@Suite struct OpenAIProviderTests {
    @Test func officialAPIRequest() throws {
        let provider = OpenAIProvider(secrets: secrets(.openAIAPI))
        var request = imageRequest
        request.responseFormat = .json
        let urlRequest = try provider.makeURLRequest(request, stream: false)
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try jsonObject(urlRequest)
        #expect(body["model"] as? String == "gpt-5")
        #expect(body["max_completion_tokens"] as? Int == 1000)
        #expect(body["max_tokens"] == nil)
        #expect(body["temperature"] == nil, "gpt-5 rejects custom temperature")
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "system")
        #expect((messages[0]["content"] as? String)?.contains("JSON") == true)
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[1]["type"] as? String == "image_url")
        let url = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/png;base64,\(pngBytes.base64EncodedString())")
    }

    @Test func nonReasoningModelKeepsTemperature() throws {
        let provider = OpenAIProvider(config: LLMProviderConfig(kind: .openAIAPI, model: "gpt-4.1"), secrets: secrets(.openAIAPI))
        let body = try jsonObject(try provider.makeURLRequest(imageRequest, stream: true))
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test func reasoningModelDetection() {
        #expect(OpenAIProvider.isReasoningModel("gpt-5"))
        #expect(OpenAIProvider.isReasoningModel("gpt-5-mini"))
        #expect(OpenAIProvider.isReasoningModel("o3"))
        #expect(OpenAIProvider.isReasoningModel("o4-mini"))
        #expect(!OpenAIProvider.isReasoningModel("gpt-4o"))
        #expect(!OpenAIProvider.isReasoningModel("olmo"))
        #expect(!OpenAIProvider.isReasoningModel("llama3.1"))
    }

    @Test func localServerRequest() throws {
        let provider = OpenAIProvider(config: LLMProviderConfig(kind: .localOpenAICompatible), secrets: InMemorySecretStore())
        let request = LLMRequest(system: "sys", messages: [.user("hi"), .assistant("hello"), .user("bye")], temperature: 0.5)
        let urlRequest = try provider.makeURLRequest(request, stream: true)
        #expect(urlRequest.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try jsonObject(urlRequest)
        #expect(body["model"] as? String == "llama3.1")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["temperature"] as? Double == 0.5)
        #expect(body["stream_options"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages[1]["content"] as? String == "hi", "text-only content is a plain string")
    }

    @Test func customBaseURL() throws {
        let provider = OpenAIProvider(
            config: LLMProviderConfig(kind: .localOpenAICompatible, baseURL: "http://127.0.0.1:1234/v1/"),
            secrets: InMemorySecretStore()
        )
        #expect(try provider.makeURLRequest(imageRequest, stream: false).url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
    }

    @Test func parsesResponse() throws {
        let json = """
        {"id":"x","model":"gpt-5-2025-08-07","choices":[{"index":0,"message":{"role":"assistant","content":"{\\"a\\":1}"},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":64}}}
        """
        let response = try OpenAIProvider.parseResponse(Data(json.utf8))
        #expect(response.text == #"{"a":1}"#)
        #expect(response.model == "gpt-5-2025-08-07")
        #expect(response.usage == LLMUsage(inputTokens: 36, outputTokens: 20, cacheReadTokens: 64))
    }

    @Test func streamDeltas() throws {
        let events = SSEParser.parse("""
        data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":1}}

        data: [DONE]
        """)
        let deltas = try events.compactMap(OpenAIProvider.textDelta(from:)).filter { !$0.isEmpty }
        #expect(deltas == ["Hel", "lo"])
    }
}

// MARK: - Gemini

@Suite struct GeminiProviderTests {
    let provider = GeminiProvider(secrets: secrets(.geminiAPI))

    @Test func requestShape() throws {
        var request = imageRequest
        request.messages.append(.assistant("Earlier answer"))
        request.responseFormat = .json
        let urlRequest = try provider.makeURLRequest(request, stream: false)
        #expect(urlRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent")
        #expect(urlRequest.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

        let body = try jsonObject(urlRequest)
        let system = try #require(body["systemInstruction"] as? [String: Any])
        #expect((system["parts"] as? [[String: Any]])?.first?["text"] as? String == "You summarize meetings.")

        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model"])
        let parts = try #require(contents[0]["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "Describe this slide")
        let inline = try #require(parts[1]["inline_data"] as? [String: Any])
        #expect(inline["mime_type"] as? String == "image/png")
        #expect(inline["data"] as? String == pngBytes.base64EncodedString())

        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["maxOutputTokens"] as? Int == 1000)
        #expect(config["temperature"] as? Double == 0.2)
        #expect(config["responseMimeType"] as? String == "application/json")
    }

    @Test func streamingURL() throws {
        let request = LLMRequest(messages: [.user("hi")], model: "models/gemini-2.5-flash")
        let url = try provider.makeURLRequest(request, stream: true).url
        #expect(url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
    }

    @Test func parsesResponseSkippingThoughts() throws {
        let json = """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking...","thought":true},{"text":"Answer"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":7,"cachedContentTokenCount":10,"thoughtsTokenCount":3},
         "modelVersion":"gemini-2.5-pro"}
        """
        let response = try GeminiProvider.parseResponse(Data(json.utf8))
        #expect(response.text == "Answer")
        #expect(response.model == "gemini-2.5-pro")
        #expect(response.usage == LLMUsage(inputTokens: 40, outputTokens: 10, cacheReadTokens: 10))
    }

    @Test func emptyAndBlockedResponsesThrow() {
        let maxTokens = #"{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]}"#
        #expect(throws: LLMError.self) { try GeminiProvider.parseResponse(Data(maxTokens.utf8)) }
        let blocked = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        #expect(throws: LLMError.self) { try GeminiProvider.parseResponse(Data(blocked.utf8)) }
    }

    @Test func streamDeltas() throws {
        let chunk = SSEEvent(data: #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#)
        #expect(try GeminiProvider.textDelta(from: chunk) == "Hi")
        let error = SSEEvent(data: #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#)
        #expect(throws: LLMError.self) { try GeminiProvider.textDelta(from: error) }
    }
}

// MARK: - Over a stubbed URLSession

@Suite struct HTTPRoundTripTests {
    @Test func anthropicCompleteAndUnauthorized() async throws {
        let (session, host) = StubURLProtocol.register { request in
            if request.value(forHTTPHeaderField: "x-api-key") == "bad" {
                return .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401)
            }
            return .json(#"{"model":"m","content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":1,"output_tokens":1}}"#)
        }
        let config = LLMProviderConfig(kind: .anthropicAPI, baseURL: "https://\(host)/v1")
        let good = AnthropicProvider(config: config, secrets: secrets(.anthropicAPI), session: session)
        #expect(try await good.complete(LLMRequest(messages: [.user("hi")])).text == "OK")
        #expect(StubURLProtocol.requests(for: host).first?.url?.path == "/v1/messages")

        let bad = AnthropicProvider(config: config, secrets: secrets(.anthropicAPI, "bad"), session: session)
        do {
            _ = try await bad.complete(LLMRequest(messages: [.user("hi")]))
            Issue.record("expected 401")
        } catch let LLMError.http(status, body) {
            #expect(status == 401)
            #expect(body.contains("check the API key") || body.contains("Check the API key"))
            #expect(body.contains("invalid x-api-key"))
        }
    }

    @Test func anthropicStream() async throws {
        let (session, host) = StubURLProtocol.register { _ in
            .sse("""
            event: message_start
            data: {"type":"message_start","message":{}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

            event: message_stop
            data: {"type":"message_stop"}


            """)
        }
        let provider = AnthropicProvider(
            config: LLMProviderConfig(kind: .anthropicAPI, baseURL: "https://\(host)/v1"),
            secrets: secrets(.anthropicAPI),
            session: session
        )
        #expect(try await collect(provider.stream(LLMRequest(messages: [.user("hi")]))) == ["Hello", ", world"])
    }

    @Test func openAIStreamHTTPErrorSurfacesMessage() async throws {
        let (session, host) = StubURLProtocol.register { _ in
            .json(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#, status: 401)
        }
        let provider = OpenAIProvider(
            config: LLMProviderConfig(kind: .openAIAPI, baseURL: "https://\(host)/v1"),
            secrets: secrets(.openAIAPI),
            session: session
        )
        do {
            _ = try await collect(provider.stream(LLMRequest(messages: [.user("hi")])))
            Issue.record("expected an error")
        } catch let LLMError.http(status, body) {
            #expect(status == 401)
            #expect(body.contains("Incorrect API key provided"))
        }
    }

    @Test func openAIStreamOverStub() async throws {
        let (session, host) = StubURLProtocol.register { _ in
            .sse("data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}\n\ndata: [DONE]\n\n")
        }
        let provider = OpenAIProvider(
            config: LLMProviderConfig(kind: .localOpenAICompatible, baseURL: "http://\(host)/v1"),
            secrets: InMemorySecretStore(),
            session: session
        )
        #expect(try await collect(provider.stream(LLMRequest(messages: [.user("hi")]))) == ["A", "B"])
        #expect(await provider.checkAvailability() == .ready)
    }

    @Test func geminiCompleteAndStream() async throws {
        let (session, host) = StubURLProtocol.register { request in
            if request.url?.absoluteString.contains("streamGenerateContent") == true {
                return .sse("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Str\"}]}}]}\r\n\r\ndata: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"eam\"}]}}]}\r\n\r\n")
            }
            return .json(#"{"candidates":[{"content":{"parts":[{"text":"Done"}]}}],"modelVersion":"g"}"#)
        }
        let provider = GeminiProvider(
            config: LLMProviderConfig(kind: .geminiAPI, baseURL: "https://\(host)/v1beta"),
            secrets: secrets(.geminiAPI),
            session: session
        )
        #expect(try await provider.complete(LLMRequest(messages: [.user("hi")])).text == "Done")
        #expect(try await collect(provider.stream(LLMRequest(messages: [.user("hi")]))) == ["Str", "eam"])
    }

    @Test func httpErrorMessages() {
        let error = HTTPClient.httpError(status: 400, body: Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#.utf8))
        #expect(error.errorDescription?.contains("API key not valid.") == true)
        let plain = HTTPClient.httpError(status: 502, body: Data("Bad gateway".utf8))
        #expect(plain.errorDescription?.contains("Bad gateway") == true)
    }
}

@Suite struct LowLatencyHintTests {
    @Test func openAIReasoningModelsGetMinimalEffortOnlyWhenAsked() throws {
        var request = LLMRequest(messages: [.user("hi")], maxTokens: 300)
        request.preferLowLatency = true
        let body = try JSONEncoder().encode(OpenAIProvider.makeBody(request, model: "gpt-5-mini", stream: true, officialAPI: true))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning_effort"] as? String == "minimal")
        request.preferLowLatency = false
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OpenAIProvider.makeBody(request, model: "gpt-5-mini", stream: true, officialAPI: true))) as? [String: Any]
        #expect(plain?["reasoning_effort"] == nil)
        request.preferLowLatency = true
        let nonReasoning = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OpenAIProvider.makeBody(request, model: "llama3.1", stream: true, officialAPI: false))) as? [String: Any]
        #expect(nonReasoning?["reasoning_effort"] == nil)
    }

    @Test func geminiFlashDisablesThinkingForLiveRequests() throws {
        var request = LLMRequest(messages: [.user("hi")], maxTokens: 300)
        request.preferLowLatency = true
        let flash = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GeminiProvider.makeBody(request, model: "gemini-2.5-flash"))) as? [String: Any]
        let config = flash?["generationConfig"] as? [String: Any]
        #expect((config?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int == 0)
        let pro = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GeminiProvider.makeBody(request, model: "gemini-2.5-pro"))) as? [String: Any]
        #expect((pro?["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil)
    }

    @Test func localModelsDoNotAdvertiseImages() {
        let local = OpenAIProvider(config: LLMProviderConfig(kind: .localOpenAICompatible), secrets: InMemorySecretStore())
        #expect(!local.capabilities.contains(.images))
        #expect(OpenAIProvider(secrets: InMemorySecretStore()).capabilities.contains(.images))
    }
}
