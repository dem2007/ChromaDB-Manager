import Foundation
import Combine

/// Stores metadata schemas locally, one per collection.
///
/// ChromaDB has no notion of a schema, so the rules cannot live in the
/// database. They are kept in Application Support, keyed by collection name,
/// and can be exported to JSON to share between machines.
@MainActor
public final class SchemaStore: ObservableObject {
    @Published public private(set) var schemas: [String: MetadataSchema] = [:]

    private let file: GuardedJSONFile<[MetadataSchema]>
    private let log: LogHandler
    private var saveTask: Task<Void, Never>?

    /// Why nothing is being saved, when that is the case.
    public var persistenceProblem: String? { file.problem }

    public init(fileURL: URL = AppPaths.schemasFile, log: @escaping LogHandler = noopLogHandler) {
        self.file = GuardedJSONFile(url: fileURL, category: "Схемы", log: log)
        self.log = log
        self.schemas = Self.keyed(file.value(or: []))
    }

    private static func keyed(_ list: [MetadataSchema]) -> [String: MetadataSchema] {
        Dictionary(list.map { ($0.collectionName, $0) }, uniquingKeysWith: { _, last in last })
    }

    public static func load(from url: URL) -> [String: MetadataSchema] {
        keyed(GuardedJSONFile<[MetadataSchema]>(url: url, category: "Схемы").value(or: []))
    }

    public func schema(for collectionName: String) -> MetadataSchema? {
        schemas[collectionName]
    }

    public func hasSchema(for collectionName: String) -> Bool {
        guard let schema = schemas[collectionName] else { return false }
        return !schema.isEmpty
    }

    public func save(_ schema: MetadataSchema) {
        var stored = schema
        stored.updatedAt = Date()
        stored.fields = stored.fields.filter { !$0.trimmedKey.isEmpty }
        schemas[schema.collectionName] = stored
        persist()
        log(.success, "Схемы", "Схема коллекции «\(schema.collectionName)» сохранена: полей \(stored.fields.count)")
    }

    /// Replaces every schema at once, for a confirmed import. Unlike
    /// `save`, this does not touch `updatedAt`: the schema arriving from
    /// another machine was edited there, and rewriting the date would erase
    /// when that actually happened.
    public func replaceAll(_ replacement: [String: MetadataSchema]) {
        schemas = replacement
        persist()
    }

    public func remove(collectionName: String) {
        schemas.removeValue(forKey: collectionName)
        persist()
        log(.warning, "Схемы", "Схема коллекции «\(collectionName)» удалена")
    }

    /// Drops schemas whose collection no longer exists — they would otherwise
    /// pile up invisibly after collections are deleted.
    public func prune(keeping existingCollections: [String]) {
        let known = Set(existingCollections)
        let stale = schemas.keys.filter { !known.contains($0) }
        guard !stale.isEmpty else { return }
        for name in stale { schemas.removeValue(forKey: name) }
        persist()
        log(.info, "Схемы", "Удалены схемы несуществующих коллекций: \(stale.sorted().joined(separator: ", "))")
    }

    // MARK: - Export / import

    public func exportJSON(_ schema: MetadataSchema) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(schema)
    }

    /// Imports a schema exported elsewhere. The collection name is taken from
    /// the current collection, not from the file — the same rules are often
    /// applied to a differently named collection on another machine.
    public func importJSON(_ data: Data, collectionName: String) throws -> MetadataSchema {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var schema = try decoder.decode(MetadataSchema.self, from: data)
        schema.id = UUID()
        schema.collectionName = collectionName
        schema.updatedAt = Date()
        // Fresh ids: two collections must not share field identity.
        schema.fields = schema.fields.map { field in
            var copy = field
            copy.id = UUID()
            return copy
        }
        return schema
    }

    // MARK: - Persistence

    private func persist() {
        saveTask?.cancel()
        let snapshot = schemas.values.sorted { $0.collectionName < $1.collectionName }
        saveTask = Task { [file] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            file.write(snapshot)
        }
    }
}

/// Walks a collection page by page and reports documents that do not match the
/// schema. Nothing is changed — this is a report, not a migration.
public struct SchemaComplianceChecker {
    public struct Report {
        public let checked: Int
        public let offending: Int
        public let violations: [SchemaViolation]
        public let stoppedEarly: Bool

        public var isClean: Bool { offending == 0 }
    }

    public struct Progress {
        public let checked: Int
        public let total: Int
    }

    private let validator = MetadataSchemaValidator()
    public init() {}

    /// - Parameter violationLimit: stops collecting details after this many
    ///   problems; the counters keep going, so a badly broken collection does
    ///   not produce a report nobody can read.
    public func check(
        collection: ChromaCollection,
        schema: MetadataSchema,
        chroma: ChromaClient,
        pageSize: Int = 200,
        violationLimit: Int = 200,
        progress: @escaping (Progress) -> Void
    ) async throws -> Report {
        let total = (try? await chroma.count(collectionID: collection.id)) ?? 0
        var offset = 0
        var checked = 0
        var offending = 0
        var violations: [SchemaViolation] = []
        var stoppedEarly = false

        while true {
            try Task.checkCancellation()
            let page = try await chroma.getDocuments(
                collectionID: collection.id,
                limit: pageSize,
                offset: offset
            )
            if page.isEmpty { break }

            for document in page {
                let metadata = document.metadata ?? [:]
                let result = validator.validate(metadata, against: schema, documentID: document.id)
                if !result.isValid {
                    offending += 1
                    if violations.count < violationLimit {
                        violations.append(contentsOf: result.violations)
                    } else {
                        stoppedEarly = true
                    }
                }
                checked += 1
            }

            progress(Progress(checked: checked, total: total))
            if page.count < pageSize { break }
            offset += pageSize
        }

        return Report(checked: checked, offending: offending, violations: violations, stoppedEarly: stoppedEarly)
    }
}
