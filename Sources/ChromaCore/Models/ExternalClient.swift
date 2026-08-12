import Foundation
import CryptoKit

/// What one external client may do.
///
/// Everything is a deny-by-default whitelist: an empty collection list means
/// «nothing», not «everything». A permission model whose empty state is
/// permissive is one forgotten field away from an open database.
public struct ClientPermissions: Codable, Hashable, Sendable {
    /// Collection **names**. The API addresses data by UUID, so the proxy
    /// resolves one to the other (see `AccessController`).
    public var collections: [String]
    public var allowsWrite: Bool
    /// Documents per day. `nil` — no limit.
    public var maxDocumentsPerDay: Int?
    /// Bytes in one document's text. `nil` — no limit.
    public var maxDocumentBytes: Int?
    /// Requests a minute and how many may arrive at once. A loop in a
    /// client agent can spend a daily quota in a minute, and the daily limit
    /// does nothing to stop it.
    public var requestsPerMinute: Int
    public var burst: Int
    /// Writes are limited separately and more strictly: they cost the most and
    /// are the ones that change data.
    public var writesPerMinute: Int
    /// Origins allowed to call the proxy from a browser. Empty — no CORS
    /// headers at all, which is the default.
    public var allowedOrigins: [String]
    /// Потолок числа результатов в одном вызове MCP. `nil` — потолок
    /// по умолчанию, 10.
    ///
    /// Ограничение не от недоверия: выдача попадает в контекст модели целиком,
    /// и полсотни документов вытесняют оттуда сам разговор.
    public var maxSearchResults: Int?
    /// Умный поиск для запросов этого ключа. `nil` — как настроено
    /// у самой коллекции.
    ///
    /// Отдельно от настройки коллекции, потому что решения разные: человек у
    /// экрана видит выдачу и правит запрос, а агент — нет, и владелец базы
    /// вправе решить, что чужому ключу переранжирование ни к чему (
    /// наоборот, что ему оно нужнее всех).
    public var smartSearch: Bool?
    /// Удаление документов. Отдельно от записи и по умолчанию нет:
    /// снести коллекцию одним неудачным вызовом слишком легко, чтобы это
    /// право ехало вместе с обычной записью.
    public var allowsDelete: Bool

    public init(
        collections: [String] = [],
        allowsWrite: Bool = false,
        maxDocumentsPerDay: Int? = nil,
        maxDocumentBytes: Int? = nil,
        requestsPerMinute: Int = 120,
        burst: Int = 20,
        writesPerMinute: Int = 30,
        allowedOrigins: [String] = [],
        maxSearchResults: Int? = nil,
        smartSearch: Bool? = nil,
        allowsDelete: Bool = false
    ) {
        self.maxSearchResults = maxSearchResults.map { max(1, $0) }
        self.smartSearch = smartSearch
        self.allowsDelete = allowsDelete
        self.collections = collections
        self.allowsWrite = allowsWrite
        self.maxDocumentsPerDay = maxDocumentsPerDay
        self.maxDocumentBytes = maxDocumentBytes
        self.requestsPerMinute = max(1, requestsPerMinute)
        self.burst = max(1, burst)
        self.writesPerMinute = max(1, writesPerMinute)
        self.allowedOrigins = allowedOrigins
    }

    /// Older configurations have no limits recorded; they get the defaults
    /// rather than «без ограничений».
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collections = ((try? container.decodeIfPresent([String].self, forKey: .collections)) ?? nil) ?? []
        allowsWrite = ((try? container.decodeIfPresent(Bool.self, forKey: .allowsWrite)) ?? nil) ?? false
        maxDocumentsPerDay = (try? container.decodeIfPresent(Int.self, forKey: .maxDocumentsPerDay)) ?? nil
        maxDocumentBytes = (try? container.decodeIfPresent(Int.self, forKey: .maxDocumentBytes)) ?? nil
        requestsPerMinute = max(1, ((try? container.decodeIfPresent(Int.self, forKey: .requestsPerMinute)) ?? nil) ?? 120)
        burst = max(1, ((try? container.decodeIfPresent(Int.self, forKey: .burst)) ?? nil) ?? 20)
        writesPerMinute = max(1, ((try? container.decodeIfPresent(Int.self, forKey: .writesPerMinute)) ?? nil) ?? 30)
        allowedOrigins = ((try? container.decodeIfPresent([String].self, forKey: .allowedOrigins)) ?? nil) ?? []
        maxSearchResults = ((try? container.decodeIfPresent(Int.self, forKey: .maxSearchResults)) ?? nil).map { max(1, $0) }
        smartSearch = (try? container.decodeIfPresent(Bool.self, forKey: .smartSearch)) ?? nil
        // Право, которого в старой конфигурации не было, не появляется само:
        // отсутствие записи о нём — это «нельзя».
        allowsDelete = ((try? container.decodeIfPresent(Bool.self, forKey: .allowsDelete)) ?? nil) ?? false
    }

    /// Whether a browser page from this origin may talk to the proxy.
    public func allowsOrigin(_ origin: String) -> Bool {
        allowedOrigins.contains("*") || allowedOrigins.contains(origin)
    }

    public var allowsAnyOrigin: Bool { allowedOrigins.contains("*") }

    public func allows(collection: String) -> Bool {
        collections.contains(collection)
    }

    public var summary: String {
        var parts = [allowsWrite
            ? (allowsDelete
               ? String(localized: "чтение, запись и удаление")
               : String(localized: "чтение и запись"))
            : String(localized: "только чтение")]
        parts.append(collections.isEmpty
                     ? String(localized: "коллекции не выбраны")
                     : String(localized: "коллекций: \(collections.count)"))
        if let perDay = maxDocumentsPerDay {
            parts.append(String(localized: "не больше \(perDay) документов в сутки"))
        }
        if let bytes = maxDocumentBytes {
            parts.append(String(localized: "документ до \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"))
        }
        parts.append(String(localized: "\(requestsPerMinute.plainDigits) запр./мин (всплеск \(burst.plainDigits)), запись \(writesPerMinute.plainDigits)/мин"))
        if let maxSearchResults {
            parts.append(String(localized: "результатов в MCP: до \(maxSearchResults.plainDigits)"))
        }
        if let smartSearch {
            parts.append(smartSearch
                         ? String(localized: "умный поиск включён")
                         : String(localized: "умный поиск выключен"))
        }
        if !allowedOrigins.isEmpty {
            parts.append(allowsAnyOrigin
                         ? String(localized: "CORS: любой origin")
                         : String(localized: "CORS: origin-ов \(allowedOrigins.count)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A registered external client.
///
/// The key itself is **not stored anywhere** — only its SHA-256 and the first
/// characters for display. That is what makes «показывается один раз при
/// создании» true rather than merely promised: a lost key cannot be recovered
/// even by reading the app's own files, it can only be reissued.
public struct ExternalClient: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var keyHash: String
    /// Shown in the list so a key found elsewhere can be matched to a row.
    public var keyPrefix: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var isEnabled: Bool
    public var permissions: ClientPermissions

    public init(
        id: UUID = UUID(),
        name: String,
        keyHash: String,
        keyPrefix: String,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        isEnabled: Bool = true,
        permissions: ClientPermissions = ClientPermissions()
    ) {
        self.id = id
        self.name = name
        self.keyHash = keyHash
        self.keyPrefix = keyPrefix
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isEnabled = isEnabled
        self.permissions = permissions
    }

    /// Creates a client and returns the key — the only moment it exists.
    public static func issue(name: String, permissions: ClientPermissions = ClientPermissions()) -> (client: ExternalClient, key: String) {
        let key = ClientKey.generate()
        let client = ExternalClient(
            name: name,
            keyHash: ClientKey.hash(key),
            keyPrefix: ClientKey.prefix(of: key),
            permissions: permissions
        )
        return (client, key)
    }

    /// Replaces the key, keeping the identity and the permissions.
    public mutating func reissue() -> String {
        let key = ClientKey.generate()
        keyHash = ClientKey.hash(key)
        keyPrefix = ClientKey.prefix(of: key)
        return key
    }

    /// Kills the key without losing who this client is or what it was allowed
    /// to do — what «экстренная остановка» does to the whole registry (spec
    /// 5). Deleting the clients outright would also work, and would throw
    /// away the collection whitelists and limits the user had set up; after an
    /// emergency the shortest path back is «issue a new key», not «configure
    /// everything again».
    public mutating func revokeKey() {
        keyHash = ""
        keyPrefix = ""
        isEnabled = false
    }

    /// A client whose key was revoked: it has no key at all until one is issued.
    public var isRevoked: Bool { keyHash.isEmpty }
}

public enum ClientKey {
    /// Prefixed so a key found in someone's config is recognisable, and long
    /// enough that guessing is not a strategy.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        // A permission key from a predictable generator is not a permission key.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return "cdbm_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func prefix(of key: String) -> String {
        String(key.prefix(12))
    }

    /// The header the client sent its key in.
    ///
    /// Both spellings are accepted because both are in use: ChromaDB's own
    /// token transport offers `X-Chroma-Token` and `Authorization: Bearer`,
    /// and the real Python client passes either through `headers=`.
    public static func extract(authorization: String?, chromaToken: String?) -> String? {
        if let chromaToken, !chromaToken.isEmpty { return chromaToken }
        guard let authorization, !authorization.isEmpty else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame {
            return parts[1]
        }
        return authorization
    }
}
