import Foundation

/// Thin URLSession wrapper shared by the HTTP providers: status validation, error mapping and SSE streaming.
struct HTTPClient: Sendable {
    let session: URLSession

    func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.map(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Self.httpError(status: http.statusCode, body: data)
        }
        return data
    }

    /// Streams SSE events; non-2xx responses throw `LLMError.http` with the provider's error message.
    func events(for request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 64_000 { break }
                        }
                        throw Self.httpError(status: http.statusCode, body: body)
                    }
                    try await SSEParser.forEachEvent(in: bytes) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds the request lazily (so missing keys surface as stream errors) and maps each SSE event to a text delta.
    /// `delta` returns `nil` for events without text; throwing ends the stream with that error.
    func textStream(
        request makeRequest: @escaping @Sendable () throws -> URLRequest,
        delta: @escaping @Sendable (SSEEvent) throws -> String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events(for: try makeRequest()) {
                        if let text = try delta(event), !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Maps transport errors to `LLMError` where there is a clear equivalent.
    static func map(_ error: Error) -> Error {
        if error is LLMError { return error }
        if error is CancellationError { return LLMError.cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return LLMError.timeout
            case .cancelled: return LLMError.cancelled
            default: return error
            }
        }
        return error
    }

    static func httpError(status: Int, body: Data) -> LLMError {
        let message = apiErrorMessage(from: body)
            ?? String(decoding: body.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String? = switch status {
        case 401, 403: "Authentication failed. Check the API key in Settings → AI Providers."
        case 404: "Not found. Check the model name and base URL."
        case 429: "Rate limited or out of quota."
        case 500...599: "The provider had a server error; try again shortly."
        default: nil
        }
        let body = [prefix, message.isEmpty ? nil : message].compactMap { $0 }.joined(separator: " ")
        return .http(status: status, body: body)
    }

    /// Extracts `error.message` (Anthropic/OpenAI/Gemini) or a top-level `message` from an error body.
    static func apiErrorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            let type = (error["type"] as? String) ?? (error["status"] as? String)
            switch (type, message) {
            case let (type?, message?): return "\(message) (\(type))"
            case let (nil, message?): return message
            case let (type?, nil): return type
            default: break
            }
        }
        if let error = object["error"] as? String { return error }
        return object["message"] as? String
    }
}

extension URL {
    /// Appends a path like "chat/completions" to a base URL string that may or may not end in "/".
    static func joining(base: String, path: String) throws -> URL {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + path), url.scheme != nil else {
            throw LLMError.invalidResponse("Invalid base URL: \(base)")
        }
        return url
    }
}

/// Resolves image content parts to bytes and a media type.
enum ImageResolver {
    static func resolve(data: Data, mediaType: String) -> (data: Data, mediaType: String) {
        (data, mediaType.isEmpty ? sniffMediaType(data) : mediaType)
    }

    static func resolve(file url: URL) throws -> (data: Data, mediaType: String) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LLMError.invalidResponse("Could not read image at \(url.path): \(error.localizedDescription)")
        }
        return (data, mediaType(forPathExtension: url.pathExtension) ?? sniffMediaType(data))
    }

    static func mediaType(forPathExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        default: nil
        }
    }

    static func fileExtension(forMediaType mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic": "heic"
        default: "jpg"
        }
    }

    static func sniffMediaType(_ data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if prefix.count >= 12, prefix[0...3] == [0x52, 0x49, 0x46, 0x46], prefix[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/jpeg"
    }
}

extension LLMRequest {
    /// The model to use: per-request override, then config, then the provider default.
    func resolvedModel(config: LLMProviderConfig) -> String {
        if let model, !model.isEmpty { return model }
        if !config.model.isEmpty { return config.model }
        return config.kind.defaultModel
    }

    /// System prompt with the JSON-only instruction appended when needed.
    var effectiveSystemPrompt: String? {
        guard responseFormat == .json else { return system }
        guard let system, !system.isEmpty else { return PromptSnippets.jsonOnly }
        return system + "\n\n" + PromptSnippets.jsonOnly
    }
}
