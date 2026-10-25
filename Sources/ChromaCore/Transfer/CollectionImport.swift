import Foundation
import CryptoKit

/// Построчное чтение большого файла.
///
/// Файл на миллион документов не должен собираться в память ни при записи, ни
/// при чтении — значит, и читать его надо кусками, а не целиком. Разделитель
/// ищется в буфере; строка длиннее буфера дочитывается следующими кусками.
public final class JSONLinesReader {
    public static let chunkSize = 256 * 1024

    private let handle: FileHandle
    /// Прочитанное, но ещё не разобранное. Массив байтов, а не `Data`:
    /// у `Data` срезы держат индексы родителя, и «отрезать голову» у неё
    /// незаметно превращается в копию всего остатка на каждой строке.
    private var buffer: [UInt8] = []
    /// Докуда в буфере уже дочитали. Отдельный указатель вместо удаления
    /// с начала: удалять по строке — это квадрат от размера файла, и на
    /// ста тысячах строк он виден невооружённым глазом.
    private var position = 0
    private var finished = false

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    /// Следующая строка без завершающего перевода, или `nil` в конце файла.
    public func next() throws -> Data? {
        while true {
            if let index = buffer[position...].firstIndex(of: 0x0A) {
                let line = buffer[position..<index]
                position = index + 1
                compactIfNeeded()
                if line.isEmpty { continue }
                return Data(line)
            }
            if finished {
                guard position < buffer.count else { return nil }
                let line = buffer[position...]
                position = buffer.count
                return line.isEmpty ? nil : Data(line)
            }
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty { finished = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    /// Хвост переезжает в начало, когда прочитанного накопилось на несколько
    /// кусков. Реже — и буфер растёт до размера файла; чаще — и мы копируем
    /// хвост на каждой строке.
    private func compactIfNeeded() {
        guard position >= Self.chunkSize * 2 else { return }
        buffer.removeFirst(position)
        position = 0
    }

    public func close() { try? handle.close() }
}

/// Что делать с документом, который в целевой коллекции уже есть.
public enum ImportConflictPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case skip
    case overwrite
    case stop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skip: return String(localized: "Пропустить существующие")
        case .overwrite: return String(localized: "Перезаписать существующие")
        case .stop: return String(localized: "Прервать при первом совпадении")
        }
    }
}

/// Отчёт импорта.
public struct ImportReport: Sendable, Hashable {
    public var written: Int = 0
    public var skipped: Int = 0
    public var overwritten: Int = 0
    /// Строки, которые не разобрались. Один битый документ не роняет перенос
    /// миллиона — но и молча не исчезает.
    public var brokenLines: [Int] = []
    public var reembedded: Int = 0
    public var stoppedAtConflict: String?
    public var finished = false

    public var line: String {
        var parts = [String(localized: "записано \(written.plainDigits)")]
        if overwritten > 0 { parts.append(String(localized: "перезаписано \(overwritten.plainDigits)")) }
        if skipped > 0 { parts.append(String(localized: "пропущено \(skipped.plainDigits)")) }
        if reembedded > 0 { parts.append(String(localized: "векторов посчитано \(reembedded.plainDigits)")) }
        if !brokenLines.isEmpty { parts.append(String(localized: "битых строк \(brokenLines.count.plainDigits)")) }
        return parts.joined(separator: ", ")
    }
}

/// Где остановился прерванный импорт.
///
/// Повтор безопасен и без этого — идентификаторы детерминированы, а запись
/// идёт через `upsert`, — но перечитывать миллион строк ради этого незачем.
public struct ImportCheckpoint: Codable, Sendable, Hashable {
    public var packagePath: String
    public var dataSHA256: String
    public var collectionName: String
    /// Коллекция, в которую шла запись, — по идентификатору, а не по имени.
    ///
    /// Имя повторяется: половину заполненную коллекцию удалили и завели
    /// заново под тем же именем, или переключились на другой сервер.
    /// Совпадение по имени продолжало такой импорт с середины, и первые
    /// тысячи документов не записывались вовсе — при отчёте «готово».
    /// Необязательный — чтобы точка, записанная до него, читалась.
    public var collectionID: String?
    public var processedLines: Int
    public var updatedAt: Date

    public init(
        packagePath: String, dataSHA256: String, collectionName: String, collectionID: String? = nil,
        processedLines: Int, updatedAt: Date = Date()
    ) {
        self.packagePath = packagePath
        self.dataSHA256 = dataSHA256
        self.collectionName = collectionName
        self.collectionID = collectionID
        self.processedLines = processedLines
        self.updatedAt = updatedAt
    }
}

public struct ImportCheckpointStore: Sendable {
    private let directory: URL
    private let log: LogHandler

    public init(
        directory: URL = AppPaths.importCheckpointsDirectory,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.directory = directory
        self.log = log
    }

    private func fileURL(for checksum: String) -> URL {
        directory.appendingPathComponent("\(checksum.prefix(32)).json")
    }

    public func load(checksum: String) -> ImportCheckpoint? {
        guard let data = try? Data(contentsOf: fileURL(for: checksum)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImportCheckpoint.self, from: data)
    }

    /// Контрольная точка — это обещание «прерванный импорт можно продолжить».
    ///
    /// Не записалась — обещание не выполнено, и узнать об этом человек должен
    /// сейчас, а не через полчаса, когда импорт прервётся и начнётся заново
    /// с первой строки.
    public func save(_ checkpoint: ImportCheckpoint) {
        _ = try? AppPaths.ensureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(checkpoint).write(
                to: fileURL(for: checkpoint.dataSHA256), options: .atomic
            )
        } catch {
            log(.warning, "Импорт",
                "Не удалось сохранить точку продолжения (\(error.localizedDescription)). "
                + "Импорт продолжает работать, но прерывать его сейчас нельзя: возобновить с этого места будет не с чего.")
        }
    }

    public func clear(checksum: String) {
        try? FileManager.default.removeItem(at: fileURL(for: checksum))
    }
}

/// Импорт пакета `.chromaexport`.
public struct CollectionImporter: Sendable {
    /// Что импорту позволено делать с базой: только запись документов и
    /// вопрос «какие из этих идентификаторов уже есть».
    public protocol Destination: Sendable {
        func existingIDs(collectionID: String, ids: [String]) async throws -> Set<String>
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws
    }

    public struct Options: Sendable {
        public var conflictPolicy: ImportConflictPolicy
        public var batchSize: Int
        /// Продолжить с места, где остановился прошлый запуск.
        public var resumesFromCheckpoint: Bool
        /// Модель для расчёта векторов, если их нет в пакете.
        public var embeddingModel: String?

        public init(
            conflictPolicy: ImportConflictPolicy = .skip,
            batchSize: Int = 100,
            resumesFromCheckpoint: Bool = true,
            embeddingModel: String? = nil
        ) {
            self.conflictPolicy = conflictPolicy
            self.batchSize = max(1, batchSize)
            self.resumesFromCheckpoint = resumesFromCheckpoint
            self.embeddingModel = embeddingModel
        }
    }

    public struct Progress: Sendable {
        public var processed: Int
        public var total: Int
    }

    private let destination: any Destination
    private let embeddings: EmbeddingProvider?
    private let checkpoints: ImportCheckpointStore
    private let log: LogHandler

    public init(
        destination: any Destination,
        embeddings: EmbeddingProvider? = nil,
        checkpoints: ImportCheckpointStore? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.destination = destination
        self.embeddings = embeddings
        // Хранилище точек продолжения по умолчанию берёт тот же журнал:
        // иначе его жалоба «точку сохранить не удалось» уходила бы в никуда
        // именно там, где импортом занимается приложение.
        self.checkpoints = checkpoints ?? ImportCheckpointStore(log: log)
        self.log = log
    }

    // MARK: - Чтение пакета

    public static func readManifest(at package: URL) throws -> CollectionExportManifest {
        let manifestURL = package.appendingPathComponent("manifest.json")
        let dataURL = package.appendingPathComponent("documents.jsonl")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: dataURL.path)
        else { throw TransferError.notAPackage(package.lastPathComponent) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: CollectionExportManifest
        do {
            manifest = try decoder.decode(CollectionExportManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw TransferError.brokenManifest(error.localizedDescription)
        }
        // Версия читается **до** всего остального: пакет из будущего мог
        // поменять смысл полей, и разбирать его наугад — худшее, что можно
        // сделать с чужими данными.
        guard manifest.formatVersion <= CollectionExportManifest.currentVersion else {
            throw TransferError.futureFormat(manifest.formatVersion)
        }
        return manifest
    }

    /// Сверка контрольной суммы — потоковая, до первой записи в базу.
    public static func verifyChecksum(at package: URL, manifest: CollectionExportManifest) throws {
        guard !manifest.dataSHA256.isEmpty else { return }
        let handle = try FileHandle(forReadingFrom: package.appendingPathComponent("documents.jsonl"))
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: {
            // Пакет бывает в гигабайты, и сверка идёт до первой записи в базу:
            // отменить её человек должен мочь, не дожидаясь конца чтения
            //.
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: JSONLinesReader.chunkSize), !chunk.isEmpty else { return false }
            digest.update(data: chunk)
            return true
        }) {}
        let actual = digest.finalize().compactMap { String(format: "%02x", $0) }.joined()
        guard actual == manifest.dataSHA256 else { throw TransferError.checksumMismatch }
    }

    /// Что мешает импортировать пакет в эту коллекцию.
    ///
    /// Размерность — запрет; метрика и модель — предупреждения, которые
    /// человек подтверждает: данные останутся валидными, но смысл поиска
    /// изменится.
    public static func problems(
        manifest: CollectionExportManifest, target: ChromaCollection?
    ) throws -> [String] {
        guard let target else { return [] }
        // Пакет без векторов пересчитывается моделью самой коллекции: его
        // размерность и модель ни с чем не смешиваются, сверять их незачем.
        //
        // Но только если модель у коллекции **есть**. Без привязки векторы
        // считает модель пакета, и сверка нужна та же, что у пакета
        // с векторами: иначе коллекция чужой модели той же размерности
        // молча получала векторы двух моделей.
        var warnings: [String] = []
        if !manifest.includesEmbeddings {
            guard target.boundModel == nil else { return [] }
            warnings.append(String(localized: "К коллекции не привязана модель: векторы посчитает модель пакета\(manifest.model.map { " «\($0)»" } ?? ""). Проверьте, что ею же посчитаны документы коллекции, — векторы разных моделей в одной коллекции искать не дают."))
        }
        if let expected = target.effectiveDimension, let got = manifest.dimension, expected != got {
            throw TransferError.dimensionMismatch(expected: expected, got: got)
        }
        if let metric = manifest.metric, let targetMetric = target.space?.rawValue, metric != targetMetric {
            warnings.append(String(localized: "Метрика не совпадает: у коллекции \(targetMetric), в пакете \(metric). Данные останутся валидными, но результаты поиска изменятся."))
        }
        if let model = manifest.model, let targetModel = target.boundModel, model != targetModel {
            warnings.append(String(localized: "Модель не совпадает: у коллекции \(targetModel), в пакете \(model). Смешивать в одной коллекции векторы разных моделей бессмысленно — искать по ним нечем."))
        }
        return warnings
    }

    // MARK: - Импорт

    public func `import`(
        package: URL,
        manifest: CollectionExportManifest,
        into collectionID: String,
        collectionName: String,
        options: Options = Options(),
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> ImportReport {
        if !manifest.includesEmbeddings, options.embeddingModel == nil {
            throw TransferError.noEmbeddingsAndNoModel
        }

        var report = ImportReport()
        var startLine = 0
        // Без контрольной суммы пакет не опознать: у всех таких пакетов
        // точка легла бы в один и тот же файл.
        let usesCheckpoint = !manifest.dataSHA256.isEmpty
        if options.resumesFromCheckpoint, usesCheckpoint,
           let checkpoint = checkpoints.load(checksum: manifest.dataSHA256),
           checkpoint.collectionName == collectionName,
           checkpoint.collectionID == collectionID {
            startLine = checkpoint.processedLines
            log(.info, "Перенос", "Импорт продолжается со строки \(startLine.plainDigits): прошлый запуск остановился на ней")
        }

        let reader = try JSONLinesReader(url: package.appendingPathComponent("documents.jsonl"))
        defer { reader.close() }
        let decoder = JSONDecoder()

        var line = 0
        // Номер строки хранится вместе с документом. Отметка о месте остановки
        // обязана указывать на **записанное**, а битые строки в пачку не
        // попадают — по её длине номер не восстановить.
        var batch: [(line: Int, document: ExportedDocument)] = []

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let consumed = try await write(
                batch.map(\.document), into: collectionID, options: options, report: &report
            )
            // Отметка — по последнему записанному документу, а не по концу
            // пачки. Пока она безусловно вставала на конец, остановка на
            // конфликте уносила с собой и чистые документы перед ним, и сам
            // конфликт: следующий заход начинал уже после них.
            let reached = consumed > 0 ? batch[consumed - 1].line : batch[0].line - 1
            batch.removeAll(keepingCapacity: true)
            if usesCheckpoint {
                checkpoints.save(ImportCheckpoint(
                    packagePath: package.path, dataSHA256: manifest.dataSHA256,
                    collectionName: collectionName, collectionID: collectionID,
                    processedLines: reached
                ))
            }
            progress?(Progress(processed: reached, total: manifest.documentCount))
        }

        while let data = try reader.next() {
            try Task.checkCancellation()
            line += 1
            guard line > startLine else { continue }
            do {
                // Пул нужен буквально: `JSONDecoder` под капотом создаёт
                // временные объекты Objective-C, и в плотном цикле без пула
                // они копятся до конца файла. На ста тысячах строк это
                // 600 МБ вместо 25 — измерено, а не предположено.
                try autoreleasepool {
                    batch.append((line: line, document: try decoder.decode(ExportedDocument.self, from: data)))
                }
            } catch {
                // Один битый документ не должен ронять перенос миллиона —
                // но и исчезнуть молча он не может.
                report.brokenLines.append(line)
                continue
            }
            if batch.count >= options.batchSize {
                try await flush()
                if report.stoppedAtConflict != nil { return report }
            }
        }
        try await flush()

        report.finished = report.stoppedAtConflict == nil
        if report.finished { checkpoints.clear(checksum: manifest.dataSHA256) }
        log(.success, "Перенос", "Импорт в «\(collectionName)»: \(report.line)")
        return report
    }

    /// Сколько документов пачки обработано: все — или те, что успели пройти
    /// до конфликта. По этому числу вызывающий ставит отметку о месте
    /// остановки.
    @discardableResult
    private func write(
        _ documents: [ExportedDocument],
        into collectionID: String,
        options: Options,
        report: inout ImportReport
    ) async throws -> Int {
        var incoming = documents
        var consumed = documents.count
        let existing = try await destination.existingIDs(collectionID: collectionID, ids: incoming.map(\.id))

        switch options.conflictPolicy {
        case .skip:
            let before = incoming.count
            incoming = incoming.filter { !existing.contains($0.id) }
            report.skipped += before - incoming.count
        case .overwrite:
            report.overwritten += incoming.filter { existing.contains($0.id) }.count
        case .stop:
            if let clash = incoming.firstIndex(where: { existing.contains($0.id) }) {
                report.stoppedAtConflict = incoming[clash].id
                log(.warning, "Перенос", "Импорт остановлен: документ \(incoming[clash].id) уже есть в коллекции")
                // Чистые документы перед конфликтным записываются: они ни в чём
                // не виноваты, а продолжить импорт нужно ровно с конфликта.
                // Раньше пачка не записывалась целиком — и терялась целиком.
                incoming = Array(incoming.prefix(clash))
                consumed = clash
            }
        }
        guard !incoming.isEmpty else { return consumed }

        // Векторов нет — считаем заново выбранной моделью. Это единственное
        // место, где импорт обращается к модели, и оно оплачивается временем,
        // о котором человека предупредили заранее (12.7).
        var vectors: [[Double]] = incoming.map { $0.embedding ?? [] }
        // Считаются **только пустые места**, а готовые векторы остаются
        // из пакета.
        //
        // Прежде хватало одного документа без вектора, чтобы вся пачка ушла
        // в модель, — и векторы, привезённые пакетом, затирались векторами
        // выбранной модели. Размерности при этом совпадают, никто не жалуется,
        // а в коллекции с одной привязкой лежит смесь двух моделей: поиск
        // сравнивает несравнимое. Заодно счётчик пересчитанных завышался
        // на всю пачку.
        let missing = vectors.indices.filter { vectors[$0].isEmpty }
        if !missing.isEmpty {
            guard let embeddings, let model = options.embeddingModel else {
                throw TransferError.noEmbeddingsAndNoModel
            }
            let texts = missing.map { incoming[$0].document ?? "" }
            let computed = try await embeddings.embed(texts: texts, model: model)
            // Вторая линия к проверке внутри клиента: недосчитанные векторы
            // означали бы тихо не импортированные документы — при отчёте,
            // где они посчитаны импортированными.
            guard computed.count == missing.count else {
                throw LMStudioError.embeddingCountMismatch(sent: missing.count, received: computed.count)
            }
            for (slot, vector) in zip(missing, computed) { vectors[slot] = vector }
            report.reembedded += missing.count
        }

        let records = zip(incoming, vectors).map { document, vector in
            EmbeddedRecord(
                id: document.id,
                document: document.document ?? "",
                embedding: vector,
                metadata: document.metadata ?? [:]
            )
        }
        try await destination.upsert(collectionID: collectionID, records: records)
        report.written += records.count
        return consumed
    }
}
