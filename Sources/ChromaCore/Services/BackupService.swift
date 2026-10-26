import Foundation

public struct BackupRecord: Identifiable, Hashable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let sizeBytes: Int64
    public let sourcePath: String?
    /// True while the marker file is still there — the copy never finished, so
    /// it is not a restore point.
    public var isIncomplete: Bool = false

    public init(url: URL, createdAt: Date, sizeBytes: Int64, sourcePath: String?, isIncomplete: Bool = false) {
        self.url = url
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
        self.sourcePath = sourcePath
        self.isIncomplete = isIncomplete
    }

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

    /// Метка времени в имени копии. Не `private`: локаль у неё закреплена
    /// сторожем.
    ///
    /// `en_US_POSIX` обязателен там, где формат задан строкой: без него
    /// `DateFormatter` берёт локаль системы, и на персидской в имени файла
    /// окажется «۲۰۲۶-۰۸-۲۵», а на тайской — год 2569. Имя копии после этого
    /// не сортируется рядом с остальными и не разбирается обратно.
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Present while a copy is in flight; removed when the copy is verified.
    static let incompleteMarker = "_chromadbmanager_incomplete"
    /// Заметка к копии: откуда она, когда и зачем.
    static let noteFile = "_chromadbmanager_backup.txt"
    /// Free space required on top of the database size, as a fraction.
    public static let freeSpaceHeadroom = 0.2

    /// Сколько места нужно копии базы такого объёма — одно правило и для
    /// проверки перед копией, и для предупреждения на экране «Состояние».
    public static func requiredSpace(forDatabaseBytes size: Int64) -> Int64 {
        size + Int64(Double(size) * freeSpaceHeadroom)
    }

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
        let required = Self.requiredSpace(forDatabaseBytes: directorySize(source))
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
        if let holder = Self.liveServer(holding: source) {
            throw BackupError.serverStillRunning(pid: holder.pid)
        }

        try AppPaths.ensureDirectory(directory)

        // Checked before anything is written: a copy that runs out of space
        // half-way is worse than a copy that never started.
        let space = spaceCheck(for: source)
        guard space.fits else {
            throw BackupError.notEnoughSpace(required: space.requiredBytes, available: space.availableBytes, directory: directory.path)
        }

        let stamp = Self.stampFormatter.string(from: Date())
        // Имя — до секунды, и две копии в одну секунду (ручная и «перед
        // обслуживанием», двойное нажатие) получили бы одну папку: вторая
        // клала метку «копия не завершена» в первую, готовую, и та переставала
        // восстанавливаться. Занятое имя получает номер.
        var name = "\(source.lastPathComponent)_\(stamp)"
        var attempt = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(source.lastPathComponent)_\(stamp)-\(attempt)"
            attempt += 1
        }
        let destination = directory.appendingPathComponent(name, isDirectory: true)

        log(.info, "Бэкап", "Копирование \(source.path) → \(destination.path)")
        // Метка ставится **до** копирования и снимается только после проверки.
        //
        // Прежде она ставилась строкой ниже — после `copyItem`, — и окно,
        // которое она закрывала, начиналось там, где опасность кончалась.
        // Копия базы на сорок гигабайт идёт минутами: выход из приложения,
        // падение или ошибка ввода-вывода посреди копирования оставляли папку
        // с половиной файлов и **без** метки. `list()` называл такую копию
        // годной, а `restore()` соглашался её развернуть — то есть отодвигал
        // живую базу и ставил на её место обрезанную.
        //
        // Поэтому папка заводится заранее, метка ложится в неё первой, а
        // содержимое копируется внутрь по одному элементу: `copyItem` на
        // готовую папку не соглашается.
        let marker = destination.appendingPathComponent(Self.incompleteMarker)
        // Без `withIntermediateDirectories`: чужая папка с тем же именем,
        // возникшая между проверкой и этой строкой, — отказ, а не слияние.
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        fileManager.createFile(atPath: marker.path, contents: Data("copy in progress\n".utf8))
        // Заметка, оставшаяся в папке базы от прежних восстановлений, — чужая:
        // у этой копии своя (или никакой).
        for entry in try fileManager.contentsOfDirectory(atPath: source.path) where entry != Self.noteFile {
            try fileManager.copyItem(
                at: source.appendingPathComponent(entry),
                to: destination.appendingPathComponent(entry)
            )
        }

        if let note {
            let metadata = "source: \(source.path)\ncreated: \(Date())\nnote: \(note)\n"
            do {
                try metadata.write(
                    to: destination.appendingPathComponent(Self.noteFile),
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
        // Пути — относительные, какими их отдаёт сам обход. Отрезать корень
        // строкой нельзя: обход пишет пути так, как они записаны на диске, —
        // с настоящим регистром букв и с «/private» у «/tmp» и «/var». У базы,
        // путь к которой в настройках набран другим регистром, ключи
        // оригинала и копии не сходились ни разу: проверка падала на каждой
        // копии, и копии перед обновлением не проходили вовсе. (С «/private»
        // замена строкой срабатывала в середине пути и портила обе стороны
        // одинаково — сходилось по случайности.)
        func inventory(_ url: URL) -> [String: Int64] {
            var result: [String: Int64] = [:]
            guard let enumerator = fileManager.enumerator(atPath: url.path) else { return result }
            for case let relative as String in enumerator {
                guard relative != Self.incompleteMarker, relative != Self.noteFile else { continue }
                // Размер — только у файлов, как и прежде: у папки он зависит
                // от файловой системы, а не от содержимого.
                let attributes = enumerator.fileAttributes
                let isFile = attributes?[.type] as? FileAttributeType == .typeRegular
                result[relative] = isFile ? ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) : 0
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
    /// Кладёт выгрузку под свободным именем.
    ///
    /// Имя — до секунды, и две выгрузки одной коллекции в одну секунду
    /// (повторное извлечение и пересчёт, подтверждённые подряд; повтор после
    /// мгновенного сбоя) писались в один файл: вторая затирала первую, и
    /// свидетельство первой операции указывало на чужое содержимое. Занятое
    /// имя получает номер, как у копий папки базы. Свободное имя проверяется
    /// переносом, а не заранее: выгрузка длится долго, и проверенное
    /// в начале имя к концу могло быть уже занято.
    func place(_ data: Data, named base: String) throws -> URL {
        let pending = directory.appendingPathComponent(".\(base)-\(UUID().uuidString).partial")
        try data.write(to: pending, options: .atomic)
        var name = "\(base).json"
        var attempt = 2
        while true {
            let destination = directory.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: pending, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                name = "\(base)-\(attempt).json"
                attempt += 1
            } catch {
                try? fileManager.removeItem(at: pending)
                throw error
            }
        }
    }

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
        let destination = try place(data, named: "\(collection.name)_\(stamp)")

        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        log(.success, "Бэкап", "Экспорт коллекции «\(collection.name)»: \(rows.count) документов → \(destination.lastPathComponent) (\(size))")
        return BackupEvidence(
            record: nil,
            exportURL: destination,
            describedAs: String(localized: "экспорт \(rows.count) документов в \(destination.lastPathComponent) (\(size))")
        )
    }

    /// Экспорт нескольких коллекций — одним свидетельством.
    ///
    /// Источник с раскладкой по подпапкам или по правилу пишет в несколько
    /// коллекций, и переизвлечение переписывает их все. Копия одной первой
    /// оставляла остальные без бэкапа — вопреки «сначала копия, всегда».
    public func exportCollections(
        _ collections: [ChromaCollection],
        from chroma: ChromaClient,
        note: String
    ) async throws -> BackupEvidence {
        var evidence: [BackupEvidence] = []
        for collection in collections {
            evidence.append(try await exportCollection(collection, from: chroma, note: note))
        }
        guard evidence.count != 1 else { return evidence[0] }
        return BackupEvidence(
            record: nil,
            exportURL: evidence.first?.exportURL,
            describedAs: zip(collections, evidence)
                .map { "«\($0.name)»: \($1.describedAs)" }
                .joined(separator: "; ")
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
                let note = try? String(contentsOf: url.appendingPathComponent(Self.noteFile), encoding: .utf8)
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
    ///
    /// Копия разворачивается **рядом** с базой, во временную папку, и только
    /// целиком встаёт на её место. Прежде живая база отодвигалась, а копия
    /// писалась прямо в её папку: оборвись копирование (нет места, ошибка
    /// ввода-вывода, выход из приложения) — и на месте базы оставалась её
    /// половина, а сама база лежала под другим именем в папке копий.
    public func restore(_ record: BackupRecord, to destination: URL) throws {
        guard !record.isIncomplete else {
            throw BackupError.incompleteBackup(record.name)
        }
        if let holder = Self.liveServer(holding: destination) {
            throw BackupError.serverStillRunning(pid: holder.pid)
        }
        let parent = destination.deletingLastPathComponent()
        try AppPaths.ensureDirectory(parent)

        // Места — на всю копию, до первого записанного байта: копия, упавшая
        // посередине, хуже копии, которая не началась.
        let required = directorySize(record.url)
        if let available = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, available < required {
            throw BackupError.notEnoughSpace(required: required, available: available, directory: parent.path)
        }

        let stamp = Self.stampFormatter.string(from: Date())
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent)_restoring_\(stamp)", isDirectory: true
        )
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: record.url, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        // Заметка копии — про копию, а не про базу: оставленная в папке базы,
        // она уехала бы в следующую копию и подписала бы её чужими словами.
        try? fileManager.removeItem(at: staging.appendingPathComponent(Self.noteFile))

        var aside: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let asideName = destination.lastPathComponent + "_before_restore_" + stamp
            let target = directory.appendingPathComponent(asideName, isDirectory: true)
            try AppPaths.ensureDirectory(directory)
            do {
                try fileManager.moveItem(at: destination, to: target)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
            aside = target
            log(.warning, "Бэкап", "Текущая база сохранена как \(target.lastPathComponent)")
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            // Подмена не удалась — прежняя база возвращается на своё место.
            if let aside { try? fileManager.moveItem(at: aside, to: destination) }
            try? fileManager.removeItem(at: staging)
            throw error
        }
        log(.success, "Бэкап", "Резервная копия \(record.name) восстановлена в \(destination.path)")
    }

    public func delete(_ record: BackupRecord) throws {
        try fileManager.removeItem(at: record.url)
        log(.warning, "Бэкап", "Резервная копия \(record.name) удалена")
    }

    public func directorySize(_ url: URL) -> Int64 { DiskUsage.size(of: url) }
}

extension BackupService {
    /// Наш сервер, который всё ещё держит эту папку базы.
    ///
    /// Копию снимают и восстанавливают, остановив сервер, — но остановка
    /// может и не удаться: процесс в непрерываемом вводе-выводе переживает
    /// SIGKILL, и запись о нём тогда остаётся. Копия папки из-под живого
    /// SQLite — испорченная копия, а восстановление поверх живого — порча
    /// самой базы. Проверка здесь, а не у каждого вызывающего: путей к копии
    /// шесть, и один забытый — это ровно та копия, на которую понадеются.
    ///
    /// «Не удалось опознать» считается живым: процесс есть, и, возможно, наш.
    static func liveServer(
        holding folder: URL, records: [RunningServerRecord] = RunningServerStore.load()
    ) -> RunningServerRecord? {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return records.first { record in
            URL(fileURLWithPath: record.path).standardizedFileURL.resolvingSymlinksInPath().path == target
                && !ServerIdentity.verify(record).allowsForgetting
        }
    }
}

public enum BackupError: LocalizedError {
    case sourceMissing(String)
    /// Папку держит работающий сервер — копировать или восстанавливать нельзя.
    case serverStillRunning(pid: Int32)
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
        case .serverStillRunning(let pid):
            return String(localized: "Папку базы держит работающий сервер ChromaDB (PID \(pid.plainDigits)) — копия из-под живого процесса была бы испорченной. Остановите его на экране «Сервер» и повторите.")
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
