import Foundation
import Synchronization

/// Multicast fan-out to any number of `AsyncStream` subscribers.
final class SubscriberSet<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ element: Element) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(element)
        }
    }

    func finishAll() {
        let all = continuations.withLock { dict in
            defer { dict.removeAll() }
            return Array(dict.values)
        }
        all.forEach { $0.finish() }
    }
}

/// Fan-out keyed by e.g. session ID: each key has its own subscriber list.
final class KeyedSubscriberSet<Key: Hashable & Sendable, Element: Sendable>: Sendable {
    private let continuations = Mutex<[Key: [UUID: AsyncStream<Element>.Continuation]]>([:])
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    func subscribe(_ key: Key) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { dict in
                dict[key]?.removeValue(forKey: id)
                if dict[key]?.isEmpty == true { dict.removeValue(forKey: key) }
            }
        }
        continuations.withLock { $0[key, default: [:]][id] = continuation }
        return stream
    }

    func hasSubscribers(_ key: Key) -> Bool {
        continuations.withLock { $0[key]?.isEmpty == false }
    }

    func yield(_ element: Element, to key: Key) {
        guard let targets = continuations.withLock({ $0[key].map { Array($0.values) } }) else { return }
        for continuation in targets { continuation.yield(element) }
    }

    func finish(_ key: Key) {
        let targets = continuations.withLock { $0.removeValue(forKey: key).map { Array($0.values) } } ?? []
        targets.forEach { $0.finish() }
    }

    func finishAll() {
        let all = continuations.withLock { dict in
            defer { dict.removeAll() }
            return dict.values.flatMap(\.values)
        }
        all.forEach { $0.finish() }
    }
}
