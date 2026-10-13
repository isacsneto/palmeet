import Foundation
import Security
import Synchronization

/// Stores API keys as generic passwords in the user's login Keychain.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "app.palmeet"

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func secret(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    public func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            item[kSecAttrLabel as String] = "PalMeet (\(account))"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deleteSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Non-persistent secret store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage: Mutex<[String: String]>

    public init(_ initial: [String: String] = [:]) {
        storage = Mutex(initial)
    }

    public func secret(for account: String) -> String? {
        storage.withLock { $0[account] }
    }

    public func setSecret(_ value: String, for account: String) throws {
        storage.withLock { $0[account] = value }
    }

    public func deleteSecret(for account: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: account) }
    }
}

extension SecretStore {
    /// Convenience for provider kinds: the API key stored under `kind.secretAccount`, trimmed.
    public func apiKey(for kind: LLMProviderKind) -> String? {
        guard let key = secret(for: kind.secretAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}
