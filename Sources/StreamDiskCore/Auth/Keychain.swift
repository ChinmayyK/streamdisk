import Foundation
import Security

/// Generic-password items in the user's login keychain.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "app.streamdisk") {
        self.service = service
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")
        }
    }

    public func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    public func write(_ data: Data, for account: String) throws {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw Failure(status: add) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
