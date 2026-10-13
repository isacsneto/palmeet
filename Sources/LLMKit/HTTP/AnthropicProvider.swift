import Foundation

/// Claude via the Anthropic Messages API (`POST /v1/messages`).
public struct AnthropicProvider: LLMProvider {
    public static let defaultBaseURL = "https://api.anthropic.com/v1"
    public static let apiVersion = "2023-06-01"

    public let config: LLMProviderConfig
    private let secrets: any SecretStore
    private let http: HTTPClient

    public var kind: LLMProviderKind { .anthropicAPI }
    public var capabilities: LLMCapabilities { [.images, .streaming, .jsonMode, .promptCaching] }
    public var isSlow: Bool { false }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .anthropicAPI), secrets: any SecretStore, session: URLSession = .shared) {
        self.config = config
        self.secrets = secrets
        self.http = HTTPClient(session: session)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let data = try await http.data(for: makeURLRequest(request, stream: false))
        return try Self.parseResponse(data)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        http.textStream(request: { try makeURLRequest(request, stream: true) }, delta: Self.textDelta(from:))
    }

    public func checkAvailability() async -> LLMAvailability {
        secrets.apiKey(for: kind) == nil ? .missingAPIKey : .ready
    }

    // MARK: Encoding

    func makeURLRequest(_ request: LLMRequest, stream: Bool) throws -> URLRequest {
        guard let apiKey = secrets.apiKey(for: kind) else { throw LLMError.missingAPIKey(kind) }
        var urlRequest = URLRequest(url: try .joining(base: config.baseURL ?? Self.defaultBaseURL, path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if stream { urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept") }
        urlRequest.httpBody = try JSONEncoder().encode(Self.makeBody(request, model: request.resolvedModel(config: config), stream: stream))
        return urlRequest
    }

    static func makeBody(_ request: LLMRequest, model: String, stream: Bool) throws -> Body {
        var system: [Body.SystemBlock] = []
        if let text = request.system, !text.isEmpty {
            system.append(.init(text: text, cacheControl: request.cacheSystemPrompt ? .ephemeral : nil))
        }
        // A separate trailing block keeps the cached prefix byte-identical across text/JSON calls.
        if request.responseFormat == .json {
            system.append(.init(text: PromptSnippets.jsonOnly, cacheControl: nil))
        }

        let messages = try request.messages.map { message in
            Body.Message(role: message.role.rawValue, content: try message.parts.map { part in
                switch part {
                case .text(let text):
                    return .text(text)
                case .image(let data, let mediaType):
                    let image = ImageResolver.resolve(data: data, mediaType: mediaType)
                    return .image(mediaType: image.mediaType, base64: image.data.base64EncodedString())
                case .imageFile(let url):
                    let image = try ImageResolver.resolve(file: url)
                    return .image(mediaType: image.mediaType, base64: image.data.base64EncodedString())
                }
            })
        }

        return Body(
            model: model,
            maxTokens: request.maxTokens,
            system: system.isEmpty ? nil : system,
            messages: messages,
            temperature: request.temperature,
            stream: stream ? true : nil
        )
    }

    struct Body: Encodable {
        var model: String
        var maxTokens: Int
        var system: [SystemBlock]?
        var messages: [Message]
        var temperature: Double?
        var stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, system, messages, temperature, stream
            case maxTokens = "max_tokens"
        }

        struct CacheControl: Encodable {
            var type: String
            static let ephemeral = CacheControl(type: "ephemeral")
        }

        struct SystemBlock: Encodable {
            var type = "text"
            var text: String
            var cacheControl: CacheControl?

            enum CodingKeys: String, CodingKey {
                case type, text
                case cacheControl = "cache_control"
            }
        }

        struct Message: Encodable {
            var role: String
            var content: [Block]
        }

        enum Block: Encodable {
            case text(String)
            case image(mediaType: String, base64: String)

            private enum Keys: String, CodingKey { case type, text, source }
            private struct Source: Encodable {
                var type = "base64"
                var mediaType: String
                var data: String
                enum CodingKeys: String, CodingKey { case type, data, mediaType = "media_type" }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .image(let mediaType, let base64):
                    try container.encode("image", forKey: .type)
                    try container.encode(Source(mediaType: mediaType, data: base64), forKey: .source)
                }
            }
        }
    }

    // MARK: Decoding

    private struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }

        var model: String?
        var content: [Block]
        var usage: Usage?
        var stopReason: String?

        enum CodingKeys: String, CodingKey {
            case model, content, usage
            case stopReason = "stop_reason"
        }
    }

    private struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }

        /// `inputTokens` counts every input token that was not a cache read (including cache writes).
        var llmUsage: LLMUsage {
            LLMUsage(
                inputTokens: (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0),
                outputTokens: outputTokens ?? 0,
                cacheReadTokens: cacheReadInputTokens ?? 0
            )
        }
    }

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Anthropic: \(HTTPClient.apiErrorMessage(from: data) ?? error.localizedDescription)")
        }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        if text.isEmpty, response.stopReason == "refusal" {
            throw LLMError.invalidResponse("Anthropic: the model declined to respond.")
        }
        return LLMResponse(text: text, model: response.model, usage: response.usage?.llmUsage)
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
        }

        struct ErrorBody: Decodable {
            var type: String?
            var message: String?
        }

        var type: String
        var delta: Delta?
        var error: ErrorBody?
    }

    static func textDelta(from event: SSEEvent) throws -> String? {
        guard let parsed = try? JSONDecoder().decode(StreamEvent.self, from: Data(event.data.utf8)) else { return nil }
        switch parsed.type {
        case "content_block_delta" where parsed.delta?.type == "text_delta":
            return parsed.delta?.text
        case "error":
            let kind = parsed.error?.type ?? "error"
            throw LLMError.invalidResponse("Anthropic stream \(kind): \(parsed.error?.message ?? event.data)")
        default:
            return nil
        }
    }
}
