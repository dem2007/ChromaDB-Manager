import Foundation

/// Which extractor produced a file's text, and which version of it.
public struct ExtractorStamp: Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// A manifest written before stage 4.3 has no stamp. That is «unknown», not
    /// «different»: we cannot tell which extractor produced that text, and
    /// guessing would either nag the user about files that are fine or stay
    /// silent about files that are not.
    public var isUnknown: Bool { id.isEmpty }

    public var text: String { isUnknown ? String(localized: "неизвестен") : "\(id) v\(version)" }
}

/// What a sync intends to do with one file, by the table in
public enum SyncDecision: Equatable, Sendable {
    case new
    /// Re-extract and re-embed.
    case reindex(reason: String)
    /// The text is the same: refresh what the manifest records about the file
    /// — hash, size, timestamp — and leave the vectors alone.
    case touch
    /// The file did not change, the extractor did. Reported, **never** queued.
    case needsReextraction(previous: ExtractorStamp)
    case skip
}

/// The facts a manifest entry should carry after a run that did not re-embed.
public struct ManifestRefresh: Hashable, Sendable {
    public var fileHash: String?
    public var contentHash: String?
    public var extractor: ExtractorStamp?
    public var modifiedAt: Date
    public var size: Int64

    public init(
        fileHash: String? = nil,
        contentHash: String? = nil,
        extractor: ExtractorStamp? = nil,
        modifiedAt: Date,
        size: Int64
    ) {
        self.fileHash = fileHash
        self.contentHash = contentHash
        self.extractor = extractor
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

/// A file whose text was produced by an older version of the extractor that
/// reads it today.
public struct StaleExtraction: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var collectionName: String
    public var previous: ExtractorStamp
    public var current: ExtractorStamp

    public init(relativePath: String, collectionName: String, previous: ExtractorStamp, current: ExtractorStamp) {
        self.relativePath = relativePath
        self.collectionName = collectionName
        self.previous = previous
        self.current = current
    }
}

/// The rule from, in one place because it is the easiest part of stage 4
/// to get quietly wrong.
///
/// | situation | action |
/// |---|---|
/// | bytes changed, text changed | re-extract and re-embed |
/// | bytes changed, text identical | update hash and mtime, **no** vectors |
/// | file unchanged, extractor version changed | mark, do **not** queue |
/// | file unchanged, versions equal | skip |
public enum SyncDecisionRules {
    /// What can be decided before opening the file. `nil` means «the file has to
    /// be read to tell» — which is where the plan spends its time, so the cases
    /// answered here are the ones that keep a repeat sync cheap.
    public static func decideUnread(
        entry: ManifestEntry?,
        sizeMatches: Bool,
        timeMatches: Bool,
        fileHash: String?,
        recipeMismatch: String?,
        current: ExtractorStamp
    ) -> SyncDecision? {
        guard let entry else { return nil }
        // A different chunking recipe, model or destination re-cuts the file
        // whatever its bytes say, and the plan wants its text length anyway.
        if recipeMismatch != nil { return nil }

        // Unchanged either by the cheap signal (size and timestamp) or by the
        // exact one (the bytes hash to what they hashed to last time).
        let untouched = sizeMatches && timeMatches
        let sameBytes = fileHash.map { !entry.fileHash.isEmpty && entry.fileHash == $0 } ?? false
        guard untouched || sameBytes else { return nil }

        if isStale(stored: entry.extractorStamp, current: current) {
            return .needsReextraction(previous: entry.extractorStamp)
        }
        // The file is where it was, but the manifest does not say so exactly —
        // a re-save with identical bytes, or an entry from before file hashes
        // were recorded. Writing that down costs nothing and saves the next run
        // from opening the file again.
        if needsRefresh(entry: entry, sizeMatches: sizeMatches, timeMatches: timeMatches, fileHash: fileHash) {
            return .touch
        }
        return .skip
    }

    /// What the extracted text decides.
    public static func decideRead(
        entry: ManifestEntry?,
        contentHash: String,
        recipeMismatch: String?
    ) -> SyncDecision {
        guard let entry else { return .new }
        if let recipeMismatch { return .reindex(reason: recipeMismatch) }
        if entry.contentHash != contentHash {
            return .reindex(reason: String(localized: "содержимое файла изменилось"))
        }
        // Bytes moved, text did not: the row of that saves hours on large
        // folders. The extractor that just produced this text is recorded as
        // well — it demonstrably gives the same result, so there is nothing to
        // re-extract and nothing to tell the user about.
        return .touch
    }

    /// Only the same extractor at an older version counts as stale.
    ///
    /// Not «anything different»: a file that went through a fallback extractor
    /// would otherwise be flagged forever, and a downgrade would offer to
    /// re-extract with *older* code, which is not an improvement anyone asked
    /// for. Silence is the safe answer whenever we cannot be sure.
    public static func isStale(stored: ExtractorStamp, current: ExtractorStamp) -> Bool {
        guard !stored.isUnknown, !current.isUnknown else { return false }
        guard stored.id == current.id else { return false }
        return stored.version < current.version
    }

    private static func needsRefresh(
        entry: ManifestEntry,
        sizeMatches: Bool,
        timeMatches: Bool,
        fileHash: String?
    ) -> Bool {
        if !sizeMatches || !timeMatches { return true }
        if let fileHash, entry.fileHash != fileHash { return true }
        if entry.fileHash.isEmpty, fileHash != nil { return true }
        return false
    }
}
