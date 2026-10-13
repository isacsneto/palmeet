import Foundation
import Network
import Synchronization

/// One accepted WebSocket connection. Thin wrapper over `NWConnection` that delivers whole
/// text/binary messages and reports closure exactly once.
final class BridgeConnection: Sendable {
    enum Message: Sendable {
        case text(Data)
        case binary(Data)
    }

    /// Application close codes (4000–4999 are private-use in RFC 6455).
    enum CloseCode: UInt16 {
        case normal = 1000
        case goingAway = 1001
        case protocolViolation = 4400
        case unauthorized = 4401
        case helloTimeout = 4408
        case replaced = 4409
    }

    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onMessage: @Sendable (BridgeConnection, Message) -> Void
    private let onClose: @Sendable (BridgeConnection) -> Void
    private let closed = Mutex(false)

    init(
        connection: NWConnection, queue: DispatchQueue,
        onMessage: @escaping @Sendable (BridgeConnection, Message) -> Void,
        onClose: @escaping @Sendable (BridgeConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onMessage = onMessage
        self.onClose = onClose
    }

    var isLoopback: Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receiveNext()
            case .failed, .cancelled: self.markClosed()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: AppMessage) {
        guard let data = try? message.encoded() else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Sends a close frame with `code`, then tears the connection down.
    func close(_ code: CloseCode) {
        guard !isClosed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code.rawValue >= 4000 ? .privateCode(code.rawValue) : .protocolCode(
            code == .goingAway ? .goingAway : .normalClosure
        )
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = self.connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        // Make sure we don't linger if the peer never reads the close frame.
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    func cancel() { connection.cancel() }

    private var isClosed: Bool { closed.withLock { $0 } }

    private func markClosed() {
        let first = closed.withLock { wasClosed in
            defer { wasClosed = true }
            return !wasClosed
        }
        guard first else { return }
        connection.stateUpdateHandler = nil
        onClose(self)
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                self.connection.cancel()
                self.markClosed()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?: self.onMessage(self, .text(content ?? Data()))
            case .binary?: self.onMessage(self, .binary(content ?? Data()))
            case .close?:
                self.connection.cancel()
                self.markClosed()
                return
            default:
                if metadata == nil, content == nil {
                    // End of stream without a close frame.
                    self.connection.cancel()
                    self.markClosed()
                    return
                }
            }
            self.receiveNext()
        }
    }
}
