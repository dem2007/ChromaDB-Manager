import Foundation
import CryptoKit

// MARK: - Request

/// Which of the two explicit operations from spec is being run.
///
/// Vectors from different models are not comparable, so "switch the model" is
/// never a toggle — it is one of these, with a backup and a confirmation.
public enum ReembeddingScenario: String, Codable, CaseIterable, Identifiable {
    /// Copy documents and metadata into a new collection, recompute the vectors,
    /// leave the original alone. The default.
    case clone
    /// Overwrite the vectors of the existing collection.
    case inPlace

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clone: return String(localized: "Клонировать в новую коллекцию")
        case .inPlace: return String(localized: "Пересчитать на месте")
        }
    }

    public var summary: String {
        switch self {
        case .clone:
            return String(localized: "Исходная коллекция не меняется — с ней можно сравнить результат, а потом удалить вручную. Вариант по умолчанию.")
        case .inPlace:
            return String(localized: "Старые векторы перезаписываются. Пока пересчёт не закончен, в коллекции лежат векторы двух моделей, и поиск по ней смешивает их — отмена сохраняет место остановки, чтобы продолжить.")
        }
    }
}

public struct ReembeddingRequest {
    public var collection: ChromaCollection
    public var targetModel: String
    public var scenario: ReembeddingScenario
    /// Clone only: name of the collection being created.
    public var newCollectionName: String
    /// Clone only: metric for the copy. `nil` keeps the original's — changing
    /// it is a reason to clone, not something to do by accident.
    public var targetMetric: DistanceMetric?
    /// Re-cut the stored documents before embedding them.
    public var rechunk: Bool
    public var chunking: ChunkingConfiguration

    public init(
        collection: ChromaCollection,
        targetModel: String,
        scenario: ReembeddingScenario = .clone,
        newCollectionName: String = "",
        targetMetric: DistanceMetric? = nil,
        rechunk: Bool = false,
        chunking: ChunkingConfiguration = ChunkingConfiguration()
    ) {
        self.collection = collection
        self.targetModel = targetModel
        self.scenario = scenario
        self.newCollectionName = newCollectionName
        self.targetMetric = targetMetric
        self.rechunk = rechunk
        self.chunking = chunking
    }

    /// Suggested name for a clone: the original plus the model, trimmed to what
    /// ChromaDB accepts.
    public static func suggestedName(for collection: ChromaCollection, model: String) -> String {
        let modelPart = model.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? model
        return CollectionNaming.sanitize("\(collection.name)_\(modelPart)")
    }

    public var problem: String? {
        if targetModel.isEmpty { return String(localized: "Не выбрана целевая модель.") }
        if scenario == .clone {
            if newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Укажите имя новой коллекции.")
            }
            if CollectionNaming.sanitize(newCollectionName) == collection.name {
                return String(localized: "Имя клона совпадает с исходной коллекцией.")
            }
        }
        if rechunk, let chunkingProblem = chunking.problem { return chunkingProblem }
        return nil
    }
}

// MARK: - Progress and result

public struct ReembeddingProgress {
    public var stage: String
    public var processed: Int
    public var total: Int
    public var written: Int
    public var isPaused: Bool

    public init(stage: String, processed: Int = 0, total: Int = 0, written: Int = 0, isPaused: Bool = false) {
        self.stage = stage
        self.processed = processed
        self.total = total
        self.written = written
        self.isPaused = isPaused
    }

    public var remaining: Int { max(0, total - processed) }
    public var fraction: Double { total > 0 ? min(1, Double(processed) / Double(total)) : 0 }
}

/// Automatic check after the run: the counts must line up and a query must
/// actually come back with something.
public struct ReembeddingVerification {
    public let sourceDocuments: Int
    public let resultDocuments: Int
    public let dimension: Int
    public let queryReturnedHit: Bool
    public let note: String?

    public var isClean: Bool { queryReturnedHit && resultDocuments > 0 && note == nil }

    public var line: String {
        var text = String(localized: "документов было \(sourceDocuments), стало \(resultDocuments), размерность \(dimension.plainDigits)")
        text += queryReturnedHit
            ? String(localized: ", пробный запрос вернул результат")
            : String(localized: ", пробный запрос ничего не вернул")
        if let note { text += " — \(note)" }
        return text
    }
}

public struct ReembeddingReport {
    public let scenario: ReembeddingScenario
    public let sourceCollection: String
    public let resultCollection: String
    public let model: String
    public let dimension: Int
    public let processedDocuments: Int
    public let writtenDocuments: Int
    public let deletedDocuments: Int
    public let duration: TimeInterval
    public let verification: ReembeddingVerification
    public let backup: String

    public var line: String {
        String(localized: "«\(sourceCollection)» → «\(resultCollection)», модель \(model): обработано \(processedDocuments), записано \(writtenDocuments), удалено \(deletedDocuments), за \(String(format: "%.1f", duration)) с")
    }
}

public enum ReembeddingError: LocalizedError {
    case invalidRequest(String)
    case sameModel(String)
    case collectionExists(String)
    case emptyCollection(String)
    case dimensionChangeRequiresClone(collection: String, stored: Int, model: Int)
    case documentWithoutText(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let details):
            return details
        case .sameModel(let model):
            return String(localized: "Коллекция уже привязана к модели \(model) — пересчитывать нечего.")
        case .collectionExists(let name):
            return String(localized: "Коллекция «\(name)» уже существует. Выберите другое имя для клона.")
        case .emptyCollection(let name):
            return String(localized: "В коллекции «\(name)» нет документов.")
        case .dimensionChangeRequiresClone(let collection, let stored, let model):
            return String(localized: "Коллекция «\(collection)» хранит векторы размерности \(stored.plainDigits), а выбранная модель даёт \(model.plainDigits). ChromaDB фиксирует размерность коллекции навсегда — пересчитать на месте невозможно.")
        case .documentWithoutText(let id):
            return String(localized: "У документа \(id) нет текста — пересчитать вектор невозможно.")
        case .cancelled:
            return String(localized: "Операция отменена.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .sameModel:
            return String(localized: "Выберите другую модель или измените параметры чанкинга.")
        case .documentWithoutText:
            return String(localized: "Такие документы можно исключить, клонировав коллекцию: в клон попадут только документы с текстом.")
        case .dimensionChangeRequiresClone:
            return String(localized: "Выберите сценарий «Клонировать в новую коллекцию»: у новой коллекции будет своя размерность. Или возьмите модель с той же размерностью.")
        default:
            return nil
        }
    }
}

// MARK: - Journal

/// One finished (or abandoned) operation. Kept on disk so the «Логи» screen can
/// show the history of re-embeddings, which the spec asks for by name.
public struct ReembeddingJournalEntry: Identifiable, Codable, Hashable {
    public enum Outcome: String, Codable {
        case finished
        case cancelled
        case failed

        public var title: String {
            switch self {
            case .finished: return String(localized: "завершено")
            case .cancelled: return String(localized: "отменено")
            case .failed: return String(localized: "ошибка")
            }
        }
    }

    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var scenario: ReembeddingScenario
    public var sourceCollection: String
    public var resultCollection: String
    public var model: String
    public var dimension: Int
    public var processed: Int
    public var written: Int
    public var outcome: Outcome
    public var detail: String

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date = Date(),
        scenario: ReembeddingScenario,
        sourceCollection: String,
        resultCollection: String,
        model: String,
        dimension: Int,
        processed: Int,
        written: Int,
        outcome: Outcome,
        detail: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scenario = scenario
        self.sourceCollection = sourceCollection
        self.resultCollection = resultCollection
        self.model = model
        self.dimension = dimension
        self.processed = processed
        self.written = written
        self.outcome = outcome
        self.detail = detail
    }
}

/// Where an interrupted in-place run stopped, so it can carry on from the last
/// finished batch instead of redoing everything.
public struct ReembeddingCheckpoint: Codable, Hashable {
    public var collectionID: String
    public var collectionName: String
    public var targetModel: String
    public var chunkingSignature: String
    public var rechunk: Bool
    /// Ids already rewritten with the new model.
    public var doneIDs: [String]
    public var totalIDs: Int
    public var startedAt: Date
    /// Метка прогона, которую несут перенарезанные им куски.
    ///
    /// По ней продолжение узнаёт документ, **уже** перенарезанный этим же
    /// прогоном после последней сохранённой точки: прочитанный заново, он
    /// оказался бы своим первым куском и нарезался бы ещё раз — а куски
    /// `#1…#n` затёрлись бы обрывками первого. Необязательная — точки,
    /// записанные до неё, читаются.
    public var runStamp: String?

    public var processed: Int { doneIDs.count }
}

public struct ReembeddingJournalFile: Codable {
    public var entries: [ReembeddingJournalEntry]
    public var checkpoints: [ReembeddingCheckpoint]

    public init(entries: [ReembeddingJournalEntry] = [], checkpoints: [ReembeddingCheckpoint] = []) {
        self.entries = entries
        self.checkpoints = checkpoints
    }
}

/// Persists the journal and the checkpoints.
public final class ReembeddingJournal {
    private let fileURL: URL
    private let log: LogHandler
    private let queue = DispatchQueue(label: "app.chromadbmanager.reembedding-journal")
    /// Older operations stay interesting for a while, but not forever.
    private let historyLimit = 200

    public init(fileURL: URL = AppPaths.reembeddingJournalFile, log: @escaping LogHandler = noopLogHandler) {
        self.fileURL = fileURL
        self.log = log
    }

    public func load() -> ReembeddingJournalFile {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return ReembeddingJournalFile() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(ReembeddingJournalFile.self, from: data)) ?? ReembeddingJournalFile()
        }
    }

    public func record(_ entry: ReembeddingJournalEntry) {
        var file = load()
        file.entries.insert(entry, at: 0)
        if file.entries.count > historyLimit { file.entries.removeLast(file.entries.count - historyLimit) }
        write(file)
    }

    /// Контрольная точка вместе с тем, что дописано в построчный список
    /// готовых документов.
    public func checkpoint(for collectionID: String) -> ReembeddingCheckpoint? {
        guard var checkpoint = load().checkpoints.first(where: { $0.collectionID == collectionID }) else {
            return nil
        }
        let appended = doneIDs(collectionID: collectionID)
        if !appended.isEmpty {
            var seen = Set(checkpoint.doneIDs)
            checkpoint.doneIDs += appended.filter { seen.insert($0).inserted }
        }
        return checkpoint
    }

    /// Готовые документы прогона — построчно, дозаписью.
    ///
    /// Не внутри контрольной точки: та записывается целиком, и список,
    /// растущий до размера коллекции, переписывался бы на каждой пачке —
    /// на двухстах тысячах документов это гигабайты на диск ради того,
    /// чтобы дописать тридцать два идентификатора (квадрат от размера).
    func doneURL(collectionID: String) -> URL {
        let safe = String(collectionID.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.map(Character.init))
        return fileURL.deletingLastPathComponent().appendingPathComponent("reembedding-done-\(safe).jsonl")
    }

    /// Дописать готовые идентификаторы. Каждый — строкой JSON: в
    /// идентификаторе бывает и перевод строки.
    public func appendDone(_ ids: [String], collectionID: String) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let url = doneURL(collectionID: collectionID)
            var data = Data()
            for id in ids {
                guard let line = try? JSONEncoder().encode(id) else { continue }
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
            do {
                try AppPaths.ensureDirectory(url.deletingLastPathComponent())
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                log(.error, "Re-embedding", "Не удалось дописать контрольную точку: \(error.localizedDescription)")
            }
        }
    }

    /// Начать список заново — с тем, что уже известно готовым.
    func resetDone(_ ids: [String], collectionID: String) {
        queue.sync { try? FileManager.default.removeItem(at: doneURL(collectionID: collectionID)) }
        appendDone(ids, collectionID: collectionID)
    }

    func doneIDs(collectionID: String) -> [String] {
        queue.sync {
            JSONLines.read(at: doneURL(collectionID: collectionID))
                .compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        }
    }

    public func save(_ checkpoint: ReembeddingCheckpoint) {
        var file = load()
        file.checkpoints.removeAll { $0.collectionID == checkpoint.collectionID }
        file.checkpoints.append(checkpoint)
        write(file)
    }

    public func clearCheckpoint(collectionID: String) {
        queue.sync { try? FileManager.default.removeItem(at: doneURL(collectionID: collectionID)) }
        var file = load()
        guard file.checkpoints.contains(where: { $0.collectionID == collectionID }) else { return }
        file.checkpoints.removeAll { $0.collectionID == collectionID }
        write(file)
    }

    private func write(_ file: ReembeddingJournalFile) {
        queue.sync {
            do {
                try AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(file).write(to: fileURL, options: .atomic)
            } catch {
                log(.error, "Re-embedding", "Не удалось сохранить журнал: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Service

/// Recomputes a collection's vectors with another model, either into a clone or
/// in place.
public actor ReembeddingService {
    /// Where to step aside between batches, set for the duration of one run.
    /// Held here rather than threaded through four private helpers: the actor
    /// runs one request at a time anyway.
    private var yieldPoint: (@Sendable () async -> Void)?

    private let log: LogHandler
    private let journal: ReembeddingJournal
    private let metrics: MetricsStore?
    private var paused = false
    private var active = false
    /// Контекст модели, в которую идёт пересчёт, на время прогона.
    private var targetContextLength: Int?
    /// Чем закончилась уборка после прерванного клонирования.
    /// Читается экраном **после** того, как прогон бросил ошибку: сообщение
    /// о судьбе клона должно называть то, что произошло, а не то, что
    /// задумывалось.
    public private(set) var lastCloneCleanup: CloneCleanup?

    public init(
        journal: ReembeddingJournal? = nil,
        metrics: MetricsStore? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.log = log
        self.journal = journal ?? ReembeddingJournal(log: log)
        self.metrics = metrics
    }

    public var isPaused: Bool { paused }
    public var isRunning: Bool { active }

    public func pause() {
        guard active else { return }
        paused = true
        log(.info, "Re-embedding", "Пауза")
    }

    public func resume() {
        guard paused else { return }
        paused = false
        log(.info, "Re-embedding", "Продолжаем")
    }

    public func journalEntries() -> [ReembeddingJournalEntry] { journal.load().entries }

    public func checkpoint(for collectionID: String) -> ReembeddingCheckpoint? {
        journal.checkpoint(for: collectionID)
    }

    public func discardCheckpoint(for collectionID: String) {
        journal.clearCheckpoint(collectionID: collectionID)
    }

    /// - Parameter backup: proof that a backup exists. There is no overload
    ///   without it — the spec calls the backup mandatory, so it is a parameter,
    ///   not a checkbox someone can forget.
    public func run(
        _ request: ReembeddingRequest,
        backup: BackupEvidence,
        chroma: ChromaClient,
        embeddings: EmbeddingProvider,
        chat: ChatProvider? = nil,
        binding: ModelBindingService,
        batchSize: Int = 32,
        resumeFromCheckpoint: Bool = false,
        /// Called between embedding batches so a more important task can take
        /// the model.
        yield: (@Sendable () async -> Void)? = nil,
        progress: @escaping @Sendable (ReembeddingProgress) -> Void
    ) async throws -> ReembeddingReport {
        yieldPoint = yield
        defer { yieldPoint = nil }
        if let problem = request.problem { throw ReembeddingError.invalidRequest(problem) }
        if !request.rechunk,
           request.scenario == .inPlace,
           request.collection.binding == BoundModel(model: request.targetModel, server: embeddings.server) {
            throw ReembeddingError.sameModel(request.targetModel)
        }

        active = true
        paused = false
        lastCloneCleanup = nil
        defer { active = false; paused = false }

        let started = Date()
        progress(ReembeddingProgress(stage: String(localized: "Подготовка")))
        log(.warning, "Re-embedding", "Старт: \(request.scenario.title), коллекция «\(request.collection.name)» → модель \(request.targetModel). Бэкап: \(backup.describedAs)")

        let sourceCount = try await chroma.count(collectionID: request.collection.id)
        guard sourceCount > 0 else { throw ReembeddingError.emptyCollection(request.collection.name) }

        let dimension = try await binding.dimension(of: request.targetModel, lmStudio: embeddings)
        // Контекст **целевой** модели: пересчитывается в неё, а не в прежнюю.
        targetContextLength = await embeddings.contextLength(of: request.targetModel)
        defer { targetContextLength = nil }

        // Verified on chroma 1.4.4: a collection's vector size is fixed by its
        // first write and stays fixed even after the collection is emptied —
        // `update` and `upsert` both answer «Collection expecting embedding with
        // dimension of N». So an in-place run to a differently sized model cannot
        // work, and refusing here beats failing halfway through the collection.
        if request.scenario == .inPlace {
            var stored = request.collection.effectiveDimension
            if stored == nil {
                stored = try? await chroma.storedDimension(collectionID: request.collection.id)
            }
            if let stored, stored != dimension {
                throw ReembeddingError.dimensionChangeRequiresClone(
                    collection: request.collection.name,
                    stored: stored,
                    model: dimension
                )
            }
        }

        do {
            let report: ReembeddingReport
            switch request.scenario {
            case .clone:
                report = try await runClone(
                    request, backup: backup, sourceCount: sourceCount, dimension: dimension,
                    chroma: chroma, embeddings: embeddings, chat: chat, binding: binding,
                    batchSize: batchSize, started: started, progress: progress
                )
            case .inPlace:
                report = try await runInPlace(
                    request, backup: backup, sourceCount: sourceCount, dimension: dimension,
                    chroma: chroma, embeddings: embeddings, chat: chat,
                    batchSize: batchSize, started: started,
                    resumeFromCheckpoint: resumeFromCheckpoint, progress: progress
                )
            }

            journal.record(ReembeddingJournalEntry(
                startedAt: started,
                scenario: request.scenario,
                sourceCollection: request.collection.name,
                resultCollection: report.resultCollection,
                model: request.targetModel,
                dimension: dimension,
                processed: report.processedDocuments,
                written: report.writtenDocuments,
                outcome: .finished,
                detail: report.verification.line
            ))
            log(
                report.verification.isClean ? .success : .warning,
                "Re-embedding",
                "\(report.line). Проверка: \(report.verification.line)"
            )
            return report
        } catch {
            // `Task.isCancelled` first, and not the error type: cancelling in
            // the middle of an HTTP call surfaces as `URLError(.cancelled)`
            // wrapped in a `ChromaError`, and the run was recorded as a failure
            // — right often enough to look correct, wrong whenever the stop
            // landed on a request.
            let isCancellation = Task.isCancelled
                || error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || (error as? ReembeddingError).map { if case .cancelled = $0 { return true } else { return false } } == true
            // В запись идёт то, что известно, а не нули. Размерность
            // посчитана до `do` и видна здесь — ноль в ней был просто потерей.
            // А сколько успела сделать операция на месте, знает контрольная
            // точка: «не сделано ничего» про отменённый прогон, оставивший
            // в коллекции новые векторы, — прямая неправда, и человек ищет
            // по журналу именно это.
            let done = request.scenario == .inPlace
                ? journal.checkpoint(for: request.collection.id)?.processed ?? 0
                : 0
            journal.record(Self.failureEntry(
                request: request, started: started, dimension: dimension, done: done,
                // У отмены причина одна — её остановили; «The operation
                // couldn’t be completed (Swift.CancellationError)» в журнале
                // операций читался как сбой.
                isCancellation: isCancellation,
                detail: isCancellation ? String(localized: "остановлено") : error.localizedDescription
            ))
            log(
                isCancellation ? .info : .error,
                "Re-embedding",
                isCancellation ? "Операция отменена" : "Операция не удалась: \(error.localizedDescription)"
            )
            // The screen distinguishes the two by the error type, so a stop must
            // arrive as a cancellation whatever it looked like underneath.
            throw isCancellation ? CancellationError() : error
        }
    }

    /// Что записать в журнал о сорвавшемся прогоне.
    ///
    /// Отдельной функцией, потому что путь до неё лежит через живые ChromaDB
    /// и LM Studio: проверить, что в записи стоит известное, а не нули,
    /// надо без них.
    static func failureEntry(
        request: ReembeddingRequest,
        started: Date,
        dimension: Int,
        done: Int,
        isCancellation: Bool,
        detail: String
    ) -> ReembeddingJournalEntry {
        ReembeddingJournalEntry(
            startedAt: started,
            scenario: request.scenario,
            sourceCollection: request.collection.name,
            resultCollection: request.scenario == .clone ? request.newCollectionName : request.collection.name,
            model: request.targetModel,
            dimension: dimension,
            processed: done,
            written: done,
            outcome: isCancellation ? .cancelled : .failed,
            detail: detail
        )
    }

    // MARK: - Clone

    private func runClone(
        _ request: ReembeddingRequest,
        backup: BackupEvidence,
        sourceCount: Int,
        dimension: Int,
        chroma: ChromaClient,
        embeddings: EmbeddingProvider,
        chat: ChatProvider?,
        binding: ModelBindingService,
        batchSize: Int,
        started: Date,
        progress: @escaping @Sendable (ReembeddingProgress) -> Void
    ) async throws -> ReembeddingReport {
        let name = CollectionNaming.sanitize(request.newCollectionName)
        if (try? await chroma.collection(named: name)) != nil {
            throw ReembeddingError.collectionExists(name)
        }

        var metadata = request.collection.metadataBinding(
            model: request.targetModel, server: embeddings.server, dimension: dimension
        )
        metadata["_cdbm_cloned_from"] = .string(request.collection.name)
        if request.rechunk {
            metadata[CollectionBindingKeys.chunkingStrategy] = .string(request.chunking.strategy.rawValue)
            metadata[CollectionBindingKeys.strategyParamsHash] = StrategyParamsHash.of(request.chunking).value
            // A clone re-chunked with a new recipe describes the new one; the
            // readable predecessor would describe neither.
            metadata.removeValue(forKey: CollectionBindingKeys.legacyChunking)
        }
        // The clone inherits the original's metric unless the user picked
        // another one: changing the metric is the same kind of reason to clone
        // as changing the model, and losing it silently would make the copy
        // rank differently from the original.
        let target = try await chroma.createCollection(
            name: name,
            metadata: metadata,
            configuration: CollectionConfiguration(
                metric: request.targetMetric ?? request.collection.space ?? .cosine
            ),
            getOrCreate: false
        )

        var processed = 0
        var written = 0
        var offset = 0
        let pageSize = 100
        let runStamp = Self.newRunStamp()

        do {
            while true {
                try await waitWhilePaused(processed: processed, total: sourceCount, written: written, progress: progress)
                try Task.checkCancellation()

                // The source collection is not being modified, so plain paging is
                // stable here.
                let page = try await chroma.getDocuments(collectionID: request.collection.id, limit: pageSize, offset: offset)
                if page.isEmpty { break }

                progress(ReembeddingProgress(
                    stage: String(localized: "Пересчёт в клон"),
                    processed: processed, total: sourceCount, written: written
                ))
                // Куски всей страницы — и векторы пачками поверх границ
                // документов: модель зовётся раз на `batchSize` кусков, а не
                // раз на документ. Без перенарезки документ — один кусок, и
                // прежде это было по вызову модели и записи в базу на каждый.
                var records: [EmbeddedRecord] = []
                for document in page {
                    try await waitWhilePaused(processed: processed, total: sourceCount, written: written, progress: progress)
                    try Task.checkCancellation()
                    records += try await pendingRecords(
                        of: document, request: request, embeddings: embeddings, chat: chat, runStamp: runStamp
                    )
                }
                written += try await write(
                    records, into: target.id, request: request, dimension: dimension,
                    embeddings: embeddings, chroma: chroma, batchSize: batchSize
                )
                processed += page.count

                if page.count < pageSize { break }
                offset += pageSize
            }
        } catch {
            // An unfinished clone is not left behind half-built. The deletion runs
            // in an unstructured task on purpose: this one is already cancelled,
            // and a request issued from a cancelled context is refused before it
            // reaches the server.
            //
            // Результат удаления больше не выбрасывается через `try?`: экран
            // сообщал «незавершённый клон удалён» безусловно, то есть утверждал
            // то, чего никто не проверял.
            log(.warning, "Re-embedding", "Клонирование прервано — незавершённая коллекция «\(name)» удаляется")
            lastCloneCleanup = await Task { () -> CloneCleanup in
                do {
                    try await chroma.deleteCollection(name: name)
                    return CloneCleanup(name: name, removed: true, failure: nil)
                } catch {
                    return CloneCleanup(
                        name: name, removed: false, failure: error.localizedDescription
                    )
                }
            }.value
            if let failure = lastCloneCleanup?.failure {
                log(.error, "Re-embedding", "Незавершённую коллекцию «\(name)» удалить не удалось: \(failure). Она осталась в базе неполной.")
            }
            throw error
        }

        let verification = try await verify(
            request: request, resultCollectionID: target.id, resultName: name,
            sourceCount: sourceCount, dimension: dimension,
            chroma: chroma, embeddings: embeddings
        )

        return ReembeddingReport(
            scenario: .clone,
            sourceCollection: request.collection.name,
            resultCollection: name,
            model: request.targetModel,
            dimension: dimension,
            processedDocuments: processed,
            writtenDocuments: written,
            deletedDocuments: 0,
            duration: Date().timeIntervalSince(started),
            verification: verification,
            backup: backup.describedAs
        )
    }

    // MARK: - In place

    private func runInPlace(
        _ request: ReembeddingRequest,
        backup: BackupEvidence,
        sourceCount: Int,
        dimension: Int,
        chroma: ChromaClient,
        embeddings: EmbeddingProvider,
        chat: ChatProvider?,
        batchSize: Int,
        started: Date,
        resumeFromCheckpoint: Bool,
        progress: @escaping @Sendable (ReembeddingProgress) -> Void
    ) async throws -> ReembeddingReport {
        // Ids are collected up front and processed by id, not by offset: an
        // in-place run rewrites rows as it goes, and offsets would shift under it.
        progress(ReembeddingProgress(stage: String(localized: "Сбор списка документов"), total: sourceCount))
        var ids = try await allIDs(of: request.collection.id, chroma: chroma)
        /// Чем коллекция была занята до этого прогона — см. `freeingPieceIDs`.
        let takenBefore = Set(ids)

        let signature = request.rechunk ? request.chunking.signature : ""
        var done: Set<String> = []
        var runStamp = Self.newRunStamp()
        if resumeFromCheckpoint,
           let checkpoint = journal.checkpoint(for: request.collection.id),
           checkpoint.targetModel == request.targetModel,
           checkpoint.rechunk == request.rechunk,
           checkpoint.chunkingSignature == signature {
            done = Set(checkpoint.doneIDs)
            if let stamp = checkpoint.runStamp { runStamp = stamp }
            log(.info, "Re-embedding", "Продолжаем с контрольной точки: уже пересчитано \(done.count) из \(checkpoint.totalIDs)")
        }

        // Готовые документы — построчным списком рядом с точкой: сама точка
        // пишется один раз, а список только дописывается.
        journal.save(ReembeddingCheckpoint(
            collectionID: request.collection.id,
            collectionName: request.collection.name,
            targetModel: request.targetModel,
            chunkingSignature: signature,
            rechunk: request.rechunk,
            doneIDs: [],
            totalIDs: ids.count,
            startedAt: started,
            runStamp: runStamp
        ))
        journal.resetDone(Array(done), collectionID: request.collection.id)

        var written = 0

        // Пачками: документы пачки читаются одним запросом, векторы считаются
        // одним вызовом модели и пишутся одной правкой. По одному документу
        // это было три запроса на документ — триста тысяч на сто тысяч.
        func process(_ remaining: [String]) async throws {
            for start in stride(from: 0, to: remaining.count, by: max(1, batchSize)) {
                try await waitWhilePaused(processed: done.count, total: ids.count, written: written, progress: progress)
                // Точка уже на диске: готовое дописывается после каждой пачки,
                // и следующий запуск продолжит отсюда.
                try Task.checkCancellation()

                progress(ReembeddingProgress(
                    stage: String(localized: "Пересчёт на месте"),
                    processed: done.count, total: ids.count, written: written
                ))

                let chunkIDs = Array(remaining[start..<min(start + max(1, batchSize), remaining.count)])
                let documents = try await chroma.getDocuments(
                    collectionID: request.collection.id, limit: chunkIDs.count, ids: chunkIDs
                )

                if request.rechunk {
                    var records: [EmbeddedRecord] = []
                    for document in documents {
                        // Уже перенарезан этим прогоном — после последней
                        // дописанной пачки или как кусок `#k` другого документа.
                        // Резать его снова нельзя: это первый кусок, и его части
                        // затёрли бы соседние.
                        if case .string(let stamp)? = document.metadata?[CollectionBindingKeys.rechunkRun],
                           stamp == runStamp {
                            continue
                        }
                        records += try await pendingRecords(
                            of: document, request: request, embeddings: embeddings, chat: chat, runStamp: runStamp
                        )
                    }
                    records = try await freeingPieceIDs(
                        records, taken: takenBefore, runStamp: runStamp,
                        collectionID: request.collection.id, chroma: chroma
                    )
                    // Первый кусок сохраняет исходный идентификатор, так что
                    // удалять нечего: см. `pieceID`.
                    written += try await write(
                        records, into: request.collection.id, request: request, dimension: dimension,
                        embeddings: embeddings, chroma: chroma, batchSize: batchSize
                    )
                } else if !documents.isEmpty {
                    written += try await reembedInPlace(
                        documents, request: request, dimension: dimension, embeddings: embeddings, chroma: chroma
                    )
                }

                done.formUnion(chunkIDs)
                journal.appendDone(chunkIDs, collectionID: request.collection.id)
            }
        }

        try await process(ids.filter { !done.contains($0) })

        // Документы, появившиеся за время прогона. Запись снаружи на время
        // пересчёта закрыта, но не вся: прерванный прогон продолжают позже,
        // а между запусками синхронизация пишет в коллекцию старой моделью.
        // Список собран в начале, и всё, что легло после, осталось бы на
        // старых векторах — а привязка ниже объявит коллекцию новой. Круги
        // ограничены: коллекция, в которую пишут без остановки, — не повод
        // крутиться вечно, остаток покажет проверка.
        for _ in 0..<3 {
            let current = try await allIDs(of: request.collection.id, chroma: chroma)
            let known = Set(ids)
            let missed = current.filter { !done.contains($0) && !known.contains($0) }
            guard !missed.isEmpty else { break }
            log(.info, "Re-embedding", "За время прогона в коллекции появилось документов: \(missed.count) — пересчитываются")
            ids += missed
            try await process(missed)
        }

        // The collection now holds vectors of the new model, and its binding must
        // say so — otherwise the next write would be checked against the old one.
        //
        // Привязка — **до** того, как забыть контрольную точку: сорвись её
        // запись после, векторы были бы новой модели, привязка старой, а
        // продолжать было бы не с чего. С точкой на месте повторный запуск
        // пройдёт по готовому списку и допишет привязку.
        try await chroma.updateCollection(
            id: request.collection.id,
            metadata: request.collection.metadataBinding(
                model: request.targetModel, server: embeddings.server, dimension: dimension
            )
        )
        journal.clearCheckpoint(collectionID: request.collection.id)

        let verification = try await verify(
            request: request, resultCollectionID: request.collection.id, resultName: request.collection.name,
            sourceCount: sourceCount, dimension: dimension,
            chroma: chroma, embeddings: embeddings
        )

        return ReembeddingReport(
            scenario: .inPlace,
            sourceCollection: request.collection.name,
            resultCollection: request.collection.name,
            model: request.targetModel,
            dimension: dimension,
            processedDocuments: done.count,
            writtenDocuments: written,
            deletedDocuments: 0,
            duration: Date().timeIntervalSince(started),
            verification: verification,
            backup: backup.describedAs
        )
    }

    /// Все идентификаторы коллекции — по идентификатору, а не по смещению:
    /// пересчёт на месте переписывает строки, и смещения под ним плывут.
    private func allIDs(of collectionID: String, chroma: ChromaClient) async throws -> [String] {
        var ids: [String] = []
        var offset = 0
        while true {
            let page = try await chroma.getDocuments(collectionID: collectionID, limit: 200, offset: offset)
            if page.isEmpty { break }
            ids += page.map(\.id)
            if page.count < 200 { break }
            offset += 200
        }
        return ids
    }

    // MARK: - Document rewriting

    /// Куски одного документа, готовые к записи, — пока без векторов.
    private func pendingRecords(
        of document: DocumentRecord,
        request: ReembeddingRequest,
        embeddings: EmbeddingProvider,
        chat: ChatProvider?,
        runStamp: String
    ) async throws -> [EmbeddedRecord] {
        guard let text = document.document, !text.isEmpty else {
            throw ReembeddingError.documentWithoutText(document.id)
        }

        let pieces = try await pieces(of: text, request: request, embeddings: embeddings, chat: chat)
        // Метка прогона ставится **на все** куски, включая первый, который
        // сохраняет исходный идентификатор: по ней инспектор отличает текущие
        // куски от вытесненных прошлым прогоном, а продолжение —
        // уже перенарезанное этим. Удалять вытесненное здесь нельзя —
        // автоматических удалений в приложении нет (правило 1 приложения 5),
        // поэтому оно показывается человеку, а решает он.
        var records: [EmbeddedRecord] = []
        for (index, piece) in pieces.enumerated() {
            var metadata = document.metadata ?? [:]
            metadata[CollectionBindingKeys.model] = .string(request.targetModel)
            // Recomputing vectors does not change where the text came from; a
            // document that never had the field came from outside.
            metadata.carryOrigin(from: document.metadata)
            metadata[CollectionBindingKeys.rechunkedFrom] = .string(document.id)
            metadata[CollectionBindingKeys.rechunkRun] = .string(runStamp)
            if pieces.count > 1 {
                metadata["chunk_index"] = .int(index)
            }
            if let note = piece.note { metadata["_cdbm_chunk_note"] = .string(note) }
            // Мера шапки — от **этого** куска: унаследованная от исходного
            // документа срезала бы на швах текст, а не шапку.
            if let length = piece.repeatedHeaderLength {
                metadata[TableChunkHeaders.lengthKey] = length > 0 ? .int(length) : nil
            }
            records.append(EmbeddedRecord(
                id: Self.pieceID(original: document.id, index: index, total: pieces.count),
                document: piece.text,
                embedding: [],
                metadata: metadata
            ))
        }
        return records
    }

    /// Векторы и запись — пачками по `batchSize` кусков, какому бы документу
    /// они ни принадлежали.
    private func write(
        _ records: [EmbeddedRecord],
        into collectionID: String,
        request: ReembeddingRequest,
        dimension: Int,
        embeddings: EmbeddingProvider,
        chroma: ChromaClient,
        batchSize: Int
    ) async throws -> Int {
        var writtenCount = 0
        for start in stride(from: 0, to: records.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let slice = Array(records[start..<min(start + max(1, batchSize), records.count)])
            let vectors = try await embed(slice.map(\.document), model: request.targetModel, embeddings: embeddings)
            guard vectors.count == slice.count else { throw LMStudioError.emptyResponse }
            if let unexpected = vectors.first(where: { $0.count != dimension }) {
                throw BindingError.dimensionConflict(collection: collectionID, stored: dimension, model: unexpected.count)
            }
            let filled = zip(slice, vectors).map {
                EmbeddedRecord(id: $0.id, document: $0.document, embedding: $1, metadata: $0.metadata)
            }
            try await chroma.upsert(collectionID: collectionID, records: filled)
            writtenCount += filled.count
            // The batch is in the collection: safe to let someone else have the
            // model.
            await yieldPoint?()
        }
        return writtenCount
    }

    /// Пересчёт без перенарезки: новый вектор под тем же идентификатором,
    /// одним вызовом модели и одной правкой на пачку — `update` оставляет
    /// всё остальное в строке нетронутым.
    private func reembedInPlace(
        _ documents: [DocumentRecord],
        request: ReembeddingRequest,
        dimension: Int,
        embeddings: EmbeddingProvider,
        chroma: ChromaClient
    ) async throws -> Int {
        var texts: [String] = []
        for document in documents {
            guard let text = document.document, !text.isEmpty else {
                throw ReembeddingError.documentWithoutText(document.id)
            }
            texts.append(text)
        }
        let vectors = try await embed(texts, model: request.targetModel, embeddings: embeddings)
        guard vectors.count == documents.count else { throw LMStudioError.emptyResponse }
        if let unexpected = vectors.first(where: { $0.count != dimension }) {
            throw BindingError.dimensionConflict(collection: request.collection.id, stored: dimension, model: unexpected.count)
        }
        let updates = zip(documents, vectors).map { document, vector -> DocumentUpdate in
            var metadata = document.metadata ?? [:]
            metadata[CollectionBindingKeys.model] = .string(request.targetModel)
            // Recomputing vectors does not change where the text came from; a
            // document that never had the field came from outside.
            metadata.carryOrigin(from: document.metadata)
            return DocumentUpdate(id: document.id, embedding: vector, metadata: metadata)
        }
        try await chroma.updateDocuments(collectionID: request.collection.id, updates: updates)
        await yieldPoint?()
        return updates.count
    }

    private struct Piece {
        let text: String
        let note: String?
        /// Мера дописанной шапки нового куска; `nil` — текст
        /// документа не менялся, и его собственная мера остаётся.
        var repeatedHeaderLength: Int? = nil
    }

    private func pieces(
        of text: String,
        request: ReembeddingRequest,
        embeddings: EmbeddingProvider,
        chat: ChatProvider?
    ) async throws -> [Piece] {
        guard request.rechunk else { return [Piece(text: text, note: nil)] }

        let started = Date()
        let pipeline = ChunkingPipeline(
            configuration: request.chunking,
            embeddings: embeddings,
            chat: chat,
            embeddingModel: request.targetModel,
            log: log
        )
        let chunks = try await pipeline.chunks(from: text)
        await metrics?.recordChunking(
            strategy: request.chunking.strategy,
            characters: text.count,
            duration: Date().timeIntervalSince(started)
        )
        guard !chunks.isEmpty else { return [Piece(text: text, note: nil)] }
        return chunks.map { Piece(text: $0.text, note: $0.note, repeatedHeaderLength: $0.repeatedHeaderLength) }
    }

    private func embed(_ texts: [String], model: String, embeddings: EmbeddingProvider) async throws -> [[Double]] {
        // Единственное место, через которое сервис считает векторы, — и до сих
        // пор единственное, которое не спрашивало, влезает ли текст.
        //
        // Здесь это опаснее, чем где-либо: смена модели — ровно тот случай,
        // когда контекст становится **меньше** прежнего. Документы, которые
        // помещались в старую модель, молча обрезались бы новой, и коллекция
        // после «успешного» пересчёта искалась бы только по началам.
        //
        // Прогон останавливается, а не пропускает документ: сервис так и
        // устроен («refusing here beats failing halfway through the
        // collection» — про несовпадение размерностей), клон при обрыве
        // удаляется, и человек получает причину до того, как половина
        // коллекции пересчитана наполовину правильно.
        if let limit = targetContextLength {
            for text in texts {
                let verdict = ContextBudget.check(text, contextLength: limit)
                if case .tooLong(let tokens, _) = verdict {
                    throw ContextError.tooLong(estimatedTokens: tokens, limit: limit, model: model)
                }
            }
        }
        let started = Date()
        let vectors = try await embeddings.embed(texts: texts, model: model)
        await metrics?.recordEmbedding(
            model: model, server: embeddings.server, texts: texts.count, duration: Date().timeIntervalSince(started)
        )
        return vectors
    }

    /// Метка прогона перенарезки: одна на прогон, а не на документ —
    /// по ней продолжение узнаёт уже сделанное этим прогоном.
    static func newRunStamp() -> String {
        ISO8601DateFormatter().string(from: Date()) + "/" + UUID().uuidString.prefix(8)
    }

    /// Куски, чей идентификатор уже занят **другим** документом коллекции,
    /// получают свободный.
    ///
    /// Второй пересчёт с перенарезкой режет заново и первый кусок прошлого
    /// прогона: «d1» снова даёт «d1» и «d1#1» — а «d1#1» в коллекции уже
    /// есть, это второй кусок прошлого прогона, самостоятельный документ
    /// со своим текстом. Запись поверх стирала этот текст (а в одной пачке
    /// с ним — и вовсе давала два документа с одним id). Занятым считается
    /// то, что было в коллекции до прогона и записано не этим прогоном:
    /// свои куски, записанные до прерывания, продолжение переписывает
    /// на месте. Свободный идентификатор выводится из метки прогона —
    /// продолжение того же прогона получает те же.
    private func freeingPieceIDs(
        _ records: [EmbeddedRecord], taken: Set<String>, runStamp: String,
        collectionID: String, chroma: ChromaClient
    ) async throws -> [EmbeddedRecord] {
        let suspects = records.filter { record in
            guard taken.contains(record.id),
                  case .string(let parent)? = record.metadata[CollectionBindingKeys.rechunkedFrom] else { return false }
            return parent != record.id
        }.map(\.id)
        guard !suspects.isEmpty else { return records }
        let existing = try await chroma.getDocuments(
            collectionID: collectionID, limit: suspects.count, includeDocuments: false, ids: suspects
        )
        // Своё — кусок **этого же** документа, записанный **этим же** прогоном
        // до прерывания. Всё прочее чужое, в том числе прошлый кусок, который
        // этот прогон уже перенарезал как самостоятельный документ: у него
        // метка прогона та же, но родитель — он сам.
        let parents = Dictionary(records.compactMap { record -> (String, String)? in
            guard case .string(let parent)? = record.metadata[CollectionBindingKeys.rechunkedFrom] else { return nil }
            return (record.id, parent)
        }, uniquingKeysWith: { first, _ in first })
        let foreign = Set(existing.filter { document in
            guard case .string(let stamp)? = document.metadata?[CollectionBindingKeys.rechunkRun], stamp == runStamp,
                  case .string(let parent)? = document.metadata?[CollectionBindingKeys.rechunkedFrom],
                  parent == parents[document.id] else { return true }
            return false
        }.map(\.id))
        guard !foreign.isEmpty else { return records }
        let tag = Self.runTag(runStamp)
        return records.map { record in
            guard foreign.contains(record.id),
                  case .string(let parent)? = record.metadata[CollectionBindingKeys.rechunkedFrom],
                  let index = record.id.split(separator: "#").last.flatMap({ Int($0) }) else { return record }
            return EmbeddedRecord(
                id: "\(parent)#\(tag).\(index)", document: record.document,
                embedding: record.embedding, metadata: record.metadata
            )
        }
    }

    /// Короткая метка прогона для идентификатора куска.
    static func runTag(_ runStamp: String) -> String {
        SHA256.hash(data: Data(runStamp.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Ids of the pieces one document turns into. A single piece keeps the
    /// original id, so a plain re-embedding never renames anything.
    static func pieceID(original: String, index: Int, total: Int) -> String {
        (total <= 1 || index == 0) ? original : "\(original)#\(index)"
    }

    // MARK: - Pause and verification

    private func waitWhilePaused(
        processed: Int,
        total: Int,
        written: Int,
        progress: @escaping @Sendable (ReembeddingProgress) -> Void
    ) async throws {
        guard paused else { return }
        progress(ReembeddingProgress(
            stage: String(localized: "Пауза"),
            processed: processed, total: total, written: written, isPaused: true
        ))
        while paused {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Counts plus a real query: a collection that answers nothing is a failed
    /// re-embedding even if every write returned 200.
    private func verify(
        request: ReembeddingRequest,
        resultCollectionID: String,
        resultName: String,
        sourceCount: Int,
        dimension: Int,
        chroma: ChromaClient,
        embeddings: EmbeddingProvider
    ) async throws -> ReembeddingVerification {
        let resultCount = (try? await chroma.count(collectionID: resultCollectionID)) ?? 0
        var note: String?

        if !request.rechunk, resultCount != sourceCount {
            note = String(localized: "число документов изменилось, хотя чанкинг не менялся")
        }

        // The metric is as immutable as the vector size, so the copy having a
        // different one is worth saying out loud — the two collections would
        // rank the same query differently.
        if request.scenario == .clone,
           let expected = request.targetMetric ?? request.collection.space,
           let actual = (try? await chroma.collection(named: resultName))?.space,
           actual != expected {
            let mismatch = String(localized: "метрика клона \(actual.shortTitle) вместо \(expected.shortTitle)")
            note = note.map { "\($0); \(mismatch)" } ?? mismatch
        }

        var hit = false
        if let sample = try? await chroma.getDocuments(collectionID: resultCollectionID, limit: 1),
           let text = sample.first?.document,
           let vector = try? await embeddings.embed(texts: [text], model: request.targetModel).first {
            let hits = try? await chroma.query(collectionID: resultCollectionID, embedding: vector, nResults: 1)
            hit = !(hits ?? []).isEmpty
        }

        return ReembeddingVerification(
            sourceDocuments: sourceCount,
            resultDocuments: resultCount,
            dimension: dimension,
            queryReturnedHit: hit,
            note: note
        )
    }
}

/// Что стало с незавершённым клоном после отмены.
///
/// **Почему клон удаляется, а не остаётся с тем, что успело скопироваться.**
/// Наполовину скопированная коллекция неотличима от целой: то же имя, те же
/// метаданные, просто документов меньше, и ничто в ней об этом не говорит.
/// Найти её через месяц и молча получить подмножество — хуже, чем не иметь её
/// вовсе. Бэкап, снятый перед прогоном, остаётся на месте, так что терять
/// нечего, кроме потраченного времени модели.
public struct CloneCleanup: Sendable, Equatable {
    public let name: String
    public let removed: Bool
    /// Заполнено, когда удалить не вышло: тогда коллекция осталась в базе
    /// неполной, и сказать об этом обязательно.
    public let failure: String?

    public init(name: String, removed: Bool, failure: String?) {
        self.name = name
        self.removed = removed
        self.failure = failure
    }

    public var message: String {
        removed
            ? String(localized: "Операция отменена: незавершённый клон «\(name)» удалён.")
            : String(localized: "Операция отменена, но незавершённую коллекцию «\(name)» удалить не удалось — она осталась в базе неполной. Удалите её вручную. Причина: \(failure ?? "неизвестна")")
    }
}
