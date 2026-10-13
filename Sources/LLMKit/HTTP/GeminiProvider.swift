import Foundation

/// Gemini via the Generative Language API (`models/{model}:generateContent`).
public struct GeminiProvider: LLMProvider {
    public static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    public let config: LLMProviderConfig
    private let secrets: any SecretStore
    private let http: HTTPClient

    public var kind: LLMProviderKind { .geminiAPI }
    public var capabilities: LLMCapabilities { [.images, .streaming, .jsonMode] }
    public var isSlow: Bool { false }

    public init(config: LLMProviderConfig = LLMProviderConfig(kind: .geminiAPI), secrets: any SecretStore, session: URLSession = .shared) {
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
        var model = request.resolvedModel(config: config)
        if model.hasPrefix("models/") { model.removeFirst("models/".count) }
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let method = stream ? "streamGenerateContent?alt=sse" : "generateContent"

        var urlRequest = URLRequest(url: try .joining(base: config.baseURL ?? Self.defaultBaseURL, path: "models/\(encodedModel):\(method)"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(Self.makeBody(request, model: model))
        return urlRequest
    }

    static func makeBody(_ request: LLMRequest, model: String = "") throws -> Body {
        let contents = try request.messages.map { message in
            Body.Content(
                role: message.role == .assistant ? "model" : "user",
                parts: try message.parts.map { part in
                    switch part {
                    case .text(let text):
                        return .text(text)
                    case .image(let data, let mediaType):
                        let image = ImageResolver.resolve(data: data, mediaType: mediaType)
                        return .inlineData(mimeType: image.mediaType, base64: image.data.base64EncodedString())
                    case .imageFile(let url):
                        let image = try ImageResolver.resolve(file: url)
                        return .inlineData(mimeType: image.mediaType, base64: image.data.base64EncodedString())
                    }
                }
            )
        }
        // Native JSON mode; the system prompt stays as written.
        let system = request.system.flatMap { $0.isEmpty ? nil : Body.Content(role: nil, parts: [.text($0)]) }
        return Body(
            contents: contents,
            systemInstruction: system,
            generationConfig: .init(
                maxOutputTokens: request.maxTokens,
                temperature: request.temperature,
                responseMimeType: request.responseFormat == .json ? "application/json" : nil,
                // Flash models can disable thinking entirely; Pro can't, so it keeps its default budget.
                thinkingConfig: request.preferLowLatency && model.lowercased().contains("flash") ? .init(thinkingBudget: 0) : nil
            )
        )
    }

    struct Body: Encodable {
        var contents: [Content]
        var systemInstruction: Content?
        var generationConfig: GenerationConfig

        struct Content: Encodable {
            var role: String?
            var parts: [Part]
        }

        struct GenerationConfig: Encodable {
            var maxOutputTokens: Int
            var temperature: Double?
            var responseMimeType: String?
            var thinkingConfig: ThinkingConfig?

            struct ThinkingConfig: Encodable {
                var thinkingBudget: Int
            }
        }

        enum Part: Encodable {
            case text(String)
            case inlineData(mimeType: String, base64: String)

            private enum Keys: String, CodingKey { case text, inlineData = "inline_data" }
            private struct InlineData: Encodable {
                var mimeType: String
                var data: String
                enum CodingKeys: String, CodingKey { case data, mimeType = "mime_type" }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                switch self {
                case .text(let text):
                    try container.encode(text, forKey: .text)
                case .inlineData(let mimeType, let base64):
                    try container.encode(InlineData(mimeType: mimeType, data: base64), forKey: .inlineData)
                }
            }
        }
    }

    // MARK: Decoding

    private struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    var text: String?
                    var thought: Bool?
                }

                var parts: [Part]?
            }

            var content: Content?
            var finishReason: String?
        }

        struct Usage: Decodable {
            var promptTokenCount: Int?
            var candidatesTokenCount: Int?
            var cachedContentTokenCount: Int?
            var thoughtsTokenCount: Int?
        }

        struct Feedback: Decodable { var blockReason: String? }

        var candidates: [Candidate]?
        var usageMetadata: Usage?
        var modelVersion: String?
        var promptFeedback: Feedback?

        /// Visible answer text, skipping "thought" parts.
        var text: String {
            (candidates?.first?.content?.parts ?? [])
                .filter { $0.thought != true }
                .compactMap(\.text)
                .joined()
        }
    }

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMError.invalidResponse("Gemini: \(HTTPClient.apiErrorMessage(from: data) ?? error.localizedDescription)")
        }
        if let reason = response.promptFeedback?.blockReason {
            throw LLMError.invalidResponse("Gemini blocked the prompt (\(reason)).")
        }
        let text = response.text
        if text.isEmpty {
            let reason = response.candidates?.first?.finishReason ?? "no candidates"
            throw LLMError.invalidResponse("Gemini returned no text (finish reason: \(reason)). If this is MAX_TOKENS, raise maxTokens: thinking tokens count against it.")
        }
        let usage = response.usageMetadata.map { usage in
            let cached = usage.cachedContentTokenCount ?? 0
            return LLMUsage(
                inputTokens: max(0, (usage.promptTokenCount ?? 0) - cached),
                outputTokens: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
                cacheReadTokens: cached
            )
        }
        return LLMResponse(text: text, model: response.modelVersion, usage: usage)
    }

    static func textDelta(from event: SSEEvent) throws -> String? {
        let data = Data(event.data.utf8)
        if event.data.contains("\"error\""), let message = HTTPClient.apiErrorMessage(from: data) {
            throw LLMError.invalidResponse("Gemini stream error: \(message)")
        }
        guard let chunk = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        if let reason = chunk.promptFeedback?.blockReason {
            throw LLMError.invalidResponse("Gemini blocked the prompt (\(reason)).")
        }
        return chunk.text
    }
}
