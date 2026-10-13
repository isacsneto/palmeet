import Foundation
import Synchronization
import Testing
@testable import LLMKit

/// URLProtocol stub routed by host, so suites using different hosts can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data]

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, chunks: [Data(text.utf8)])
        }

        static func sse(_ text: String) -> Reply {
            // Split into small chunks to exercise line reassembly across reads.
            let data = Data(text.utf8)
            let chunks = stride(from: 0, to: data.count, by: 7).map { data[$0..<min($0 + 7, data.count)] }
            return Reply(headers: ["Content-Type": "text/event-stream"], chunks: chunks.map { Data($0) })
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let captured = Mutex<[String: [URLRequest]]>([:])

    /// Registers a handler for a unique host and returns a session plus the base URL to use.
    static func register(_ handler: @escaping Handler) -> (session: URLSession, host: String) {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return (URLSession(configuration: configuration), host)
    }

    static func requests(for host: String) -> [URLRequest] {
        captured.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        Self.captured.withLock { $0[host, default: []].append(request) }
        let reply = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func jsonObject(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var parts: [String] = []
    for try await part in stream { parts.append(part) }
    return parts
}

/// A fresh temporary directory, removed by the caller.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LLMKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes an executable shell script.
@discardableResult
func writeScript(_ body: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: name)
    try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

func sampleJob(images: [URL] = [], system: String? = nil, model: String? = nil, prompt: String = "Hello") -> CLIJob {
    let directory = URL(filePath: "/tmp/palmeet-job")
    return CLIJob(
        prompt: prompt,
        system: system,
        model: model,
        imageFiles: images,
        workingDirectory: directory,
        promptFile: directory.appending(path: "prompt.md")
    )
}
