import Foundation
import LLMKit
import os

/// Whether each AI provider works right now: API providers by whether a key is saved (read live, so a new key
/// applies at once), CLIs and local servers by their last check.
public final class ProviderReadiness: Sendable {
    private let hasAPIKey: @Sendable (LLMProviderKind) -> Bool
    private let checked = OSAllocatedUnfairLock<[LLMProviderKind: Bool]>(initialState: [:])

    public init(hasAPIKey: @escaping @Sendable (LLMProviderKind) -> Bool) {
        self.hasAPIKey = hasAPIKey
    }

    /// true/false, or nil when a CLI or local server hasn't been checked yet.
    public func isReady(_ kind: LLMProviderKind) -> Bool? {
        kind.needsAPIKey ? hasAPIKey(kind) : checked.withLock { $0[kind] }
    }

    public func record(_ kind: LLMProviderKind, ready: Bool) {
        checked.withLock { $0[kind] = ready }
    }
}
