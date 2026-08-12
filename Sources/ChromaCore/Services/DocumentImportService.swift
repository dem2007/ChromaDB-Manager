import Foundation

public struct ImportProgress {
    public var stage: String
    public var processed: Int
    public var total: Int

    public var fraction: Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }

    public init(stage: String, processed: Int, total: Int) {
        self.stage = stage
        self.processed = processed
        self.total = total
    }
}

/// What an import does when a row's id is already in the collection.
///
/// The server does not decide this for us: `add` keeps the old document and
/// answers 201, `upsert` replaces it, and neither says a word. So the
/// choice is the user's, and «пропустить» is the default — it is the only
/// option that cannot destroy anything.
public enum DuplicatePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case skip
    case overwrite
    case abort

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skip: return String(localized: "пропустить дубли")
        case .overwrite: return String(localized: "перезаписать")
        case .abort: return String(localized: "прервать импорт")
        }
    }

    public var explanation: String {
        switch self {
        case .skip: return String(localized: "Строки с уже существующими ID не записываются; в отчёте будет их число.")
        case .overwrite: return String(localized: "Существующие документы заменяются: текст, вектор и метаданные — из файла.")
        case .abort: return String(localized: "Первый же существующий ID останавливает импорт; записанное до него остаётся.")
        }
    }
}

public struct ImportSummary {
    public let written: Int
    public let skippedEmpty: Int
    public let duration: TimeInterval
    public let model: String
    public let dimension: Int
    /// Rows left out because they were longer than the model's context.
    public let skippedTooLong: [String]
    /// Rows left out because their id was already in the collection.
    public let skippedDuplicates: [String]

    public init(
        written: Int,
        skippedEmpty: Int,
        duration: TimeInterval,
        model: String,
        dimension: Int,
        skippedTooLong: [String] = [],
        skippedDuplicates: [String] = []
    ) {
        self.written = written
        self.skippedEmpty = skippedEmpty
        self.duration = duration
        self.model = model
        self.dimension = dimension
        self.skippedTooLong = skippedTooLong
        self.skippedDuplicates = skippedDuplicates
    }
}

/// Writes prepared documents into a collection: one row is one document, with
/// its vector computed by the collection's model.
///
/// No chunking happens here — splitting text belongs to data sources (2C).
public final class DocumentImportService {
    private let log: LogHandler

    public init(log: @escaping LogHandler = noopLogHandler) {
        self.log = log
    }

    /// Writes the documents, optionally picking up where an earlier run stopped.
    ///
    /// `startingAt` is the number of documents already in the collection from a
    /// previous attempt. Re-embedding them would cost minutes and, for rows
    /// without an id column, would write them a second time under new ids — so
    /// a resumed import skips them entirely.
    public func importDocuments(
        _ documents: [PreparedDocument],
        skippedEmpty: Int = 0,
        into collection: ChromaCollection,
        model: String,
        chroma: ChromaClient,
        lmStudio: LMStudioClient,
        binding: ModelBindingService,
        batchSize: Int = 32,
        startingAt resumePoint: Int = 0,
        duplicates: DuplicatePolicy = .skip,
        /// Called between embedding batches so a more important task can take
        /// the model.
        yield: (@Sendable () async -> Void)? = nil,
        progress: @escaping (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        let started = Date()
        guard !documents.isEmpty else {
            throw ImportError.emptyFile
        }

        progress(ImportProgress(stage: String(localized: "Подготовка"), processed: 0, total: documents.count))

        // Fail before writing anything if the model does not fit the collection.
        let dimension = try await binding.dimension(of: model, lmStudio: lmStudio)
        try await binding.validate(vectorLength: dimension, for: collection)

        // A row longer than the model's context would be embedded from its
        // first pages only, with a 200 from LM Studio and nothing to notice
        //. One such row does not stop the import — it is skipped and
        // named, the way schema violations already are.
        let contextLength = await binding.contextLength(of: model, lmStudio: lmStudio)
        var oversized: [String] = []
        var duplicated: [String] = []

        // Two counters on purpose: `position` is where to continue from, and
        // it moves past skipped rows too; `written` is what actually went into
        // the collection. Conflating them would make a resumed import redo the
        // rows that were skipped.
        var position = min(max(0, resumePoint), documents.count)
        var written = position
        var index = position
        if position > 0 {
            log(.info, "Импорт", "Продолжение с документа \(position + 1) из \(documents.count)")
        }
        while index < documents.count {
            try Task.checkCancellation()

            var slice = Array(documents[index..<min(index + batchSize, documents.count)])
            let sliceStart = index
            slice = slice.enumerated().filter { offset, document in
                let verdict = ContextBudget.check(document.text, contextLength: contextLength)
                guard verdict.blocksSending else { return true }
                let name = document.id ?? String(localized: "строка \(sliceStart + offset + 1)")
                oversized.append(name)
                log(.warning, "Импорт", "Пропущен документ «\(name)»: \(verdict.message ?? "")")
                return false
            }.map(\.element)
            // Ids the user supplied and that are already taken. Rows without an
            // id get a fresh UUID and cannot collide.
            let named = slice.compactMap(\.id)
            if !named.isEmpty, duplicates != .overwrite {
                let taken = try await chroma.existingIDs(collectionID: collection.id, ids: named)
                if !taken.isEmpty {
                    if duplicates == .abort {
                        log(.warning, "Импорт", "Импорт остановлен: идентификатор «\(taken.sorted().first ?? "")» уже есть в коллекции")
                        throw ImportError.duplicateID(taken.sorted().first ?? "", written: position, total: documents.count)
                    }
                    duplicated.append(contentsOf: taken.sorted())
                    slice = slice.filter { document in
                        guard let id = document.id else { return true }
                        return !taken.contains(id)
                    }
                }
            }

            guard !slice.isEmpty else {
                index += batchSize
                position = min(index, documents.count)
                continue
            }
            // Progress counts rows handled, not rows written: a file whose
            // duplicates are being skipped still gets to the end, and a bar
            // that stops at 96 % looks like a hang.
            progress(ImportProgress(
                stage: String(localized: "Эмбеддинг и запись"),
                processed: position,
                total: documents.count
            ))

            do {
                let vectors = try await lmStudio.embed(texts: slice.map(\.text), model: model)
                guard vectors.count == slice.count else { throw LMStudioError.emptyResponse }
                if let odd = vectors.first(where: { $0.count != dimension }) {
                    throw BindingError.dimensionConflict(
                        collection: collection.name,
                        stored: dimension,
                        model: odd.count
                    )
                }

                let records = zip(slice, vectors).map { document, vector in
                    EmbeddedRecord(
                        id: document.id ?? UUID().uuidString,
                        document: document.text,
                        embedding: vector,
                        metadata: document.metadata
                    )
                }
                // Upsert either way: for «перезаписать» that is the point, and
                // for «пропустить» the colliding rows are already filtered out,
                // so the two agree on what lands.
                try await chroma.upsert(collectionID: collection.id, records: records)
                written += records.count
                position = min(index + batchSize, documents.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A partial write inside the batch counts too: those rows are in
                // the collection whether the batch finished or not.
                if case ChromaError.partialWrite(let failure) = error {
                    written += failure.written
                    position += failure.written
                }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log(.error, "Импорт", "Прервано на документе \(position + 1) из \(documents.count): \(reason)")
                throw ImportError.interrupted(written: position, total: documents.count, reason: reason)
            }
            index += batchSize
            // Between batches: the rows just written are in the collection and
            // the resume point is recorded, so stepping aside is safe.
            await yield?()
        }

        progress(ImportProgress(stage: String(localized: "Готово"), processed: position, total: documents.count))
        let summary = ImportSummary(
            written: written,
            skippedEmpty: skippedEmpty,
            duration: Date().timeIntervalSince(started),
            model: model,
            dimension: dimension,
            skippedTooLong: oversized,
            skippedDuplicates: duplicated
        )
        if !duplicated.isEmpty {
            log(.warning, "Импорт", "Пропущено строк с существующими идентификаторами: \(duplicated.count)")
        }
        if !oversized.isEmpty {
            log(.warning, "Импорт", "Не записано документов длиннее контекста модели: \(oversized.count) (\(oversized.prefix(5).joined(separator: ", ")))")
        }
        log(.success, "Импорт", "В коллекцию «\(collection.name)» записано документов: \(written), пропущено пустых: \(skippedEmpty), за \(String(format: "%.1f", summary.duration)) с")
        return summary
    }
}
