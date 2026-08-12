import Foundation

/// One document captured just before it was deleted.
///
/// Self-contained JSON Lines record, the same reasoning as the audit log
/// (`AuditLog`): a crash mid-write costs only the last line, never the file.
/// Collection binding (model / dimension / metric) travels with every entry
/// rather than being looked up once, because the whole point of `.collection`
/// entries is surviving the collection itself being gone.
public struct TrashEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// This document alone was deleted.
        case document
        /// The document went with the whole collection.
        case collection
    }

    public var id: UUID
    public var deletedAt: Date
    public var documentID: String
    public var document: String?
    public var metadata: ChromaMetadata?
    public var embedding: [Double]?
    public var collectionName: String
    public var collectionMetric: DistanceMetric?
    public var collectionModel: String?
    public var collectionDimension: Int?
    public var reason: Reason

    public init(
        id: UUID = UUID(),
        deletedAt: Date = Date(),
        documentID: String,
        document: String?,
        metadata: ChromaMetadata?,
        embedding: [Double]?,
        collectionName: String,
        collectionMetric: DistanceMetric?,
        collectionModel: String?,
        collectionDimension: Int?,
        reason: Reason
    ) {
        self.id = id
        self.deletedAt = deletedAt
        self.documentID = documentID
        self.document = document
        self.metadata = metadata
        self.embedding = embedding
        self.collectionName = collectionName
        self.collectionMetric = collectionMetric
        self.collectionModel = collectionModel
        self.collectionDimension = collectionDimension
        self.reason = reason
    }

    /// Rough size on disk, for the volume-limited eviction. Exact to the byte
    /// is not the point — knowing whether the trash is 10 MB or 10 GB is.
    var sizeEstimate: Int {
        var bytes = (document?.utf8.count ?? 0) + (embedding?.count ?? 0) * 8
        bytes += (metadata?.count ?? 0) * 32
        return bytes
    }
}

/// Local recycle bin for documents and collections deleted through the UI.
///
/// Rule 1 of Приложение 5: automatic deletions are forbidden, but nothing
/// protects the user from a *manual* delete they did not mean to make. This is
/// that protection — the data is written here before the delete request ever
/// reaches ChromaDB, so a slipped click or a wrong row is not automatically
/// unrecoverable.
///
/// Deliberately not append-only like `AuditLog`: an audit trail must never
/// lose a record on its own, but a recycle bin that never actually empties
/// defeats its own volume limit. Restoring, expiring by age and emptying by
/// hand all remove entries for real — each one is a visible, explicit action
/// (rule 2), the same standing the embedding cache's LRU eviction and the
/// log's own rotation already have.
@MainActor
public final class TrashService: ObservableObject {
    /// `nonisolated`: это просто числа, и они нужны значениями по умолчанию
    /// в местах, не привязанных к главному потоку, — например в `Configuration`.
    public nonisolated static let defaultLimitBytes: Int64 = 1024 * 1024 * 1024
    public nonisolated static let defaultRetentionDays = 14

    /// Newest first.
    @Published public private(set) var entries: [TrashEntry] = []

    private let fileURL: URL
    private var retentionDays: Int
    private var limitBytes: Int64
    private let writeQueue = DispatchQueue(label: "io.github.chromadbmanager.trash")
    private let log: LogHandler

    public init(
        fileURL: URL = AppPaths.trashFile,
        retentionDays: Int = TrashService.defaultRetentionDays,
        limitBytes: Int64 = TrashService.defaultLimitBytes,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.fileURL = fileURL
        self.retentionDays = retentionDays
        self.limitBytes = limitBytes
        self.log = log
        entries = Self.load(from: fileURL)
        applyRetention()
    }

    public var fileLocation: URL { fileURL }

    public var collectionNames: [String] {
        Array(Set(entries.map(\.collectionName))).sorted()
    }

    public var totalBytes: Int {
        entries.reduce(0) { $0 + $1.sizeEstimate }
    }

    /// Called whenever the settings screen changes retention — re-sweeps
    /// immediately so a tightened limit takes effect without waiting for the
    /// next delete.
    public func updateRetention(days: Int, limitBytes: Int64) {
        retentionDays = days
        self.limitBytes = limitBytes
        applyRetention()
    }

    /// Что захват не состоялся.
    ///
    /// Своим типом, а не `Bool`: вызывающая сторона обязана отменить удаление
    /// и **сказать человеку почему**, а для этого нужна причина, а не «нет».
    public struct CaptureFailed: LocalizedError {
        public let reason: String

        public var errorDescription: String? {
            String(localized: "Не удалось положить копию в корзину: \(reason). Удаление отменено — без копии оно было бы необратимым.")
        }
    }

    /// Records documents about to be deleted. Called **before** the delete
    /// request is sent — see `CollectionsViewModel.deleteDocument` /
    /// `deleteSelected` — so a crash between the two leaves the backup copy
    /// and the still-live document, never neither.
    ///
    /// **Бросает, если копия не легла на диск, и вызывающая сторона обязана
    /// тогда не удалять**. Раньше метод возвращал `Void`, писал файл
    /// асинхронно и глотал каждую ошибку внутри — узнать об отказе было
    /// физически нечем, и все четыре пути удаления шли дальше в любом случае.
    /// При недоступном `trash.jsonl` это давало ровно то, что корзина обязана
    /// исключать: приложение говорит «копии в корзине», из базы документы
    /// уходят, а после перезапуска восстанавливать нечего.
    ///
    /// Запись идёт **до** появления в памяти: показывать в окне копии,
    /// которых нет на диске, — тоже враньё, просто менее заметное.
    public func record(_ batch: [TrashEntry]) throws {
        guard !batch.isEmpty else { return }
        do {
            try appendToFile(batch)
        } catch {
            // Системная ошибка сама по себе говорит только «нет разрешения на
            // сохранение файла». Человеку в этот момент важнее другое: что
            // из-за неё **удаление не состоялось** и база цела. Поэтому
            // причина оборачивается, а не пробрасывается как есть.
            let failure = CaptureFailed(reason: Self.tidy(error.localizedDescription))
            log(.error, "Корзина", failure.errorDescription ?? "")
            throw failure
        }
        entries.insert(contentsOf: batch, at: 0)
        applyRetention()
    }

    /// Системные описания заканчиваются точкой, а наше предложение продолжается.
    private static func tidy(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    public func record(_ entry: TrashEntry) throws {
        try record([entry])
    }

    public func entries(withIDs ids: Set<UUID>) -> [TrashEntry] {
        entries.filter { ids.contains($0.id) }
    }

    /// Removes entries after they were successfully written back to the
    /// database — a restored copy is not a backup of anything any more.
    public func forget(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        rewriteFile()
    }

    /// The one place that throws everything away for good — only ever called
    /// from an explicit, confirmed user action, the same standing
    /// `AuditLog.removeArchive` has.
    public func emptyTrash() {
        let count = entries.count
        entries.removeAll()
        writeQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
        log(.warning, "Корзина", "Корзина очищена вручную: удалено записей \(count.plainDigits)")
    }

    // MARK: - Retention

    /// Age limit, then volume limit. Both are silent-but-visible housekeeping
    /// on the app's own backup copy, not on the database itself (rule 2): every
    /// sweep that removes something says so in the log.
    private func applyRetention() {
        var removedForAge = 0
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            let expired = entries.filter { $0.deletedAt < cutoff }
            if !expired.isEmpty {
                entries.removeAll { $0.deletedAt < cutoff }
                removedForAge = expired.count
            }
        }

        var removedForSize = 0
        var total = entries.reduce(0) { $0 + $1.sizeEstimate }
        if total > limitBytes {
            // Oldest first: a document just deleted is the one most likely to
            // still be wanted back.
            for entry in entries.sorted(by: { $0.deletedAt < $1.deletedAt }) {
                if total <= limitBytes { break }
                total -= entry.sizeEstimate
                removedForSize += 1
            }
            if removedForSize > 0 {
                let toDrop = Set(entries.sorted(by: { $0.deletedAt < $1.deletedAt }).prefix(removedForSize).map(\.id))
                entries.removeAll { toDrop.contains($0.id) }
            }
        }

        guard removedForAge > 0 || removedForSize > 0 else { return }
        rewriteFile()
        if removedForAge > 0 {
            log(.info, "Корзина", "Просрочено (старше \(retentionDays.plainDigits) дн.) и удалено из корзины: \(removedForAge.plainDigits)")
        }
        if removedForSize > 0 {
            log(.warning, "Корзина", "Превышен предел объёма корзины — вытеснено самых старых записей: \(removedForSize.plainDigits)")
        }
    }

    // MARK: - File

    /// Дописывает копии в файл — синхронно и с отчётом.
    ///
    /// `writeQueue.sync`, а не `async`: удаление ждёт результата, а очередь
    /// сохраняется, чтобы дозапись не столкнулась с полной перезаписью файла
    /// из `forget` и вытеснения. Взаимоблокировки нет — на самой очереди
    /// `record` не вызывается ниоткуда.
    private func appendToFile(_ batch: [TrashEntry]) throws {
        try writeQueue.sync { [fileURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for entry in batch {
                // Не `try?`: незакодированная запись — это документ, копии
                // которого не будет, и молча пропустить его нельзя.
                var line = try encoder.encode(entry)
                line.append(0x0A)
                data.append(line)
            }
            guard !data.isEmpty else { return }
            _ = try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // `Data.write`, а не `FileManager.createFile`: второй возвращает
                // `Bool` и причину отказа не сообщает вовсе.
                try data.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // Без этого «записано» значит «лежит в кэше страниц»: аварийное
            // завершение сразу после удаления забрало бы копию с собой,
            // то есть ровно в том случае, ради которого корзина и заведена.
            try handle.synchronize()
        }
    }

    /// Removals (restore, expiry, manual purge) rewrite the whole file: unlike
    /// the audit log this store's entries can legitimately disappear one at a
    /// time, and there is no append-only way to do that.
    private func rewriteFile() {
        let snapshot = entries
        writeQueue.async { [fileURL] in
            guard !snapshot.isEmpty else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for entry in snapshot {
                guard var line = try? encoder.encode(entry) else { continue }
                line.append(0x0A)
                data.append(line)
            }
            _ = try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func load(from url: URL) -> [TrashEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A truncated last line is normal after a crash and must not cost the
        // whole file (same reasoning as `AuditLog.load`).
        return text
            .split(separator: "\n")
            .compactMap { try? decoder.decode(TrashEntry.self, from: Data($0.utf8)) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }
}
