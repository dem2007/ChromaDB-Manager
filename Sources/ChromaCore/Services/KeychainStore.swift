import Foundation
import Security

/// Access tokens live in the login Keychain — never in UserDefaults, the JSON
/// config or the logs (see spec. The rest of a server profile is plain
/// configuration and stays in `config.json`.
public struct KeychainStore {
    public enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
                return String(localized: "Ошибка Keychain: \(message)")
            }
        }
    }

    public let service: String

    public init(service: String = "io.github.chromadbmanager.tokens") {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores (or replaces) a token. An empty value removes the item, so the
    /// UI can clear a token by emptying the field.
    public func set(_ token: String, for account: String) throws {
        guard !token.isEmpty else {
            try remove(account: account)
            return
        }

        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unexpectedStatus(update) }
        case errSecItemNotFound:
            query.merge(attributes) { _, new in new }
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func token(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes every item this app stored, by service prefix.
    ///
    /// Used only by the «удалить все данные» action: the prefix is what
    /// makes «все элементы, созданные приложением» a statement the code can
    /// keep, rather than a list somebody has to remember to update.
    @discardableResult
    public func removeAllAppItems() -> Int {
        var removed = 0
        for service in Self.allServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess { removed += 1 }
        }
        return removed
    }

    /// Every Keychain service the app writes under — currently one, and the
    /// list exists so that adding a second one cannot be forgotten here.
    /// Client keys are deliberately not in it: only their hashes are stored,
    /// in the configuration file.
    public static let allServices = ["io.github.chromadbmanager.tokens"]

    public func hasToken(for account: String) -> Bool {
        ((try? token(for: account)) ?? nil) != nil
    }
}

public extension ServerProfile {
    /// Keychain account name for this profile's token.
    var keychainAccount: String { "server-profile-\(id.uuidString)" }

    /// Builds the endpoint, adding the auth header when a token is stored.
    func endpoint(with token: String?) -> ChromaEndpoint {
        var result = endpoint
        if let token, !token.isEmpty {
            switch tokenHeader {
            case .authorizationBearer:
                result.headers["Authorization"] = "Bearer \(token)"
            case .xChromaToken:
                result.headers["X-Chroma-Token"] = token
            }
        }
        return result
    }
}
