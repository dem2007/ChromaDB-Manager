import Foundation

/// ChromaDB metadata values are scalars only (string / number / bool).
public enum MetadataValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        // Nested objects/arrays are not valid Chroma metadata; keep them readable anyway.
        self = .string("<unsupported>")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var displayString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "—"
        }
    }

    /// Which of the five kinds this is, for messages about type mismatches.
    public var kindName: String {
        switch self {
        case .string: return String(localized: "строка")
        case .int: return String(localized: "целое")
        case .double: return String(localized: "дробное")
        case .bool: return String(localized: "логическое")
        case .null: return String(localized: "пусто")
        }
    }

    /// Comparisons (`$gt` and friends) are numbers-only on the server side.
    public var isNumber: Bool {
        switch self {
        case .int, .double: return true
        default: return false
        }
    }

    /// Parses free-form user input into the most specific scalar type.
    public static func inferred(from text: String) -> MetadataValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .string("") }
        if let value = Int(trimmed) { return .int(value) }
        if let value = Double(trimmed) { return .double(value) }
        if trimmed == "true" || trimmed == "false" { return .bool(trimmed == "true") }
        return .string(trimmed)
    }
}

public typealias ChromaMetadata = [String: MetadataValue]

public struct ChromaCollection: Identifiable, Hashable, Decodable, Sendable {
    public let id: String
    public let name: String
    public let metadata: ChromaMetadata?
    public let dimension: Int?
    public let tenant: String?
    public let database: String?
    /// Filled in separately via `/count`, because listing does not return it.
    public var documentCount: Int?
    /// Embedding function recorded by the server (usually `null` for
    /// collections created over HTTP — vectors are computed client-side).
    public var embeddingFunctionName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, metadata, dimension, tenant, database
        case configurationJSON = "configuration_json"
    }

    /// Metric the server reports for this collection.
    ///
    /// Read from `configuration_json`, which the server returns for **every**
    /// collection including ones it did not create — so a foreign collection
    /// does not have to be guessed at. `nil` only when the server said nothing
    /// recognisable, and then the app says «метрика неизвестна» rather than
    /// assuming a default.
    public var space: DistanceMetric?
    /// Index parameters as they stand right now.
    public var hnsw: HNSWParameters?

    private struct Configuration: Decodable {
        struct EmbeddingFunction: Decodable { let name: String?; let type: String? }
        struct HNSW: Decodable {
            let space: String?
            let ef_construction: Int?
            let ef_search: Int?
            let max_neighbors: Int?
        }
        let embedding_function: EmbeddingFunction?
        let hnsw: HNSW?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        metadata = try container.decodeIfPresent(ChromaMetadata.self, forKey: .metadata)
        dimension = try container.decodeIfPresent(Int.self, forKey: .dimension)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant)
        database = try container.decodeIfPresent(String.self, forKey: .database)
        let configuration = (try? container.decodeIfPresent(Configuration.self, forKey: .configurationJSON)) ?? nil
        embeddingFunctionName = configuration?.embedding_function?.name
            ?? configuration?.embedding_function?.type
        // The server first; the metadata key only for a server that reported
        // nothing. Never a default — an unknown metric stays unknown.
        space = configuration?.hnsw?.space.flatMap(DistanceMetric.init(rawValue:))
            ?? Self.metricFromMetadata(metadata)
        if let hnsw = configuration?.hnsw {
            self.hnsw = HNSWParameters(
                efConstruction: hnsw.ef_construction,
                efSearch: hnsw.ef_search,
                maxNeighbors: hnsw.max_neighbors
            )
        }
    }

    private static func metricFromMetadata(_ metadata: ChromaMetadata?) -> DistanceMetric? {
        guard let metadata else { return nil }
        for key in [CollectionBindingKeys.space, CollectionBindingKeys.legacySpace] {
            if case .string(let value)? = metadata[key], let metric = DistanceMetric(rawValue: value) {
                return metric
            }
        }
        return nil
    }

    public init(
        id: String,
        name: String,
        metadata: ChromaMetadata? = nil,
        dimension: Int? = nil,
        tenant: String? = nil,
        database: String? = nil,
        documentCount: Int? = nil,
        embeddingFunctionName: String? = nil,
        space: DistanceMetric? = nil,
        hnsw: HNSWParameters? = nil
    ) {
        self.id = id
        self.name = name
        self.metadata = metadata
        self.dimension = dimension
        self.tenant = tenant
        self.database = database
        self.documentCount = documentCount
        self.embeddingFunctionName = embeddingFunctionName
        self.space = space ?? Self.metricFromMetadata(metadata)
        self.hnsw = hnsw
    }
}

/// Keys this app writes into a collection's metadata so that the binding
/// "collection → model" survives a move to another machine. Collections made
/// by other tools simply do not have them, which is normal, not an error.
public enum CollectionBindingKeys {
    public static let model = "_cdbm_model"
    public static let dimension = "_cdbm_dimension"
    /// The metric this app asked for. The server's own `configuration_json` is
    /// the truth and is always read first; this is written so the database
    /// stays self-describing when it travels somewhere the configuration does
    /// not (an export, an older tool).
    public static let space = "_cdbm_space"
    /// How the metric is spelled in a collection's metadata by the older
    /// mechanism, which the server still honours.
    public static let legacySpace = "hnsw:space"
    /// Which strategy produced the chunks (2C).
    public static let chunkingStrategy = "_cdbm_chunking_strategy"
    /// Digest of the whole chunking recipe, versioned. Its predecessor
    /// `_cdbm_chunking` held the recipe as readable text and is still found in
    /// collections filled before this key existed.
    public static let strategyParamsHash = "_cdbm_strategy_params_hash"
    public static let legacyChunking = "_cdbm_chunking"

    /// Документ, из которого нарезан этот кусок при пересчёте с перенарезкой.
    /// У первого куска совпадает с его собственным идентификатором.
    public static let rechunkedFrom = "_cdbm_rechunked_from"
    /// Метка прогона перенарезки: одна на все куски одного документа
    /// в одном прогоне.
    ///
    /// Нужна, чтобы отличить текущий кусок от вытесненного. Пересчёт на месте
    /// только дописывает и ничего не удаляет (правило 1 приложения 5:
    /// автоматических удалений нет), поэтому прогон, давший меньше кусков,
    /// чем предыдущий, оставляет хвост со **старыми векторами**. Без метки
    /// такой хвост неотличим от живых кусков: идентификаторы у него
    /// правильные, метаданные тоже.
    public static let rechunkRun = "_cdbm_rechunk_run"
}

public extension ChromaCollection {
    /// Model recorded by this app, if any.
    var boundModel: String? {
        if case .string(let value)? = metadata?[CollectionBindingKeys.model] { return value }
        return nil
    }

    /// Vector size: what the server reports for stored data wins, because it
    /// is the truth; the recorded value is the fallback for empty collections.
    var effectiveDimension: Int? {
        if let dimension { return dimension }
        if case .int(let value)? = metadata?[CollectionBindingKeys.dimension] { return value }
        return nil
    }

    var isBound: Bool { boundModel != nil }

    /// The strategy this app recorded when it filled the collection (2C).
    var chunkingStrategy: ChunkStrategy? {
        guard case .string(let value)? = metadata?[CollectionBindingKeys.chunkingStrategy] else { return nil }
        return ChunkStrategy(rawValue: value)
    }

    /// Whether the collection was cut into two levels, according to its own
    /// metadata.
    ///
    /// A hint, not the verdict: documents written by another client carry no
    /// such metadata, which is why the search itself asks the data instead
    /// (`CollectionShapeCache`). Good enough to decide what a settings screen
    /// greys out; not good enough to decide what a query does.
    var looksHierarchical: Bool { chunkingStrategy == .hierarchical }

    /// Metadata for a rebind, preserving everything else the collection carries.
    func metadataBinding(model: String, dimension: Int) -> ChromaMetadata {
        var merged = metadata ?? [:]
        merged[CollectionBindingKeys.model] = .string(model)
        merged[CollectionBindingKeys.dimension] = .int(dimension)
        return merged
    }
}

public struct DocumentRecord: Identifiable, Hashable {
    public let id: String
    public let document: String?
    public let metadata: ChromaMetadata?
    /// Length of the stored vector, when embeddings were requested.
    public let embeddingDimension: Int?

    public init(id: String, document: String?, metadata: ChromaMetadata?, embeddingDimension: Int? = nil) {
        self.id = id
        self.document = document
        self.metadata = metadata
        self.embeddingDimension = embeddingDimension
    }

    public var preview: String {
        guard let document, !document.isEmpty else { return "— пустой документ —" }
        let flat = document.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}

public struct QueryHit: Identifiable, Hashable {
    public let id: String
    public let document: String?
    public let metadata: ChromaMetadata?
    public let distance: Double?
    /// Present only when the caller asked for vectors — MMR does, and
    /// nothing else should: a page of embeddings is megabytes.
    public let embedding: [Double]?

    public init(
        id: String, document: String?, metadata: ChromaMetadata?, distance: Double?,
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.document = document
        self.metadata = metadata
        self.distance = distance
        self.embedding = embedding
    }

    /// A distance on its own means nothing — the scales of the three metrics
    /// are different and not comparable — so it is always shown together with
    /// what produced it. Cosine additionally gets the percentage people
    /// actually read; the others do not, because for them there is none.
    public func distanceText(metric: DistanceMetric?) -> String {
        guard let distance else { return "—" }
        guard let metric else { return String(format: "%.4f", distance) }
        return metric.describe(distance: distance)
    }
}

/// A partial edit of an existing document. `nil` fields are left alone.
public struct DocumentUpdate {
    public let id: String
    public let document: String?
    public let embedding: [Double]?
    public let metadata: ChromaMetadata?

    public init(id: String, document: String? = nil, embedding: [Double]? = nil, metadata: ChromaMetadata? = nil) {
        self.id = id
        self.document = document
        self.embedding = embedding
        self.metadata = metadata
    }
}

/// One document to write into a collection, with its vector already computed.
public struct EmbeddedRecord {
    public let id: String
    public let document: String
    public let embedding: [Double]
    public let metadata: ChromaMetadata

    public init(id: String, document: String, embedding: [Double], metadata: ChromaMetadata) {
        self.id = id
        self.document = document
        self.embedding = embedding
        self.metadata = metadata
    }
}
