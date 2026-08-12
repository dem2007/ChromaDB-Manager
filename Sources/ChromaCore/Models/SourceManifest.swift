import Foundation

/// What the app knows about one already-indexed file.
///
/// The manifest is the only reason a second sync can be cheap: without it every
/// run would have to re-read, re-chunk and re-embed the whole folder.
public struct ManifestEntry: Codable, Hashable {
    public var relativePath: String
    /// SHA-256 of the extracted text, not of the raw bytes: a PDF re-saved
    /// without editing its text must not count as changed.
    public var contentHash: String
    /// SHA-256 of the raw bytes. Both hashes are needed together: the pair is
    /// what turns «the file was re-saved» into «the text is the same, keep the
    /// vectors». Empty for an entry written before it was recorded, and
    /// for a document package, which is a directory rather than a file.
    public var fileHash: String
    public var modifiedAt: Date
    public var size: Int64
    public var embeddedAt: Date
    public var chunkIDs: [String]
    public var collectionName: String
    /// Chunking parameters that produced these chunks. Different parameters mean
    /// the file has to be re-chunked even if its bytes never changed.
    public var chunkingSignature: String
    public var embeddingModel: String
    /// Which extractor produced this text, and which version of it.
    /// Empty id means «written before this was recorded» — unknown, not stale.
    public var extractorID: String
    public var extractorVersion: Int
    /// Extraction options this file was written under. Empty for an
    /// entry from before they existed — unknown, and therefore not a mismatch.
    public var extractionSignature: String
    /// Set when the file is gone from disk but the user chose to keep its chunks,
    /// so it is not reported as "needs a decision" again on every sync.
    public var isOrphaned: Bool
    /// What the extraction warned about for this file, in the wording that went
    /// into the chunk metadata. Kept so the diagnostics screen can list
    /// «файлы с предупреждениями» without re-reading every document.
    public var warnings: [String]

    public var extractorStamp: ExtractorStamp {
        ExtractorStamp(id: extractorID, version: extractorVersion)
    }

    public init(
        relativePath: String,
        contentHash: String,
        fileHash: String = "",
        modifiedAt: Date,
        size: Int64,
        embeddedAt: Date = Date(),
        chunkIDs: [String],
        collectionName: String,
        chunkingSignature: String,
        embeddingModel: String,
        extractorID: String = "",
        extractorVersion: Int = 0,
        extractionSignature: String = "",
        isOrphaned: Bool = false,
        warnings: [String] = []
    ) {
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.fileHash = fileHash
        self.extractorID = extractorID
        self.extractorVersion = extractorVersion
        self.extractionSignature = extractionSignature
        self.modifiedAt = modifiedAt
        self.size = size
        self.embeddedAt = embeddedAt
        self.chunkIDs = chunkIDs
        self.collectionName = collectionName
        self.chunkingSignature = chunkingSignature
        self.embeddingModel = embeddingModel
        self.isOrphaned = isOrphaned
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        fileHash = try container.decodeIfPresent(String.self, forKey: .fileHash) ?? ""
        extractorID = try container.decodeIfPresent(String.self, forKey: .extractorID) ?? ""
        extractorVersion = try container.decodeIfPresent(Int.self, forKey: .extractorVersion) ?? 0
        extractionSignature = try container.decodeIfPresent(String.self, forKey: .extractionSignature) ?? ""
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        size = try container.decode(Int64.self, forKey: .size)
        embeddedAt = try container.decodeIfPresent(Date.self, forKey: .embeddedAt) ?? Date()
        chunkIDs = try container.decodeIfPresent([String].self, forKey: .chunkIDs) ?? []
        collectionName = try container.decode(String.self, forKey: .collectionName)
        chunkingSignature = try container.decodeIfPresent(String.self, forKey: .chunkingSignature) ?? ""
        embeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
        isOrphaned = try container.decodeIfPresent(Bool.self, forKey: .isOrphaned) ?? false
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    /// Records what a run learned about a file it did **not** re-embed: the file
    /// moved on disk, the text did not. Absent facts stay as they were —
    /// an entry whose extractor is unknown keeps it that way rather than being
    /// stamped with an extractor that never ran on it.
    public func applying(_ refresh: ManifestRefresh) -> ManifestEntry {
        var updated = self
        if let fileHash = refresh.fileHash { updated.fileHash = fileHash }
        if let contentHash = refresh.contentHash { updated.contentHash = contentHash }
        if let extractor = refresh.extractor, !extractor.isUnknown {
            updated.extractorID = extractor.id
            updated.extractorVersion = extractor.version
        }
        updated.modifiedAt = refresh.modifiedAt
        updated.size = refresh.size
        return updated
    }
}

/// A file that vanished from disk while its chunks are still in the database.
///
/// Deletions are never performed automatically — not even in the automatic
/// modes of 2D. The user decides, and until then the record waits here.
public struct PendingRemoval: Identifiable, Codable, Hashable {
    public var id: String { relativePath }
    public var relativePath: String
    public var collectionName: String
    public var chunkIDs: [String]
    public var noticedAt: Date

    public init(relativePath: String, collectionName: String, chunkIDs: [String], noticedAt: Date = Date()) {
        self.relativePath = relativePath
        self.collectionName = collectionName
        self.chunkIDs = chunkIDs
        self.noticedAt = noticedAt
    }
}

public struct SourceManifest: Codable {
    /// Bumped whenever the meaning of a field changes. A manifest from the
    /// future is not read at all: silently treating an unknown format as if it
    /// were this one is how a source ends up half re-indexed.
    public static let currentVersion = 1

    public var sourceID: UUID
    public var version: Int
    public var updatedAt: Date?
    /// Keyed by relative path — the identity of a file inside its source.
    public var entries: [String: ManifestEntry]
    public var pendingRemovals: [PendingRemoval]
    /// Files the last run could not read, with the reason and the action worth
    /// trying. Replaced wholesale by each run that reached the end: a
    /// problem that is no longer reported is a problem that is gone.
    public var problems: [FileProblem]

    public init(
        sourceID: UUID,
        version: Int = SourceManifest.currentVersion,
        updatedAt: Date? = nil,
        entries: [String: ManifestEntry] = [:],
        pendingRemovals: [PendingRemoval] = [],
        problems: [FileProblem] = []
    ) {
        self.sourceID = sourceID
        self.version = version
        self.updatedAt = updatedAt
        self.entries = entries
        self.pendingRemovals = pendingRemovals
        self.problems = problems
    }

    /// A manifest written before versions existed reads as version 1 — it is
    /// this format, it just did not say so.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(UUID.self, forKey: .sourceID)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        entries = try container.decodeIfPresent([String: ManifestEntry].self, forKey: .entries) ?? [:]
        pendingRemovals = try container.decodeIfPresent([PendingRemoval].self, forKey: .pendingRemovals) ?? []
        problems = try container.decodeIfPresent([FileProblem].self, forKey: .problems) ?? []
    }

    /// Indexed files that were read, but not cleanly.
    public var warnedEntries: [ManifestEntry] {
        entries.values.filter { !$0.warnings.isEmpty }.sorted { $0.relativePath < $1.relativePath }
    }

    public var chunkCount: Int { entries.values.reduce(0) { $0 + $1.chunkIDs.count } }
    public var fileCount: Int { entries.count }

    public var collections: [String] {
        Array(Set(entries.values.map(\.collectionName))).sorted()
    }

    public mutating func record(_ entry: ManifestEntry) {
        entries[entry.relativePath] = entry
        pendingRemovals.removeAll { $0.relativePath == entry.relativePath }
        // A file that has just been indexed is not a file that needs a decision,
        // whatever the run before this one thought of it.
        problems.removeAll { $0.relativePath == entry.relativePath }
    }

    public mutating func forget(relativePath: String) {
        entries.removeValue(forKey: relativePath)
        pendingRemovals.removeAll { $0.relativePath == relativePath }
        problems.removeAll { $0.relativePath == relativePath }
    }
}

/// Reads and writes manifests, one JSON file per source.
///
/// Deliberately not `@MainActor`: syncing happens off the main thread and the
/// manifest is written between files so an interrupted run keeps what it did.
public final class ManifestStore {
    private let directory: URL
    private let log: LogHandler
    private let queue = DispatchQueue(label: "app.chromadbmanager.manifests")

    public init(directory: URL = AppPaths.manifestsDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.directory = directory
        self.log = log
    }

    public func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    public func load(sourceID: UUID) -> SourceManifest {
        queue.sync {
            let url = fileURL(for: sourceID)
            guard let data = GuardedJSONFile<SourceManifest>.readDataWithRetry(at: url) else {
                // Нет файла — источник новый, это норма. Файл есть, но не
                // прочитался — совсем другое дело: сейчас будет переиндексирован
                // весь источник, и знать об этом надо заранее, а не по счёту
                // за час работы модели.
                if FileManager.default.fileExists(atPath: url.path) {
                    log(.error, "Источники", "Манифест источника есть, но не читается — источник будет проиндексирован заново. Рядом лежит \(url.deletingPathExtension().lastPathComponent).previous.json, если он вам нужен.")
                }
                return SourceManifest(sourceID: sourceID)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(SourceManifest.self, from: data) else {
                // A corrupt manifest must not block indexing: the worst case is
                // one full re-index, and upsert keeps ids stable anyway.
                log(.warning, "Источники", "Манифест источника повреждён и будет пересоздан")
                return SourceManifest(sourceID: sourceID)
            }
            guard manifest.version <= SourceManifest.currentVersion else {
                // Written by a newer build. Reading it as if it were ours would
                // mean guessing at fields we do not know; a full re-index is
                // slow but correct, and the user is told why.
                log(.warning, "Источники", "Манифест источника записан более новой версией приложения (\(manifest.version) вместо \(SourceManifest.currentVersion)) — источник будет проиндексирован заново")
                return SourceManifest(sourceID: sourceID)
            }
            return manifest
        }
    }

    /// Atomic **and** durable: a manifest that is only half on disk when the
    /// power goes out breaks the whole source.
    public func save(_ manifest: SourceManifest) {
        queue.sync {
            var stored = manifest
            stored.version = SourceManifest.currentVersion
            stored.updatedAt = Date()
            do {
                try AppPaths.ensureDirectory(directory)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(stored)
                let destination = fileURL(for: manifest.sourceID)
                // Прежний манифест остаётся рядом: он стоит часов работы модели
                //.
                GuardedJSONFile<SourceManifest>.keepPreviousVersion(of: destination, unless: data)
                // Temporary file in the same directory, flushed to the platter,
                // then swapped in. `Data.write(.atomic)` does the swap but does
                // not promise the bytes reached the disk before it.
                let temporary = directory.appendingPathComponent(".\(manifest.sourceID.uuidString).tmp")
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } catch {
                log(.error, "Источники", "Не удалось сохранить манифест: \(error.localizedDescription)")
            }
        }
    }

    public func remove(sourceID: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(for: sourceID))
        }
    }
}
