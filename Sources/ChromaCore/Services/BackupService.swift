import Foundation

public struct BackupRecord: Identifiable, Hashable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int64
    public let sourcePath: String?
    /// True while the marker file is still there — the copy never finished, so
    /// it is not a restore point.
    public var isIncomplete: Bool = false

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Proof that a backup was taken.
///
/// Re-embedding demands one of these, and only `BackupService` can produce it
/// (the initialiser is internal to this module). That makes «обязательный бэкап»
/// from the spec a rule the type system enforces, not a habit.
public struct BackupEvidence: Sendable {
    /// Directory copy — the local-database case.
    public let record: BackupRecord?
    /// JSON export of documents and metadata — the external-server case.
    public let exportURL: URL?
    public let createdAt: Date
    public let describedAs: String

    init(record: BackupRecord?, exportURL: URL?, describedAs: String) {
        self.record = record
        self.exportURL = exportURL
        self.createdAt = Date()
        self.describedAs = describedAs
    }
}

/// Copies embedded ChromaDB directories to
/// `~/Library/Application Support/ChromaDBManager/backups/`.
///
/// Used before every upgrade of the `chromadb` package, before re-embedding,
/// and available manually.
/// Потокобезопасен по построению, и это объявлено: всё состояние —
/// `let`, каталог и обработчик журнала задаются при создании и не меняются,
/// а `FileManager.default` для этих операций документирован как безопасный.
/// Без пометки компилятор обязан считать каждое обращение из очереди
/// непроверенным — три предупреждения в `EnvironmentViewModel` были именно
/// об этом, и в Swift 6 они станут ошибками сборки.
public final class BackupService: @unchecked Sendable {
    private let log: LogHandler
    private let fileManager = FileManager.default
    /// Where copies and exports go. Injectable so tests never write into the
    /// user's real Application Support folder.
    private let directory: URL

    public init(directory: URL = AppPaths.backupsDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.directory = directory
        self.log = log
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Present while a copy is in flight; removed when the copy is verified.
    static let incompleteMarker = "_chromadbmanager_incomplete"
    /// Free space required on top of the database size, as a fraction.
    public static let freeSpaceHeadroom = 0.2

    /// What a backup would need and what the volume has.
    public struct SpaceCheck: Hashable, Sendable {
        public let requiredBytes: Int64
        public let availableBytes: Int64
        public var fits: Bool { availableBytes >= requiredBytes }

        public var requiredText: String {
            ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
        }
        public var availableText: String {
            ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        }
    }

    /// Measures the database and the free space where the copy would go.
    ///
    /// A 40 GB database copied onto a volume with 30 GB free fails halfway and
    /// leaves something that looks like a backup. Cheaper to ask first.
    public func spaceCheck(for source: URL) -> SpaceCheck {
        let size = directorySize(source)
        let required = size + Int64(Double(size) * Self.freeSpaceHeadroom)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage
            // A path that does not exist yet has no volume values; ask its parent.
            ?? (try? directory.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        return SpaceCheck(requiredBytes: required, availableBytes: available ?? 0)
    }

    @discardableResult
    public func backup(databaseAt source: URL, note: String? = nil) throws -> BackupRecord {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackupError.sourceMissing(source.path)
        }

        try AppPaths.ensureDirectory(directory)

        // Checked before anything is written: a copy that runs out of space
        // half-way is worse than a copy that never started.
        let space = spaceCheck(for: source)
        guard space.fits else {
            throw BackupError.notEnoughSpace(required: space.requiredBytes, available: space.availableBytes, directory: directory.path)
        }

        let stamp = Self.stampFormatter.string(from: Date())
        let name = "\(source.lastPathComponent)_\(stamp)"
        let destination = directory.appendingPathComponent(name, isDirectory: true)

        log(.info, "Бэкап", "Копирование \(source.path) → \(destination.path)")
        try fileManager.copyItem(at: source, to: destination)
        // The marker goes in immediately after the copy and comes off only
        // when the result has been checked; a crash in between leaves a backup
        // that says so instead of one that lies.
        let marker = destination.appendingPathComponent(Self.incompleteMarker)
        fileManager.createFile(atPath: marker.path, contents: Data("copy in progress\n".utf8))

        if let note {
            let metadata = "source: \(source.path)\ncreated: \(Date())\nnote: \(note)\n"
            do {
                try metadata.write(
                    to: destination.appendingPathComponent("_chromadbmanager_backup.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                // Копия цела, но заметку человек писал сам, и молча её терять
                // нельзя: через месяц он будет выбирать из десятка копий
                // именно по ней.
                log(.warning, "Резервные копии",
                    "Копия создана, но заметку к ней сохранить не удалось (\(error.localizedDescription)). Текст заметки: \(note)")
            }
        }

        // Integrity check: the copy must contain the same files, and the SQLite
        // database must be there and non-empty. Only then does the marker go.
        try verify(copy: destination, of: source)
        try? fileManager.removeItem(at: marker)

        let record = BackupRecord(
            url: destination,
            createdAt: Date(),
            sizeBytes: directorySize(destination),
            sourcePath: source.path
        )
        log(.success, "Бэкап", "Создана резервная копия \(record.name) (\(record.sizeText))")
        return record
    }

    /// What «проверка целостности» means here: the same number of files, and a
    /// SQLite file of the same size. Not a checksum — reading 40 GB twice to
    /// prove a copy the filesystem just made is not worth the wait.
    private func verify(copy: URL, of source: URL) throws {
        func inventory(_ url: URL) -> [String: Int64] {
            var result: [String: Int64] = [:]
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return result }
            for case let fileURL as URL in enumerator {
                let relative = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                guard relative != Self.incompleteMarker else { continue }
                result[relative] = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return result
        }
        let original = inventory(source)
        let made = inventory(copy)
        let missing = original.filter { made[$0.key] != $0.value }
        guard missing.isEmpty else {
            throw BackupError.verificationFailed(
                copy.lastPathComponent,
                String(localized: "не совпали файлы: \(missing.keys.sorted().prefix(3).joined(separator: ", "))")
            )
        }
    }

    /// Directory copy, for a local database. The caller must have stopped the
    /// server first — copying SQLite files underneath a running server is how
    /// you get a backup that restores into a corrupt database.
    public func backupLocalDatabase(at source: URL, note: String) throws -> BackupEvidence {
        let record = try backup(databaseAt: source, note: note)
        return BackupEvidence(
            record: record,
            exportURL: nil,
            describedAs: String(localized: "копия папки базы: \(record.name) (\(record.sizeText))")
        )
    }

    /// JSON export of one collection, for a server whose files we cannot touch.
    ///
    /// Documents and metadata only — vectors are left out on purpose: they are
    /// exactly what is about to be recomputed, and they would multiply the file
    /// size for nothing.
    public func exportCollection(
        _ collection: ChromaCollection,
        from chroma: ChromaClient,
        pageSize: Int = 200,
        note: String
    ) async throws -> BackupEvidence {
        try AppPaths.ensureDirectory(directory)
        let stamp = Self.stampFormatter.string(from: Date())
        let destination = directory
            .appendingPathComponent("\(collection.name)_\(stamp).json")

        var rows: [[String: Any]] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await chroma.getDocuments(collectionID: collection.id, limit: pageSize, offset: offset)
            if page.isEmpty { break }
            for document in page {
                var row: [String: Any] = ["id": document.id]
                if let text = document.document { row["document"] = text }
                if let metadata = document.metadata {
                    row["metadata"] = try encodeMetadata(metadata)
                }
                rows.append(row)
            }
            if page.count < pageSize { break }
            offset += pageSize
        }

        let payload: [String: Any] = [
            "collection": collection.name,
            "collection_id": collection.id,
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "note": note,
            "embeddings_included": false,
            "documents": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)

        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        log(.success, "Бэкап", "Экспорт коллекции «\(collection.name)»: \(rows.count) документов → \(destination.lastPathComponent) (\(size))")
        return BackupEvidence(
            record: nil,
            exportURL: destination,
            describedAs: String(localized: "экспорт \(rows.count) документов в \(destination.lastPathComponent) (\(size))")
        )
    }

    private func encodeMetadata(_ metadata: ChromaMetadata) throws -> [String: Any] {
        let data = try JSONEncoder().encode(metadata)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func list() -> [BackupRecord] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let note = try? String(contentsOf: url.appendingPathComponent("_chromadbmanager_backup.txt"), encoding: .utf8)
                let source = note?
                    .split(separator: "\n")
                    .first { $0.hasPrefix("source: ") }
                    .map { String($0.dropFirst("source: ".count)) }
                return BackupRecord(
                    url: url,
                    createdAt: created,
                    sizeBytes: directorySize(url),
                    sourcePath: source,
                    isIncomplete: fileManager.fileExists(atPath: url.appendingPathComponent(Self.incompleteMarker).path)
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores a backup over a database directory. The current content is
    /// moved aside first, never deleted outright.
    public func restore(_ record: BackupRecord, to destination: URL) throws {
        guard !record.isIncomplete else {
            throw BackupError.incompleteBackup(record.name)
        }
        if fileManager.fileExists(atPath: destination.path) {
            let asideName = destination.lastPathComponent + "_before_restore_" + Self.stampFormatter.string(from: Date())
            let aside = directory.appendingPathComponent(asideName, isDirectory: true)
            try AppPaths.ensureDirectory(directory)
            try fileManager.moveItem(at: destination, to: aside)
            log(.warning, "Бэкап", "Текущая база сохранена как \(aside.lastPathComponent)")
        }
        try fileManager.copyItem(at: record.url, to: destination)
        log(.success, "Бэкап", "Резервная копия \(record.name) восстановлена в \(destination.path)")
    }

    public func delete(_ record: BackupRecord) throws {
        try fileManager.removeItem(at: record.url)
        log(.warning, "Бэкап", "Резервная копия \(record.name) удалена")
    }

    public func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

public enum BackupError: LocalizedError {
    case sourceMissing(String)
    case notEnoughSpace(required: Int64, available: Int64, directory: String)
    case verificationFailed(String, String)
    case incompleteBackup(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Каталог базы данных не найден: \(path)"
        case .notEnoughSpace(let required, let available, let directory):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return String(localized: "Недостаточно места для резервной копии: нужно \(need), доступно \(have) в \(directory).")
        case .verificationFailed(let name, let reason):
            return String(localized: "Резервная копия \(name) не прошла проверку: \(reason)")
        case .incompleteBackup(let name):
            return String(localized: "Копия \(name) не была завершена и не годится для восстановления.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notEnoughSpace:
            return String(localized: "Освободите место или выберите другой каталог для резервных копий.")
        case .incompleteBackup:
            return String(localized: "Удалите её и создайте копию заново.")
        default:
            return nil
        }
    }
}
