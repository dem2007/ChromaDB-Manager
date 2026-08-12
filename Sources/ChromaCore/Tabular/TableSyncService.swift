import Foundation

/// Everything the app remembers about one table file.
public struct TableFileManifest: Codable, Hashable, Sendable {
    public var relativePath: String
    public var collectionName: String
    /// Per sheet, keyed by sheet name.
    public var sheets: [String: SheetManifest]
    public var modifiedAt: Date
    public var size: Int64
    /// The source's profiles as they were when this file was written.
    ///
    /// Without it an untouched file would never be looked at again, and an
    /// edited profile would silently apply only to files that happened to
    /// change afterwards.
    public var profilesSignature: String

    public init(
        relativePath: String,
        collectionName: String,
        sheets: [String: SheetManifest] = [:],
        modifiedAt: Date = Date(),
        size: Int64 = 0,
        profilesSignature: String = ""
    ) {
        self.relativePath = relativePath
        self.collectionName = collectionName
        self.sheets = sheets
        self.modifiedAt = modifiedAt
        self.size = size
        self.profilesSignature = profilesSignature
    }

    public var rowCount: Int { sheets.values.reduce(0) { $0 + $1.rowCount } }
}

/// A sheet the run could not process, and why.
public struct SheetProblem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(relativePath)\u{0}\(sheetName)" }
    public var relativePath: String
    public var sheetName: String
    public var reason: String
    /// Set when a saved profile nearly fits — what the offer should point at.
    public var closestProfileID: UUID?

    public init(relativePath: String, sheetName: String, reason: String, closestProfileID: UUID? = nil) {
        self.relativePath = relativePath
        self.sheetName = sheetName
        self.reason = reason
        self.closestProfileID = closestProfileID
    }
}

/// What one table file's run did.
public struct TableSyncReport: Sendable {
    public var relativePath: String = ""
    public var sheetsIndexed: [String] = []
    public var sheetsSkipped: [String] = []
    public var rowsAdded: Int = 0
    public var rowsReembedded: Int = 0
    public var rowsMetadataOnly: Int = 0
    public var rowsUnchanged: Int = 0
    /// Rows gone from the file. **Never deleted here** — rule 1.
    public var disappeared: [TableRowRecord] = []
    public var problems: [SheetProblem] = []
    public var warnings: [String] = []
    /// Sheets whose mapping changed: a re-index, offered rather than performed.
    public var sheetsNeedingReindex: [String] = []

    public var rowsWritten: Int { rowsAdded + rowsReembedded + rowsMetadataOnly }

    public var line: String {
        String(localized: "листов \(sheetsIndexed.count), строк добавлено \(rowsAdded), переэмбедено \(rowsReembedded), метаданные \(rowsMetadataOnly), без изменений \(rowsUnchanged)")
    }
}

/// Indexes table files.
///
/// **A pipeline of its own, not a branch inside `SourceSyncService`.**'s
/// requirement is structural: a table is a set of records, and the moment its
/// handling lives inside the text pipeline somebody will «just add» a call that
/// flattens a sheet into prose. Keeping it apart makes that an obvious mistake
/// rather than a small edit.
public actor TableSyncService {
    private let log: LogHandler
    private let metrics: MetricsStore?

    public init(metrics: MetricsStore? = nil, log: @escaping LogHandler = noopLogHandler) {
        self.metrics = metrics
        self.log = log
    }

    /// What a run needs that this service does not own.
    public struct Context: Sendable {
        public var sourceID: UUID
        public var relativePath: String
        public var collectionID: String
        public var collectionName: String
        public var embeddingModel: String
        public var dimension: Int
        public var profiles: [TableProfile]
        /// Профиль, назначенный **этому файлу** вручную. `nil` — как
        /// раньше, подбором по набору колонок.
        public var assignedProfileID: UUID?
        /// Rows to process at most, for a trial run on a sample.
        public var rowLimit: Int?
        public var batchSize: Int
        /// Контекст модели эмбеддинга. `nil` — неизвестен: тогда только
        /// предупреждение, блокировать по догадке нельзя.
        ///
        /// Строка таблицы — такой же документ, как файл, и длины у неё такие же
        /// произвольные: одна ячейка с описанием на десять тысяч символов
        /// уходила в модель целиком и молча обрезалась.
        public var contextLength: Int?
        /// How a «документ»-mode sheet is cut once rendered to text.
        ///
        /// Injected rather than built here: the strategy, its sizes and its
        /// overlap belong to the source, and a table pipeline that decided them
        /// on its own would disagree with the rest of the app.
        public var chunker: (@Sendable (String) async throws -> [TextChunk])?

        public init(
            sourceID: UUID,
            relativePath: String,
            collectionID: String,
            collectionName: String,
            embeddingModel: String,
            dimension: Int,
            profiles: [TableProfile],
            assignedProfileID: UUID? = nil,
            rowLimit: Int? = nil,
            batchSize: Int = 32,
            contextLength: Int? = nil,
            chunker: (@Sendable (String) async throws -> [TextChunk])? = nil
        ) {
            self.contextLength = contextLength
            self.sourceID = sourceID
            self.relativePath = relativePath
            self.collectionID = collectionID
            self.collectionName = collectionName
            self.embeddingModel = embeddingModel
            self.dimension = dimension
            self.profiles = profiles
            self.assignedProfileID = assignedProfileID
            self.rowLimit = rowLimit
            self.batchSize = batchSize
            self.chunker = chunker
        }

        /// Назначенный профиль, если он ещё существует.
        ///
        /// Через поиск по списку, а не отдельным полем с самим профилем:
        /// назначение переживает удаление профиля, и «ссылается в пустоту»
        /// должно означать «подбором, как раньше», а не падение.
        public var assignedProfile: TableProfile? {
            assignedProfileID.flatMap { id in profiles.first { $0.id == id } }
        }
    }

    /// A stable fingerprint of a source's profiles, so a change to any of them
    /// makes every table file worth looking at again.
    public static func profilesSignature(_ profiles: [TableProfile]) -> String {
        profiles
            .flatMap { profile in
                profile.variants.map { "\(profile.name)\u{0}\($0.sheets.title)\u{0}\($0.mapping.signature)" }
            }
            .sorted()
            .joined(separator: "\u{1}")
    }

    // MARK: - Reading

    /// The sheets of a file, whatever kind of table it is.
    ///
    /// One entry point for every format so the rest of the pipeline never asks
    /// what it is reading.
    public static func read(
        url: URL,
        allowApplicationExport: Bool = false,
        limits: XLSXReader.Limits = XLSXReader.Limits()
    ) async throws -> (sheets: [(sheet: SheetInfo, rows: [SheetRow])], warnings: [XLSXWarning], temporary: URL?) {
        switch TabularFormat.of(url) {
        case .workbook:
            let reader = try XLSXReader(url: url)
            return (try Self.collect(reader.sheets) { try reader.rows(of: $0, limits: limits) }, [], nil)

        case .openDocument:
            let reader = try ODSReader(url: url)
            return (try Self.collect(reader.sheets) { try reader.rows(of: $0, limits: limits) }, [], nil)

        case .delimited:
            let (rows, _) = try DelimitedTableReader.rows(url: url)
            let sheet = SheetInfo(name: url.deletingPathExtension().lastPathComponent, isHidden: false, path: url.path)
            return ([(sheet, rows)], [], nil)

        // One branch for both: `.numbers` and `.xls` are read the same way —
        // the application that owns the format converts it to `.xlsx` and the
        // reader of 5.1 takes over.
        case .numbers, .legacyExcel:
            let (reader, temporary) = try await NumbersReader()
                .workbook(at: url, allowApplicationExport: allowApplicationExport)
            return (try Self.collect(reader.sheets) { try reader.rows(of: $0, limits: limits) }, [], temporary)

        case .legacyBinary:
            throw TabularError.legacyBinaryFormat(url.pathExtension.lowercased())

        case nil:
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }
    }

    private static func collect(
        _ sheets: [SheetInfo],
        _ read: (SheetInfo) throws -> (rows: [SheetRow], warnings: [XLSXWarning])
    ) rethrows -> [(sheet: SheetInfo, rows: [SheetRow])] {
        try sheets.map { ($0, try read($0).rows) }
    }

    // MARK: - Planning

    /// The plan for every sheet of a file, without writing anything.
    public func plan(
        sheets: [(sheet: SheetInfo, rows: [SheetRow])],
        manifest: TableFileManifest,
        context: Context
    ) -> (plans: [(sheet: String, mapping: TableMapping, plan: SheetSyncPlan)], problems: [SheetProblem]) {
        var plans: [(String, TableMapping, SheetSyncPlan)] = []
        var problems: [SheetProblem] = []

        for (index, entry) in sheets.enumerated() {
            let (shape, match) = TableSyncService.claim(
                sheet: entry.sheet, rows: entry.rows, index: index,
                profiles: context.profiles, assigned: context.assignedProfile
            )

            let mapping: TableMapping
            switch match {
            case .matched(_, let variant):
                mapping = variant.mapping
            case .ambiguous(let candidates):
                problems.append(SheetProblem(
                    relativePath: context.relativePath, sheetName: entry.sheet.name,
                    reason: String(localized: "листу подходит несколько профилей: \(candidates.map(\.name).joined(separator: ", ")) — выберите один")
                ))
                continue
            case .needsDecision(let reason, let closest, _, _):
                // A sheet nobody has mapped is not indexed «как получится»
                // — unless it is one the detector says to skip, which is
                // not a problem but an answer.
                if shape.mode == .skip { continue }
                problems.append(SheetProblem(
                    relativePath: context.relativePath, sheetName: entry.sheet.name,
                    reason: reason, closestProfileID: closest?.id
                ))
                continue
            }

            guard mapping.mode == .dataTable else { continue }

            // The sheet is read with the header the matcher matched — this
            // file's, in this file's order. The profile only says what the
            // columns mean.
            let layout = SheetLayout(shape: shape)
            let missing = layout.missing(from: mapping.columns)
            guard missing.isEmpty else {
                // Unreachable while matching is by header set, and checked all
                // the same: reading a column that is not there yields an empty
                // field, and an empty field is invisible until somebody's filter
                // returns nothing.
                problems.append(SheetProblem(
                    relativePath: context.relativePath, sheetName: entry.sheet.name,
                    reason: String(localized: "профиль ссылается на колонки, которых нет в файле: \(missing.joined(separator: ", "))")
                ))
                continue
            }

            var sheetPlan = TableSyncPlanner.plan(
                rows: entry.rows,
                mapping: mapping,
                layout: layout,
                manifest: manifest.sheets[entry.sheet.name] ?? SheetManifest(sheetName: entry.sheet.name),
                sourceID: context.sourceID,
                sourceFile: context.relativePath
            )
            if let limit = context.rowLimit { sheetPlan = sheetPlan.limitedToFirstRows(limit) }
            plans.append((entry.sheet.name, mapping, sheetPlan))
        }
        return (plans, problems)
    }

    // MARK: - Writing

    /// Writes one file's rows and returns what it did.
    ///
    /// Documents are written **before** anything is removed, and removal is only
    /// ever of a row's own previous document by explicit id. Rows that
    /// vanished from the file are reported, never deleted (rule 1).
    public func sync(
        sheets: [(sheet: SheetInfo, rows: [SheetRow])],
        manifest: inout TableFileManifest,
        context: Context,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> TableSyncReport {
        var report = TableSyncReport()
        report.relativePath = context.relativePath

        let (plans, problems) = plan(sheets: sheets, manifest: manifest, context: context)
        report.problems = problems
        report.sheetsSkipped = problems.map(\.sheetName)

        // a «документ» sheet is not a set of records. It is rendered to
        // text, cut by the source's own strategy, and — the part the section
        // calls compulsory — the header row is repeated in every chunk.
        for (index, entry) in sheets.enumerated() {
            // Отмена спрашивается на каждом листе, а не только внутри пакетов
            // записи. У книги, где почти всё не изменилось, до пакетов дело
            // может не дойти вовсе — и «Отменить» не действовало до конца
            // файла.
            try Task.checkCancellation()
            guard let claimed = mapping(for: entry, index: index, context: context),
                  claimed.mapping.mode == .document else { continue }
            let written = try await writeRendered(
                entry: entry, mapping: claimed.mapping, layout: claimed.layout, manifest: &manifest,
                context: context, chroma: chroma, embeddings: embeddings
            )
            report.sheetsIndexed.append(entry.sheet.name)
            report.rowsAdded += written.added
            report.rowsReembedded += written.reembedded
            report.rowsUnchanged += written.unchanged
        }

        let total = plans.reduce(0) { $0 + $1.plan.writes }
        var written = 0

        for (sheetName, mapping, sheetPlan) in plans {
            try Task.checkCancellation()
            if sheetPlan.mappingChanged {
                // a different recipe for every row is a re-index with a
                // backup, offered as its own operation. The sheet is left alone.
                report.sheetsNeedingReindex.append(sheetName)
                log(.warning, "Таблицы",
                    "Лист «\(sheetName)» файла \(context.relativePath): сопоставление изменилось — нужна переиндексация листа, автоматически ничего не пересчитывается")
                continue
            }

            var sheetManifest = manifest.sheets[sheetName] ?? SheetManifest(sheetName: sheetName)

            // Embedded work first: added and re-embedded rows.
            let embedding = sheetPlan.added.map { ($0, nil as String?) }
                + sheetPlan.reembedded.map { ($0.document, $0.previousID) }

            // Строка длиннее контекста модели уходила бы в неё целиком и молча
            // обрезалась — строка проиндексирована началом, по остальному
            // не находится никогда. Лист пропускается целиком
            // и называется в отчёте, как файл в синхронизации папок.
            if let oversized = embedding.first(where: {
                ContextBudget.check($0.0.text, contextLength: context.contextLength).blocksSending
            }) {
                let verdict = ContextBudget.check(oversized.0.text, contextLength: context.contextLength)
                let reason = String(localized: "строка \(oversized.0.id) длиннее контекста модели (≈\(TokenEstimator.estimatedTokens(oversized.0.text)) токенов): \(verdict.message ?? "")")
                report.problems.append(SheetProblem(
                    relativePath: context.relativePath, sheetName: sheetName, reason: reason
                ))
                report.sheetsSkipped.append(sheetName)
                log(.warning, "Таблицы", "Лист «\(sheetName)» файла \(context.relativePath) пропущен: \(reason)")
                continue
            }
            for batch in stride(from: 0, to: embedding.count, by: context.batchSize).map({
                Array(embedding[$0..<min($0 + context.batchSize, embedding.count)])
            }) {
                try Task.checkCancellation()
                try await write(batch, context: context, chroma: chroma, embeddings: embeddings)
                written += batch.count
                progress(written, total)
            }

            // Metadata-only rows need no vector at all: the text they carry is
            // unchanged, so the stored embedding still describes them.
            // Through `updateDocuments`, never through an upsert with an empty
            // vector — that would replace the embedding with nothing.
            if !sheetPlan.metadataOnly.isEmpty {
                let updates = sheetPlan.metadataOnly.map { document, _ in
                    DocumentUpdate(id: document.id, metadata: enriched(document.metadata, context: context))
                }
                try await chroma.updateDocuments(collectionID: context.collectionID, updates: updates)
                written += updates.count
                progress(written, total)
            }

            // Only now the previous document of a row whose identity changed —
            // after the new one is safely written.
            let superseded = (sheetPlan.reembedded + sheetPlan.metadataOnly)
                .filter { $0.previousID != $0.document.id }
                .map(\.previousID)
            if !superseded.isEmpty {
                try await chroma.deleteDocuments(collectionID: context.collectionID, ids: superseded)
            }

            sheetManifest = TableSyncPlanner.applying(sheetPlan, to: sheetManifest, mapping: mapping)
            manifest.sheets[sheetName] = sheetManifest

            report.sheetsIndexed.append(sheetName)
            report.rowsAdded += sheetPlan.added.count
            report.rowsReembedded += sheetPlan.reembedded.count
            report.rowsMetadataOnly += sheetPlan.metadataOnly.count
            report.rowsUnchanged += sheetPlan.unchanged
            report.disappeared += sheetPlan.disappeared
            if !sheetPlan.empty.isEmpty {
                report.warnings.append(String(localized: "лист «\(sheetName)»: строк без текста пропущено \(sheetPlan.empty.count)"))
            }
        }

        manifest.collectionName = context.collectionName
        manifest.profilesSignature = TableSyncService.profilesSignature(context.profiles)
        return report
    }

    private func write(
        _ batch: [(TableRowDocument, String?)],
        context: Context,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider
    ) async throws {
        let started = Date()
        let vectors = try await embeddings.embed(texts: batch.map(\.0.text), model: context.embeddingModel)
        await metrics?.recordEmbedding(
            model: context.embeddingModel,
            texts: batch.count,
            duration: Date().timeIntervalSince(started)
        )
        guard vectors.count == batch.count else { throw LMStudioError.emptyResponse }
        if let unexpected = vectors.first(where: { $0.count != context.dimension }) {
            throw BindingError.dimensionConflict(
                collection: context.collectionID, stored: context.dimension, model: unexpected.count
            )
        }

        let records = zip(batch, vectors).map { entry, vector in
            EmbeddedRecord(
                id: entry.0.id, document: entry.0.text, embedding: vector,
                metadata: enriched(entry.0.metadata, context: context)
            )
        }
        try await chroma.upsert(collectionID: context.collectionID, records: records)
    }

    /// The fields every document of a source carries, whatever produced it.
    private func enriched(_ metadata: ChromaMetadata, context: Context) -> ChromaMetadata {
        var result = metadata
        result["source_id"] = .string(context.sourceID.uuidString)
        result[DocumentOrigin.metadataKey] = .string(DocumentOrigin.source.rawValue)
        return result
    }
}

extension TableSyncService {
    /// The mapping a sheet would be read with and where its columns are in this
    /// file, or `nil` when nothing claims it.
    func mapping(
        for entry: (sheet: SheetInfo, rows: [SheetRow]),
        index: Int,
        context: Context
    ) -> (mapping: TableMapping, layout: SheetLayout)? {
        let (shape, match) = TableSyncService.claim(
            sheet: entry.sheet, rows: entry.rows, index: index,
            profiles: context.profiles, assigned: context.assignedProfile
        )
        guard let mapping = match.mapping else { return nil }
        return (mapping, SheetLayout(shape: shape))
    }

    /// Каким профилем читается лист и по какой шапке.
    ///
    /// Сначала — форма, найденная автоопределением: она остаётся главной, и
    /// файлы, где таблица начинается с первой строки, читаются ровно как
    /// раньше. Если под неё не подошёл ни один профиль, лист пробуют прочесть
    /// со строк заголовка, назначенных вручную в профилях этого источника.
    ///
    /// Без этого шага ручная строка заголовка живёт только в редакторе:
    /// профиль сохраняется, а при следующем запуске заголовок снова
    /// определяется сам, читает «Отчёт за март» и ни с чем не совпадает
    ///.
    ///
    /// Скрытые листы не перебираются: по они не индексируются вовсе,
    /// и подбор шапки не повод это обойти.
    ///
    /// Назначенный файлу профиль идёт первым и без подбора: человек
    /// уже ответил на вопрос, который подбор пытается угадать. Шапка при этом
    /// читается со строки, записанной в самом профиле, — иначе назначение
    /// работало бы только на файлах, где таблица начинается сверху.
    ///
    /// Что назначение **не** отменяет: если в листе нет колонок, которых
    /// профиль требует, лист уходит в «требуют решения» — эта проверка стоит
    /// дальше, в `plan`, и она про молча пропавшие метаданные, а не про то,
    /// кто выбрал профиль.
    static func claim(
        sheet: SheetInfo,
        rows: [SheetRow],
        index: Int,
        profiles: [TableProfile],
        assigned: TableProfile? = nil
    ) -> (shape: SheetShape, match: TableProfileMatch) {
        func matching(_ shape: SheetShape) -> TableProfileMatch {
            TableProfileMatcher.match(
                profiles: profiles, sheetName: sheet.name,
                sheetIndex: index, columns: shape.columns
            )
        }

        let auto = SheetModeDetector.suggest(rows: rows, isHidden: sheet.isHidden)

        // Назначенный профиль: берётся тот его вариант, который про этот лист.
        // Скрытые листы не индексируются и по назначению тоже.
        if let assigned, !sheet.isHidden {
            let admitting = assigned.variants.filter { $0.sheets.admits(sheetName: sheet.name, index: index) }
            // Сначала — вариант, чьи колонки сошлись с прочитанным листом;
            // если таких нет, первый подходящий по выбору листов: он и скажет,
            // с какой строки читать шапку.
            let byColumns = admitting.first { $0.headerSignature == TableProfile.signature(of: auto.columns) }
            if let variant = byColumns ?? admitting.first {
                let shape = variant.mapping.headerRow
                    .flatMap { SheetModeDetector.shape(rows: rows, headerRow: $0) } ?? auto
                return (shape, .matched(profile: assigned, variant: variant))
            }
        }

        let automatic = matching(auto)
        if automatic.profile != nil || sheet.isHidden { return (auto, automatic) }

        var tried: Set<Int> = auto.headerRow.map { [$0] } ?? []
        for row in profiles.flatMap(\.headerRows).sorted() where !tried.contains(row) {
            tried.insert(row)
            guard let shape = SheetModeDetector.shape(rows: rows, headerRow: row) else { continue }
            let match = matching(shape)
            if match.profile != nil { return (shape, match) }
        }
        // Ни одна шапка не подошла — рассказывается про автоопределение:
        // о нём человеку и думать, если он ещё не назначал строку сам.
        return (auto, automatic)
    }

    /// Writes a «документ»-mode sheet: rendered, chunked, header repeated.
    ///
    /// Chunks are identified by sheet and position, so re-running rewrites the
    /// same documents instead of accumulating copies. A chunk whose text has not
    /// moved is left alone — the same rule the rows follow.
    func writeRendered(
        entry: (sheet: SheetInfo, rows: [SheetRow]),
        mapping: TableMapping,
        layout: SheetLayout,
        manifest: inout TableFileManifest,
        context: Context,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider
    ) async throws -> (added: Int, reembedded: Int, unchanged: Int) {
        // This file's header row: the one repeated in every chunk must be the
        // one this file actually has.
        let rendered = SheetRenderer.render(rows: entry.rows, headerRow: layout.headerRow)
        guard !rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (0, 0, 0)
        }

        let raw = try await context.chunker?(rendered.text)
            ?? [TextChunk(index: 0, text: rendered.text)]
        let chunks = SheetRenderer.repeatingHeader(rendered.header, in: raw)

        var sheetManifest = manifest.sheets[entry.sheet.name] ?? SheetManifest(sheetName: entry.sheet.name)
        var added = 0, reembedded = 0, unchanged = 0
        var pending: [(TableRowDocument, String?)] = []
        var records: [String: TableRowRecord] = [:]

        for chunk in chunks {
            let id = RowMapper.identifier(
                sourceID: context.sourceID,
                sheetName: entry.sheet.name,
                key: "chunk-\(chunk.index)",
                rowContent: ""
            )
            var metadata: ChromaMetadata = [
                "source_file": .string(context.relativePath),
                "sheet_name": .string(entry.sheet.name),
                "table_mode": .string(SheetMode.document.rawValue),
                "chunk_index": .int(chunk.index),
                "chunk_estimated_tokens": .int(chunk.estimatedTokens),
            ]
            if let note = chunk.note { metadata["extraction_warnings"] = .string(note) }

            let document = TableRowDocument(id: id, text: chunk.text, metadata: metadata, rowKey: nil)
            let identity = TableRowRecord.identity(rowKey: "chunk-\(chunk.index)", rowNumber: chunk.index)
            let record = TableRowRecord(
                documentID: id, rowNumber: chunk.index, rowKey: "chunk-\(chunk.index)",
                textHash: TableSyncPlanner.hash(chunk.text),
                metadataHash: TableSyncPlanner.hash(TableSyncPlanner.metadataSeed(metadata))
            )
            records[identity] = record

            if let previous = sheetManifest.rows[identity], previous.textHash == record.textHash {
                unchanged += 1
                continue
            }
            if sheetManifest.rows[identity] == nil { added += 1 } else { reembedded += 1 }
            pending.append((document, nil))
        }

        for batch in stride(from: 0, to: pending.count, by: context.batchSize).map({
            Array(pending[$0..<min($0 + context.batchSize, pending.count)])
        }) {
            try Task.checkCancellation()
            try await write(batch, context: context, chroma: chroma, embeddings: embeddings)
        }

        // A sheet that got shorter leaves chunks nothing refers to; they go by
        // explicit id, after the new ones are written.
        let stale = sheetManifest.rows.filter { records[$0.key] == nil }.map(\.value.documentID)
        if !stale.isEmpty {
            try await chroma.deleteDocuments(collectionID: context.collectionID, ids: stale)
        }

        sheetManifest.rows = records
        sheetManifest.mappingSignature = mapping.signature
        manifest.sheets[entry.sheet.name] = sheetManifest
        return (added, reembedded, unchanged)
    }
}
