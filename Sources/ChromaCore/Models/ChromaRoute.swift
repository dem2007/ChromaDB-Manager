import Foundation

/// What a request to the ChromaDB v2 API is asking for.
///
/// Built from traffic captured from the real `chromadb` Python client, not from
/// the shape of the API as documented. Three things that captured traffic shows
/// and guesswork would get wrong:
///
/// * `get` and `query` are **reads performed with POST**, so the HTTP method
///   cannot classify access — only the last path segment can;
/// * `count` is a **GET** with a query string (`?read_level=index_and_wal`);
/// * `DELETE …/collections/{ref}` passes the collection **name**, while data
///   operations pass its **UUID** — the same position in the path holds two
///   different kinds of identifier.
public struct ChromaRoute: Equatable {
    public enum Access: String, Codable, Equatable, Sendable {
        /// Reads data or metadata.
        case read
        /// Creates, changes or removes something.
        case write
        /// Heartbeat, version, identity — no collection involved.
        case service
    }

    public enum Target: Equatable {
        case none
        /// The API uses one path position for both UUIDs and names, so which
        /// one this is can only be guessed from its shape.
        case collection(reference: String, looksLikeID: Bool)

        public var reference: String? {
            if case .collection(let reference, _) = self { return reference }
            return nil
        }
    }

    /// Stable name of the operation, used in the audit log and in permissions.
    public let operation: String
    public let access: Access
    public let target: Target
    public let tenant: String?
    public let database: String?
    /// False for anything not in the table below. A permission layer must deny
    /// unknown **writes** rather than guess, so this has to be
    /// distinguishable from a known operation.
    public let isKnown: Bool

    public var collectionReference: String? { target.reference }

    public init(
        operation: String,
        access: Access,
        target: Target = .none,
        tenant: String? = nil,
        database: String? = nil,
        isKnown: Bool = true
    ) {
        self.operation = operation
        self.access = access
        self.target = target
        self.tenant = tenant
        self.database = database
        self.isKnown = isKnown
    }

    /// Sub-paths under `…/collections/{ref}/` and what they do.
    private static let collectionOperations: [String: Access] = [
        "add": .write,
        "upsert": .write,
        "update": .write,
        "delete": .write,
        "get": .read,
        "query": .read,
        "count": .read,
    ]

    public static func parse(method: String, path: String) -> ChromaRoute {
        let method = method.uppercased()
        // The query string carries no routing information (`?read_level=…`).
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        var segments = withoutQuery
            .split(separator: "/")
            .map { $0.removingPercentEncoding ?? String($0) }

        guard segments.count >= 2, segments[0] == "api", segments[1] == "v2" else {
            return unknown(method: method)
        }
        segments.removeFirst(2)

        guard let first = segments.first else {
            return unknown(method: method)
        }

        // Service endpoints: /api/v2/{heartbeat,version,healthcheck,…}
        if first != "tenants" {
            switch first {
            case "heartbeat", "version", "healthcheck", "pre-flight-checks":
                return ChromaRoute(operation: first, access: .service)
            case "auth":
                // The real client asks for this before anything else; a proxy
                // that does not pass it through breaks the client on creation.
                return ChromaRoute(operation: "auth_identity", access: .service)
            case "reset":
                return ChromaRoute(operation: "reset", access: .write)
            default:
                return unknown(method: method)
            }
        }

        // /api/v2/tenants/{tenant}[/databases/{database}[/collections[/…]]]
        guard segments.count >= 2 else { return unknown(method: method) }
        let tenant = segments[1]
        guard segments.count >= 3 else {
            return ChromaRoute(operation: "get_tenant", access: .service, tenant: tenant)
        }
        guard segments[2] == "databases", segments.count >= 4 else {
            return unknown(method: method, tenant: tenant)
        }
        let database = segments[3]
        guard segments.count >= 5 else {
            return ChromaRoute(operation: "get_database", access: .service, tenant: tenant, database: database)
        }
        guard segments[4] == "collections" else {
            return unknown(method: method, tenant: tenant, database: database)
        }

        // …/collections
        guard segments.count >= 6 else {
            return ChromaRoute(
                operation: method == "POST" ? "create_collection" : "list_collections",
                access: method == "POST" ? .write : .read,
                tenant: tenant,
                database: database
            )
        }

        let reference = segments[5]
        let target = Target.collection(reference: reference, looksLikeID: looksLikeUUID(reference))

        // …/collections/{ref}
        guard segments.count >= 7 else {
            switch method {
            case "DELETE":
                return ChromaRoute(operation: "delete_collection", access: .write, target: target, tenant: tenant, database: database)
            case "PUT", "PATCH":
                return ChromaRoute(operation: "update_collection", access: .write, target: target, tenant: tenant, database: database)
            case "GET":
                return ChromaRoute(operation: "get_collection", access: .read, target: target, tenant: tenant, database: database)
            default:
                return unknown(method: method, target: target, tenant: tenant, database: database)
            }
        }

        // …/collections/{ref}/{operation}
        let operation = segments[6]
        guard let access = collectionOperations[operation] else {
            return unknown(method: method, target: target, tenant: tenant, database: database)
        }
        return ChromaRoute(operation: operation, access: access, target: target, tenant: tenant, database: database)
    }

    /// Anything we do not recognise. Reads stay reads so a new read-only
    /// endpoint keeps working after a ChromaDB update; everything else counts
    /// as a write, which is what deny-by-default needs.
    private static func unknown(
        method: String,
        target: Target = .none,
        tenant: String? = nil,
        database: String? = nil
    ) -> ChromaRoute {
        ChromaRoute(
            operation: "unknown",
            access: (method == "GET" || method == "HEAD") ? .read : .write,
            target: target,
            tenant: tenant,
            database: database,
            isKnown: false
        )
    }

    static func looksLikeUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Short human wording for the audit log.
    public var title: String {
        switch operation {
        case "add": return String(localized: "добавление")
        case "upsert": return String(localized: "запись (upsert)")
        case "update": return String(localized: "изменение")
        case "delete": return String(localized: "удаление записей")
        case "get": return String(localized: "чтение")
        case "query": return String(localized: "поиск")
        case "count": return String(localized: "счётчик")
        case "create_collection": return String(localized: "создание коллекции")
        case "delete_collection": return String(localized: "удаление коллекции")
        case "update_collection": return String(localized: "изменение коллекции")
        case "get_collection": return String(localized: "чтение коллекции")
        case "list_collections": return String(localized: "список коллекций")
        case "reset": return String(localized: "сброс базы")
        case "unknown": return String(localized: "неизвестная операция")
        default: return operation
        }
    }
}
