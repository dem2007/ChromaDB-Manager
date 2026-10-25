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
    /// Подпись полей источника — уровней пути и своих полей, с
    /// которой файл записан.
    ///
    /// Поля файла стоят в каждой строке и куске листа, а обновление полей
    /// без пересчёта векторов ходит только по документам. Без этой
    /// подписи книга, у которой на диске ничего не менялось, после правки
    /// уровней пути оставалась бы с прежними значениями до следующего
    /// сохранения самой книги.
    public var metadataSignature: String
    /// Строки, которых больше нет в файле, — по листам.
    ///
    /// Ровно то же, что `pendingRemovals` у файлового манифеста, и по той же
    /// причине: удалять их приложение не вправе, а молчать о них — значит
    /// оставить в коллекции строки, которые продолжают находиться поиском.
    public var pendingRemovals: [String: SheetRowRemoval]
    /// Листы, очищенные под переиндексацию и ещё не записанные заново.
    ///
    /// Без этого признака состояние «строк в базе нет, и это мы их убрали»
    /// не хранилось нигде: лист исчезал из манифеста целиком, карточка
    /// с кнопкой пропадала вместе с ним (она показывается, пока строк
    /// больше нуля), и единственным следом оставалось сообщение на экране.
    /// Закрыли экран — следа нет, а пятисот строк в коллекции нет тоже,
    /// и поиск по ним честно отвечает «ничего не найдено».
    ///
    /// Снимается там же, где лист записывается заново, — прогоном
    /// синхронизации.
    public var sheetsAwaitingWrite: Set<String>

    public init(
        relativePath: String,
        collectionName: String,
        sheets: [String: SheetManifest] = [:],
        modifiedAt: Date = Date(),
        size: Int64 = 0,
        profilesSignature: String = "",
        metadataSignature: String = "",
        pendingRemovals: [String: SheetRowRemoval] = [:],
        sheetsAwaitingWrite: Set<String> = []
    ) {
        self.relativePath = relativePath
        self.collectionName = collectionName
        self.sheets = sheets
        self.modifiedAt = modifiedAt
        self.size = size
        self.profilesSignature = profilesSignature
        self.metadataSignature = metadataSignature
        self.pendingRemovals = pendingRemovals
        self.sheetsAwaitingWrite = sheetsAwaitingWrite
    }

    /// Манифест прошлых версий читается как есть: списка на решение в нём
    /// просто не было.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        collectionName = try container.decode(String.self, forKey: .collectionName)
        sheets = try container.decodeIfPresent([String: SheetManifest].self, forKey: .sheets) ?? [:]
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        profilesSignature = try container.decodeIfPresent(String.self, forKey: .profilesSignature) ?? ""
        // Записанный до подписи полей — как записанный другими полями: один
        // раз перечитывается.
        metadataSignature = try container.decodeIfPresent(String.self, forKey: .metadataSignature) ?? ""
        pendingRemovals = try container.decodeIfPresent([String: SheetRowRemoval].self, forKey: .pendingRemovals) ?? [:]
        // Манифест, записанный до появления признака, читается как «ничего
        // не ждёт»: там и очищать листы было нечем.
        sheetsAwaitingWrite = try container.decodeIfPresent(Set<String>.self, forKey: .sheetsAwaitingWrite) ?? []
    }

    public var rowCount: Int { sheets.values.reduce(0) { $0 + $1.rowCount } }

    /// Забыть лист перед переиндексацией.
    ///
    /// Возвращает идентификаторы документов, которые лист занимал: их
    /// вызывающий сначала кладёт в корзину, потом удаляет из коллекции.
    /// Сам манифест после этого не помнит о листе ничего, поэтому следующий
    /// прогон пишет **все** его строки заново — по новой разметке, а не
    /// упирается в «сопоставление изменилось».
    ///
    /// Подпись профилей файла тоже сбрасывается. Без этого файл, у которого
    /// на диске ничего не менялось, план объявил бы неизменившимся и не открыл
    /// бы вовсе: переиндексация прошла бы вхолостую, а лист остался бы пустым.
    ///
    /// Лист помечается ждущим записи: до следующего прогона его
    /// строк в коллекции нет, и человек должен видеть это, даже закрыв экран.
    public mutating func forgetSheet(_ sheetName: String) -> [String] {
        guard let sheet = sheets[sheetName] else { return [] }
        sheets[sheetName] = nil
        pendingRemovals[sheetName] = nil
        profilesSignature = ""
        sheetsAwaitingWrite.insert(sheetName)
        return sheet.documentIDs
    }

    /// Лист записан — ждать больше нечего.
    public mutating func noteSheetWritten(_ sheetName: String) {
        sheetsAwaitingWrite.remove(sheetName)
    }
}

/// Исчезнувшие строки одного листа, ждущие решения человека.
public struct SheetRowRemoval: Codable, Hashable, Sendable {
    public var rows: [TableRowRecord]
    /// Когда их хватились впервые. Не обновляется, пока строки не вернулись:
    /// «замечено вчера» — это про пропажу, а не про последний прогон.
    public var noticedAt: Date

    public init(rows: [TableRowRecord], noticedAt: Date = Date()) {
        self.rows = rows
        self.noticedAt = noticedAt
    }
}

/// Исчезнувшие строки одного листа — так, как их показывают человеку.
///
/// Собирается из манифеста при чтении: в файле хранится только то, что нельзя
/// вывести, а путь и коллекция там и так есть.
public struct PendingRowRemoval: Hashable, Sendable, Identifiable {
    public var id: String { "\(relativePath)\u{0}\(sheetName)" }
    public var relativePath: String
    public var sheetName: String
    public var collectionName: String
    public var rows: [TableRowRecord]
    public var noticedAt: Date

    public init(
        relativePath: String, sheetName: String, collectionName: String,
        rows: [TableRowRecord], noticedAt: Date
    ) {
        self.relativePath = relativePath
        self.sheetName = sheetName
        self.collectionName = collectionName
        self.rows = rows
        self.noticedAt = noticedAt
    }

    /// Чем строки названы человеку: ключом, если он есть, иначе номером.
    public var rowLabels: [String] {
        rows.map { record in
            if let key = record.rowKey, !key.isEmpty {
                return String(localized: "строка \(record.rowNumber.plainDigits) · \(key)")
            }
            return String(localized: "строка \(record.rowNumber.plainDigits)")
        }
    }
}

/// A sheet the run could not process, and why.
public struct SheetProblem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(relativePath)\u{0}\(sheetName)" }
    public var relativePath: String
    public var sheetName: String
    public var reason: String
    /// Set when a saved profile nearly fits — what the offer should point at.
    public var closestProfileID: UUID?
    /// Разряд для «Диагностики», если лист не про профиль. `nil` —
    /// листу нужен профиль: так у всех проблем, кроме строки длиннее
    /// контекста модели.
    public var remedy: FileRemedy?

    public init(
        relativePath: String, sheetName: String, reason: String,
        closestProfileID: UUID? = nil, remedy: FileRemedy? = nil
    ) {
        self.relativePath = relativePath
        self.sheetName = sheetName
        self.reason = reason
        self.closestProfileID = closestProfileID
        self.remedy = remedy
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
    /// Строки, которые дают тот же документ, что и строка выше:
    /// лист → группы повторов. Записана первая из каждой группы.
    public var duplicates: [(sheetName: String, groups: [DuplicateRowGroup])] = []
    /// Sheets whose mapping changed: a re-index, offered rather than performed.
    public var sheetsNeedingReindex: [String] = []
    /// Листы книги, которые не размечены ни одним профилем.
    ///
    /// Раньше они пропускались молча, и это стоило дорого: у книги на
    /// четырнадцать листов размечены были пять, в базу попали 73 строки из
    /// полутора тысяч, а лист с ценами не попал вовсе. Ни человек, ни агент
    /// об этом не знали — выдача выглядела полной.
    public var sheetsWithoutMapping: [String] = []

    public var rowsWritten: Int { rowsAdded + rowsReembedded + rowsMetadataOnly }

    public var line: String {
        var text = String(localized: "листов \(sheetsIndexed.count), строк добавлено \(rowsAdded), переэмбедено \(rowsReembedded), метаданные \(rowsMetadataOnly), без изменений \(rowsUnchanged)")
        if !sheetsWithoutMapping.isEmpty {
            text += String(localized: "; листов без разметки \(sheetsWithoutMapping.count) — их строки в базу не попали: \(sheetsWithoutMapping.prefix(5).joined(separator: ", "))")
        }
        return text
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
        /// Размер куска в знаках — тот же, по которому режет `chunker`
        ///: шапка листа дописывается к кускам после нарезки и обязана
        /// уложиться в тот же размер, а не вылезти за него.
        public var chunkLimit: (@Sendable (TextChunk) -> Int?)?
        /// Сколько документов записала очередная партия: табличный
        /// файл пишется минутами, и счётчик хода без этого стоял, пока не
        /// запишется весь файл, — экран выглядел зависшим.
        public var onBatchWritten: (@Sendable (Int) -> Void)?
        /// Лист, под который не подошёл ни один профиль, записывается
        /// текстом — режимом «Документ», — а не пропадает.
        public var unmatchedSheetsAsText: Bool
        /// Поля файла, которые несёт каждый документ источника:
        /// `file_name`, `file_id`, уровни пути, свои поля источника. Без них
        /// лист книги не попадал под фильтр «ведомство», «год», «тип
        /// документа», а в выдаче у него не было имени файла.
        public var documentMetadata: ChromaMetadata
        /// Подпись настроек, из которых `documentMetadata` собраны
        /// (`DataSource.metadataSignature`): запоминается в манифесте файла.
        public var metadataSignature: String

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
            chunker: (@Sendable (String) async throws -> [TextChunk])? = nil,
            chunkLimit: (@Sendable (TextChunk) -> Int?)? = nil,
            onBatchWritten: (@Sendable (Int) -> Void)? = nil,
            unmatchedSheetsAsText: Bool = false,
            documentMetadata: ChromaMetadata = [:],
            metadataSignature: String = ""
        ) {
            self.documentMetadata = documentMetadata
            self.metadataSignature = metadataSignature
            self.chunkLimit = chunkLimit
            self.onBatchWritten = onBatchWritten
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
            self.unmatchedSheetsAsText = unmatchedSheetsAsText
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
    public static func profilesSignature(_ profiles: [TableProfile], unmatchedSheetsAsText: Bool = false) -> String {
        // Схема идентификаторов строк — тоже рецепт: когда она меняется, каждый
        // табличный файл обязан быть перечитан один раз, иначе неизменившиеся
        // книги остались бы под прежними (сталкивавшимися) id навсегда.
        // Запись неразмеченных листов текстом — тоже: включили —
        // книги, где такие листы есть, должны быть прочитаны снова.
        "ids:\(Self.rowIdentityScheme)\u{1}render:\(SheetRenderer.version)\u{1}" + (unmatchedSheetsAsText ? "unmatched:text\u{1}" : "") + profiles
            .flatMap { profile in
                profile.variants.map { "\(profile.name)\u{0}\($0.sheets.title)\u{0}\($0.mapping.signature)" }
            }
            .sorted()
            .joined(separator: "\u{1}")
    }

    /// Версия схемы идентификаторов строк. Вторая — с файлом и настоящим
    /// листом в идентификаторе; третья — объединения разложены и вбок
    ///: строки с такими ячейками читаются иначе, и неизменившиеся
    /// книги обязаны быть перечитаны, чтобы правило дошло и до них.
    static let rowIdentityScheme = 3

    // MARK: - Reading

    /// The sheets of a file, whatever kind of table it is.
    ///
    /// One entry point for every format so the rest of the pipeline never asks
    /// what it is reading.
    public static func read(
        url: URL,
        allowApplicationExport: Bool = false,
        limits: XLSXReader.Limits = XLSXReader.Limits()
    ) async throws -> (sheets: [(sheet: SheetInfo, rows: [SheetRow])], warnings: [String], temporary: URL?) {
        switch TabularFormat.of(url) {
        case .workbook:
            let reader = try XLSXReader(url: url)
            let read = try Self.collect(reader.sheets) { try reader.rowsAndMerges(of: $0, limits: limits) }
            return (read.sheets, read.warnings, nil)

        case .openDocument:
            let reader = try ODSReader(url: url)
            let read = try Self.collect(reader.sheets) { try reader.rowsAndMerges(of: $0, limits: limits) }
            return (read.sheets, read.warnings, nil)

        case .delimited:
            let (rows, _) = try DelimitedTableReader.rows(url: url)
            let sheet = SheetInfo(name: url.deletingPathExtension().lastPathComponent, isHidden: false, path: url.path)
            return ([(sheet, rows)], [], nil)

        // Старая книга — своей читалкой: формат тот же контейнер OLE2,
        // что и у `.doc`, и просить чужую программу открыть его больше незачем.
        // Numbers остаётся запасным путём — для книг Excel 5.0 и старше,
        // у которых внутри другой поток.
        case .legacyExcel:
            if let reader = try? XLSReader(url: url) {
                let read = try Self.collect(reader.sheets) {
                    try reader.rowsAndMerges(of: $0, limits: XLSReader.Limits(maxRows: limits.maxRows))
                }
                return (read.sheets, read.warnings, nil)
            }
            let (reader, temporary) = try await NumbersReader()
                .workbook(at: url, allowApplicationExport: allowApplicationExport)
            let read = try Self.readExported(reader, temporary: temporary, limits: limits)
            return (read.sheets, read.warnings, temporary)

        // `.numbers` читается только так: формат закрыт, и открывает его
        // приложение, которому он принадлежит.
        case .numbers:
            let (reader, temporary) = try await NumbersReader()
                .workbook(at: url, allowApplicationExport: allowApplicationExport)
            let read = try Self.readExported(reader, temporary: temporary, limits: limits)
            return (read.sheets, read.warnings, temporary)

        case .legacyBinary:
            throw TabularError.legacyBinaryFormat(url.pathExtension.lowercased())

        case nil:
            throw ExtractionError.unsupportedFormat(url.pathExtension)
        }
    }

    /// Листы книги, выгруженной из Numbers во временный `.xlsx`.
    ///
    /// Временный файл убирает вызывающий — но только если путь до него
    /// дошёл. Сбой разбора бросал ошибку раньше, и файл оставался в папке
    /// временных файлов навсегда; здесь он убирается и в этом случае.
    private static func readExported(
        _ reader: XLSXReader, temporary: URL, limits: XLSXReader.Limits
    ) throws -> (sheets: [(sheet: SheetInfo, rows: [SheetRow])], warnings: [String]) {
        do {
            return try collect(reader.sheets) { try reader.rowsAndMerges(of: $0, limits: limits) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// - Parameter merges: объединённые ячейки листа; листу они
    ///   записываются в `SheetInfo.merges`.
    /// Листы с их строками; объединения — тем же чтением, что и строки
    ///: отдельный проход ради них перечитывал XML листа, а у ODS —
    /// весь `content.xml` на каждый лист.
    ///
    /// Оговорки читалки — с именем листа. Раньше они терялись
    /// здесь же: лист, обрезанный пределом строк, и формулы без значения
    /// проходили молча.
    private static func collect(
        _ sheets: [SheetInfo],
        _ read: (SheetInfo) throws -> (rows: [SheetRow], warnings: [XLSXWarning], merges: [XLSXReader.MergedRange])
    ) rethrows -> (sheets: [(sheet: SheetInfo, rows: [SheetRow])], warnings: [String]) {
        var warnings: [String] = []
        let result = try sheets.map { sheet in
            let found = try read(sheet)
            var info = sheet
            info.merges = found.merges
            warnings += found.warnings.map { String(localized: "лист «\(sheet.name)»: \($0.text)") }
            return (info, found.rows)
        }
        return (result, warnings)
    }

    // MARK: - Planning

    /// The plan for every sheet of a file, without writing anything.
    public func plan(
        sheets: [(sheet: SheetInfo, rows: [SheetRow])],
        manifest: TableFileManifest,
        context: Context
    ) -> (
        plans: [(sheet: String, mapping: TableMapping, plan: SheetSyncPlan)],
        problems: [SheetProblem],
        warnings: [String],
        coverage: SheetCoverage
    ) {
        var plans: [(String, TableMapping, SheetSyncPlan)] = []
        var problems: [SheetProblem] = []
        /// Листы, разобранные назначенным профилем с оговорками.
        var looseMatches: [String] = []

        // Первым проходом — сколько листов книги вообще размечено.
        // Знать это надо **до** записи первой же строки: покрытие уходит
        // в метаданные каждой строки, и посчитать его после было бы поздно.
        // Разметка спрашивается здесь один раз и переиспользуется ниже.
        let claims = sheets.enumerated().map { index, entry in
            TableSyncService.claim(
                sheet: entry.sheet, rows: entry.rows, index: index,
                profiles: context.profiles, assigned: context.assignedProfile
            )
        }
        // Пустой или скрытый лист, которому никто не назначил разметку,
        // пропускается по правилу, а не по недосмотру, — и в счёт «сколько
        // листов книги в базе» он не входит. Иначе каждая строка обычной
        // книги с пустым «Лист2» сообщала агенту, что книга неполная.
        let skipped = Set(zip(sheets, claims).compactMap { entry, claim in
            claim.match.mapping == nil && claim.shape.mode == .skip ? entry.sheet.name : nil
        })
        let fallbacks = zip(sheets, claims).map { entry, claim in
            TableSyncService.textFallback(
                sheet: entry.sheet, shape: claim.shape, match: claim.match, allowed: context.unmatchedSheetsAsText
            )
        }
        let coverage = SheetCoverage(
            indexed: zip(claims, fallbacks).filter { $0.match.mapping != nil || $1 != nil }.count,
            total: sheets.count - skipped.count,
            skipped: skipped
        )

        for (index, entry) in sheets.enumerated() {
            let (shape, match) = claims[index]
            // Лист без подходящего профиля записывается текстом —
            // в документном проходе; здесь только оговорка: записей
            // с колонками у него не будет.
            if let reason = fallbacks[index] {
                looseMatches.append(String(localized: "\(entry.sheet.name): \(reason) — записан текстом (режим «Документ»): фильтров по колонкам у него нет; чтобы строки стали записями, сохраните подходящий листу профиль и переиндексируйте лист на экране «Таблицы»"))
                continue
            }

            var mapping: TableMapping
            switch match {
            case .matched(_, let variant):
                mapping = variant.mapping
                // Лист — этот, а не тот, на котором профиль размечали: от
                // него зависят и `sheet_name` строки, и её идентификатор.
                mapping.sheetName = entry.sheet.name
                // Совпало не точно — сказать об этом. Недостающая колонка
                // метаданных не мешает разобрать строку, но фильтра по ней
                // у этих записей не будет, и узнавать об этом по пустой
                // выдаче через месяц — худший из способов.
                let acceptance = variant.accepts(columns: shape.columns, strict: false)
                //
                // Предупреждением, а не «проблемой»: лист разобран и записан,
                // а `problems` попадают в «пропущенные» — сказать про
                // проиндексированный лист, что он пропущен, было бы враньём.
                if acceptance.matches, !acceptance.exact, !acceptance.missing.isEmpty {
                    looseMatches.append(String(localized: "\(entry.sheet.name): в файле нет колонок \(acceptance.missing.joined(separator: ", ")) — метаданных по ним не будет"))
                }
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
            // Проверяются только текст и ключ — ровно то, что требует подбор
            // (`requiredColumns`). Назначенный профиль принимает лист и без
            // части колонок метаданных, о чём выше сказано предупреждением;
            // проверка всех колонок профиля отбрасывала такой лист следом,
            // и послабление не работало ни разу. Недостающие метаданные
            // `RowMapper` просто не пишет.
            let required = mapping.textColumns + (mapping.keyColumn.map { [$0] } ?? [])
            let missing = layout.missing(from: required)
            guard missing.isEmpty else {
                // Unreachable while matching demands the same columns, and
                // checked all the same: reading a text or key column that is
                // not there yields an empty document or a wrong identity.
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
                sourceFile: context.relativePath,
                coverage: coverage,
                sheetIndex: index,
                merges: entry.sheet.merges,
                shared: context.documentMetadata
            )
            if let limit = context.rowLimit { sheetPlan = sheetPlan.limitedToFirstRows(limit) }
            plans.append((entry.sheet.name, mapping, sheetPlan))
        }
        return (plans, problems, looseMatches, coverage)
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
        embeddings: EmbeddingProvider
    ) async throws -> TableSyncReport {
        var report = TableSyncReport()
        report.relativePath = context.relativePath

        let (plans, problems, looseMatches, coverage) = plan(sheets: sheets, manifest: manifest, context: context)
        report.problems = problems
        report.sheetsSkipped = problems.map(\.sheetName)
        report.warnings.append(contentsOf: looseMatches)

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
            // Та же граница, что у строк: сменилась разметка — это
            // переиндексация с копией, предложенная отдельно. Раньше лист,
            // переведённый в «документ», молча стирал все свои строки по id
            // и писал куски на их место — без корзины и без вопроса.
            if let previous = manifest.sheets[entry.sheet.name]?.mappingSignature,
               !previous.isEmpty, previous != claimed.mapping.signature {
                report.sheetsNeedingReindex.append(entry.sheet.name)
                log(.warning, "Таблицы",
                    "Лист «\(entry.sheet.name)» файла \(context.relativePath): сопоставление изменилось — нужна переиндексация листа (экран «Таблицы», кнопка «Переиндексировать лист»), автоматически ничего не пересчитывается")
                continue
            }
            // Пробный прогон на выборке строк лист-документ целиком
            // не пишет: выборка существует ровно затем, чтобы не платить за всё.
            if context.rowLimit != nil {
                report.warnings.append(String(localized: "лист «\(entry.sheet.name)» разбирается как документ — в пробный прогон на выборке строк он не входит"))
                report.sheetsSkipped.append(entry.sheet.name)
                continue
            }
            let written: (added: Int, reembedded: Int, unchanged: Int, split: Int)
            do {
                written = try await writeRendered(
                    entry: entry, mapping: claimed.mapping, layout: claimed.layout, manifest: &manifest,
                    context: context, chroma: chroma, embeddings: embeddings, coverage: coverage,
                    sheetIndex: index
                )
            } catch let unsendable as UnsendableSheet {
                // Тем же правилом, что пустой чанк файла: в отчёт и «требуют
                // решения», а не молча.
                report.problems.append(SheetProblem(
                    relativePath: context.relativePath, sheetName: entry.sheet.name,
                    reason: unsendable.reason, remedy: .retry
                ))
                report.sheetsSkipped.append(entry.sheet.name)
                log(.warning, "Таблицы", "Лист «\(entry.sheet.name)» файла \(context.relativePath) пропущен: \(unsendable.reason)")
                continue
            }
            if written.split > 0 {
                // Как у файлов: нарезка подвинулась — это видно в сводке.
                report.warnings.append(String(localized: "лист «\(entry.sheet.name)»: кусков, не влезавших в контекст модели, дорезано по предложениям: \(written.split)"))
                log(.warning, "Таблицы",
                    "Лист «\(entry.sheet.name)» файла \(context.relativePath): кусков, не влезавших в контекст модели, дорезано по предложениям: \(written.split.plainDigits). Уменьшите размер чанка, если это повторяется.")
            }
            report.sheetsIndexed.append(entry.sheet.name)
            // Лист записан — ждать его больше нечего.
            manifest.noteSheetWritten(entry.sheet.name)
            report.rowsAdded += written.added
            report.rowsReembedded += written.reembedded
            report.rowsUnchanged += written.unchanged
        }

        for (sheetName, mapping, sheetPlan) in plans {
            try Task.checkCancellation()
            if sheetPlan.mappingChanged {
                // a different recipe for every row is a re-index with a
                // backup, offered as its own operation. The sheet is left alone.
                report.sheetsNeedingReindex.append(sheetName)
                log(.warning, "Таблицы",
                    "Лист «\(sheetName)» файла \(context.relativePath): сопоставление изменилось — нужна переиндексация листа (экран «Таблицы», кнопка «Переиндексировать лист»), автоматически ничего не пересчитывается")
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
                    relativePath: context.relativePath, sheetName: sheetName, reason: reason, remedy: .retry
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
            }

            // Metadata-only rows need no vector at all: the text they carry is
            // unchanged, so the stored embedding still describes them.
            // Through `updateDocuments`, never through an upsert with an empty
            // vector — that would replace the embedding with nothing.
            //
            // Две оговорки, обе про то, что `update` у ChromaDB умеет и чего нет.
            //
            // Метаданные он **сливает**: ключ, которого у строки больше нет
            // (очищенная ячейка, пометка о неполной книге), остался бы в базе
            // навсегда — а манифест запомнил бы новый хеш и не вернулся к нему.
            // Поэтому замена целиком, с явным снятием исчезнувших ключей.
            //
            // И записей он **не создаёт**. У листа без колонки-ключа
            // идентификатор строки считается от её значений, и правка одной
            // лишь цены меняет его: `update` по новому идентификатору молча
            // не делал ничего, прежний документ удалялся ниже как заменённый,
            // и строка пропадала из коллекции насовсем. Такая строка
            // переезжает под новый идентификатор со своим прежним вектором —
            // текст тот же, считать его заново незачем.
            if !sheetPlan.metadataOnly.isEmpty {
                let previousIDs = sheetPlan.metadataOnly.map(\.previousID)
                let storedRecords = Dictionary(
                    try await chroma.documents(collectionID: context.collectionID, ids: previousIDs)
                        .map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let stored = storedRecords.mapValues(\.metadata)
                let movedIDs = sheetPlan.metadataOnly.filter { $0.previousID != $0.document.id }.map(\.previousID)
                let vectors = movedIDs.isEmpty
                    ? [:]
                    : try await chroma.embeddings(collectionID: context.collectionID, ids: movedIDs)

                var updates: [DocumentUpdate] = []
                var moved: [EmbeddedRecord] = []
                var reembed: [(TableRowDocument, String?)] = []
                for (document, previousID) in sheetPlan.metadataOnly {
                    let metadata = enriched(document.metadata, context: context)
                    if previousID == document.id {
                        updates.append(.replacingMetadata(
                            id: document.id, metadata: metadata, previous: stored[previousID] ?? nil
                        ))
                    } else if let vector = vectors[previousID], !vector.isEmpty,
                              storedRecords[previousID]?.document == document.text {
                        // Вектор переезжает, только если под прежним id лежит
                        // **этот** текст. Под id, который прежде делили строки
                        // разных файлов, лежит текст того, кто записался
                        // последним, — и его вектор чужой.
                        moved.append(EmbeddedRecord(
                            id: document.id, document: document.text, embedding: vector, metadata: metadata
                        ))
                    } else {
                        // Прежнего вектора нет — строка считается заново.
                        reembed.append((document, previousID))
                    }
                }
                if !updates.isEmpty {
                    try await chroma.updateDocuments(collectionID: context.collectionID, updates: updates)
                }
                if !moved.isEmpty {
                    try await chroma.upsert(collectionID: context.collectionID, records: moved)
                }
                for batch in stride(from: 0, to: reembed.count, by: context.batchSize).map({
                    Array(reembed[$0..<min($0 + context.batchSize, reembed.count)])
                }) {
                    try Task.checkCancellation()
                    try await write(batch, context: context, chroma: chroma, embeddings: embeddings)
                }
            }

            // Only now the previous document of a row whose identity changed —
            // after the new one is safely written.
            let updated = TableSyncPlanner.applying(sheetPlan, to: sheetManifest, mapping: mapping)
            // …и только то, чего в манифесте после прогона уже нет.
            // «Прежний» документ одной строки бывает **нынешним** документом
            // другой: без этой проверки правка в файле уносила из базы живые
            // строки, а манифест продолжал считать их записанными — то есть
            // ни один следующий прогон их не возвращал.
            let alive = Set(updated.documentIDs)
            let superseded = (sheetPlan.reembedded + sheetPlan.metadataOnly)
                .filter { $0.previousID != $0.document.id }
                .map(\.previousID)
                .filter { !alive.contains($0) }
            if !superseded.isEmpty {
                try await chroma.deleteDocuments(collectionID: context.collectionID, ids: superseded)
            }

            sheetManifest = updated
            manifest.sheets[sheetName] = sheetManifest

            report.sheetsIndexed.append(sheetName)
            // Выборка — не весь лист: лист, ждущий записи, ждёт
            // и дальше, а список исчезнувших строк выборка не трогает —
            // в её плане их нет вовсе, и пустой список значил бы «вернулись».
            let sample = context.rowLimit != nil
            if !sample { manifest.noteSheetWritten(sheetName) }
            report.rowsAdded += sheetPlan.added.count
            report.rowsReembedded += sheetPlan.reembedded.count
            report.rowsMetadataOnly += sheetPlan.metadataOnly.count
            report.rowsUnchanged += sheetPlan.unchanged
            report.disappeared += sheetPlan.disappeared
            // Список на решение — в манифест, а не только в отчёт:
            // отчёт живёт до конца прогона, а решать человек будет потом.
            // Вернулись строки на место — список чистится сам, как у файлов
            //: пустой `disappeared` и есть «решать больше нечего».
            if sample {
                // Решение о строках — по полному чтению листа, не по выборке.
            } else if sheetPlan.disappeared.isEmpty {
                manifest.pendingRemovals[sheetName] = nil
            } else {
                manifest.pendingRemovals[sheetName] = SheetRowRemoval(
                    rows: sheetPlan.disappeared,
                    noticedAt: manifest.pendingRemovals[sheetName]?.noticedAt ?? Date()
                )
            }
            if !sheetPlan.empty.isEmpty {
                report.warnings.append(String(localized: "лист «\(sheetName)»: строк без текста пропущено \(sheetPlan.empty.count)"))
            }
            // Обрезанные по длине значения: считаются по колонкам,
            // а не по строкам, — колонка одна на все сорок тысяч, и сорок
            // тысяч одинаковых строк в отчёте прячут всё остальное.
            let truncated = (sheetPlan.added + sheetPlan.reembedded.map(\.document)
                             + sheetPlan.metadataOnly.map(\.document))
                .flatMap(\.truncatedColumns)
            if !truncated.isEmpty {
                let byColumn = Dictionary(grouping: truncated, by: { $0 })
                    .map { "\($0.key) — \($0.value.count.plainDigits)" }
                    .sorted()
                    .joined(separator: ", ")
                report.warnings.append(String(localized: "лист «\(sheetName)»: значений обрезано по длине (\(RowMapper.metadataValueLimit.plainDigits) знаков) — \(byColumn)"))
                log(.warning, "Таблицы",
                    "Лист «\(sheetName)» файла \(context.relativePath): значения длиннее \(RowMapper.metadataValueLimit.plainDigits) знаков обрезаны в метаданных — \(byColumn). Полный текст стоит держать в колонке с ролью «текст».")
            }
            if !sheetPlan.duplicates.isEmpty {
                report.duplicates.append((sheetName, sheetPlan.duplicates))
                let rows = sheetPlan.duplicates.reduce(0) { $0 + $1.skipped.count }
                let examples = sheetPlan.duplicates.prefix(5).map(\.line).joined(separator: "; ")
                let tail = sheetPlan.duplicates.count > 5 ? String(localized: " и ещё \(sheetPlan.duplicates.count - 5)") : ""
                report.warnings.append(String(localized: "лист «\(sheetName)»: строк-повторов пропущено \(rows) — \(examples)\(tail)"))
                log(.warning, "Таблицы",
                    "Лист «\(sheetName)» файла \(context.relativePath): \(rows.plainDigits) строк дают тот же документ, что строка выше, и записаны не были — \(examples)\(tail)")
            }
        }

        // Листы, до которых разметка не дотянулась. Считаются в конце
        // и по остатку, а не по ходу: лист мог обработаться как документ,
        // попасть в план строк или отложиться с проблемой — «не размечен»
        // означает, что не случилось ничего из этого.
        let touched = Set(report.sheetsIndexed)
            .union(plans.map(\.sheet))
            .union(report.sheetsSkipped)
            .union(report.sheetsNeedingReindex)
        report.sheetsWithoutMapping = sheets.map(\.sheet.name)
            .filter { !touched.contains($0) && !coverage.skipped.contains($0) }
        if !report.sheetsWithoutMapping.isEmpty {
            log(.warning, "Таблицы",
                "Файл \(context.relativePath): листов без разметки \(report.sheetsWithoutMapping.count.plainDigits) из \(sheets.count.plainDigits) — их строки в базу не попали: \(report.sheetsWithoutMapping.joined(separator: ", "))")
        }

        manifest.collectionName = context.collectionName
        // Подписи — знак «файл записан по этим правилам». После выборки это
        // неправда: следующий полный прогон обязан открыть файл.
        if context.rowLimit == nil {
            manifest.profilesSignature = TableSyncService.profilesSignature(
                context.profiles, unmatchedSheetsAsText: context.unmatchedSheetsAsText
            )
            manifest.metadataSignature = context.metadataSignature
        }
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
        context.onBatchWritten?(records.count)
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
        guard var mapping = match.mapping else {
            // Ни один профиль не подошёл — лист записывается текстом, если
            // источник так велит. Разметка — документная: шапка
            // из этого файла, без ролей колонок и без ключа.
            guard TableSyncService.textFallback(
                sheet: entry.sheet, shape: shape, match: match, allowed: context.unmatchedSheetsAsText
            ) != nil else { return nil }
            let fallback = TableMapping(
                sheetName: entry.sheet.name, mode: .document, headerRow: shape.headerRow, columns: shape.columns
            )
            return (fallback, SheetLayout(shape: shape))
        }
        mapping.sheetName = entry.sheet.name
        return (mapping, SheetLayout(shape: shape))
    }

    /// Почему лист, не размеченный ни одним профилем, записывается текстом,
    /// или `nil` — не записывается.
    ///
    /// **Что было.** По лист с другим набором колонок не читается
    /// «как получится» и уходит в «требуют решения». Правило про **записи**:
    /// полусопоставленный лист дал бы строки, у которых молча нет колонки,
    /// по которой фильтруют. Но и сам лист при этом в базу не попадал вовсе:
    /// один общий профиль «Налоговая» на папку с ФЭО отправил в диагностику
    /// 2413 листов, и их цифры не находились ни по одному вопросу.
    ///
    /// **Как теперь.** Такой лист записывается режимом «Документ» — текстом
    /// с шапкой в каждом куске. Колонок-фильтров он не обещает, поэтому
    /// не нарушается, а текст ищется. Скрытый лист и лист, который
    /// автоопределение велит пропустить, не записываются, как и раньше.
    static func textFallback(
        sheet: SheetInfo, shape: SheetShape, match: TableProfileMatch, allowed: Bool
    ) -> String? {
        guard allowed, !sheet.isHidden, shape.mode != .skip else { return nil }
        switch match {
        case .matched:
            return nil
        case .ambiguous(let candidates):
            return String(localized: "листу подходит несколько профилей: \(candidates.map(\.name).joined(separator: ", "))")
        case .needsDecision(let reason, _, _, _):
            return reason
        }
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
            // Шапка читается со строки, записанной в самом варианте: назначение
            // должно работать и на файлах, где таблица начинается не сверху.
            func shape(for variant: TableProfile.Variant) -> SheetShape {
                // Разметку по буквам колонок автоопределение не воспроизведёт:
                // заголовков в этой строке нет, оно и вернёт «не вышло».
                // Читаем так же, как размечали, — иначе профиль работал бы
                // только в редакторе.
                if variant.mapping.usesColumnLetters {
                    return SheetModeDetector.lettered(rows: rows, headerRow: variant.mapping.headerRow ?? 0)
                }
                return variant.mapping.headerRow
                    .flatMap { SheetModeDetector.shape(rows: rows, headerRow: $0) } ?? auto
            }

            // Точный вариант вперёд неточного, а неточный — вперёд ничего.
            var loose: (TableProfile.Variant, SheetShape)?
            for variant in admitting {
                let found = shape(for: variant)
                let acceptance = variant.accepts(columns: found.columns, strict: false)
                guard acceptance.matches else { continue }
                if acceptance.exact { return (found, .matched(profile: assigned, variant: variant)) }
                if loose == nil { loose = (variant, found) }
            }
            if let (variant, found) = loose {
                return (found, .matched(profile: assigned, variant: variant))
            }

            // **Ни один вариант не подошёл — и это отказ, а не повод взять
            // первый попавшийся.** Раньше здесь стояло `admitting.first`:
            // лист, для которого в профиле разбора нет, читался разметкой
            // соседнего листа. С вариантом «любой подходящий лист» это
            // означало, что один разбор перехватывал всю книгу — записи
            // получались из чужих колонок, и человек видел «перемешанные
            // настройки». Хуже того: лист, помеченный «не индексировать»,
            // попадал в индекс под чужим вариантом.
            if !admitting.isEmpty {
                var names: [String] = []
                for column in admitting.flatMap(\.requiredColumns) where !names.contains(column) {
                    names.append(column)
                }
                return (auto, .needsDecision(
                    reason: String(localized: "профиль «\(assigned.name)» назначен файлу, но ни один его вариант не подходит листу: нет колонок \(names.joined(separator: ", "))"),
                    closest: assigned, missing: names, extra: []
                ))
            }
            return (auto, .needsDecision(
                reason: String(localized: "профиль «\(assigned.name)» назначен файлу, но про этот лист в нём ничего не сказано"),
                closest: assigned, missing: [], extra: []
            ))
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

    /// Лист-документ, кусок которого не отправить модели и после дорезки
    ///: пустой.
    struct UnsendableSheet: Error {
        let reason: String
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
        embeddings: EmbeddingProvider,
        coverage: SheetCoverage? = nil,
        /// Место листа в книге.
        sheetIndex: Int? = nil
    ) async throws -> (added: Int, reembedded: Int, unchanged: Int, split: Int) {
        // This file's header row: the one repeated in every chunk must be the
        // one this file actually has.
        let rendered = SheetRenderer.render(rows: entry.rows, headerRow: layout.headerRow, merges: entry.sheet.merges)
        guard !rendered.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (0, 0, 0, 0)
        }

        let raw = try await context.chunker?(rendered.text)
            ?? [TextChunk(index: 0, text: rendered.text)]
        var chunks = SheetRenderer.repeatingHeader(rendered.header, in: raw)
        // Шапка, дописанная после нарезки, — в размер куска: кусок,
        // который вылез за него, делится по строкам, и шапка — в каждой части.
        if let limit = context.chunkLimit {
            chunks = TableChunks.fitted(chunks, in: rendered.text, limit: limit)
        }
        // Кусок длиннее контекста модели ушёл бы в неё и молча обрезался
        //: кусок вырастает после нарезки — шапкой и строкой,
        // которую нарезка не делит, — а без нарезчика лист и вовсе один
        // кусок. Он дорезается, как кусок файла: лист-документ — это
        // текст, нарезанный стратегией источника, и пропускать его целиком
        // из-за одного куска — ровно то, от чего ушёл у файлов
        // (ревью…).
        let fitted = OversizeChunks.fitted(chunks, contextLength: context.contextLength)
        chunks = fitted.chunks
        // Пустой кусок дорезкой не лечится — как и у файлов.
        if let blocked = chunks.first(where: {
            ContextBudget.check($0.text, contextLength: context.contextLength).blocksSending
        }) {
            let verdict = ContextBudget.check(blocked.text, contextLength: context.contextLength)
            throw UnsendableSheet(reason: String(localized: "кусок \(blocked.index + 1) листа не отправляется модели: \(verdict.message ?? "")"))
        }

        var sheetManifest = manifest.sheets[entry.sheet.name] ?? SheetManifest(sheetName: entry.sheet.name)
        var added = 0, reembedded = 0, unchanged = 0
        var pending: [(TableRowDocument, String?)] = []
        var metadataOnly: [TableRowDocument] = []
        /// Тот же текст под другим id — записанное по прежней схеме
        /// идентификаторов: переезжает со своим вектором.
        var relocated: [(document: TableRowDocument, previousID: String)] = []
        var records: [String: TableRowRecord] = [:]

        for chunk in chunks {
            let id = RowMapper.identifier(
                sourceID: context.sourceID,
                sourceFile: context.relativePath,
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
            if let sheetIndex { metadata["sheet_index"] = .int(sheetIndex) }
            // Форма (бланк) — строками текста, а не сеткой: агенту
            // видно, что колонок у этого текста нет и складывать по ним
            // нечего.
            if let layout = SheetRenderer.layoutValue(rendered.layout) { metadata[SheetRenderer.layoutKey] = .string(layout) }
            if chunk.repeatedHeaderLength > 0 {
                metadata[TableChunkHeaders.lengthKey] = .int(chunk.repeatedHeaderLength)
            }
            if let note = chunk.note { metadata["extraction_warnings"] = .string(note) }
            // Книга в базе не целиком — это верно и для листа,
            // разобранного документом, а не строками.
            if let coverage, coverage.isPartial {
                metadata["sheets_indexed"] = .int(coverage.indexed)
                metadata["sheets_total"] = .int(coverage.total)
            }
            // Поля файла — до хеша, как и у строк.
            metadata = context.documentMetadata.merging(metadata) { _, own in own }

            let document = TableRowDocument(id: id, text: chunk.text, metadata: metadata, rowKey: nil)
            let identity = TableRowRecord.identity(rowKey: "chunk-\(chunk.index)", rowNumber: chunk.index)
            let record = TableRowRecord(
                documentID: id, rowNumber: chunk.index, rowKey: "chunk-\(chunk.index)",
                textHash: TableSyncPlanner.hash(chunk.text),
                metadataHash: TableSyncPlanner.hash(TableSyncPlanner.metadataSeed(metadata))
            )
            records[identity] = record

            if let previous = sheetManifest.rows[identity], previous.textHash == record.textHash,
               previous.documentID != id {
                relocated.append((document, previous.documentID))
                continue
            }
            if let previous = sheetManifest.rows[identity], previous.textHash == record.textHash {
                unchanged += 1
                // Текст тот же, а метаданные — нет: книга стала полной или
                // неполной, у куска сменилась пометка. Вектор не нужен, а
                // обновление — нужно: манифест ниже запомнит новый хеш, и
                // без записи в базу к этому чанку уже никто не вернулся бы.
                if previous.metadataHash != record.metadataHash { metadataOnly.append(document) }
                continue
            }
            if sheetManifest.rows[identity] == nil { added += 1 } else { reembedded += 1 }
            pending.append((document, nil))
        }

        if !metadataOnly.isEmpty {
            // Целиком, со снятием исчезнувших ключей: `update` у ChromaDB
            // метаданные сливает, и пометка о неполной книге иначе осталась бы.
            let stored = Dictionary(
                try await chroma.documents(collectionID: context.collectionID, ids: metadataOnly.map(\.id))
                    .map { ($0.id, $0.metadata) },
                uniquingKeysWith: { first, _ in first }
            )
            try await chroma.updateDocuments(
                collectionID: context.collectionID,
                updates: metadataOnly.map { document in
                    .replacingMetadata(
                        id: document.id, metadata: enriched(document.metadata, context: context),
                        previous: stored[document.id] ?? nil
                    )
                }
            )
        }

        if !relocated.isEmpty {
            // Вектор переезжает, только если под прежним id лежит **этот**
            // текст: прежний id мог делить кусок другого файла, и тогда
            // вектор под ним чужой — такой кусок считается заново.
            let previousIDs = relocated.map(\.previousID)
            let stored = Dictionary(
                try await chroma.documents(collectionID: context.collectionID, ids: previousIDs)
                    .map { ($0.id, $0.document) },
                uniquingKeysWith: { first, _ in first }
            )
            let vectors = try await chroma.embeddings(collectionID: context.collectionID, ids: previousIDs)
            var moved: [EmbeddedRecord] = []
            for (document, previousID) in relocated {
                if let vector = vectors[previousID], !vector.isEmpty, stored[previousID] == document.text {
                    moved.append(EmbeddedRecord(
                        id: document.id, document: document.text, embedding: vector,
                        metadata: enriched(document.metadata, context: context)
                    ))
                    unchanged += 1
                } else {
                    pending.append((document, previousID))
                    reembedded += 1
                }
            }
            if !moved.isEmpty {
                try await chroma.upsert(collectionID: context.collectionID, records: moved)
            }
        }

        for batch in stride(from: 0, to: pending.count, by: context.batchSize).map({
            Array(pending[$0..<min($0 + context.batchSize, pending.count)])
        }) {
            try Task.checkCancellation()
            try await write(batch, context: context, chroma: chroma, embeddings: embeddings)
        }

        // A sheet that got shorter leaves chunks nothing refers to; they go by
        // explicit id, after the new ones are written. Прежние id
        // переехавших кусков — туда же: под ними остались копии.
        let alive = Set(records.values.map(\.documentID))
        let stale = (sheetManifest.rows.filter { records[$0.key] == nil }.map(\.value.documentID)
            + relocated.map(\.previousID))
            .filter { !alive.contains($0) }
        if !stale.isEmpty {
            try await chroma.deleteDocuments(collectionID: context.collectionID, ids: stale)
        }

        sheetManifest.rows = records
        sheetManifest.mappingSignature = mapping.signature
        sheetManifest.headerRow = layout.headerRow
        manifest.sheets[entry.sheet.name] = sheetManifest
        return (added, reembedded, unchanged, fitted.split)
    }
}
