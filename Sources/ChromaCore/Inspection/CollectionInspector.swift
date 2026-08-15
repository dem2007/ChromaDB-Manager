import Foundation
import CryptoKit

/// То, что инспектору позволено делать с базой.
///
/// Протокол read-only **по построению**: методов записи в нём нет вовсе.
/// Это сильнее договорённости «инспектор ничего не меняет» — так его нельзя
/// заставить изменить данные, даже случайно.
public protocol InspectionReader: Sendable {
    func count(collectionID: String) async throws -> Int
    func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord]
    /// Именно эти документы, а не страница подряд. Нужен там, где текст
    /// требуется у горстки записей из десятков тысяч.
    func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord]
    func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]]
    func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit]
}

extension ChromaClient: InspectionReader {
    public func documents(collectionID: String, limit: Int, offset: Int) async throws -> [DocumentRecord] {
        try await getDocuments(collectionID: collectionID, limit: limit, offset: offset)
    }

    public func query(collectionID: String, embedding: [Double], nResults: Int) async throws -> [QueryHit] {
        try await query(collectionID: collectionID, embedding: embedding, nResults: nResults, filter: nil)
    }
}

/// Инспектор здоровья коллекции.
///
/// Только читает и сообщает. Ни одна проверка ничего не исправляет: каждая
/// находка сопровождается предлагаемым действием, а выполняет его человек
/// отдельно и с подтверждением — прямое продолжение запрета на автоматические
/// удаления (8.4).
public struct CollectionInspector: Sendable {
    /// Сколько документов читать за раз.
    static let pageSize = 500
    /// Сколько документов брать на проверку размерности: она «средняя» по цене,
    /// и вытягивать ради неё векторы всей коллекции незачем.
    static let dimensionProbe = 20

    private let reader: any InspectionReader
    private let validator = MetadataSchemaValidator()
    private let log: LogHandler

    public init(reader: any InspectionReader, log: @escaping LogHandler = noopLogHandler) {
        self.reader = reader
        self.log = log
    }

    public struct Context: Sendable {
        public var collection: ChromaCollection
        /// Источники, зарегистрированные в приложении: по ним отличается сирота
        /// от документа, добавленного руками.
        public var knownSourceIDs: Set<String>
        public var schema: MetadataSchema?
        /// Пары, которые человек уже посмотрел и признал не дублями.
        public var acknowledgedPairs: Set<String>

        public init(
            collection: ChromaCollection,
            knownSourceIDs: Set<String> = [],
            schema: MetadataSchema? = nil,
            acknowledgedPairs: Set<String> = []
        ) {
            self.collection = collection
            self.knownSourceIDs = knownSourceIDs
            self.schema = schema
            self.acknowledgedPairs = acknowledgedPairs
        }
    }

    public func inspect(
        context: Context,
        options: InspectionOptions = InspectionOptions(),
        progress: ((_ done: Int, _ total: Int, _ stage: String) -> Void)? = nil
    ) async throws -> InspectionReport {
        let started = Date()
        let collectionID = context.collection.id
        let total = (try? await reader.count(collectionID: collectionID)) ?? 0

        var findings: [InspectionFinding] = []
        var acknowledged = 0

        // Что копится при обходе страниц.
        var examined = 0
        /// Группа документов с одинаковым текстом: кто в неё входит, из каких
        /// файлов и как этот текст начинается. Без начала текста и
        /// файлов список дублей был перечнем идентификаторов, по которому
        /// нельзя понять, что именно повторилось.
        var byHash: [String: (ids: [String], files: [String], sample: String)] = [:]
        var chunkIndexes: [String: Set<Int>] = [:]
        /// Куски перенарезки по документу-родителю: идентификатор и метка
        /// прогона, который их записал.
        var rechunkPieces: [String: [(id: String, run: String?)]] = [:]
        /// Файлы, у чанков которых стоит пометка о подменённой стратегии.
        var substitutedChunking: [String: Set<String>] = [:]
        var firstIDs: [String] = []

        progress?(0, min(total, options.sampleSize), String(localized: "Чтение документов"))
        var offset = 0
        while examined < options.sampleSize {
            try Task.checkCancellation()
            let limit = min(Self.pageSize, options.sampleSize - examined)
            let page = try await reader.documents(collectionID: collectionID, limit: limit, offset: offset)
            guard !page.isEmpty else { break }
            offset += page.count
            examined += page.count

            for record in page {
                let text = record.document ?? ""
                let metadata = record.metadata ?? [:]

                // Куски перенарезки собираются по документу-родителю: какой
                // прогон их записал, определится после обхода — по метке
                // на самом родителе.
                // Пометка о подменённой стратегии — по файлам, а не
                // по чанкам: у одного файла их сотни, и сотня одинаковых
                // находок скрыла бы всё остальное.
                if case .string(let note)? = metadata["_cdbm_chunk_note"] {
                    var file = record.id
                    if case .string(let name)? = metadata["source_file"] { file = name }
                    substitutedChunking[file, default: []].insert(note)
                }

                if case .string(let parent)? = metadata[CollectionBindingKeys.rechunkedFrom] {
                    var run: String?
                    if case .string(let value)? = metadata[CollectionBindingKeys.rechunkRun] { run = value }
                    rechunkPieces[parent, default: []].append((id: record.id, run: run))
                }

                // Ни одного слова — своя находка, и **не** вместе с короткими
                //: такой чанк не молчит в выдаче, а лезет в неё
                // по любому запросу. Показывать сам текст здесь можно и нужно
                // — он в один-два знака и объясняет находку целиком.
                if !text.isEmpty, !ChunkHygiene.carriesMeaning(text) {
                    findings.append(InspectionFinding(
                        category: .wordlessChunks, documentIDs: [record.id],
                        subject: record.id,
                        detail: String(localized: "текст: «\(text.trimmingCharacters(in: .whitespacesAndNewlines))»")
                    ))
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).count < options.minimumTextLength {
                    findings.append(InspectionFinding(
                        category: .emptyDocuments, documentIDs: [record.id],
                        subject: record.id,
                        detail: String(localized: "знаков: \(text.count.plainDigits)")
                    ))
                }

                // Только пользовательские поля: служебные `_cdbm_*` и `origin`
                // приложение проставляет само, и документ, у которого нет
                // ничего, кроме них, метаданных всё равно не имеет.
                let meaningful = metadata.keys.filter { !$0.hasPrefix("_cdbm_") && $0 != DocumentOrigin.metadataKey }
                if meaningful.isEmpty {
                    findings.append(InspectionFinding(
                        category: .withoutMetadata, documentIDs: [record.id], subject: record.id
                    ))
                }

                if let schema = context.schema, !schema.isEmpty {
                    let result = validator.validate(metadata, against: schema, documentID: record.id)
                    for violation in result.violations {
                        findings.append(InspectionFinding(
                            category: .schemaViolations, documentIDs: [record.id],
                            subject: record.id, detail: violation.message
                        ))
                    }
                }

                if case .string(let sourceID)? = metadata["source_id"] {
                    if !context.knownSourceIDs.contains(sourceID) {
                        findings.append(InspectionFinding(
                            category: .orphanChunks, documentIDs: [record.id],
                            subject: record.id,
                            detail: String(localized: "источник \(sourceID) не зарегистрирован")
                        ))
                    }
                } else {
                    // Не дефект, а отдельная категория: помечать такие
                    // документы сиротами значило бы ругаться на каждую ручную
                    // запись.
                    findings.append(InspectionFinding(
                        category: .outsideSources, documentIDs: [record.id], subject: record.id
                    ))
                }

                if case .string(let file)? = metadata["source_file"],
                   case .int(let index)? = metadata["chunk_index"] {
                    chunkIndexes[file, default: []].insert(index)
                }

                let hash = Self.textHash(of: record)
                var group = byHash[hash] ?? (ids: [], files: [], sample: Self.opening(of: record.document))
                group.ids.append(record.id)
                if case .string(let file)? = metadata["source_file"], !group.files.contains(file) {
                    group.files.append(file)
                }
                byHash[hash] = group
                if firstIDs.count < options.nearDuplicateSampleSize { firstIDs.append(record.id) }
            }
            progress?(examined, min(total, options.sampleSize), String(localized: "Чтение документов"))
        }

        // Дубли по тексту — по тексту самого документа.
        //
        // Находка называется тем, что повторилось, а не списком
        // идентификаторов: по строке «1076f52700b2011a-192, 1e7e40b370e6939a-593»
        // нельзя было понять ни что за текст, ни откуда он взялся.
        // Файлы и идентификаторы остались, но после текста и в подробностях.
        for (_, group) in byHash where group.ids.count > 1 {
            let ids = group.ids.sorted()
            var parts = [String(localized: "документов \(ids.count.plainDigits)")]
            if !group.files.isEmpty {
                let shown = group.files.sorted().prefix(3).joined(separator: ", ")
                parts.append(group.files.count > 3
                    ? String(localized: "файлы: \(shown) и ещё \((group.files.count - 3).plainDigits)")
                    : String(localized: "файлы: \(shown)"))
            }
            parts.append(String(localized: "id: \(ids.prefix(4).joined(separator: ", "))"))
            findings.append(InspectionFinding(
                category: .duplicates, documentIDs: ids,
                subject: group.sample,
                detail: parts.joined(separator: " · ")
            ))
        }

        // Разрывы в нумерации: след прерванной синхронизации.
        for (file, indexes) in chunkIndexes.sorted(by: { $0.key < $1.key }) {
            guard let maximum = indexes.max() else { continue }
            let missing = (0...maximum).filter { !indexes.contains($0) }
            guard !missing.isEmpty else { continue }
            findings.append(InspectionFinding(
                category: .chunkGaps, documentIDs: [],
                subject: file,
                detail: String(localized: "нет чанков: \(missing.map(\.description).joined(separator: ", ")) из \((maximum + 1).plainDigits)")
            ))
        }

        for (file, notes) in substitutedChunking.sorted(by: { $0.key < $1.key }) {
            findings.append(InspectionFinding(
                category: .substitutedChunking, documentIDs: [],
                subject: file,
                detail: notes.sorted().joined(separator: "; ")
            ))
        }

        // Вытесненные куски перенарезки.
        //
        // Пересчёт на месте только дописывает — автоматических удалений
        // в приложении нет (правило 1 приложения 5). Прогон, нарезавший
        // документ на меньшее число кусков, чем предыдущий, оставляет хвост
        // со **старыми векторами**, и в выдачу тот попадает наравне
        // с текущими. Отличить его можно только по метке прогона.
        //
        // Текущей считается метка на самом родителе: первый кусок сохраняет
        // исходный идентификатор, поэтому он и есть свидетельство последнего
        // прогона. Если родителя в выборке нет, судить не по чему — и мы
        // молчим, а не гадаем: инспектор работает по выборке, и «не видели»
        // здесь не то же самое, что «нет».
        for (parent, pieces) in rechunkPieces.sorted(by: { $0.key < $1.key }) {
            guard let current = pieces.first(where: { $0.id == parent })?.run else { continue }
            let superseded = pieces.filter { $0.id != parent && $0.run != current }
            guard !superseded.isEmpty else { continue }
            let ids = superseded.map(\.id).sorted()
            findings.append(InspectionFinding(
                category: .supersededPieces, documentIDs: ids,
                subject: parent,
                detail: String(localized: "кусков от прошлой перенарезки: \(ids.count.plainDigits) · id: \(ids.prefix(4).joined(separator: ", "))")
            ))
        }

        findings.append(contentsOf: Self.bindingFindings(of: context.collection))

        // Размерность — проверка «средней» цены: векторы берутся у нескольких
        // документов, а не у всей коллекции.
        if let declared = context.collection.declaredDimension, !firstIDs.isEmpty {
            let probe = Array(firstIDs.prefix(Self.dimensionProbe))
            if let vectors = try? await reader.embeddings(collectionID: collectionID, ids: probe) {
                for (id, vector) in vectors.sorted(by: { $0.key < $1.key }) where vector.count != declared {
                    findings.append(InspectionFinding(
                        category: .dimensionMismatch, documentIDs: [id], subject: id,
                        detail: String(localized: "вектор длиной \(vector.count.plainDigits), а у коллекции записано \(declared.plainDigits)")
                    ))
                }
            }
        }

        var checkedNear = false
        if options.checksNearDuplicates, !firstIDs.isEmpty {
            checkedNear = true
            let (pairs, skipped) = try await nearDuplicates(
                ids: firstIDs, collectionID: collectionID, context: context,
                options: options, progress: progress
            )
            findings.append(contentsOf: pairs)
            acknowledged = skipped
        }

        let report = InspectionReport(
            collectionName: context.collection.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            examined: examined,
            total: max(total, examined),
            findings: findings,
            nearDuplicatesChecked: checkedNear,
            acknowledged: acknowledged
        )
        log(.info, "Инспектор", "Коллекция «\(context.collection.name)»: \(report.line)")
        return report
    }

    // MARK: - Похожие документы

    /// Полное попарное сравнение — O(n²) и на десяти тысячах документов
    /// нереалистично. Поэтому: свой вектор каждого документа → `query` с
    /// маленьким `n_results` → соседи ближе порога.
    ///
    /// **Векторы берутся из базы, эмбеддинг не выполняется ни разу** — иначе
    /// проверка стала бы дороже переиндексации.
    private func nearDuplicates(
        ids: [String],
        collectionID: String,
        context: Context,
        options: InspectionOptions,
        progress: ((_ done: Int, _ total: Int, _ stage: String) -> Void)?
    ) async throws -> ([InspectionFinding], Int) {
        var findings: [InspectionFinding] = []
        var seenPairs: Set<String> = []
        var skipped = 0
        var done = 0

        var index = 0
        while index < ids.count {
            try Task.checkCancellation()
            let slice = Array(ids[index..<min(index + Self.dimensionProbe * 5, ids.count)])
            index += slice.count
            let vectors = try await reader.embeddings(collectionID: collectionID, ids: slice)

            for id in slice {
                try Task.checkCancellation()
                guard let vector = vectors[id], !vector.isEmpty else { continue }
                let hits = try await reader.query(
                    collectionID: collectionID, embedding: vector, nResults: options.neighbours
                )
                for hit in hits {
                    guard hit.id != id, let distance = hit.distance, distance <= options.nearDuplicateDistance else { continue }
                    let key = Self.pairKey(id, hit.id)
                    guard seenPairs.insert(key).inserted else { continue }
                    guard !context.acknowledgedPairs.contains(key) else {
                        skipped += 1
                        continue
                    }
                    findings.append(InspectionFinding(
                        category: .nearDuplicates, documentIDs: [id, hit.id],
                        subject: key,
                        detail: String(localized: "расстояние \(String(format: "%.4f", distance))")
                    ))
                }
                done += 1
                if done % 50 == 0 {
                    progress?(done, ids.count, String(localized: "Поиск похожих документов"))
                }
            }
        }
        progress?(done, ids.count, String(localized: "Поиск похожих документов"))
        return (findings, skipped)
    }

    // MARK: - Мелочи

    /// Ключ пары — от порядка не зависит: «A и B» и «B и A» это одна находка.
    public static func pairKey(_ left: String, _ right: String) -> String {
        [left, right].sorted().joined(separator: " ↔ ")
    }

    static func bindingFindings(of collection: ChromaCollection) -> [InspectionFinding] {
        let metadata = collection.metadata ?? [:]
        var missing: [String] = []
        if metadata[CollectionBindingKeys.model] == nil { missing.append(String(localized: "модель")) }
        if metadata[CollectionBindingKeys.dimension] == nil { missing.append(String(localized: "размерность")) }
        if metadata[CollectionBindingKeys.space] == nil, metadata[CollectionBindingKeys.legacySpace] == nil {
            missing.append(String(localized: "метрика"))
        }
        guard !missing.isEmpty else { return [] }
        return [InspectionFinding(
            category: .collectionBindingMissing, documentIDs: [],
            subject: collection.name,
            detail: String(localized: "не записано: \(missing.joined(separator: ", "))")
        )]
    }

    /// Хэш **самого текста документа** — и только его.
    ///
    /// Соблазн взять готовый `content_hash` из метаданных был велик, и он
    /// оказался ловушкой: в этом приложении `content_hash` — хэш текста
    /// **файла целиком**, один на все его чанки. Дубли по нему превращают
    /// каждый многочанковый файл в находку: на живой коллекции это дало
    /// 241 ложное срабатывание, включая «одинаковый текст, документов 30»
    /// для файла из тридцати разных кусков.
    ///
    /// Два одинаковых файла найдутся и без него: у их чанков совпадут тексты.
    /// Начало текста одной строкой: по нему находку узнают в лицо.
    ///
    /// Переводы строк и повторные пробелы схлопываются — иначе первая строка
    /// в отчёте оказывается заголовком таблицы или пустотой, а не текстом.
    static func opening(of text: String?) -> String {
        let flat = (text ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !flat.isEmpty else { return String(localized: "(пустой текст)") }
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }

    static func textHash(of record: DocumentRecord) -> String {
        let text = (record.document ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

public extension ChromaCollection {
    /// Размерность, записанная у коллекции, если она там есть.
    var declaredDimension: Int? {
        guard case .int(let value)? = metadata?[CollectionBindingKeys.dimension] else { return nil }
        return value
    }
}
