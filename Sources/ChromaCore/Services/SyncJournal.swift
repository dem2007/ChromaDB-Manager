import Foundation

/// What one file's re-index is in the middle of doing.
///
/// The record is written **before** the database is touched, which is the whole
/// point: an interrupted re-index has to be recognisable afterwards. Everything
/// needed to finish the job without reading the file again is here — the ids on
/// both sides and the manifest entry's fields.
public struct SyncJournalEntry: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Intent recorded; nothing has been written yet.
        case started
        /// New chunks are in the collection. The old tail may still be there.
        case upserted
        /// Tail removed. Only the manifest is left to update.
        case cleaned
        /// The file is done and the record is void.
        case done
    }

    public var relativePath: String
    public var collectionName: String
    /// Chunk ids the manifest remembered before this run.
    public var oldIDs: [String]
    /// Chunk ids this run is writing. Deterministic, so they are known before
    /// a single vector has been computed.
    public var newIDs: [String]
    public var state: State
    public var contentHash: String
    /// Carried through the journal so a run recovered after a crash writes the
    /// same manifest entry the interrupted one would have.
    public var fileHash: String
    public var extractorID: String
    public var extractorVersion: Int
    public var extractionSignature: String
    /// Поля метаданных, с которыми пишется файл — здесь по той же
    /// причине, что и остальные подписи: доигранный после сбоя прогон обязан
    /// записать в манифест то же, что записал бы прерванный.
    public var metadataSignature: String
    public var modifiedAt: Date
    public var size: Int64
    public var chunkingSignature: String
    public var embeddingModel: String
    /// What the extraction warned about. Here for the same reason the hashes
    /// are: a run finished after a crash has to write the manifest entry the
    /// interrupted one would have, warnings included, or the file quietly drops
    /// off the diagnostics screen.
    public var warnings: [String]
    public var startedAt: Date

    public init(
        relativePath: String,
        collectionName: String,
        oldIDs: [String],
        newIDs: [String],
        state: State = .started,
        contentHash: String,
        fileHash: String = "",
        extractorID: String = "",
        extractorVersion: Int = 0,
        extractionSignature: String = "",
        metadataSignature: String = "",
        modifiedAt: Date,
        size: Int64,
        chunkingSignature: String,
        embeddingModel: String,
        warnings: [String] = [],
        startedAt: Date = Date()
    ) {
        self.relativePath = relativePath
        self.collectionName = collectionName
        self.oldIDs = oldIDs
        self.newIDs = newIDs
        self.state = state
        self.contentHash = contentHash
        self.fileHash = fileHash
        self.extractorID = extractorID
        self.extractorVersion = extractorVersion
        self.extractionSignature = extractionSignature
        self.metadataSignature = metadataSignature
        self.modifiedAt = modifiedAt
        self.size = size
        self.chunkingSignature = chunkingSignature
        self.embeddingModel = embeddingModel
        self.warnings = warnings
        self.startedAt = startedAt
    }

    /// Written by a build that did not know about extractor stamps yet.
    ///
    /// Tolerated on purpose: a line the decoder refuses is skipped without a
    /// word, and the one place that matters is exactly this one — a run
    /// interrupted by the update itself would lose the record that makes it
    /// recoverable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        collectionName = try container.decode(String.self, forKey: .collectionName)
        oldIDs = try container.decodeIfPresent([String].self, forKey: .oldIDs) ?? []
        newIDs = try container.decodeIfPresent([String].self, forKey: .newIDs) ?? []
        state = try container.decode(State.self, forKey: .state)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        fileHash = try container.decodeIfPresent(String.self, forKey: .fileHash) ?? ""
        extractorID = try container.decodeIfPresent(String.self, forKey: .extractorID) ?? ""
        extractorVersion = try container.decodeIfPresent(Int.self, forKey: .extractorVersion) ?? 0
        extractionSignature = try container.decodeIfPresent(String.self, forKey: .extractionSignature) ?? ""
        metadataSignature = try container.decodeIfPresent(String.self, forKey: .metadataSignature) ?? ""
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        size = try container.decode(Int64.self, forKey: .size)
        chunkingSignature = try container.decodeIfPresent(String.self, forKey: .chunkingSignature) ?? ""
        embeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    }

    /// The ids that step 4 has to remove: what the file used to occupy and no
    /// longer does. A file that got shorter leaves a tail; without this it would
    /// stay in the collection forever, referenced by nothing.
    public var tailIDs: [String] {
        let kept = Set(newIDs)
        return oldIDs.filter { !kept.contains($0) }
    }

    /// The manifest entry this run is heading towards.
    public func manifestEntry() -> ManifestEntry {
        ManifestEntry(
            relativePath: relativePath,
            contentHash: contentHash,
            fileHash: fileHash,
            modifiedAt: modifiedAt,
            size: size,
            chunkIDs: newIDs,
            collectionName: collectionName,
            chunkingSignature: chunkingSignature,
            embeddingModel: embeddingModel,
            extractorID: extractorID,
            extractorVersion: extractorVersion,
            extractionSignature: extractionSignature,
            metadataSignature: metadataSignature,
            warnings: warnings
        )
    }
}

/// Append-only record of files being re-indexed right now, one file per source
/// in flight.
///
/// **Append-only on purpose.** A journal that rewrites itself in place can be
/// caught half-written by the very crash it exists to survive; appending cannot
/// lose what was already there. The effective state of a file is its last line,
/// and the file is truncated once nothing is in flight — so in normal operation
/// this is an empty file, not a growing one.
public final class SyncJournal {
    private let directory: URL
    private let log: LogHandler
    private let queue = DispatchQueue(label: "app.chromadbmanager.syncjournal")

    public init(directory: URL = AppPaths.syncJournalsDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.directory = directory
        self.log = log
    }

    public func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).jsonl")
    }

    /// Files left in flight by an earlier run, newest state per file.
    public func pending(sourceID: UUID) -> [SyncJournalEntry] {
        queue.sync { foldEntries(sourceID: sourceID) }
    }

    public func isEmpty(sourceID: UUID) -> Bool { pending(sourceID: sourceID).isEmpty }

    /// Records the intent. Returns only once the record is on disk — the next
    /// line of code is allowed to touch the database, and not before.
    public func begin(_ entry: SyncJournalEntry, sourceID: UUID) throws {
        try queue.sync { try append(entry, sourceID: sourceID) }
    }

    public func advance(sourceID: UUID, relativePath: String, to state: SyncJournalEntry.State) throws {
        try queue.sync {
            guard var entry = foldEntries(sourceID: sourceID).first(where: { $0.relativePath == relativePath }) else { return }
            entry.state = state
            try append(entry, sourceID: sourceID)
            // Nothing is in flight any more: the journal goes back to empty
            // instead of accumulating the history of every sync ever run.
            if state == .done, foldEntries(sourceID: sourceID).isEmpty {
                try? FileManager.default.removeItem(at: fileURL(for: sourceID))
            }
        }
    }

    public func finish(sourceID: UUID, relativePath: String) throws {
        try advance(sourceID: sourceID, relativePath: relativePath, to: .done)
    }

    /// Drops the journal without replaying it — used when a source is deleted.
    public func clear(sourceID: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(for: sourceID))
            try? FileManager.default.removeItem(at: blockURL(for: sourceID))
        }
    }

    // MARK: - Blocking automatic runs

    /// Recovery that fails leaves a marker: automatic modes must stay away from
    /// this source until a person starts it by hand. The reason is kept
    /// with the marker so the interface can say what happened.
    /// Возвращает `false`, если метку поставить не удалось.
    ///
    /// Молчать здесь нельзя. Метка — единственное, что удерживает
    /// автоматические прогоны от источника, у которого не доигралось
    /// восстановление; не записалась она — и таймер через час пойдёт
    /// индексировать поверх состояния, которого никто не понимает. Отказ
    /// записи маловероятен, но его цена — ровно то, ради чего метка и
    /// заведена.
    @discardableResult
    public func block(sourceID: UUID, reason: String) -> Bool {
        queue.sync {
            _ = try? AppPaths.ensureDirectory(directory)
            do {
                try Data(reason.utf8).write(to: blockURL(for: sourceID), options: .atomic)
                return true
            } catch {
                log(.error, "Синхронизация",
                    "Не удалось пометить источник как требующий ручного запуска (\(error.localizedDescription)). "
                    + "Автоматические прогоны этого источника ничем не удерживаются — остановите автоиндексацию вручную. Причина метки: \(reason)")
                return false
            }
        }
    }

    public func unblock(sourceID: UUID) {
        queue.sync { try? FileManager.default.removeItem(at: blockURL(for: sourceID)) }
    }

    public func blockReason(sourceID: UUID) -> String? {
        queue.sync {
            guard let data = try? Data(contentsOf: blockURL(for: sourceID)) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func blockURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).blocked")
    }

    // MARK: - File

    private func append(_ entry: SyncJournalEntry, sourceID: UUID) throws {
        try AppPaths.ensureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)

        let url = fileURL(for: sourceID)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        // The line that matters is the one that survives a power cut.
        try handle.synchronize()
    }

    /// Last state per file, with finished files dropped. A truncated last line
    /// (a crash mid-write) is skipped rather than failing the whole read.
    private func foldEntries(sourceID: UUID) -> [SyncJournalEntry] {
        guard let text = try? String(contentsOf: fileURL(for: sourceID), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var latest: [String: SyncJournalEntry] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(SyncJournalEntry.self, from: Data(line.utf8)) else { continue }
            if latest[entry.relativePath] == nil { order.append(entry.relativePath) }
            latest[entry.relativePath] = entry
        }
        return order.compactMap { latest[$0] }.filter { $0.state != .done }
    }
}
