import Foundation
import Security

/// Stores secrets (API keys) as generic passwords in the user's Keychain.
nonisolated struct KeychainStore: Sendable {
    enum KeychainError: LocalizedError, Equatable {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "companion") + ".api-keys") {
        self.service = service
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value; an empty value deletes the item.
    func write(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(account: account)
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
