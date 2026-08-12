import Foundation

/// How a collection measures the distance between two vectors.
///
/// Fixed at creation and **immutable afterwards** — the server has no field for
/// it in the update schema at all (verified: `PUT` with `space` answers 422
/// «unknown field `space`»). That puts it in the same class as the vector size:
/// changing it means a new collection.
public enum DistanceMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Cosine distance, 0…2. What almost every embedding model in LM Studio is
    /// trained for, and the app's default — the server's own default is `l2`.
    case cosine
    /// Euclidean distance, unbounded.
    case l2
    /// Inner product; can be negative.
    case ip

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cosine: return String(localized: "Косинусная (cosine)")
        case .l2: return String(localized: "Евклидова (l2)")
        case .ip: return String(localized: "Скалярное произведение (ip)")
        }
    }

    public var shortTitle: String { rawValue }

    public var explanation: String {
        switch self {
        case .cosine:
            return String(localized: "Подходит почти всем эмбеддинг-моделям: они нормированы под неё. Значение от 0 до 2, рядом показывается схожесть в процентах.")
        case .l2:
            return String(localized: "Евклидово расстояние. Не ограничено сверху и зависит от масштаба векторов — в процентах его показать нельзя.")
        case .ip:
            return String(localized: "Скалярное произведение. Может быть отрицательным; чем больше, тем ближе.")
        }
    }

    /// Similarity as a fraction of 1, or `nil` when the metric has no bounded
    /// scale. A percentage is what people expect to see, and inventing one for
    /// an unbounded metric would be a lie.
    public func similarity(forDistance distance: Double) -> Double? {
        guard self == .cosine else { return nil }
        // Cosine distance runs 0…2; anything outside is clamped rather than
        // shown as a negative percentage.
        return min(1, max(0, 1 - distance))
    }

    /// How one distance value is shown in a result list.
    public func describe(distance: Double) -> String {
        if let similarity = similarity(forDistance: distance) {
            return String(localized: "\(Int((similarity * 100).rounded()))% · d=\(String(format: "%.4f", distance))")
        }
        switch self {
        case .l2: return String(localized: "евклидово \(String(format: "%.4f", distance))")
        case .ip: return String(localized: "произведение \(String(format: "%.4f", distance))")
        case .cosine: return String(format: "%.4f", distance)
        }
    }
}

/// Index parameters a user may override at creation.
///
/// Every field is optional and **an empty field is not sent at all**: the app
/// has no business inventing its own idea of the server's defaults.
/// The names are the ones the server actually accepts — it rejects anything
/// else with 422 and lists the valid set, which is how these were found:
/// `space`, `ef_construction`, `ef_search`, `max_neighbors`, `num_threads`,
/// `resize_factor`, `sync_threshold`, `batch_size`.
public struct HNSWParameters: Codable, Hashable, Sendable {
    /// Width of the search when the index is built; higher is more accurate and
    /// slower to write.
    public var efConstruction: Int?
    /// Width of the search when a query runs. The only one of the three that
    /// can still be changed after the collection exists.
    public var efSearch: Int?
    /// Links per node of the graph; higher is more accurate and bigger on disk.
    public var maxNeighbors: Int?

    public init(efConstruction: Int? = nil, efSearch: Int? = nil, maxNeighbors: Int? = nil) {
        self.efConstruction = efConstruction
        self.efSearch = efSearch
        self.maxNeighbors = maxNeighbors
    }

    public var isEmpty: Bool {
        efConstruction == nil && efSearch == nil && maxNeighbors == nil
    }

    /// The `hnsw` object of the create request, with absent fields absent.
    public func requestFields() -> [String: Any] {
        var fields: [String: Any] = [:]
        if let efConstruction { fields["ef_construction"] = efConstruction }
        if let efSearch { fields["ef_search"] = efSearch }
        if let maxNeighbors { fields["max_neighbors"] = maxNeighbors }
        return fields
    }
}

/// What the app asks for when it creates a collection.
public struct CollectionConfiguration: Hashable, Sendable {
    public var metric: DistanceMetric
    public var hnsw: HNSWParameters

    public init(metric: DistanceMetric = .cosine, hnsw: HNSWParameters = HNSWParameters()) {
        self.metric = metric
        self.hnsw = hnsw
    }

    /// Body fragment for `POST /collections`.
    ///
    /// Both spellings go out together on purpose. The modern field
    /// (`configuration`) is what the installed server stores; the legacy
    /// metadata key (`hnsw:space`) is what older ones understand, and this
    /// server accepts it too and applies it identically — checked on both
    ///. Sending both is one request that works on either, instead of a
    /// version guess against `/api/v2/version`, which reports the API version
    /// (a constant `1.0.0`) and says nothing about the engine.
    public func requestBody() -> [String: Any] {
        var hnswFields = hnsw.requestFields()
        hnswFields["space"] = metric.rawValue
        return ["hnsw": hnswFields]
    }

    /// The legacy half: goes into the collection's metadata.
    public var legacyMetadata: ChromaMetadata {
        [CollectionBindingKeys.legacySpace: .string(metric.rawValue)]
    }
}
