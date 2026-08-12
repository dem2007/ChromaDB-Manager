import Foundation
import CryptoKit

/// Digest of everything that shapes the chunks of a collection (2.3).
///
/// Kept next to a **schema version**, because the set of fields that go into it
/// grows: seed and the extended generation block join it with part G. Without a
/// version, adding a field would move the digest of every collection ever made
/// at once, and the app would offer to re-index collections where nothing
/// changed — hours of local model time for no reason (same trick as the
/// manifest schema version in A6.4).
public struct StrategyParamsHash: Equatable, Hashable, Sendable {
    /// Bump when the set of fields feeding the digest changes.
    /// 1 — the chunking recipe as described by `ChunkingConfiguration.signature`
    ///     (strategy, sizes, separators, chat model, temperature, prompt).
    /// 2 — part G widened the LLM-based recipe: the whole generation block
    ///     (seed, token limit, top_p/top_k/min_p/penalties) and the
    ///     structured-output switch now shape the boundaries too, so they
    ///     belong in the digest. Bumped rather than silently recomputed —
    ///     without this every existing collection would report itself
    ///     heterogeneous at once and ask for a re-index that changes nothing.
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let digest: String

    public init(schemaVersion: Int, digest: String) {
        self.schemaVersion = schemaVersion
        self.digest = digest
    }

    /// What goes into `_cdbm_strategy_params_hash`: version and value together,
    /// so a value can never be compared across schemas by accident.
    public var stored: String { "v\(schemaVersion):\(digest)" }

    public var value: MetadataValue { .string(stored) }

    public static func parse(_ raw: String?) -> StrategyParamsHash? {
        guard let raw, raw.hasPrefix("v") else { return nil }
        let parts = raw.dropFirst().split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let version = Int(parts[0]), !parts[1].isEmpty else { return nil }
        return StrategyParamsHash(schemaVersion: version, digest: String(parts[1]))
    }

    public static func parse(_ metadata: ChromaMetadata?) -> StrategyParamsHash? {
        guard case .string(let raw)? = metadata?[CollectionBindingKeys.strategyParamsHash] else { return nil }
        return parse(raw)
    }

    public static func of(_ configuration: ChunkingConfiguration) -> StrategyParamsHash {
        StrategyParamsHash(
            schemaVersion: currentSchemaVersion,
            digest: SHA256.hash(data: Data(configuration.signature.utf8))
                .compactMap { String(format: "%02x", $0) }
                .joined()
        )
    }

    /// What to do with a collection that already carries a hash.
    public enum Comparison: Equatable, Sendable {
        /// Same schema, same value: the collection is homogeneous.
        case matches
        /// No hash yet, or one written under an older schema. Recomputed and
        /// written **without** a warning — the fields changed, not the recipe.
        case migrate
        /// Same schema, different value: the recipe really did change, and the
        /// collection is about to become heterogeneous.
        case differs(stored: String)
    }

    public static func compare(stored: StrategyParamsHash?, current: StrategyParamsHash) -> Comparison {
        guard let stored else { return .migrate }
        guard stored.schemaVersion == current.schemaVersion else { return .migrate }
        return stored.digest == current.digest ? .matches : .differs(stored: stored.digest)
    }
}
