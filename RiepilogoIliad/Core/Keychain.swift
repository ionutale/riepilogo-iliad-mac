import Foundation
import Security

/// Password storage abstraction (fakeable in tests).
protocol CredentialStore: Sendable {
    func password(for accountID: UUID) throws -> String?
    func setPassword(_ password: String, for accountID: UUID) throws
    func deletePassword(for accountID: UUID) throws
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialStore: CredentialStore {
    let service = "riepilogo-iliad"

    private func query(accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
        ]
    }

    func password(for accountID: UUID) throws -> String? {
        var q = query(accountID: accountID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, for accountID: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(
            query(accountID: accountID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var q = query(accountID: accountID)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func deletePassword(for accountID: UUID) throws {
        let status = SecItemDelete(query(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// In-memory store for tests and previews.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func password(for accountID: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountID]
    }

    func setPassword(_ password: String, for accountID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = password
    }

    func deletePassword(for accountID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }
}
