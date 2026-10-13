import Foundation

/// OpenAI Chat Completions (`POST {base}/chat/completions`).
///
/// Chat Completions (rather than the Responses API) keeps this usable for OpenAI-compatible local
/// servers such as Ollama and LM Studio (`.localOpenAICompatible`).
public struct OpenAIProvider: LLMProvider {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultLocalBaseURL = "http://localhost:11434/v1"

    public let config: LLMProviderConfig
    private let secrets: any SecretStore
    private let http: HTTPClient

    public var kind: LLMProviderKind { config.kind }
    /// Local models are usually text-only; sending images to them fails the whole request.
    public var capabilities: LLMCapabilities {
        config.kind == .localOpenAICompatible ? [.streaming, .jsonMode] : [.images, .streaming, .jsonMode]
    }
    public var isSlow: Bool { false }

    /// `config.kind` should be `.openAIAPI` or `.localOpenAICompatible`.
    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .openAIAPI), secrets: any SecretStore, session: URLSession = .shared) {
        self.config = config
        self.secrets = secrets
        self.http = HTTPClient(session: session)
    }

    var baseURL: String {
        if let base = config.baseURL, !base.trimmingCharacters(in: .whitespaces).isEmpty { return base }
        return config.kind == .localOpenAICompatible ? Self.defaultLocalBaseURL : Self.defaultBaseURL
    }

    /// api.openai.com wants `max_completion_tokens`; most compatible servers only understand `max_tokens`.
    var isOfficialAPI: Bool {
        URL(string: baseURL)?.host?.lowercased() == "api.openai.com"
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let data = try await http.data(for: makeURLRequest(request, stream: false))
        return try Self.parseResponse(data)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        http.textStream(request: { try makeURLRequest(request, stream: true) }, delta: Self.textDelta(from:))
    }

    public func checkAvailability() async -> LLMAvailability {
        if kind.needsAPIKey { return secrets.apiKey(for: kind) == nil ? .missingAPIKey : .ready }
        // Local server: listing models is free and fast.
        do {
            var request = URLRequest(url: try .joining(base: baseURL, path: "models"))
            request.timeoutInterval = 3
            if let key = secrets.apiKey(for: kind) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            _ = try await http.data(for: request)
            return .ready
        } catch {
            return .error("No OpenAI-compatible server responded at \(baseURL). Start Ollama or LM Studio, or fix the base URL.")
        }
    }

    // MARK: Encoding

    func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        let apiKey = secrets.apiKey(for: kind)
        if kind.needsAPIKey, apiKey == nil { throw LLMError.missingAPIKey(kind) }

        var urlRequest = URLRequest(url: try .joining(base: baseURL, path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if stream { urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept") }

        let body = try Self.makeBody(
            request,
            model: request.resolvedModel(config: config),
            stream: stream,
            officialAPI: isOfficialAPI
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    /// GPT-5 and o-series reasoning models reject a custom temperature.
    static func isReasoningModel(_ model: String) -> Bool {
        let name = model.lowercased()
        if name.hasPrefix("gpt-5") { return true }
        guard name.hasPrefix("o"), name.count > 1 else { return false }
        return name[name.index(after: name.startIndex)].isNumber
    }

    static func makeBody(_ request: LLMRequest, model: String, stream: Bool, officialAPI: Bool) throws -> Body {
        var messages: [Body.Message] = []
        // json_object mode requires the word "JSON" in the prompt, so the instruction is added here too.
        if let system = request.effectiveSystemPrompt, !system.isEmpty {
            messages.append(.init(role: "system", content: .text(system)))
        }
        for message in request.messages {
            let parts = try message.parts.map { part -> Body.Part in
                switch part {
                case .text(let text):
                    return .text(text)
                case .image(let data, let mediaType):
                    let image = ImageResolver.resolve(data: data, mediaType: mediaType)
                    return .imageURL("data:\(image.mediaType);base64,\(image.data.base64EncodedString())")
                case .imageFile(let url):
                    let image = try ImageResolver.resolve(file: url)
                    return .imageURL("data:\(image.mediaType);base64,\(image.data.base64EncodedString())")
                }
            }
            // Plain string content is the most widely supported shape for local servers.
            let textOnly = parts.allSatisfy { if case .text = $0 { true } else { false } }
            let content: Body.Content = textOnly
                ? .text(parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n\n"))
                : .parts(parts)
            messages.append(.init(role: message.role.rawValue, content: content))
        }

        return Body(
            model: model,
            messages: messages,
            maxCompletionTokens: officialAPI ? request.maxTokens : nil,
            maxTokens: officialAPI ? nil : request.maxTokens,
            temperature: isReasoningModel(model) ? nil : request.temperature,
            responseFormat: request.responseFormat == .json ? .init(type: "json_object") : nil,
            reasoningEffort: request.preferLowLatency && isReasoningModel(model) ? (model.lowercased().hasPrefix("gpt-5") ? "minimal" : "low") : nil,
            stream: stream ? true : nil,
            streamOptions: stream && officialAPI ? .init(includeUsage: true) : nil
        )
    }

    struct Body: Encodable {
        var model: String
        var messages: [Message]
        var maxCompletionTokens: Int?
        var maxTokens: Int?
        var temperature: Double?
        var responseFormat: ResponseFormat?
        var reasoningEffort: String?
        var stream: Bool?
        var streamOptions: StreamOptions?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case reasoningEffort = "reasoning_effort"
            case maxCompletionTokens = "max_completion_tokens"
            case maxTokens = "max_tokens"
            case responseFormat = "response_format"
            case streamOptions = "stream_options"
        }

        struct ResponseFormat: Encodable { var type: String }

        struct StreamOptions: Encodable {
            var includeUsage: Bool
            enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
        }

        struct Message: Encodable {
            var role: String
            var content: Content
        }

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text): try container.encode(text)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }

        enum Part: Encodable {
            case text(String)
            case imageURL(String)

            private enum Keys: String, CodingKey { case type, text, imageURL = "image_url" }
            private struct ImageURL: Encodable { var url: String }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let url):
                    try container.encode("image_url", forKey: .type)
                    try container.encode(ImageURL(url: url), forKey: .imageURL)
                }
            }
        }
    }

    // MARK: Decoding

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
                var refusal: String?
            }

            var message: Message?
            var finishReason: String?
            enum CodingKeys: String, CodingKey { case message, finishReason = "finish_reason" }
        }

        struct Usage: Decodable {
            struct Details: Decodable {
                var cachedTokens: Int?
                enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
            }

            var promptTokens: Int?
            var completionTokens: Int?
            var promptTokensDetails: Details?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case promptTokensDetails = "prompt_tokens_details"
            }

            /// OpenAI's `prompt_tokens` includes cached tokens; `inputTokens` reports only the uncached part.
            var llmUsage: LLMUsage {
                let cached = promptTokensDetails?.cachedTokens ?? 0
                return LLMUsage(
                    inputTokens: max(0, (promptTokens ?? 0) - cached),
                    outputTokens: completionTokens ?? 0,
                    cacheReadTokens: cached
                )
            }
        }

        var model: String?
        var choices: [Choice]?
        var usage: Usage?
    }

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMError.invalidResponse("OpenAI: \(HTTPClient.apiErrorMessage(from: data) ?? error.localizedDescription)")
        }
        guard let choice = response.choices?.first, let message = choice.message else {
            throw LLMError.invalidResponse("OpenAI: \(HTTPClient.apiErrorMessage(from: data) ?? "response had no choices")")
        }
        if let refusal = message.refusal, !refusal.isEmpty, (message.content ?? "").isEmpty {
            throw LLMError.invalidResponse("OpenAI refused: \(refusal)")
        }
        return LLMResponse(text: message.content ?? "", model: response.model, usage: response.usage?.llmUsage)
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta?
        }

        struct ErrorBody: Decodable { var message: String? }

        var choices: [Choice]?
        var error: ErrorBody?
    }

    static func textDelta(from event: SSEEvent) throws -> String? {
        let payload = event.data.trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8)) else { return nil }
        if let error = chunk.error {
            throw LLMError.invalidResponse("OpenAI stream error: \(error.message ?? payload)")
        }
        return chunk.choices?.first?.delta?.content
    }
}
