import Foundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Plan

/// What a sync intends to do with one file.
public enum SyncItemKind: Hashable {
    case new
    /// Reason is shown in the plan: the user should be able to tell a genuine
    /// edit from "you changed the chunk size, so everything is re-chunked".
    case changed(reason: String)
    case unchanged
    /// Read but not usable (unsupported format, too big, empty). Carries what
    /// is worth trying about it, classified where the error was still in hand
    /// rather than guessed from its wording later.
    case skipped(reason: String, remedy: FileRemedy)
    /// The mapping mode has nowhere to put it.
    case unroutable(reason: String)

    public var writesDocuments: Bool {
        switch self {
        case .new, .changed: return true
        case .unchanged, .skipped, .unroutable: return false
        }
    }

    public var title: String {
        switch self {
        case .new: return String(localized: "новый")
        case .changed: return String(localized: "изменён")
        case .unchanged: return String(localized: "без изменений")
        case .skipped: return String(localized: "пропущен")
        case .unroutable: return String(localized: "не размещён")
        }
    }

    public var detail: String? {
        switch self {
        case .changed(let reason), .unroutable(let reason): return reason
        case .skipped(let reason, _): return reason
        case .new, .unchanged: return nil
        }
    }
}

public struct SyncPlanItem: Identifiable, Hashable {
    public var id: String { relativePath }
    public let relativePath: String
    public let url: URL
    public let kind: SyncItemKind
    /// Target collection; `nil` for files that are not going anywhere.
    public let collectionName: String?
    public let size: Int64
    public let modifiedAt: Date
    /// Hash of the extracted text; absent for files the planner did not read.
    public let contentHash: String?
    /// Length of the extracted text, in characters — populated exactly when
    /// `contentHash` is, i.e. whenever the planner actually read the file
    /// (J2: this is what the chunk-count estimate uses instead of raw file
    /// size, which for PDF/RTF/etc. bears little relation to the text length).
    public let textLength: Int?
    /// Metadata contributed by the mapping mode (`relative_path`).
    public let routeMetadata: ChromaMetadata
    /// What the manifest should record about a file that is **not** being
    /// re-embedded: it moved on disk, its text did not.
    public let refresh: ManifestRefresh?
    /// Документ пришёл из сети, а не с диска. Тогда `url` — это
    /// временный файл с телом ответа, и рассказывать про него как про файл
    /// пользователя нельзя: имя и время у него наши, а не страницы.
    public let isRemote: Bool

    public init(
        relativePath: String,
        url: URL,
        kind: SyncItemKind,
        collectionName: String?,
        size: Int64,
        modifiedAt: Date,
        contentHash: String? = nil,
        textLength: Int? = nil,
        routeMetadata: ChromaMetadata = [:],
        refresh: ManifestRefresh? = nil,
        isRemote: Bool = false
    ) {
        self.relativePath = relativePath
        self.url = url
        self.kind = kind
        self.collectionName = collectionName
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.textLength = textLength
        self.routeMetadata = routeMetadata
        self.refresh = refresh
        self.isRemote = isRemote
    }
}

/// The result of comparing a folder against its manifest — cheap, read-only and
/// Массовое исчезновение файлов источника.
///
/// Правило простое: столько файлов разом человек не удаляет. Отключённый
/// внешний диск, размонтированная шара, папка, синхронизация которой
/// не докачалась, — вот обычные причины, и все они означают «данные на месте,
/// просто их сейчас не видно».
///
/// Порог — доля **и** абсолютное число: пять файлов из десяти это работа
/// человека, а восемь тысяч из восьми тысяч — нет.
public struct MassDisappearance: Sendable, Hashable {
    public let missing: Int
    public let known: Int

    public init(missing: Int, known: Int) {
        self.missing = missing
        self.known = known
    }

    public var share: Double { known > 0 ? Double(missing) / Double(known) : 0 }

    public var summary: String {
        String(localized: "с диска исчезло \(missing.plainDigits) файлов из \(known.plainDigits)")
    }
}

/// shown to the user before anything is written or embedded.
public struct SyncPlan {
    public let sourceID: UUID
    public let sourceName: String
    public let items: [SyncPlanItem]
    /// Files in the manifest that are no longer on disk, newly noticed now.
    public let newlyMissing: [PendingRemoval]
    /// Everything awaiting a decision, including what earlier syncs found.
    public let pendingRemovals: [PendingRemoval]
    /// Массовая пропажа файлов: столько с диска разом не исчезает
    /// по воле человека. Пока она не подтверждена, список «требуют решения»
    /// не пополняется вовсе, а прогон не запускается.
    public let massDisappearance: MassDisappearance?
    /// Files whose text came from an older version of the extractor that reads
    /// them today. Deliberately **not** part of `items`: forbids queueing
    /// them, and anything inside `items` is work this run intends to do.
    public let staleExtraction: [StaleExtraction]
    /// Rows a table source would send to the model. Counted during the
    /// plan, because the price of a sheet cannot be guessed from its file size.
    public let tableRowsToEmbed: Int
    /// Уровни вложенности глубже названных. Как и устаревший
    /// экстрактор — сообщаются, но работы не создают: имя уровню даёт человек.
    public let newFolderLevels: [NewFolderLevel]

    public init(
        sourceID: UUID,
        sourceName: String,
        items: [SyncPlanItem],
        newlyMissing: [PendingRemoval],
        pendingRemovals: [PendingRemoval],
        massDisappearance: MassDisappearance? = nil,
        staleExtraction: [StaleExtraction] = [],
        tableRowsToEmbed: Int = 0,
        newFolderLevels: [NewFolderLevel] = []
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.items = items
        self.newlyMissing = newlyMissing
        self.pendingRemovals = pendingRemovals
        self.massDisappearance = massDisappearance
        self.staleExtraction = staleExtraction
        self.tableRowsToEmbed = tableRowsToEmbed
        self.newFolderLevels = newFolderLevels
    }

    public func count(of kind: (SyncItemKind) -> Bool) -> Int {
        items.filter { kind($0.kind) }.count
    }

    public var newCount: Int { count { if case .new = $0 { return true }; return false } }
    public var changedCount: Int { count { if case .changed = $0 { return true }; return false } }
    public var unchangedCount: Int { count { $0 == .unchanged } }
    public var skippedCount: Int { count { if case .skipped = $0 { return true }; return false } }
    public var unroutableCount: Int { count { if case .unroutable = $0 { return true }; return false } }

    public var writeItems: [SyncPlanItem] { items.filter { $0.kind.writesDocuments } }
    public var hasWork: Bool { !writeItems.isEmpty }

    /// Collections this run would touch.
    public var targetCollections: [String] {
        var seen: [String] = []
        for item in writeItems {
            guard let name = item.collectionName else { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.sorted()
    }

    public var summaryLine: String {
        String(localized: "новых \(newCount), изменённых \(changedCount), без изменений \(unchangedCount), пропущено \(skippedCount + unroutableCount), требуют решения \(pendingRemovals.count)")
    }

    // MARK: - J2: chunk and time estimate

    /// ≈ chunks the write items would produce. Falls back to raw file size for
    /// the rare item the planner did not read (should not normally happen —
    /// every write item comes from the branch that extracts text).
    public func estimatedChunkCount(chunking: ChunkingConfiguration) -> Int {
        writeItems.reduce(0) { total, item in
            total + chunking.estimatedChunkCount(forCharacters: item.textLength ?? Int(item.size))
        }
    }

    /// Total characters the run would actually chunk — the input to the
    /// chunking-throughput half of the time estimate.
    public var writeItemsCharacterCount: Int {
        writeItems.reduce(0) { $0 + ($1.textLength ?? Int($1.size)) }
    }

    /// whether a manual run should show itself and wait for a confirmation
    /// first — по любой из причин, перечисленных в `confirmationReasons`.
    ///
    /// Причин две: файлов больше порога и строк из таблиц больше пяти тысяч
    ///. Раньше здесь считалась только первая, а вторую проверяла
    /// модель экрана отдельным условием — и объяснение на экране разошлось
    /// с тем, что на самом деле сработало.
    ///
    /// Порог файлов читается ровно так, как написано в настройке —
    /// «показывать план, если файлов больше N», — поэтому 0 означает
    /// «останавливаться на всём, что пишет». Когда-то ноль был особым
    /// случаем «выключено», и настройка говорила одно, а делала другое.
    public func needsConfirmation(threshold: Int) -> Bool {
        !confirmationReasons(threshold: threshold).isEmpty
    }

    /// Почему план остановился и ждёт человека.
    ///
    /// Причин две, и они независимы: много файлов и много строк из таблиц.
    /// Раньше про причину знали ворота, а баннер на экране рассказывал
    /// **всегда про первую** — и на плане из сорока двух файлов при пороге сто
    /// писал «42 — больше порога 100». Утверждение неверное, и человеку
    /// приходилось искать, чему верить: числу или порогу.
    ///
    /// Поэтому причина считается здесь, рядом с самими воротами, и текст
    /// берётся у неё. Возвращается список: обе причины могут сработать разом,
    /// и умалчивать о второй — та же беда меньшего размера.
    public func confirmationReasons(threshold: Int) -> [ConfirmationReason] {
        var reasons: [ConfirmationReason] = []
        if writeItems.count > max(0, threshold) {
            reasons.append(.manyFiles(files: writeItems.count, threshold: max(0, threshold)))
        }
        if tableRowsToEmbed > TableRunEstimate.warningThreshold {
            reasons.append(.manyTableRows(rows: tableRowsToEmbed, threshold: TableRunEstimate.warningThreshold))
        }
        return reasons
    }

    /// Что именно велело остановиться, словами.
    public enum ConfirmationReason: Equatable, Sendable {
        /// Файлов к записи больше, чем разрешает настройка «показывать план».
        case manyFiles(files: Int, threshold: Int)
        /// Строк из таблиц столько, что каждая станет обращением к модели.
        case manyTableRows(rows: Int, threshold: Int)

        /// Одно предложение: что случилось и что с этим делать.
        public var sentence: String {
            switch self {
            case .manyFiles(let files, let threshold):
                return String(localized: "Файлов к записи \(files.plainDigits) — больше, чем \(threshold.plainDigits), после которых приложение показывает план. Снимите отметки с тех, что трогать не нужно.")
            case .manyTableRows(let rows, let threshold):
                return String(localized: "Строк из таблиц \(rows.plainDigits) — каждая станет отдельным обращением к модели, а предупреждение включается после \(threshold.plainDigits). Это надолго: проверьте, те ли это файлы.")
            }
        }
    }
}

/// Chunking time and embedding time, each present only when there is a
/// measured average to base it on (rule 4, Приложение 5: warn before running,
/// never with a guessed number).
public struct SyncTimeEstimate {
    public let chunkingSeconds: Double?
    public let embeddingSeconds: Double?

    public var totalSeconds: Double? {
        guard chunkingSeconds != nil || embeddingSeconds != nil else { return nil }
        return (chunkingSeconds ?? 0) + (embeddingSeconds ?? 0)
    }
}

public extension SyncPlan {
    /// Combines this plan's size with what has actually been measured — never a
    /// guess: a strategy or model with nothing measured simply contributes
    /// nothing, and `nil` overall means "no data yet" (F3/8.8).
    ///
    /// Two sources of truth for embedding speed, in this order:
    ///
    /// 1. the running average of real work (`MetricsStore`) — it was measured on
    ///    this user's own texts, on this machine, doing this job;
    /// 2. the benchmark — a controlled measurement on a fixed corpus,
    ///    which is what makes an estimate possible *before* the first run, the
    ///    gap F3 exists to close.
    ///
    /// Real work wins where both exist: the benchmark's corpus is representative,
    /// the user's own texts are the truth.
    func estimatedDuration(
        chunking: ChunkingConfiguration,
        embeddingModel: String,
        metrics: MetricsSnapshot,
        benchmarks: [ModelBenchmark] = []
    ) -> SyncTimeEstimate? {
        guard hasWork else { return nil }

        var chunkingSeconds: Double?
        if let strategyMetric = metrics.strategies.first(where: { $0.strategy == chunking.strategy }),
           strategyMetric.throughput > 0 {
            chunkingSeconds = Double(writeItemsCharacterCount) / (strategyMetric.throughput * 1000)
        }

        var secondsPerText: Double?
        if let modelMetric = metrics.models.first(where: { $0.model == embeddingModel }),
           modelMetric.averageSeconds > 0 {
            secondsPerText = modelMetric.averageSeconds
        } else if let benchmark = benchmarks.first(where: { $0.model == embeddingModel }),
                  benchmark.secondsPerText > 0 {
            secondsPerText = benchmark.secondsPerText
        }

        let embeddingSeconds = secondsPerText.map { $0 * Double(estimatedChunkCount(chunking: chunking)) }

        guard chunkingSeconds != nil || embeddingSeconds != nil else { return nil }
        return SyncTimeEstimate(chunkingSeconds: chunkingSeconds, embeddingSeconds: embeddingSeconds)
    }
}

// MARK: - Progress and summary

public struct SyncProgress {
    public var stage: String
    public var processedFiles: Int
    public var totalFiles: Int
    public var chunksWritten: Int
    public var currentFile: String?

    public init(stage: String, processedFiles: Int = 0, totalFiles: Int = 0, chunksWritten: Int = 0, currentFile: String? = nil) {
        self.stage = stage
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.chunksWritten = chunksWritten
        self.currentFile = currentFile
    }

    public var fraction: Double {
        totalFiles > 0 ? min(1, Double(processedFiles) / Double(totalFiles)) : 0
    }
}

public struct SyncSummary {
    public let sourceName: String
    public let added: Int
    public let updated: Int
    public let unchanged: Int
    public let chunksWritten: Int
    public let chunksDeleted: Int
    public let skipped: [(file: String, reason: String)]
    public let needsDecision: [PendingRemoval]
    /// Files written despite an unmet schema requirement, marked in metadata.
    public let markedForAttention: [String]
    public let collections: [String]
    public let duration: TimeInterval
    public let embeddingModel: String
    public let dimension: Int?
    /// Файлы, на которых выбранная стратегия нарезки была подменена, и чем
    /// именно. Раньше об этом говорила только пометка в метаданных каждого
    /// чанка: человек заводил шесть источников с разными стратегиями, получал
    /// шесть одинаковых коллекций и узнавал причину, лишь раскрыв чанк
    ///.
    public var substituted: [(file: String, reason: String)] = []
    /// Files an interrupted previous run left behind and this one finished off.
    /// Recovery happens by itself, but never silently.
    public var recoveredFiles: Int = 0
    /// Files that had to be re-indexed because the interrupted run died before
    /// it could know how much of its write landed.
    public var reindexedAfterFailure: Int = 0
    /// Collections whose stored chunking recipe differs from the one this run
    /// writes with: their contents are now mixed. Never resolved by the
    /// app itself — re-indexing or cloning is the user's call.
    /// Чанков, дорезанных под контекст модели. Ноль почти всегда;
    /// не ноль — повод уменьшить размер чанка у источника.
    public var chunksSplitToFit: Int = 0
    public var heterogeneousCollections: [String] = []
    /// Files whose text an older version of the extractor produced. Reported,
    /// never queued: forbids an app update from starting hours of local
    /// model time on its own.
    public var staleExtraction: [StaleExtraction] = []
    /// Оговорки табличного конвейера: достигнутый предел строк,
    /// формулы без сохранённого значения, пропущенные строки, листы, которым
    /// нужна переиндексация. Считались и терялись: отчёт таблиц собирался
    /// в переменную, которую никто не читал.
    public var tableWarnings: [String] = []
    /// Исчезнувшие строки таблиц, ждущие решения.
    public var tableRowsNeedingDecision: Int = 0
    /// Уровни вложенности глубже названных.
    public var newFolderLevels: [NewFolderLevel] = []

    public var wroteNothing: Bool { added == 0 && updated == 0 }

    /// «Стратегия нарезки подменена у N файлов: …» — или `nil`, если подмен
    /// не было.
    ///
    /// Причины сворачиваются в набор: их всего две, а файлов могут быть сотни.
    public var substitutionLine: String? {
        guard !substituted.isEmpty else { return nil }
        let reasons = Array(Set(substituted.map(\.reason))).sorted()
        let files = RussianCount.grouped(substituted.count, "файла", "файлов", "файлов")
        return String(localized: "Стратегия нарезки подменена у \(files): \(reasons.joined(separator: "; "))")
    }

    public var staleExtractionLine: String? {
        guard !staleExtraction.isEmpty else { return nil }
        let versions = Set(staleExtraction.map { "\($0.previous.text) → \($0.current.text)" }).sorted()
        return String(localized: "файлов, извлечённых прежней версией экстрактора: \(staleExtraction.count) (\(versions.joined(separator: ", "))) — переизвлечение запускается вручную")
    }

    public var newFolderLevelsLine: String? {
        guard let deepest = newFolderLevels.first else { return nil }
        let names = deepest.examples.joined(separator: ", ")
        return String(localized: "появился уровень вложенности \(deepest.number) (\(deepest.folderCount) папок: \(names)) — поле не задано, названия папок в базу не попадают")
    }

    public var heterogeneityLine: String? {
        guard !heterogeneousCollections.isEmpty else { return nil }
        return String(localized: "параметры чанкинга разошлись с записанными в коллекциях: \(heterogeneousCollections.joined(separator: ", ")) — содержимое стало неоднородным, нужна переиндексация или клонирование")
    }

    public var recoveryLine: String? {
        guard recoveredFiles + reindexedAfterFailure > 0 else { return nil }
        return String(localized: "восстановлено после незавершённого прогона: доиграно \(recoveredFiles), переиндексировано \(reindexedAfterFailure)")
    }

    public var line: String {
        let base = String(localized: "добавлено \(added), обновлено \(updated), без изменений \(unchanged); чанков записано \(chunksWritten), удалено \(chunksDeleted)")
        return [base, recoveryLine, heterogeneityLine, staleExtractionLine, newFolderLevelsLine]
            .compactMap { $0 }.joined(separator: "; ")
    }
}

public enum SyncError: LocalizedError {
    case folderMissing(String)
    /// Том источника не тот, что был раньше: `/Volumes/Backup`
    /// сегодня и вчера бывает разными дисками.
    case volumeChanged(expected: String, found: String?)
    /// С диска исчезло столько, что это больше похоже на отключённый том,
    /// чем на работу человека.
    case massDisappearance(missing: Int, known: Int)
    /// Чанк длиннее того, что модель эмбеддинга читает.
    ///
    /// Не «модель отказала» — она бы приняла и вернула вектор начала,
    /// а хвост остался бы незакодированным. Отказ здесь наш.
    case longerThanModelReads(path: String, characters: Int, limit: Int, model: String)
    case noExtensions
    case noFiles(String)
    case noEmbeddingModel
    case ruleInvalid(String)
    case chunkingMisconfigured(String)
    case schemaNotCovered(collection: String, fields: [String])
    case schemaConflict(collection: String, message: String)
    case alreadyRunning(String)
    case cancelled
    /// A previous run could not be finished, so this one does not start:
    /// planning against a manifest known to be behind the database is worse
    /// than refusing.
    case recoveryFailed(file: String, reason: String)
    /// Окна LLM-нарезки не получается: либо не помещается в контекст, с
    /// которым загружена чат-модель, либо модель не успевает его
    /// переписать за отпущенное время. Проверяется до первого файла.
    case chunkingWindowTooSmall(LLMContextCheck)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            return String(localized: "Папка источника не найдена: \(path)")
        case .volumeChanged(let expected, let found):
            return found.map {
                String(localized: "Папка источника лежит на другом томе: ожидался «\(expected)», сейчас подключён «\($0)». Синхронизация не запускалась.")
            } ?? String(localized: "Том «\(expected)», на котором лежит источник, не подключён. Синхронизация не запускалась.")
        case .massDisappearance(let missing, let known):
            return String(localized: "С диска исчезло \(missing.plainDigits) файлов из \(known.plainDigits) — это похоже на отключённый диск, а не на правку папки. Синхронизация остановлена, из базы ничего не удалено.")
        case .longerThanModelReads(let path, let characters, let limit, let model):
            return String(localized: "Файл «\(path)»: чанк в \(characters.plainDigits) знаков длиннее того, что модель «\(model)» читает за раз — измерено \(limit.plainDigits) знаков. Модель приняла бы его молча, посчитав вектор только по началу, поэтому файл пропущен.")
        case .noExtensions:
            return String(localized: "У источника не указано ни одного расширения файлов.")
        case .noFiles(let path):
            return String(localized: "В папке \(path) не найдено подходящих файлов (проверьте список расширений и флаг рекурсии).")
        case .noEmbeddingModel:
            return String(localized: "Не выбрана эмбеддинг-модель LM Studio. Откройте раздел «Эмбеддинги» и выберите модель.")
        case .ruleInvalid(let details):
            return String(localized: "Правило маппинга некорректно: \(details)")
        case .chunkingMisconfigured(let details):
            return String(localized: "Параметры чанкинга не позволяют начать: \(details)")
        case .schemaNotCovered(let collection, let fields):
            return String(localized: "Схема коллекции «\(collection)» требует поля, которых источник не даёт: \(fields.joined(separator: ", ")).")
        case .schemaConflict(let collection, let message):
            return String(localized: "Метаданные источника не проходят схему коллекции «\(collection)»: \(message)")
        case .alreadyRunning(let name):
            return String(localized: "Синхронизация источника «\(name)» уже идёт.")
        case .cancelled:
            return String(localized: "Синхронизация отменена.")
        case .recoveryFailed(let file, let reason):
            return String(localized: "Прошлая синхронизация не была завершена, и доиграть её не получилось на файле \(file): \(reason)")
        case .chunkingWindowTooSmall(let check):
            return check.summary
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .volumeChanged:
            return String(localized: "Подключите тот же диск (или сетевую шару) и запустите синхронизацию заново. Если папка действительно переехала, укажите новый путь в настройках источника — том запомнится заново.")
        case .massDisappearance:
            return String(localized: "Проверьте, что диск с папкой подключён и это тот самый диск. Если файлы удалены намеренно, запустите синхронизацию ещё раз и подтвердите массовое исчезновение — только тогда они попадут в «требуют решения».")
        case .longerThanModelReads:
            return String(localized: "Уменьшите предельный размер чанка у источника (для document-based — «max_section_size» и откат для крупных секций), либо возьмите модель, читающую больше. Предел измерен пробой самой модели: то, что она сообщает о своём контексте, с ним не совпадает.")
        case .recoveryFailed:
            return String(localized: "Проверьте, что база доступна, и запустите синхронизацию источника вручную. Пока это не сделано, автоматические режимы для источника приостановлены.")
        case .schemaNotCovered:
            return String(localized: "Добавьте недостающие поля в метаданные источника, снимите с них обязательность в схеме или переключите источник в режим «помечать требуют внимания».")
        case .schemaConflict:
            return String(localized: "Исправьте значение в метаданных источника или тип поля в схеме коллекции.")
        case .chunkingWindowTooSmall(let check):
            // Совет зависит от того, чего именно не хватило. Пока
            // причина была одна, совет был один — «перезагрузите модель
            // с бо́льшим контекстом», — и при нехватке времени он делал
            // ровно наоборот: окно от большего контекста только росло.
            if check.timeIsTheLimit {
                return String(localized: "Увеличьте таймаут в настройках источника или возьмите модель полегче. Перезагружать модель с бо́льшим контекстом не нужно: места ей хватает, не хватает времени.")
            }
            // Контекст задаётся при загрузке модели в LM Studio, и приложение
            // его не меняет само: перезагрузка модели — это минуты и гигабайты
            // в чужом приложении, и решает это человек.
            let target = check.maximum.map { String(localized: " Модель поддерживает до \($0.plainDigits) токенов — перезагрузите её с бо́льшим контекстом кнопкой на экране «Модели».") } ?? ""
            return String(localized: "Уменьшите размер чанка, укоротите шаблон запроса или выберите другую стратегию нарезки.\(target)")
        default:
            return nil
        }
    }
}

// MARK: - Schema hookup

/// How well a source covers the target collection's schema.
public struct SourceSchemaCoverage {
    public let collectionName: String
    /// Keys the source will write, in a stable order.
    public let providedKeys: [String]
    /// Required schema fields nobody is going to fill in.
    public let uncoveredRequiredFields: [String]
    /// Type errors in the source's own key-values, found before the run starts.
    public let typeProblems: [SchemaViolation]

    public var isSatisfied: Bool { uncoveredRequiredFields.isEmpty && typeProblems.isEmpty }
}

// MARK: - Service

/// Registers what a folder contains, keeps a manifest and syncs it into
/// ChromaDB incrementally.
///
/// An actor: the per-source lock that keeps two syncs of the same folder from
/// fighting over the same rows lives here, not in the UI.
public actor SourceSyncService {
    private let log: LogHandler
    private let manifests: ManifestStore
    /// Which extractor reads which file. A registry rather than a
    /// switch on file extension: each format brings its own fallbacks,
    /// warnings and structure.
    private let registry: ExtractorRegistry
    private let router = CollectionRouter()
    private let validator = MetadataSchemaValidator()
    /// Файловая система. Подменяется только в проверках — например, чтобы
    /// посчитать, сколько раз план ходит на диск за атрибутами.
    private let fileManager: FileManager
    private let metrics: MetricsStore?
    private let journal: SyncJournal
    /// Passwords the user has given for individual documents. Read one
    /// file at a time, straight from the Keychain, never held in the source.
    private let passwords: DocumentPasswordStore
    /// tables go through their own pipeline. This service only routes to it
    /// — the moment a spreadsheet is handled here, has been broken.
    private let tables: TableSyncService
    private let tableManifests: TableManifestStore
    private var running: Set<UUID> = []
    /// Профили сопоставления, общие для всех источников.
    ///
    /// Здесь, а не в `DataSource`: источник — это то, что человек про папку
    /// сказал, и подмешивать в него чужие профили значило бы записать их
    /// в его настройки при первом же сохранении. Служба получает их из
    /// настроек приложения и держит до следующего изменения.
    private var sharedTableProfiles: [TableProfile] = []

    /// Принять новый список общих профилей. Вызывается на каждое изменение
    /// настроек, а не перед прогоном: прогонов много, и забытый вызов означал
    /// бы источник, молча читаемый вчерашней разметкой.
    public func adopt(sharedTableProfiles profiles: [TableProfile]) {
        sharedTableProfiles = profiles
    }

    /// Профили, которыми читается этот источник: свои плюс общие. Свой
    /// одноимённый главнее — см. `TableProfile.resolved(own:shared:)`.
    func tableProfiles(of source: DataSource) -> [TableProfile] {
        TableProfile.resolved(own: source.tableProfiles, shared: sharedTableProfiles)
    }

    public init(
        manifests: ManifestStore? = nil,
        metrics: MetricsStore? = nil,
        journal: SyncJournal? = nil,
        registry: ExtractorRegistry? = nil,
        passwords: DocumentPasswordStore = DocumentPasswordStore(),
        tableManifests: TableManifestStore? = nil,
        fileManager: FileManager = .default,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.fileManager = fileManager
        self.log = log
        self.manifests = manifests ?? ManifestStore(log: log)
        self.metrics = metrics
        self.journal = journal ?? SyncJournal(log: log)
        self.registry = registry ?? ExtractorRegistry.standard(log: log)
        self.passwords = passwords
        self.tableManifests = tableManifests ?? TableManifestStore(log: log)
        self.tables = TableSyncService(metrics: metrics, log: log)
    }

    /// Доля пропавших файлов, за которой это перестаёт быть работой человека.
    public static let massDisappearanceShare = 0.5
    /// …и абсолютное число, ниже которого доля ничего не значит: два файла
    /// из трёх — это обычная правка папки, а не отключённый диск.
    public static let massDisappearanceMinimum = 10

    /// Пропало ли столько, что прогон надо остановить.
    static func massDisappearance(missing: Int, known: Int) -> MassDisappearance? {
        guard missing >= massDisappearanceMinimum, known > 0 else { return nil }
        guard Double(missing) / Double(known) >= massDisappearanceShare else { return nil }
        return MassDisappearance(missing: missing, known: known)
    }

    /// One file — or one package that *is* a document.
    ///
    /// `.pages`, `.key` and some `.epub` are directories. Asking only for
    /// regular files drops them silently; walking into them indexes
    /// `Index.zip` and `preview.jpg` as separate documents and never extracts
    /// the document itself. `.skipsPackageDescendants` handles the second half,
    /// this handles the first.
    static func isIndexableEntry(_ url: URL) -> Bool {
        guard !isOfficeLockFile(url) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        // Ссылка — не файл источника. Обход в неё и так не заходит
        // (проверено вживую: `isRegularFile` у симлинка равен `false`), но
        // пакет опознаётся **по расширению**, и ссылка с именем `отчёт.pages`
        // прочиталась бы из-за корня источника. Индексировать чужое, потому
        // что кто-то положил в папку ссылку, приложение не должно.
        if values?.isSymbolicLink == true { return false }
        if values?.isRegularFile == true { return true }
        return ExtractorRegistry.isDocumentPackage(url)
    }

    /// Файл, изменённый за эти секунды до прогона, считается подозрительным
    /// и проверяется вторым замером.
    ///
    /// FSEvents срабатывает на середине записи: копирование гигабайтного PDF
    /// по сети — это событие в момент, когда на диске лежит его половина.
    /// Прочитанная половина получает честный хэш половины и попадает в базу
    /// как полноценный документ.
    public static let stabilisationSeconds: TimeInterval = 5
    /// Пауза между двумя замерами. Одна на весь прогон, а не на файл.
    public static let stabilisationSample: TimeInterval = 1
    /// Ниже этого размера файл не проверяется вовсе.
    ///
    /// Не из лени: маленький файл редакторы пишут во временный и переименовывают,
    /// то есть он появляется целиком и сразу. Ждать секунду ради каждой свежей
    /// заметки значило бы наказать самый частый случай ради самого редкого —
    /// и «скопировал папку, нажал синхронизацию» переставало бы работать
    /// вовсе: всё было бы «ещё пишется».
    public static let stabilisationMinimumBytes: Int64 = 1_048_576

    /// Стоит ли присматриваться к этому файлу.
    static func isBeingWritten(modifiedAt: Date, size: Int64, now: Date = Date()) -> Bool {
        size >= stabilisationMinimumBytes && now.timeIntervalSince(modifiedAt) < stabilisationSeconds
    }

    /// Размер и время изменения файла — то, что план спрашивает у диска.
    public struct FileSnapshot: Sendable, Hashable {
        public let size: Int64
        public let modifiedAt: Date
    }

    /// Что план узнал у файловой системы за **один** обход.
    ///
    /// Раньше атрибуты снимались дважды: сначала проверкой «не пишется ли
    /// файл прямо сейчас», потом основным циклом плана. На восьми
    /// тысячах файлов это шестнадцать тысяч обращений вместо восьми, причём
    /// у плана, который заявлен как дешёвая операция «просто посмотреть,
    /// что будет сделано». На сетевой шаре разница видна глазами.
    struct FileScan: Sendable {
        /// Файлы, которые растут прямо сейчас: читать их рано.
        var growing: Set<String> = []
        /// Снимок по пути файла. Пути нет вовсе — файл исчез между обходом
        /// папки и замером; план разберётся с ним сам, как разбирался всегда.
        var snapshots: [String: FileSnapshot] = [:]
    }

    /// Один обход: атрибуты всех файлов и те из них, что растут прямо сейчас
    ///.
    ///
    /// Два замера с паузой между ними, и пауза одна на весь прогон, а не на
    /// файл: иначе папка из тысячи свежих файлов ждала бы тысячу секунд.
    /// Изменился размер или время — файл пишут, и читать его нельзя; не
    /// изменился — копирование кончилось, и ждать нечего.
    ///
    /// Второй замер делается только по подозрительным файлам и **обновляет
    /// снимок**: если файл всё-таки дорос и успокоился, план увидит его
    /// сегодняшний размер, а не тот, что был секунду назад.
    static func scan(
        _ files: [URL], fileManager: FileManager = .default, now: Date = Date()
    ) async -> FileScan {
        func sample(_ url: URL) -> FileSnapshot? {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
            return FileSnapshot(
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: (attributes[.modificationDate] as? Date) ?? .distantPast
            )
        }

        var result = FileScan()
        var suspicious: [URL: FileSnapshot] = [:]
        for url in files {
            guard let first = sample(url) else { continue }
            result.snapshots[url.path] = first
            if isBeingWritten(modifiedAt: first.modifiedAt, size: first.size, now: now) {
                suspicious[url] = first
            }
        }
        guard !suspicious.isEmpty else { return result }

        try? await Task.sleep(nanoseconds: UInt64(stabilisationSample * 1_000_000_000))

        for (url, before) in suspicious {
            guard let after = sample(url) else {
                // Файл исчез между замерами — это точно не то, что стоит
                // читать сейчас.
                result.growing.insert(url.path)
                result.snapshots[url.path] = nil
                continue
            }
            result.snapshots[url.path] = after
            if after != before { result.growing.insert(url.path) }
        }
        return result
    }

    /// Только растущие файлы — для проверок, которым остальное не нужно.
    static func growingFiles(
        _ files: [URL], fileManager: FileManager = .default, now: Date = Date()
    ) async -> Set<String> {
        await scan(files, fileManager: fileManager, now: now).growing
    }

    /// Файл лежит в облаке и на диске его нет.
    ///
    /// Специфика macOS, которую не обойти: при включённой оптимизации
    /// хранилища файл в каталоге есть, у него имя, размер и время, а данных
    /// нет. Наивное чтение либо блокируется на скачивании, либо возвращает
    /// ошибку — и то и другое хуже честного «требует загрузки»: скачивание
    /// это чужой трафик и чужое место на диске, и решать про них должен
    /// человек.
    static func needsDownloadFromCloud(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true else { return false }
        guard let status = values?.ubiquitousItemDownloadingStatus else { return false }
        // `.current` — файл на диске целиком. `.downloaded` — на диске, но
        // в облаке есть свежее: читать можно, это по-прежнему документ.
        return status == .notDownloaded
    }

    /// Служебный файл-замок Word, Excel или PowerPoint.
    ///
    /// Office кладёт рядом с открытым документом файл `~$имя.docx` — он хранит
    /// имя владельца, а не документ, и содержимого нужного формата в нём нет.
    /// Расширение у него то же самое, поэтому в отбор он проходит, а извлечение
    /// на нём честно ломается: в журнале появляется «файл не читается: неверный
    /// формат» на файл, которого пользователь не создавал и в источнике не
    /// видит. Скрытым он на macOS не помечен, так что `.skipsHiddenFiles`
    /// его не отсеивает — проверено по журналу приложения 10 и 11 августа.
    ///
    /// Молча, а не предупреждением: пропуск замка — это норма, а не событие,
    /// о котором стоит рассказывать.
    static func isOfficeLockFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("~$")
    }

    /// What this source asks of an extraction.
    ///
    /// Static and public so the extraction preview asks for exactly what a real
    /// run would ask for. A preview taken with default options would tell the
    /// user a scan has no text layer while their source has recognition on.
    public static func extractionOptions(
        for source: DataSource,
        reason: SyncReason = .manual,
        password: String? = nil,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) -> ExtractionOptions {
        ExtractionOptions(
            maxFileSize: source.maxFileSizeBytes,
            ocrEnabled: source.ocrEnabled,
            ocrLanguages: source.ocrLanguages,
            includeDocumentMetadata: source.includeDocumentMetadata,
            // Two switches, and both must be on for a timer to open Pages.
            allowApplicationExport: source.iWorkExportEnabled
                && (!reason.isAutomatic || source.iWorkExportInAutomaticRuns),
            password: password,
            progress: progress
        )
    }

    /// The same options, with the password this file has been given. Fetched per
    /// file and only when there is one: an unlocked document never causes a
    /// Keychain read.
    private func extractionOptions(
        for source: DataSource,
        relativePath: String,
        reason: SyncReason = .manual,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) -> ExtractionOptions {
        Self.extractionOptions(
            for: source,
            reason: reason,
            password: passwords.password(sourceID: source.id, relativePath: relativePath),
            progress: progress
        )
    }

    /// What the plan already knows cannot be read. Run-stage failures
    /// are added to these — a file refused during scanning and a file refused
    /// while being read are the same thing to the person looking at the screen.
    static func plannedProblems(of plan: SyncPlan) -> [FileProblem] {
        plan.items.compactMap { item in
            guard case .skipped(let reason, let remedy) = item.kind else { return nil }
            return FileProblem(relativePath: item.relativePath, reason: reason, remedy: remedy)
        }
    }

    /// The wording a skipped file carries into the plan and the summary.
    public static func reason(for error: Error) -> String {
        if let extraction = error as? ExtractionError {
            return extraction.errorDescription ?? String(localized: "файл не удалось прочитать")
        }
        return error.localizedDescription
    }

    /// Auto metadata every chunk gets. Fixed by the spec so incremental sync can
    /// find a file's chunks again by `source_file`.
    public static let autoMetadataKeys = [
        DocumentOrigin.metadataKey,
        "source_id", "source_file", "file_id", "chunk_index", "content_hash",
        "file_ext", "file_mtime", "file_size",
    ]

    /// What extraction adds to every chunk. Kept apart from
    /// `autoMetadataKeys`, which is the fixed minimum incremental sync depends
    /// on: these describe where the text came from, not how to find it again.
    public static let extractionMetadataKeys = [
        "extractor_id", "extractor_version", "container_format", "structure_source",
        // язык и ключевые слова средствами системы. Здесь, а не
        // в `autoMetadataKeys`: инкрементальная синхронизация на них
        // не опирается, они описывают текст, а не способ его найти.
        "document_language", "language", "keywords",
    ]

    /// a manual sync above this many write-items shows the plan and waits
    /// for confirmation instead of running straight away (rule 4, Приложение 5).
    public static let defaultPreviewThresholdFiles = 100

    /// Turns the files marked into work — and only on purpose.
    ///
    /// The backup travels with the paths rather than beside them: this rewrites
    /// documents that were not broken, and «the caller promised to back up
    /// first» is not something a signature can check, while a value that can
    /// only come from `BackupService` is.
    public struct ReextractionRequest: Sendable {
        public let paths: Set<String>
        public let backup: BackupEvidence

        public init(paths: Set<String>, backup: BackupEvidence) {
            self.paths = paths
            self.backup = backup
        }
    }

    /// The same plan with the named unchanged files marked as work.
    static func forcing(_ paths: Set<String>, in plan: SyncPlan) -> SyncPlan {
        guard !paths.isEmpty else { return plan }
        let items = plan.items.map { item -> SyncPlanItem in
            guard item.kind == .unchanged, paths.contains(item.relativePath) else { return item }
            return SyncPlanItem(
                relativePath: item.relativePath, url: item.url,
                kind: .changed(reason: String(localized: "переизвлечение прежней версией экстрактора")),
                collectionName: item.collectionName, size: item.size, modifiedAt: item.modifiedAt,
                contentHash: item.contentHash, textLength: item.textLength,
                routeMetadata: item.routeMetadata
            )
        }
        // Переносится **всё**, кроме того, что этот вызов меняет намеренно.
        // Раньше поля перечислялись выборочно, и каждое новое поле плана
        // молча терялось при переизвлечении: так исчезала пометка о новом
        // уровне вложенности — уровень в папке оставался, а строка с карточки
        // пропадала.
        return SyncPlan(
            sourceID: plan.sourceID, sourceName: plan.sourceName, items: items,
            newlyMissing: plan.newlyMissing, pendingRemovals: plan.pendingRemovals,
            massDisappearance: plan.massDisappearance,
            // The list is kept as it was: a run that re-extracts part of it
            // should still report what is left.
            staleExtraction: plan.staleExtraction.filter { !paths.contains($0.relativePath) },
            tableRowsToEmbed: plan.tableRowsToEmbed,
            newFolderLevels: plan.newFolderLevels
        )
    }

    public func isRunning(sourceID: UUID) -> Bool { running.contains(sourceID) }

    public func manifest(for sourceID: UUID) -> SourceManifest { manifests.load(sourceID: sourceID) }

    public func removeManifest(for sourceID: UUID) { manifests.remove(sourceID: sourceID) }

    // MARK: - Переиндексация листа

    /// Что переиндексация должна убрать из базы.
    public struct SheetReindexTarget: Sendable {
        /// Коллекция берётся из манифеста **файла**, а не из источника:
        /// источник умеет раскладывать файлы по разным коллекциям (по
        /// подпапке, по правилу из пути), и его `collectionName` — только
        /// запасной вариант. Ошибиться здесь значит снести не то или не
        /// снести ничего, забыв при этом лист.
        public let collectionName: String
        public let documentIDs: [String]
    }

    /// Переиндексация листа: забыть его строки, чтобы прогон написал их заново.
    ///
    /// Держит источник занятым на всё время операции — тем же замком, что и
    /// прогон. Без этого автоматическая синхронизация, начавшаяся между
    /// «спросили список» и «забыли лист», писала бы манифест поверх и оставила
    /// бы в коллекции строки, о которых манифест уже не помнит.
    ///
    /// Удаление делает вызывающий: корзина и база живут в слое приложения,
    /// а манифест — здесь. Порядок закреплён самим устройством метода: сначала
    /// список, потом `removing`, и только после её успеха — забвение листа.
    @discardableResult
    public func reindexSheet(
        source: DataSource,
        relativePath: String,
        sheetName: String,
        removing: @Sendable (SheetReindexTarget) async throws -> Void
    ) async throws -> Int {
        guard !running.contains(source.id) else { throw SyncError.alreadyRunning(source.name) }
        running.insert(source.id)
        defer { running.remove(source.id) }

        var files = tableManifests.load(sourceID: source.id)
        guard let file = files[relativePath], let sheet = file.sheets[sheetName], sheet.rowCount > 0 else {
            return 0
        }
        try await removing(SheetReindexTarget(
            collectionName: file.collectionName, documentIDs: sheet.documentIDs
        ))

        var updated = file
        let forgotten = updated.forgetSheet(sheetName)
        files[relativePath] = updated
        tableManifests.save(files, sourceID: source.id)
        log(.warning, "Таблицы",
            "Лист «\(sheetName)» файла \(relativePath): забыт для переиндексации — строк \(forgotten.count.plainDigits), они будут записаны заново при следующей синхронизации")
        return forgotten.count
    }

    /// Что манифест помнит про листы файла — для экрана «Таблицы».
    ///
    /// Через службу, а не мимо неё: манифест принадлежит ей, и второй читатель
    /// со своим экземпляром хранилища рано или поздно прочитает его в момент
    /// записи.
    public func indexedSheets(sourceID: UUID, relativePath: String) -> [String: SheetManifest] {
        tableManifests.load(sourceID: sourceID)[relativePath]?.sheets ?? [:]
    }

    /// Записать манифест, изменённый снаружи.
    ///
    /// Нужно ровно для переноса чанков при переименовании: он меняет
    /// базу до запуска синхронизации, и манифест обязан догнать её сразу —
    /// прерванный на этом месте запуск не должен искать чанки по старому имени.
    public func save(manifest: SourceManifest) { manifests.save(manifest) }

    /// Снять находки диагностики с файлов источника.
    ///
    /// Одним обращением к актору, а не «прочитать снаружи, поправить,
    /// сохранить»: те два шага чередуются с чужими обращениями к манифесту —
    /// например, с записью соседнего решения по диагностике, — и тот, кто
    /// сохранит последним, затирает работу другого.
    ///
    /// Чего это **не** снимает: прогон синхронизации читает манифест в начале
    /// и сохраняет в конце, а между ними у него десятки `await`, на которых
    /// актор впускает других. Находка, снятая человеком посреди прогона,
    /// вернётся на экран вместе с итоговой записью прогона. Это цена
    /// реентерабельности актора, и лечится она не здесь, а тем, что прогон
    /// перестанет держать манифест через `await`.
    ///
    /// - Parameter paths: пути, находки о которых снимаются. `nil` — снять
    ///   все находки этого источника (красная кнопка «очистить»).
    /// - Returns: сколько находок снято.
    @discardableResult
    public func forgetProblems(_ paths: Set<String>?, sourceID: UUID) -> Int {
        var manifest = manifests.load(sourceID: sourceID)
        let before = manifest.problems.count
        if let paths {
            manifest.problems.removeAll { paths.contains($0.relativePath) }
        } else {
            manifest.problems.removeAll()
        }
        let removed = before - manifest.problems.count
        guard removed > 0 else { return 0 }
        manifests.save(manifest)
        return removed
    }

    // MARK: - Scanning

    public func scanFiles(source: DataSource) throws -> [URL] {
        let root = source.url
        // Том проверяется **до** обхода папки: пустая папка на чужом
        // диске неотличима от папки, из которой всё удалили, — а стоит эта
        // неотличимость восемь тысяч документов.
        switch SourceVolume.check(path: root.path, expected: source.volume, fileManager: fileManager) {
        case .missing:
            throw SyncError.folderMissing(root.path)
        case .changed(let expected, let found):
            log(.error, "Источники",
                "Источник «\(source.name)»: ожидался том «\(expected.title)», обнаружен «\(found?.title ?? "нет тома")» — сканирование не выполнялось")
            throw SyncError.volumeChanged(expected: expected.title, found: found?.title)
        case .ready:
            break
        }
        let wanted = Set(source.fileExtensions.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { throw SyncError.noExtensions }

        var files: [URL] = []
        if source.recursive {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            for case let url as URL in enumerator {
                guard wanted.contains(url.pathExtension.lowercased()) else { continue }
                if Self.isIndexableEntry(url) { files.append(url) }
            }
        } else {
            let contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            files = contents.filter {
                wanted.contains($0.pathExtension.lowercased()) && Self.isIndexableEntry($0)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Уровни вложенности папки источника — тем же обходом и теми же
    /// правилами, что и синхронизация.
    ///
    /// Именно теми же: редактор, показывающий уровни по одному списку файлов,
    /// и прогон, работающий по другому, рано или поздно разойдутся в том,
    /// сколько в папке уровней, — и правым в этом споре будет прогон, а
    /// объясняться придётся человеку.
    public func folderLevels(source: DataSource) throws -> FolderLevels {
        let files = try scanFiles(source: source)
        let excluded = Set(source.excludedPaths)
        let paths = files
            .map { Self.relative($0, to: source.url) }
            .filter { !excluded.contains($0) }
        return FolderLevels.of(paths: paths)
    }

    // MARK: - Plan

    /// Compares the folder with the manifest. Reads only the files that might
    /// have changed and never calls the embedding model, so it is safe to run
    /// just to look at what a sync would do.
    /// - Parameter allowMassRemovals: составлять список «требуют решения»
    ///   даже при массовой пропаже. Ставится только после того, как человек
    /// подтвердил, что файлы исчезли по-настоящему.
    public func plan(
        source: DataSource, embeddingModel: String, allowMassRemovals: Bool = false
    ) async throws -> SyncPlan {
        if source.mapping.needsRule,
           let problem = CollectionRouter.ruleProblem(pattern: source.rulePattern, template: source.ruleTemplate) {
            throw SyncError.ruleInvalid(problem)
        }

        let files = try scanFiles(source: source)
        let manifest = manifests.load(sourceID: source.id)
        let signature = source.chunking.signature
        let extractionSignature = source.extractionSignature
        // Только для выбора экстрактора: пароль сюда не нужен, а он стоит
        // похода в Keychain на каждый файл.
        let stampOptions = Self.extractionOptions(for: source)
        var items: [SyncPlanItem] = []
        var staleExtraction: [StaleExtraction] = []
        var seenPaths: Set<String> = []
        let tableFiles = tableManifests.load(sourceID: source.id)
        let currentProfilesSignature = TableSyncService.profilesSignature(tableProfiles(of: source))
        var tableRowsToEmbed = 0

        let excluded = Set(source.excludedPaths)
        // Один обход файловой системы на прогон: и размеры
        // со временем изменения, и ответ на вопрос «кто из них растёт прямо
        // сейчас». Раньше обходов было два, и второй спрашивал ровно то же,
        // что первый уже знал.
        let scan = await Self.scan(files, fileManager: fileManager)
        if !scan.growing.isEmpty {
            log(.info, "Источники",
                "Источник «\(source.name)»: файлов, которые пишутся прямо сейчас: \(scan.growing.count.plainDigits) — они будут прочитаны следующим прогоном")
        }
        for file in files {
            let relativePath = Self.relative(file, to: source.url)
            // Not added to `seenPaths`: from the source's point of view the file
            // is no longer there, so an entry left in the manifest becomes
            // «требует решения» rather than being quietly forgotten.
            if excluded.contains(relativePath) { continue }
            seenPaths.insert(relativePath)

            // Снимка нет — файл исчез между обходом папки и замером. Прежние
            // умолчания сохранены: ноль и «сейчас», то есть файл считается
            // изменившимся и уходит на чтение, где и выяснится, что его нет.
            let snapshot = scan.snapshots[file.path]
            let size = snapshot?.size ?? 0
            let modified = snapshot?.modifiedAt ?? Date()

            // Файл растёт прямо сейчас — читать его рано. Половина
            // документа с честным хэшем половины хуже, чем документ,
            // прочитанный следующим прогоном: она выглядит правдой.
            if scan.growing.contains(file.path) {
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file,
                    kind: .skipped(
                        reason: String(localized: "файл изменялся секунду назад — возможно, он ещё пишется; будет прочитан следующим прогоном"),
                        remedy: .retry
                    ),
                    collectionName: nil, size: size, modifiedAt: modified
                ))
                continue
            }

            // Файл из облака, которого нет на диске. Не скачиваем
            // молча: это чужой трафик и чужое место.
            if Self.needsDownloadFromCloud(file) {
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file,
                    kind: .skipped(
                        reason: String(localized: "файл хранится в облаке и не загружен на диск — откройте его в Finder («Загрузить сейчас») или отключите оптимизацию хранилища"),
                        remedy: .retry
                    ),
                    collectionName: nil, size: size, modifiedAt: modified
                ))
                continue
            }

            guard size <= source.maxFileSizeBytes else {
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file,
                    kind: .skipped(
                        // Предел назван вместе с тем, где его менять: раньше
                        // строка сообщала число, изменить которое было нельзя
                        // ничем.
                        reason: String(localized: "файл больше \(ByteCountFormatter.string(fromByteCount: source.maxFileSizeBytes, countStyle: .file)) — предел задан в настройках источника"),
                        remedy: .exclude
                    ),
                    collectionName: nil, size: size, modifiedAt: modified
                ))
                continue
            }

            let outcome = router.route(relativePath: relativePath, source: source)
            guard let route = outcome.route else {
                let reason: String
                if case .unroutable(let value) = outcome { reason = value } else { reason = "" }
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file, kind: .unroutable(reason: reason),
                    collectionName: nil, size: size, modifiedAt: modified
                ))
                continue
            }

            let entry = manifest.entries[relativePath]
            // a table is not text and never reaches the extractors. What
            // the plan decides here is only whether the file is worth opening —
            // which rows changed is decided per row, inside the table pipeline
            //.
            if TabularFormat.of(file) != nil {
                let known = tableFiles[relativePath]
                let untouched = known.map {
                    abs($0.modifiedAt.timeIntervalSince(modified)) < 1
                        && $0.size == size
                        && $0.profilesSignature == currentProfilesSignature
                } ?? false
                let kind: SyncItemKind
                if known == nil {
                    kind = .new
                } else if untouched {
                    kind = .unchanged
                } else if known?.profilesSignature != currentProfilesSignature {
                    kind = .changed(reason: String(localized: "изменился профиль сопоставления"))
                } else {
                    kind = .changed(reason: String(localized: "файл изменился"))
                }
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file, kind: kind,
                    collectionName: route.collectionName, size: size, modifiedAt: modified,
                    routeMetadata: route.extraMetadata
                ))
                // the price of a sheet cannot be guessed from its size,
                // so the plan counts the rows that would reach the model. Only
                // for files it already called work — and never for `.numbers`,
                // whose row count would cost raising the Numbers window.
                if kind.writesDocuments, TabularFormat.of(file) != .numbers {
                    tableRowsToEmbed += await countTableRows(
                        file: file, relativePath: relativePath, source: source,
                        collectionName: route.collectionName,
                        manifest: known ?? TableFileManifest(
                            relativePath: relativePath, collectionName: route.collectionName
                        )
                    )
                }
                continue
            }

            let recipeMatches = entry.map {
                $0.chunkingSignature == signature
                    && $0.embeddingModel == embeddingModel
                    && $0.collectionName == route.collectionName
                    // Empty means «written before extraction options existed» —
                    // unknown, not different, so an old entry is not re-indexed
                    // for a setting nobody has touched.
                    && ($0.extractionSignature.isEmpty || $0.extractionSignature == extractionSignature)
            } ?? false

            let recipeMismatch: String? = {
                guard let entry, !recipeMatches else { return nil }
                if entry.chunkingSignature != signature { return String(localized: "изменились параметры чанкинга") }
                if entry.embeddingModel != embeddingModel { return String(localized: "сменилась модель эмбеддинга") }
                if !entry.extractionSignature.isEmpty, entry.extractionSignature != extractionSignature {
                    return String(localized: "изменились параметры извлечения")
                }
                return String(localized: "сменилась коллекция назначения")
            }()
            let sizeMatches = entry?.size == size
            let timeMatches = entry.map { abs($0.modifiedAt.timeIntervalSince(modified)) < 1 } ?? false
            let currentExtractor = Self.stamp(
                of: file, storedID: entry?.extractorID ?? "",
                registry: registry, options: stampOptions
            )

            // Hashing the bytes is worth it only when the cheap signal already
            // says something moved: it answers «re-saved, or actually edited?»
            // for the price of one read, where being wrong costs an extraction
            // and a full re-embedding of the file.
            let fileHash: String? = (entry != nil && !(sizeMatches && timeMatches))
                ? Self.fileHash(of: file)
                : nil

            // Fast path: nothing about the file moved — do not open it. This is
            // what keeps a repeat sync of 10 000 files quick and, above all,
            // free of embedding calls.
            if let decision = SyncDecisionRules.decideUnread(
                entry: entry, sizeMatches: sizeMatches, timeMatches: timeMatches,
                fileHash: fileHash, recipeMismatch: recipeMismatch, current: currentExtractor
            ) {
                if case .needsReextraction(let previous) = decision {
                    staleExtraction.append(StaleExtraction(
                        relativePath: relativePath,
                        collectionName: entry?.collectionName ?? route.collectionName,
                        previous: previous,
                        current: currentExtractor
                    ))
                }
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file, kind: .unchanged,
                    collectionName: route.collectionName, size: size, modifiedAt: modified,
                    contentHash: entry?.contentHash, routeMetadata: route.extraMetadata,
                    refresh: decision == .touch
                        ? ManifestRefresh(fileHash: fileHash, modifiedAt: modified, size: size)
                        : nil
                ))
                continue
            }

            do {
                let extracted = try await registry.extract(
                    from: file, options: extractionOptions(for: source, relativePath: relativePath)
                )
                let text = extracted.plainText
                let hash = Self.contentHash(of: text)
                let stamp = ExtractorStamp(id: extracted.extractorID, version: extracted.extractorVersion)
                let decision = SyncDecisionRules.decideRead(
                    entry: entry, contentHash: hash, recipeMismatch: recipeMismatch
                )
                let kind: SyncItemKind
                var refresh: ManifestRefresh?
                switch decision {
                case .new:
                    kind = .new
                case .reindex(let reason):
                    kind = .changed(reason: reason)
                case .touch, .skip, .needsReextraction:
                    // Touched but not edited (a copy, a re-save) — the text is
                    // what matters, not the timestamp. The extractor that just
                    // produced this text is recorded with it: it demonstrably
                    // gives the same result, so there is nothing to re-extract.
                    kind = .unchanged
                    refresh = ManifestRefresh(
                        fileHash: fileHash ?? Self.fileHash(of: file),
                        contentHash: hash,
                        extractor: stamp,
                        modifiedAt: modified,
                        size: size
                    )
                }
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file, kind: kind,
                    collectionName: route.collectionName, size: size, modifiedAt: modified,
                    contentHash: hash, textLength: text.count, routeMetadata: route.extraMetadata,
                    refresh: refresh
                ))
            } catch {
                // Never a silent drop: every file the run cannot read says why,
                // in words the user can act on.
                items.append(SyncPlanItem(
                    relativePath: relativePath, url: file,
                    kind: .skipped(reason: Self.reason(for: error), remedy: FileProblem.remedy(for: error)),
                    collectionName: route.collectionName, size: size, modifiedAt: modified,
                    routeMetadata: route.extraMetadata
                ))
            }
        }

        // Gone from disk: reported, never deleted on our own initiative.
        var newlyMissing: [PendingRemoval] = []
        var pending = manifest.pendingRemovals
        // Вернулся на место — решать больше нечего. Список требующих
        // решения только пополнялся: файл возвращали на диск, запускали
        // синхронизацию, а плашка «файлы исчезли с диска» и весь список
        // оставались на экране до тех пор, пока по каждой строке не нажмут
        // «Оставить в базе» — то есть до ручной работы, которой уже не нужно.
        pending.removeAll { seenPaths.contains($0.relativePath) }

        // Сколько файлов манифеста не нашлось на диске — считается **до**
        // того, как из них составят список на удаление.
        let known = manifest.entries.values.filter { !$0.isOrphaned }.count
        let vanished = manifest.entries.filter { !seenPaths.contains($0.key) && !$0.value.isOrphaned }.count
        let disappearance = Self.massDisappearance(missing: vanished, known: known)

        // Массовая пропажа — и список не пополняется вовсе. Это и есть
        // защита: «требуют решения» на восемь тысяч строк подтверждают одним
        // нажатием, а список, которого нет, подтвердить нельзя.
        if disappearance == nil || allowMassRemovals {
            for (path, entry) in manifest.entries.sorted(by: { $0.key < $1.key })
            where !seenPaths.contains(path) && !entry.isOrphaned {
                let removal = PendingRemoval(
                    relativePath: path,
                    collectionName: entry.collectionName,
                    chunkIDs: entry.chunkIDs
                )
                if !pending.contains(where: { $0.relativePath == path }) {
                    pending.append(removal)
                    newlyMissing.append(removal)
                }
            }
        } else if let disappearance {
            log(.error, "Источники",
                "Источник «\(source.name)»: \(disappearance.summary) — список «требуют решения» не составлялся. Проверьте, тот ли диск подключён.")
        }

        if !staleExtraction.isEmpty {
            // Said once, in the plan and in the log; never turned into work.
            // An app update must not start hours of local model time by itself
            // (rule 1 of Приложение 5).
            log(.info, "Источники",
                "Источник «\(source.name)»: файлов, извлечённых прежней версией экстрактора: \(staleExtraction.count). Автоматически ничего не пересчитывается — операция «переизвлечь и переэмбедить» запускается вручную.")
        }

        // Уровень глубже названных. Считается по тем же путям, что
        // уже собраны для плана, — отдельного обхода папки это не стоит.
        // Сообщается и только: имя уровню даёт человек, а `level_4`,
        // придуманный приложением, — мусор в метаданных всей коллекции.
        let newLevels = FolderLevels.of(paths: Array(seenPaths))
            .unnamed(beyond: source.pathLevels.count)
        if let deepest = newLevels.first {
            log(.info, "Источники",
                "Источник «\(source.name)»: появился уровень вложенности \(deepest.number) (\(deepest.folderCount) папок) — поле для него не задано, названия папок в базу не попадают.")
        }

        return SyncPlan(
            sourceID: source.id,
            sourceName: source.name,
            items: items,
            newlyMissing: newlyMissing,
            pendingRemovals: pending,
            massDisappearance: disappearance,
            staleExtraction: staleExtraction,
            tableRowsToEmbed: tableRowsToEmbed,
            newFolderLevels: newLevels
        )
    }

    // MARK: - Schema hookup

    /// Which schema fields the source closes and which it leaves open.
    ///
    /// Static on purpose: auto fields and the source's own key-values are the
    /// same for every file, so the answer is known before the first byte is read
    /// and a mismatch can stop the run instead of surfacing halfway through.
    /// - Parameter levels: уровни папки, если их уже посчитали. Нужны
    ///   ради одного вопроса: поле уровня попадёт **каждому** чанку или только
    ///   тем файлам, что лежат достаточно глубоко. Без ответа поле обещанным
    ///   не считается — обещание, которое конвейер держит через раз, хуже
    ///   честного «не закрыто».
    public func coverage(
        source: DataSource, schema: MetadataSchema, levels: FolderLevels? = nil
    ) -> SourceSchemaCoverage {
        var provided = Set(Self.autoMetadataKeys)
        provided.formUnion(["file_name", "chunk_count", "chunk_estimated_tokens", "chunk_level"])
        // Written for every chunk of every file. `page_number`,
        // `heading_path` and the warnings are *not* here: they depend on what is
        // in the file, and a required schema field must not be satisfied by a
        // promise the pipeline can only sometimes keep.
        provided.formUnion(["extractor_id", "extractor_version", "container_format", "structure_source"])
        if source.chunking.strategy.producesLevels { provided.insert("parent_chunk_id") }
        provided.formUnion(source.customMetadata.keys.filter { !$0.isEmpty })
        provided.formUnion(Self.guaranteedLevelKeys(of: source, levels: levels))

        let uncovered = schema.fields
            .filter { $0.isRequired && !$0.trimmedKey.isEmpty }
            .filter { !provided.contains($0.trimmedKey) && $0.parsedDefault == nil }
            .map(\.trimmedKey)

        // Type check of the constant part of the metadata: a source that types
        // `year = «2024-13-45»` into a date field should hear about it now.
        var probe: ChromaMetadata = [:]
        for (key, value) in source.customMetadata where !key.isEmpty {
            probe[key] = .inferred(from: value)
        }
        var problems = validator.validate(probe, against: schema).violations
            .filter { $0.kind == .wrongType }
        problems.append(contentsOf: Self.levelTypeProblems(of: source, schema: schema))

        return SourceSchemaCoverage(
            collectionName: schema.collectionName,
            providedKeys: provided.sorted(),
            uncoveredRequiredFields: uncovered,
            typeProblems: problems
        )
    }

    /// Поля уровней, которые получит **каждый** чанк источника.
    ///
    /// Уровень со значением по умолчанию гарантирован всегда: файлу, который
    /// до уровня не достаёт, запишется это значение. Уровень без него —
    /// только когда посчитанное дерево говорит, что выше уровня файлов нет;
    /// не посчитали — значит не знаем, и обещать нечего.
    static func guaranteedLevelKeys(of source: DataSource, levels: FolderLevels?) -> Set<String> {
        var result: Set<String> = []
        for (index, level) in source.pathLevels.prefix(PathLevel.maximumLevels).enumerated() {
            guard level.isNamed else { continue }
            if level.parsedFallback != nil {
                result.insert(level.trimmedKey)
                continue
            }
            guard let known = levels?.levels.first(where: { $0.number == index + 1 }) else { continue }
            // Имя папки, не приводящееся к типу, — дырка в том же обещании:
            // такому файлу поле не запишется.
            if known.filesAbove == 0, known.namesNotMatching(level).isEmpty, !known.namesTruncated {
                result.insert(level.trimmedKey)
            }
        }
        return result
    }

    /// Уровень объявлен строкой, а схема ждёт от этого поля число: значения
    /// разойдутся с договором коллекции на каждом файле, и сказать об этом
    /// надо в редакторе, а не на сотом документе.
    static func levelTypeProblems(of source: DataSource, schema: MetadataSchema) -> [SchemaViolation] {
        source.pathLevels.compactMap { level in
            guard level.isNamed, let field = schema.field(for: level.trimmedKey) else { return nil }
            guard field.type != level.type else { return nil }
            return SchemaViolation(
                field: level.trimmedKey,
                kind: .wrongType,
                message: String(localized: "Уровень пути «\(level.trimmedKey)» объявлен как \(level.type.title), а схема коллекции ждёт \(field.type.title).")
            )
        }
    }

    // MARK: - Обновление метаданных без пересчёта векторов

    /// Что дало обновление полей у уже проиндексированных файлов.
    public struct MetadataRefreshReport: Sendable {
        public var filesUpdated = 0
        public var chunksUpdated = 0
        public var keysRemoved: [String] = []
        public var failures: [(file: String, reason: String)] = []

        public var isEmpty: Bool { filesUpdated == 0 && failures.isEmpty }
    }

    /// Файлы, у которых поля в базе записаны прежними настройками.
    ///
    /// Пустая подпись — запись прежней сборки: чем она записана, неизвестно.
    /// Такие файлы попадают в список только когда источник **пользуется**
    /// полями из пути: иначе обновление предлагалось бы каждому источнику
    /// после первого же обновления приложения, а менять там нечего.
    public func filesWithOutdatedMetadata(in manifest: SourceManifest, source: DataSource) -> [String] {
        let current = source.metadataSignature
        return manifest.entries.values
            .filter { entry in
                if entry.metadataSignature.isEmpty {
                    return !source.pathLevels.filter(\.isNamed).isEmpty
                }
                return entry.metadataSignature != current
            }
            .map(\.relativePath)
            .sorted()
    }

    public func filesWithOutdatedMetadata(source: DataSource) -> [String] {
        filesWithOutdatedMetadata(in: manifests.load(sourceID: source.id), source: source)
    }

    /// Переписывает поля уже проиндексированных чанков — и только их.
    ///
    /// Ни одного обращения к модели: текст файлов не менялся, изменились
    /// подписи к нему. Поэтому же операция отдельная, а не «переиндексируйте
    /// источник»: у папки на пять тысяч документов это разница между минутой
    /// и половиной суток.
    ///
    /// Ключи, которые источник больше не пишет, убираются явно: `update`
    /// у ChromaDB метаданные **сливает**, и поле, выброшенное из настроек,
    /// осталось бы в базе навсегда.
    ///
    /// - Parameter backup: доказательство, что копия сделана. Значение,
    ///   которое нельзя получить иначе как у `BackupService`: это перезапись
    ///   документов, которые никто не ломал (правила 8.7).
    @discardableResult
    public func refreshMetadata(
        source: DataSource,
        chroma: any SyncDatabase,
        backup: BackupEvidence,
        paths: Set<String>? = nil,
        progress: @Sendable (SyncProgress) -> Void = { _ in }
    ) async throws -> MetadataRefreshReport {
        // Тот же замок, что у синхронизации, и по той же причине: обе операции
        // читают манифест целиком, ждут на `await` и сохраняют свою копию.
        // Прогон, начавшийся посередине обновления полей, потерял бы записи
        // о только что проиндексированных файлах — вместе с их `chunkIDs`,
        // то есть и с возможностью убрать их прежние чанки.
        guard !running.contains(source.id) else { throw SyncError.alreadyRunning(source.name) }
        running.insert(source.id)
        defer { running.remove(source.id) }

        var manifest = manifests.load(sourceID: source.id)
        let outdated = Set(filesWithOutdatedMetadata(in: manifest, source: source))
        let wanted = paths.map { outdated.intersection($0) } ?? outdated
        var report = MetadataRefreshReport()
        guard !wanted.isEmpty else { return report }

        log(.info, "Источники",
            "Источник «\(source.name)»: обновляем поля у \(wanted.count.plainDigits) файлов без пересчёта векторов. \(backup.describedAs)")

        let signature = source.metadataSignature
        let currentKeys = source.writtenMetadataKeys
        var collectionIDs: [String: String] = [:]
        var removedKeys: Set<String> = []
        var done = 0

        for relativePath in wanted.sorted() {
            // Отмена спрашивается у себя, а не ожидается от клиента базы:
            // «Остановить» на пяти тысячах файлов должно останавливать, даже
            // когда каждый вызов возвращается мгновенно и бросить ему нечего.
            do {
                try Task.checkCancellation()
            } catch {
                manifests.save(manifest)
                throw CancellationError()
            }
            guard let entry = manifest.entries[relativePath] else { continue }
            done += 1
            progress(SyncProgress(
                stage: String(localized: "Обновление полей"),
                processedFiles: done, totalFiles: wanted.count, currentFile: relativePath
            ))
            guard !entry.chunkIDs.isEmpty else {
                // Записи без списка чанков остались от сборок до A6.2: искать
                // их в базе по фильтру ради полей — дороже, чем честно сказать.
                report.failures.append((file: relativePath, reason: String(localized: "у файла не записаны идентификаторы чанков — обновите его обычной синхронизацией")))
                continue
            }
            guard let route = router.route(relativePath: relativePath, source: source).route else {
                report.failures.append((file: relativePath, reason: String(localized: "файл не размещается нынешним правилом маппинга")))
                continue
            }

            var fields = route.extraMetadata
            for (key, value) in source.customMetadata where !key.isEmpty {
                fields[key] = .inferred(from: value)
            }
            // Убирается то, что писалось прежними настройками и не пишется
            // сейчас. Плюс поля, которых у этого файла не оказалось: уровень
            // мог перестать доставать до него.
            var removed = MetadataSignature(entry.metadataSignature).writtenKeys
            removed.formUnion(currentKeys)
            removed.subtract(fields.keys)
            // `relative_path` новым чанкам больше не пишется, но из
            // старых не выковыривается: по нему могли быть построены
            // сохранённые фильтры и внешние запросы. Обновление полей — не
            // повод ломать их у половины файлов.
            removed.remove("relative_path")
            removedKeys.formUnion(removed)

            do {
                let collectionID: String
                if let known = collectionIDs[entry.collectionName] {
                    collectionID = known
                } else {
                    collectionID = try await chroma.resolveID(of: entry.collectionName)
                    collectionIDs[entry.collectionName] = collectionID
                }
                try await chroma.updateDocuments(
                    collectionID: collectionID,
                    updates: entry.chunkIDs.map {
                        DocumentUpdate(id: $0, metadata: fields, removedMetadataKeys: removed.sorted())
                    }
                )
                var updated = entry
                updated.metadataSignature = signature
                manifest.entries[relativePath] = updated
                report.filesUpdated += 1
                report.chunksUpdated += entry.chunkIDs.count
                // Манифест пишется по ходу, а не в конце: прерванная операция
                // должна оставить сделанное сделанным, иначе повтор пойдёт
                // по второму кругу через всю папку.
                if report.filesUpdated % 50 == 0 { manifests.save(manifest) }
            } catch is CancellationError {
                manifests.save(manifest)
                throw CancellationError()
            } catch {
                report.failures.append((file: relativePath, reason: Self.reason(for: error)))
            }
        }

        manifests.save(manifest)
        report.keysRemoved = removedKeys.sorted()
        log(report.failures.isEmpty ? .success : .warning, "Источники",
            "Источник «\(source.name)»: поля обновлены у \(report.filesUpdated.plainDigits) файлов (\(report.chunksUpdated.plainDigits) чанков), не вышло у \(report.failures.count.plainDigits); векторы не пересчитывались")
        return report
    }

    // MARK: - Recovery

    /// What an interrupted previous run left behind, and what was done about it.
    public struct SyncRecovery: Sendable {
        /// Files finished off without recomputing a single vector.
        public var finished: [String] = []
        /// Files that have to be re-indexed: the run died before we could know
        /// how much of the write landed.
        public var toReindex: [String] = []
        public var failures: [(file: String, reason: String)] = []

        public var isEmpty: Bool { finished.isEmpty && toReindex.isEmpty && failures.isEmpty }
        public var handledCount: Int { finished.count + toReindex.count }
    }

    /// Files an earlier run left in flight. Empty in normal operation.
    public func pendingRecovery(sourceID: UUID) -> [SyncJournalEntry] {
        journal.pending(sourceID: sourceID)
    }

    /// Automatic modes stay away from a source whose recovery failed, until a
    /// person does something about it.
    public func recoveryBlockReason(sourceID: UUID) -> String? {
        journal.blockReason(sourceID: sourceID)
    }

    /// Replays an interrupted run. Called before every sync of the source, and
    /// callable on its own so the interface can report it at launch.
    ///
    /// Recovery never guesses: what it does is decided by the state the journal
    /// recorded, and each state has exactly one safe continuation.
    @discardableResult
    public func recover(source: DataSource, chroma: any SyncDatabase) async -> SyncRecovery {
        var report = SyncRecovery()
        let pending = journal.pending(sourceID: source.id)
        guard !pending.isEmpty else {
            journal.unblock(sourceID: source.id)
            return report
        }

        var manifest = manifests.load(sourceID: source.id)
        var collectionIDs: [String: String] = [:]

        for entry in pending {
            do {
                switch entry.state {
                case .done:
                    continue

                case .started:
                    // The write may have landed in part; nothing tells us how
                    // much. Both id sets are remembered so the next run's tail
                    // cleanup covers whatever got through, and the content hash
                    // is cleared so that run definitely happens — even if the
                    // file on disk has not changed since.
                    var restored = entry.manifestEntry()
                    restored.chunkIDs = Array(Set(entry.oldIDs + entry.newIDs)).sorted()
                    // Everything the planner uses to decide «unchanged» is
                    // invalidated, including the size-and-mtime fast path: the
                    // file itself may well be untouched, and the re-index has
                    // to happen anyway. The **file hash** belongs in this list
                    // too — made it a way to answer «unchanged» on its
                    // own, and leaving it behind let a recovered file decide it
                    // was current because its bytes still matched.
                    restored.contentHash = ""
                    restored.fileHash = ""
                    restored.size = -1
                    restored.modifiedAt = .distantPast
                    manifest.record(restored)
                    report.toReindex.append(entry.relativePath)

                case .upserted:
                    // New chunks are in. Finish the tail and the manifest —
                    // no text, no chunking, no embeddings needed.
                    let tail = entry.tailIDs
                    if !tail.isEmpty {
                        let id = try await collectionID(
                            for: entry.collectionName, cache: &collectionIDs, chroma: chroma
                        )
                        try await chroma.deleteDocuments(collectionID: id, ids: tail)
                    }
                    manifest.record(entry.manifestEntry())
                    report.finished.append(entry.relativePath)

                case .cleaned:
                    manifest.record(entry.manifestEntry())
                    report.finished.append(entry.relativePath)
                }
                manifests.save(manifest)
                try journal.finish(sourceID: source.id, relativePath: entry.relativePath)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                report.failures.append((entry.relativePath, reason))
            }
        }

        if let failure = report.failures.first {
            let reason = String(localized: "не удалось доиграть \(failure.file): \(failure.reason)")
            journal.block(sourceID: source.id, reason: reason)
            log(.error, "Источники", "Источник «\(source.name)»: \(reason). Автоматическая индексация приостановлена до ручного запуска.")
        } else {
            journal.unblock(sourceID: source.id)
            if !report.isEmpty {
                log(.warning, "Источники", "Источник «\(source.name)»: восстановлено после незавершённого прогона — доиграно файлов \(report.finished.count), будет переиндексировано \(report.toReindex.count)")
            }
        }
        return report
    }

    /// Resolves a collection name once per sync, not once per file.
    private func collectionID(
        for name: String,
        cache: inout [String: String],
        chroma: any SyncDatabase
    ) async throws -> String {
        if let cached = cache[name] { return cached }
        let resolved = try await chroma.resolveID(of: name)
        cache[name] = resolved
        return resolved
    }

    // MARK: - Sync

    /// Applies a plan: writes new and changed files, leaves the rest alone.
    ///
    /// - Parameter schemas: metadata schemas by collection name. Documents from a
    ///   source go through the same validator as hand-typed ones.
    public func sync(
        source: DataSource,
        embeddingModel: String,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider,
        binding: ModelBindingService,
        chat: ChatProvider? = nil,
        schemas: [String: MetadataSchema] = [:],
        batchSize: Int = 32,
        /// Context of the embedding model, when it is known. A chunk that does
        /// not fit is not sent: LM Studio would answer 200 and embed only its
        /// beginning.
        contextLength: Int? = nil,
        /// files the user unchecked in the plan before confirming — reported
        /// as skipped, never silently dropped (rule 2, Приложение 5).
        excludedPaths: Set<String> = [],
        /// re-extract files that did not change, because the extractor
        /// did. Never set by an automatic run — the request carries the backup
        /// that rule 5 of Приложение 5 requires before rewriting documents that
        /// were perfectly fine.
        reextraction: ReextractionRequest? = nil,
        /// a trial run writes only the first rows of each sheet, so the
        /// template and the column roles can be judged before the whole sheet is
        /// paid for.
        tableRowLimit: Int? = nil,
        /// raising Pages or Keynote is fine when a person pressed the
        /// button and unwanted when a timer did. The run has to know which it is.
        reason: SyncReason = .manual,
        /// у веб-источника план строит обход, а не обход папки. Всё
        /// остальное — журнал, манифест, чанкинг, запись — идёт тем же путём,
        /// что и для файлов: два разных пути записи в базу разошлись бы через
        /// месяц, и разошлись бы молча.
        preparedPlan: SyncPlan? = nil,
        /// человек подтвердил, что файлы действительно исчезли, а не
        /// диск отключён. Без этого прогон, увидевший массовую пропажу,
        /// не начинается вовсе — и списка на удаление не составляет.
        confirmedMassRemoval: Bool = false,
        /// Called between embedding batches so a more important task can take
        /// the model. Between batches and not between files: a batch can
        /// take up to 300 s by A8.1, and that is the honest upper bound on how
        /// long a search waits.
        yield: (@Sendable () async -> Void)? = nil,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) async throws -> SyncSummary {
        guard !running.contains(source.id) else { throw SyncError.alreadyRunning(source.name) }
        running.insert(source.id)
        defer { running.remove(source.id) }

        if let problem = source.chunking.problem {
            throw SyncError.chunkingMisconfigured(problem)
        }

        // До первого файла, а не на первом файле. Контекст, с которым
        // модель загружена в LM Studio, — не свойство модели и не настройка
        // приложения: он меняется без ведома обоих. Раньше о том, что окно
        // не помещается, говорила либо строка в журнале, либо ошибка изнутри
        // прогона — то есть уже после того, как человек нажал кнопку и ушёл.
        if source.chunking.strategy == .llmBased,
           let chat, let chatModel = source.chunking.chatModel, !chatModel.isEmpty {
            progress(SyncProgress(stage: String(localized: "Проверка контекста модели")))
            let check = await LLMChunker.contextCheck(
                configuration: source.chunking, model: chatModel, chat: chat
            )
            guard check.fits else { throw SyncError.chunkingWindowTooSmall(check) }
            if check.isReduced { log(.warning, "Чанкинг", check.summary) }
        }

        let started = Date()

        // Before anything else: a run that did not finish last time is finished
        // now. Doing this after planning would plan against a manifest that is
        // knowingly behind the database.
        progress(SyncProgress(stage: String(localized: "Проверка журнала")))
        let recovery = await recover(source: source, chroma: chroma)
        if let failure = recovery.failures.first {
            throw SyncError.recoveryFailed(file: failure.file, reason: failure.reason)
        }

        progress(SyncProgress(stage: String(localized: "Сравнение с манифестом")))

        var plan: SyncPlan
        // Уровни вложенности считает только наш план: у git- и
        // веб-источника его готовит своя служба, и её пустой список — это
        // «не считали», а не «уровней нет». Флаг живёт рядом с планом и
        // меняется вместе с ним: план ниже бывает пересчитан нашим кодом.
        var countsFolderLevels = preparedPlan == nil
        if let preparedPlan {
            plan = preparedPlan
        } else {
            plan = try await self.plan(source: source, embeddingModel: embeddingModel)
        }
        // Массовая пропажа — стоп до первой записи. Именно здесь,
        // а не в плане: план обязан её показать, а решает человек.
        if let disappearance = plan.massDisappearance {
            guard confirmedMassRemoval else {
                log(.error, "Источники",
                    "Источник «\(source.name)»: прогон остановлен — \(disappearance.summary)")
                throw SyncError.massDisappearance(missing: disappearance.missing, known: disappearance.known)
            }
            // Подтверждено — план пересчитывается со списком пропавших:
            // тот, что был на руках, составлялся без него намеренно.
            log(.warning, "Источники",
                "Источник «\(source.name)»: массовое исчезновение подтверждено человеком — \(disappearance.summary), файлы уходят в «требуют решения»")
            plan = try await self.plan(
                source: source, embeddingModel: embeddingModel, allowMassRemovals: true
            )
            countsFolderLevels = true
        }
        if let reextraction {
            log(.info, "Источники",
                "Переизвлечение источника «\(source.name)»: файлов \(reextraction.paths.count), бэкап — \(reextraction.backup.describedAs)")
            plan = Self.forcing(reextraction.paths, in: plan)
        }
        // excluded files are simply not in the list this run works from —
        // everything downstream (targetCollections stays as the plan computed
        // it, so a collection an excluded file alone would have needed is
        // still prepared; harmless, since `createCollection` is idempotent).
        let writeItems = plan.writeItems.filter { !excludedPaths.contains($0.relativePath) }
        var manifest = manifests.load(sourceID: source.id)
        manifest.pendingRemovals = plan.pendingRemovals

        // Files that moved on disk without their text changing: the manifest
        // learns the new bytes, the vectors are left alone. Applied
        // here rather than at the end because the commonest run of all — the
        // one with nothing to write — returns long before the end, and that is
        // exactly the run where re-saved files are waiting to be recorded.
        // Safe this early: these are files nothing is going to write.
        var refreshed = 0
        for item in plan.items where item.refresh != nil && !item.kind.writesDocuments {
            guard let entry = manifest.entries[item.relativePath], let refresh = item.refresh else { continue }
            manifest.entries[item.relativePath] = entry.applying(refresh)
            refreshed += 1
        }
        if refreshed > 0 {
            log(.debug, "Источники", "Файлов пересохранено без изменения текста: \(refreshed) — векторы не пересчитывались")
        }

        // Save at once: what disappeared from disk must survive a cancelled run.
        manifests.save(manifest)

        // Schema hookup, before anything is written.
        var attentionNote: [String: String] = [:]
        for collectionName in plan.targetCollections {
            guard let schema = schemas[collectionName], !schema.isEmpty else { continue }
            let report = coverage(source: source, schema: schema)
            if let problem = report.typeProblems.first {
                throw SyncError.schemaConflict(collection: collectionName, message: problem.message)
            }
            guard !report.uncoveredRequiredFields.isEmpty else { continue }
            switch source.unresolvedSchemaPolicy {
            case .block:
                throw SyncError.schemaNotCovered(collection: collectionName, fields: report.uncoveredRequiredFields)
            case .markAttention:
                attentionNote[collectionName] = String(localized: "схема: не закрыты поля \(report.uncoveredRequiredFields.joined(separator: ", "))")
                log(.warning, "Источники", "Коллекция «\(collectionName)»: источник не закрывает поля \(report.uncoveredRequiredFields.joined(separator: ", ")) — документы помечаются как требующие внимания")
            }
        }

        guard !writeItems.isEmpty else {
            let excludedSkips: [(file: String, reason: String)] = plan.writeItems
                .filter { excludedPaths.contains($0.relativePath) }
                .map { ($0.relativePath, String(localized: "исключён вручную из плана")) }
            let summary = SyncSummary(
                sourceName: source.name, added: 0, updated: 0, unchanged: plan.unchangedCount,
                chunksWritten: 0, chunksDeleted: 0,
                skipped: plan.items.compactMap { item in
                    guard let reason = item.kind.detail, !item.kind.writesDocuments, item.kind != .unchanged else { return nil }
                    return (item.relativePath, reason)
                } + excludedSkips,
                needsDecision: plan.pendingRemovals, markedForAttention: [],
                collections: manifest.collections, duration: Date().timeIntervalSince(started),
                embeddingModel: embeddingModel, dimension: nil,
                recoveredFiles: recovery.finished.count,
                reindexedAfterFailure: recovery.toReindex.count,
                staleExtraction: plan.staleExtraction,
                newFolderLevels: plan.newFolderLevels
            )
            // The skipped files belong in this line too. Without them a run that
            // read nothing because every file was refused looked identical to a
            // run where nothing had changed — and the reasons were only visible
            // on screen, never in the log.
            let skippedNote = summary.skipped.isEmpty
                ? ""
                : String(localized: ", пропущено \(summary.skipped.count)")
            log(.info, "Источники", "Источник «\(source.name)»: изменений нет (файлов без изменений \(plan.unchangedCount)\(skippedNote))\(summary.staleExtractionLine.map { "; " + $0 } ?? "")")
            for item in summary.skipped {
                log(.warning, "Источники", "Пропущен \(item.file): \(item.reason)")
            }
            // Even a run that wrote nothing has learned which files it cannot
            // read; that is exactly what the diagnostics screen is for.
            manifest.problems = Self.plannedProblems(of: plan)
            // Уровень, появившийся в папке, переживает перезапуск приложения:
            // он замечен прогоном, а решать по нему человеку — может быть,
            // завтра. Пометка обновляется только когда план считали
            // здесь: у git- и веб-источника план готовит своя служба, уровней
            // не считает вовсе, и присвоение пустого списка стирало бы то,
            // что заметил предыдущий прогон.
            if countsFolderLevels { manifest.newFolderLevels = plan.newFolderLevels }
            manifests.save(manifest)
            return summary
        }

        // One probe, before any collection is created: a wrong dimension must be
        // caught by us rather than by the server on the first write.
        let dimension = try await binding.dimension(of: embeddingModel, lmStudio: embeddings)

        var collectionIDs: [String: String] = [:]
        var heterogeneous: [String] = []
        for name in plan.targetCollections {
            progress(SyncProgress(stage: String(localized: "Подготовка коллекции «\(name)»")))
            let collection = try await chroma.createCollection(
                name: name,
                metadata: [
                    CollectionBindingKeys.model: .string(embeddingModel),
                    CollectionBindingKeys.dimension: .int(dimension),
                    CollectionBindingKeys.chunkingStrategy: .string(source.chunking.strategy.rawValue),
                    CollectionBindingKeys.strategyParamsHash: StrategyParamsHash.of(source.chunking).value,
                    "_cdbm_source_name": .string(source.name),
                ],
                // A collection a source creates gets the same metric as one
                // created by hand: the server's `l2` default is wrong for the
                // models this app works with.
                configuration: CollectionConfiguration(metric: source.metric),
                getOrCreate: true
            )
            try await binding.validate(vectorLength: dimension, for: collection)
            collectionIDs[name] = collection.id
            if try await isHeterogeneous(collection, chunking: source.chunking, chroma: chroma) {
                heterogeneous.append(name)
            }
        }

        // One pipeline for every strategy, including the ones that call a model
        // while chunking. The test bench uses the same one, so a preview cannot
        // disagree with a real run.
        let pipeline = ChunkingPipeline(
            configuration: source.chunking,
            embeddings: embeddings,
            chat: chat,
            embeddingModel: embeddingModel,
            log: log
        )
        // The same sizes and separators, only without the structural strategy.
        let ocrPipeline = ChunkingPipeline(
            configuration: Self.recursiveEquivalent(of: source.chunking),
            embeddings: embeddings,
            chat: chat,
            embeddingModel: embeddingModel,
            log: log
        )
        // Контекстное обогащение чат-моделью — только если его
        // включили **и** есть чем: без модели опция молчит, а не притворяется
        // работающей.
        // Та же модель, что назвал экран: пустая строка равна «не выбрана»,
        // и решается это в одном месте (`resolvedEnrichmentModel`).
        let enrichmentModel = source.chunking.resolvedEnrichmentModel
        let enrichment: ContextEnricher? = {
            guard source.chunking.contextEnrichment,
                  let chat, let model = enrichmentModel, !model.isEmpty else { return nil }
            return ContextEnricher(model: model, log: log) { prompt, model in
                try await chat.complete(
                    prompt: prompt, model: model,
                    settings: ChatGenerationSettings(),
                    schema: nil,
                    timeout: ContextEnricher.timeout
                )
            }
        }()
        if source.chunking.contextEnrichment && enrichment == nil {
            log(.warning, "Чанкинг",
                "Обогащение контекстом включено, но чат-модель не выбрана — фрагменты уйдут в эмбеддинг без контекста")
        }

        let signature = source.chunking.signature
        var added = 0
        var updated = 0
        var chunksWritten = 0
        var chunksDeleted = 0
        var marked: [String] = []
        var substituted: [(file: String, reason: String)] = []
        /// Сколько чанков пришлось дорезать под контекст модели.
        var chunksSplitToFit = 0
        // Сколько знаков модель читает **на самом деле**.
        // Мерится пробой и не совпадает с контекстом в токенах: живой случай —
        // контекст 8192 токена при пределе 2937 знаков. Меряется лениво и
        // один раз: проба стоит семи вызовов модели, и обычный прогон, где
        // длинных чанков нет, не платит за неё ничего.
        var measuredInputLimit: Int?
        var inputLimitMeasured = false
        var skipped: [(file: String, reason: String)] = plan.items.compactMap { item in
            guard let reason = item.kind.detail, !item.kind.writesDocuments else { return nil }
            return (item.relativePath, reason)
        }
        for item in plan.writeItems where excludedPaths.contains(item.relativePath) {
            skipped.append((item.relativePath, String(localized: "исключён вручную из плана")))
        }
        // Excluded by hand for one run is a choice, not a problem: it does not
        // reach the diagnostics screen.
        var runProblems = Self.plannedProblems(of: plan)
        var tableFiles = tableManifests.load(sourceID: source.id)
        /// Оговорки табличного конвейера за весь прогон.
        var tableWarnings: [String] = []

        for (index, item) in writeItems.enumerated() {
            if Task.isCancelled {
                manifests.save(manifest)
                throw SyncError.cancelled
            }
            guard let collectionName = item.collectionName,
                  let collectionID = collectionIDs[collectionName] else { continue }

            progress(SyncProgress(
                stage: String(localized: "Чтение и чанкинг"),
                processedFiles: index, totalFiles: writeItems.count,
                chunksWritten: chunksWritten, currentFile: item.relativePath
            ))

            // a table goes to its own pipeline, which writes rows rather
            // than chunks and keeps its own row-level manifest.
            if TabularFormat.of(item.url) != nil {
                do {
                    let read = try await TableSyncService.read(
                        url: item.url,
                        allowApplicationExport: source.numbersExportEnabled && !reason.isAutomatic
                    )
                    defer { read.temporary.map { try? fileManager.removeItem(at: $0) } }
                    // Оговорки читалки — предел в 200 000 строк, формулы без
                    // сохранённого значения, фантомные даты — раньше не доходили
                    // никуда: из прочитанного брались только листы.
                    // Файл, сохранённый без пересчёта формул, индексировался
                    // пустыми значениями молча.
                    for warning in read.warnings {
                        tableWarnings.append("\(item.relativePath): \(warning)")
                        log(.warning, "Таблицы", "Файл \(item.relativePath): \(warning)")
                    }

                    var fileManifest = tableFiles[item.relativePath]
                        ?? TableFileManifest(relativePath: item.relativePath, collectionName: collectionName)
                    let report = try await tables.sync(
                        sheets: read.sheets,
                        manifest: &fileManifest,
                        context: TableSyncService.Context(
                            sourceID: source.id,
                            relativePath: item.relativePath,
                            collectionID: collectionID,
                            collectionName: collectionName,
                            embeddingModel: embeddingModel,
                            dimension: dimension,
                            profiles: tableProfiles(of: source),
                            // Профиль, назначенный этому файлу вручную.
                            assignedProfileID: source.tableProfileAssignments[item.relativePath],
                            rowLimit: tableRowLimit,
                            batchSize: batchSize,
                            // Тот же предел, что и для файлов: строка таблицы —
                            // такой же документ, и режется молча так же.
                            contextLength: contextLength,
                            // A «документ» sheet is cut by the source's own
                            // strategy — the table pipeline does not get to
                            // invent one.
                            chunker: { text in
                                try await pipeline.chunks(from: text, fileExtension: "md")
                            }
                        ),
                        chroma: chroma,
                        embeddings: embeddings
                    )
                    fileManifest.modifiedAt = item.modifiedAt
                    fileManifest.size = item.size
                    tableFiles[item.relativePath] = fileManifest
                    tableManifests.save(tableFiles, sourceID: source.id)

                    chunksWritten += report.rowsWritten
                    if report.rowsAdded > 0 || report.rowsReembedded > 0 || report.rowsMetadataOnly > 0 {
                        if case .new = item.kind { added += 1 } else { updated += 1 }
                    }
                    // Отчёт таблиц — в сводку прогона, а не в переменную,
                    // которую никто не читает.
                    tableWarnings.append(contentsOf: report.warnings.map { "\(item.relativePath): \($0)" })
                    for sheetName in report.sheetsNeedingReindex {
                        tableWarnings.append(String(localized: "\(item.relativePath) → \(sheetName): сопоставление изменилось — сам лист не пересчитывается. Переиндексация листа есть на экране «Таблицы» отдельной кнопкой: строки уйдут в корзину, а запишутся заново следующей синхронизацией"))
                    }
                    // Повторы ключа — пропущенные строки, и место им там же,
                    // где пропущенным файлам. Молча их пропускать
                    // нельзя: человек видит «добавлено 900» при 1000 строк
                    // в файле и не знает, где делись сто.
                    for (sheetName, groups) in report.duplicates {
                        let rows = groups.reduce(0) { $0 + $1.skipped.count }
                        let examples = groups.prefix(5).map(\.line).joined(separator: "; ")
                        let tail = groups.count > 5 ? String(localized: " и ещё \(groups.count - 5)") : ""
                        skipped.append((
                            "\(item.relativePath) → \(sheetName)",
                            String(localized: "строк-повторов не записано \(rows): \(examples)\(tail). Записана первая строка из каждой группы; выберите другую ключевую колонку или уберите повторы в файле")
                        ))
                    }
                    for problem in report.problems {
                        skipped.append((
                            "\(item.relativePath) → \(problem.sheetName)", problem.reason
                        ))
                        runProblems.append(FileProblem(
                            relativePath: "\(item.relativePath) → \(problem.sheetName)",
                            reason: problem.reason,
                            remedy: .retry
                        ))
                    }
                    log(.info, "Таблицы", "Файл \(item.relativePath): \(report.line)")
                } catch {
                    skipped.append((item.relativePath, Self.reason(for: error)))
                    runProblems.append(FileProblem(
                        relativePath: item.relativePath,
                        reason: Self.reason(for: error),
                        remedy: FileProblem.remedy(for: error)
                    ))
                }
                progress(SyncProgress(
                    stage: String(localized: "Таблицы"),
                    processedFiles: index + 1, totalFiles: writeItems.count,
                    chunksWritten: chunksWritten, currentFile: item.relativePath
                ))
                continue
            }

            // Re-read here rather than carrying every file's text in the plan:
            // a folder of a few thousand documents would otherwise sit in memory
            // all at once, and reading a file again is cheap next to embedding it.
            let extracted: ExtractedDocument
            do {
                // A scan of two hundred pages is minutes of work; the queue has
                // to be able to say which page it is on.
                let relativePath = item.relativePath
                let processed = index
                let total = writeItems.count
                let written = chunksWritten
                extracted = try await registry.extract(
                    from: item.url,
                    options: extractionOptions(for: source, relativePath: item.relativePath, reason: reason) { update in
                        progress(SyncProgress(
                            stage: String(localized: "Извлечение — \(update.text)"),
                            processedFiles: processed, totalFiles: total,
                            chunksWritten: written, currentFile: relativePath
                        ))
                    }
                )
            } catch {
                // One bad file does not take the batch down with it.
                skipped.append((item.relativePath, Self.reason(for: error)))
                runProblems.append(FileProblem(
                    relativePath: item.relativePath,
                    reason: Self.reason(for: error),
                    remedy: FileProblem.remedy(for: error)
                ))
                continue
            }
            let text = extracted.plainText
            let hash = Self.contentHash(of: text)
            let chunkingStarted = Date()
            // Подмена стратегии учитывается на месте: иначе о ней узнают
            // только раскрыв чанк в списке документов.
            if let swap = Self.substitution(for: source.chunking, document: extracted) {
                substituted.append((item.relativePath, swap.note))
            }
            var chunks = try await Self.plannedChunks(
                of: extracted,
                fileExtension: item.url.pathExtension,
                pipeline: pipeline,
                ocrPipeline: ocrPipeline,
                configuration: source.chunking
            )
            // Подмена, случившаяся **во время** нарезки, а не при планировании:
            // чат-модель ответила не по формату, и границы определил Recursive.
            // Об этом говорил только журнал, то есть практически никто.
            if chunks.contains(where: { $0.note == LLMChunker.recursiveFallbackNote }) {
                substituted.append((item.relativePath, LLMChunker.recursiveFallbackNote))
            }
            // Timings come from real runs — the statistics screen must not show
            // numbers somebody guessed.
            await metrics?.recordChunking(
                strategy: source.chunking.strategy,
                characters: text.count,
                duration: Date().timeIntervalSince(chunkingStarted)
            )
            guard !chunks.isEmpty else {
                let reason = String(localized: "после чанкинга не осталось текста")
                skipped.append((item.relativePath, reason))
                runProblems.append(FileProblem(relativePath: item.relativePath, reason: reason, remedy: .exclude))
                continue
            }

            // Chunking usually solves the length problem, but not always: a
            // size in characters over Cyrillic text, or a section the strategy
            // refuses to split, can still produce a chunk past the model's
            // context. The file is left as it was and named in the report
            // rather than indexed with its tail cut off.
            // Чанк длиннее контекста модели дорезается по предложениям
            //, а не отменяет индексацию всего файла. Правило A7.3
            // про обрезанный хвост в силе — хвост просто становится
            // следующим чанком, и об этом говорится вслух.
            //
            // Дорезается и по замеренному пределу в знаках, не только по
            // контексту в токенах: раньше чанк, влезавший в токены,
            // но не влезавший в предел, уводил **весь файл** в пропущенные
            // и обрывал прогон.
            if !inputLimitMeasured,
               chunks.contains(where: { $0.text.count >= EmbeddingInputProbe.suspiciousCharacters }) {
                measuredInputLimit = await binding.measuredInputLimit(of: embeddingModel, embeddings: embeddings)
                // Отметка ставится только по удаче: сорвавшаяся проба
                // не должна выключать дорезку до конца прогона.
                // Повторный вызов ничего не стоит — служба помнит и то,
                // что предела не нашлось.
                inputLimitMeasured = measuredInputLimit != nil
            }
            let fitted = OversizeChunks.fitted(
                chunks, contextLength: contextLength, characterLimit: measuredInputLimit
            )
            if fitted.split > 0 {
                chunks = fitted.chunks
                chunksSplitToFit += fitted.split
                log(.warning, "Источники",
                    "Файл \(item.relativePath): чанков, не влезавших в контекст модели, дорезано по предложениям: \(fitted.split.plainDigits). Уменьшите размер чанка, если это повторяется.")
            }
            // Пустой чанк дорезкой не лечится: его нечем делить, и отправлять
            // его модели незачем.
            if let empty = chunks.first(where: {
                ContextBudget.check($0.text, contextLength: contextLength).blocksSending
            }) {
                let verdict = ContextBudget.check(empty.text, contextLength: contextLength)
                let reason = String(localized: "чанк \(empty.index + 1) не отправляется модели: \(verdict.message ?? "")")
                skipped.append((item.relativePath, reason))
                runProblems.append(FileProblem(relativePath: item.relativePath, reason: reason, remedy: .retry))
                continue
            }

            // Every id this file will occupy is known before a single vector is
            // computed — they are derived from the path and the chunk index.
            let newIDs = chunks.map { Self.documentID(relativePath: item.relativePath, chunkIndex: $0.index) }
            let previous = manifest.entries[item.relativePath]
            let record = SyncJournalEntry(
                relativePath: item.relativePath,
                collectionName: collectionName,
                oldIDs: previous?.chunkIDs ?? [],
                newIDs: newIDs,
                contentHash: hash,
                // Both hashes and the extractor stamp go into the journal, so a
                // run finished after a crash records what this one would have
                //: otherwise a recovered file would look «extracted by
                // an unknown version» forever.
                fileHash: Self.fileHash(of: item.url) ?? "",
                extractorID: extracted.extractorID,
                extractorVersion: extracted.extractorVersion,
                extractionSignature: source.extractionSignature,
                metadataSignature: source.metadataSignature,
                modifiedAt: item.modifiedAt,
                size: item.size,
                chunkingSignature: signature,
                embeddingModel: embeddingModel,
                warnings: extracted.warnings.map(\.text)
            )
            // The intent reaches the disk **before** the database is touched.
            // Everything below can be interrupted; only a record written first
            // makes the interruption recoverable.
            // Один файл больше не уводит за собой весь прогон.
            //
            // Так уходил файл, чанк которого не влезал в то, что модель
            // читает на самом деле: ошибка поднималась из записи наружу,
            // прогон обрывался на этом файле, и остальные сотни не
            // разбирались вовсе. Теперь непрошедшее называется в отчёте,
            // а разбор идёт дальше.
            let writtenBeforeFile = chunksWritten
            do {
                try journal.begin(record, sourceID: source.id)

                let baseMetadata = metadata(
                    for: item, text: text, hash: hash, source: source,
                    embeddingModel: embeddingModel, totalChunks: chunks.count,
                    attention: attentionNote[collectionName], extracted: extracted
                )
                let schema = schemas[collectionName]
                // Where each chunk landed in the document, found once per file.
                let placements = ChunkLocator.placements(of: chunks, in: extracted)

                var batch: [TextChunk] = []
                for chunk in chunks {
                    batch.append(chunk)
                    if batch.count == batchSize {
                        try await flush(
                            batch, relativePath: item.relativePath, baseMetadata: baseMetadata,
                            placements: placements,
                            contextPrefixEnabled: source.chunking.contextPrefix,
                            enrichment: enrichment,
                            schema: schema, collectionID: collectionID, model: embeddingModel,
                            dimension: dimension, chroma: chroma, embeddings: embeddings,
                            binding: binding
                        )
                        chunksWritten += batch.count
                        batch.removeAll()
                        progress(SyncProgress(
                            stage: String(localized: "Эмбеддинг"),
                            processedFiles: index, totalFiles: writeItems.count,
                            chunksWritten: chunksWritten, currentFile: item.relativePath
                        ))
                        // The batch is written and the journal is consistent: the
                        // safe moment to let a more important task have the model.
                        await yield?()
                    }
                }
                if !batch.isEmpty {
                    try await flush(
                        batch, relativePath: item.relativePath, baseMetadata: baseMetadata,
                        placements: placements,
                        contextPrefixEnabled: source.chunking.contextPrefix,
                        enrichment: enrichment,
                        schema: schema, collectionID: collectionID, model: embeddingModel,
                        dimension: dimension, chroma: chroma, embeddings: embeddings,
                        binding: binding
                    )
                    chunksWritten += batch.count
                }

                try journal.advance(sourceID: source.id, relativePath: item.relativePath, to: .upserted)

                // Only now the old tail goes — by explicit ids, never by a `where`
                // condition. A file that got shorter leaves chunks nothing refers
                // to any more, and a filter could take more than it should if two
                // sources ever agreed on the same metadata.
                let tail = record.tailIDs
                if !tail.isEmpty {
                    try await chroma.deleteDocuments(collectionID: collectionID, ids: tail)
                    chunksDeleted += tail.count
                }
                try journal.advance(sourceID: source.id, relativePath: item.relativePath, to: .cleaned)

                if case .new = item.kind { added += 1 } else { updated += 1 }
                if attentionNote[collectionName] != nil { marked.append(item.relativePath) }

                manifest.record(record.manifestEntry())
                // Written per file, and never before the database confirmed the
                // write: an interrupted sync keeps everything it managed to do, and
                // the next run picks up where it stopped.
                manifests.save(manifest)
                try journal.finish(sourceID: source.id, relativePath: item.relativePath)
            } catch let error as SyncError {
                guard case .longerThanModelReads = error else { throw error }
                let reason = Self.reason(for: error)
                // Записанное этим файлом снимается: манифест о нём не
                // узнал, и оставленные чанки стали бы сиротами, на которые
                // никто не ссылается и которых никто не перезапишет.
                try? await chroma.deleteDocuments(collectionID: collectionID, ids: record.newIDs)
                try? journal.finish(sourceID: source.id, relativePath: item.relativePath)
                chunksWritten = writtenBeforeFile
                skipped.append((item.relativePath, reason))
                runProblems.append(FileProblem(
                    relativePath: item.relativePath, reason: reason, remedy: .retry
                ))
                log(.warning, "Источники", "Файл \(item.relativePath) пропущен: \(reason)")
                continue
            }
        }

        progress(SyncProgress(
            stage: String(localized: "Готово"),
            processedFiles: writeItems.count, totalFiles: writeItems.count,
            chunksWritten: chunksWritten
        ))

        // Replaced wholesale rather than merged: a file that read cleanly this
        // time is not still broken because it was broken last week.
        manifest.problems = runProblems
        if countsFolderLevels { manifest.newFolderLevels = plan.newFolderLevels }
        manifests.save(manifest)

        let summary = SyncSummary(
            sourceName: source.name, added: added, updated: updated, unchanged: plan.unchangedCount,
            chunksWritten: chunksWritten, chunksDeleted: chunksDeleted, skipped: skipped,
            needsDecision: manifest.pendingRemovals, markedForAttention: marked,
            collections: plan.targetCollections, duration: Date().timeIntervalSince(started),
            embeddingModel: embeddingModel, dimension: dimension,
            substituted: substituted,
            recoveredFiles: recovery.finished.count,
            reindexedAfterFailure: recovery.toReindex.count,
            chunksSplitToFit: chunksSplitToFit,
            heterogeneousCollections: heterogeneous,
            staleExtraction: plan.staleExtraction,
            tableWarnings: tableWarnings,
            tableRowsNeedingDecision: tableManifests.pendingRemovals(sourceID: source.id)
                .reduce(0) { $0 + $1.rows.count },
            newFolderLevels: plan.newFolderLevels
        )
        log(.success, "Источники", "Источник «\(source.name)» → \(plan.targetCollections.joined(separator: ", ")): \(summary.line), за \(String(format: "%.1f", summary.duration)) с")
        for item in skipped {
            log(.warning, "Источники", "Пропущен \(item.file): \(item.reason)")
        }
        // Одной строкой на прогон, а не строкой на файл: подмена обычно
        // касается всех файлов одного вида сразу, и сотня одинаковых строк
        // прячет всё остальное.
        if let line = summary.substitutionLine {
            log(.warning, "Источники", line)
        }
        if !manifest.pendingRemovals.isEmpty {
            log(.warning, "Источники", "Требуют решения (исчезли с диска, из базы не удалены): \(manifest.pendingRemovals.map(\.relativePath).joined(separator: ", "))")
        }
        return summary
    }

    // MARK: - Pending removals

    public enum RemovalDecision: String, CaseIterable, Identifiable {
        /// Delete the file's chunks from the collection.
        case deleteChunks
        /// Keep the documents; stop asking about this file.
        case keepInDatabase
        /// Decide later — the file stays on the list.
        case postpone

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .deleteChunks: return String(localized: "Удалить из базы")
            case .keepInDatabase: return String(localized: "Оставить в базе")
            case .postpone: return String(localized: "Решить позже")
            }
        }
    }

    @discardableResult
    public func resolve(
        removal: PendingRemoval,
        decision: RemovalDecision,
        source: DataSource,
        chroma: (any SyncDatabase)?
    ) async throws -> Int {
        var manifest = manifests.load(sourceID: source.id)
        switch decision {
        case .postpone:
            return 0

        case .keepInDatabase:
            if var entry = manifest.entries[removal.relativePath] {
                // Remembered as orphaned instead of forgotten: if the file comes
                // back, its chunks are recognised as already indexed.
                entry.isOrphaned = true
                manifest.entries[removal.relativePath] = entry
            }
            manifest.pendingRemovals.removeAll { $0.relativePath == removal.relativePath }
            manifests.save(manifest)
            log(.info, "Источники", "Файл \(removal.relativePath) исчез с диска, документы оставлены в базе по решению пользователя")
            return 0

        case .deleteChunks:
            guard let chroma else { throw ChromaError.notConfigured }
            var collectionIDs: [String: String] = [:]
            let deleted = try await deleteChunks(
                ofFile: removal.relativePath,
                sourceID: source.id,
                collectionName: removal.collectionName,
                knownIDs: removal.chunkIDs,
                collectionIDs: &collectionIDs,
                chroma: chroma
            )
            manifest.forget(relativePath: removal.relativePath)
            manifests.save(manifest)
            log(.warning, "Источники", "Файл \(removal.relativePath) удалён с диска — из базы удалено документов: \(deleted)")
            return deleted
        }
    }

    /// То же решение, но о строках таблицы.
    ///
    /// Отдельным методом, а не веткой внутри `resolve(removal:)`: у строки
    /// другой манифест, другая единица удаления (документ по явному id, никогда
    /// по фильтру на `row_number`) и другое «оставить в базе» — отметка
    /// на записи строки, а не на записи файла.
    @discardableResult
    public func resolve(
        rowRemoval: PendingRowRemoval,
        decision: RemovalDecision,
        source: DataSource,
        chroma: (any SyncDatabase)?
    ) async throws -> Int {
        guard decision != .postpone else { return 0 }
        var files = tableManifests.load(sourceID: source.id)
        guard var file = files[rowRemoval.relativePath] else { return 0 }

        switch decision {
        case .postpone:
            return 0

        case .keepInDatabase:
            // Записи остаются в манифесте и помечаются осиротевшими: забыть их
            // значило бы оставить документы, которые больше нечем адресовать.
            if var sheet = file.sheets[rowRemoval.sheetName] {
                for record in rowRemoval.rows where sheet.rows[record.identity] != nil {
                    sheet.rows[record.identity]?.isOrphaned = true
                }
                file.sheets[rowRemoval.sheetName] = sheet
            }
            file.pendingRemovals[rowRemoval.sheetName] = nil
            files[rowRemoval.relativePath] = file
            tableManifests.save(files, sourceID: source.id)
            log(.info, "Таблицы",
                "Лист «\(rowRemoval.sheetName)» файла \(rowRemoval.relativePath): строк исчезло \(rowRemoval.rows.count.plainDigits), документы оставлены в базе по решению пользователя")
            return 0

        case .deleteChunks:
            guard let chroma else { throw ChromaError.notConfigured }
            guard let collectionID = try? await chroma.resolveID(of: rowRemoval.collectionName) else {
                // Коллекции нет — удалять нечего, и это не ошибка.
                file.pendingRemovals[rowRemoval.sheetName] = nil
                files[rowRemoval.relativePath] = file
                tableManifests.save(files, sourceID: source.id)
                return 0
            }
            // По явным id, никогда по условию на `row_number`: фильтр забрал бы
            // всё, что случайно делит с ними номер.
            let ids = TableSyncPlanner.removalIDs(for: rowRemoval.rows)
            try await chroma.deleteDocuments(collectionID: collectionID, ids: ids)
            if var sheet = file.sheets[rowRemoval.sheetName] {
                for record in rowRemoval.rows { sheet.rows[record.identity] = nil }
                file.sheets[rowRemoval.sheetName] = sheet
            }
            file.pendingRemovals[rowRemoval.sheetName] = nil
            files[rowRemoval.relativePath] = file
            tableManifests.save(files, sourceID: source.id)
            log(.warning, "Таблицы",
                "Лист «\(rowRemoval.sheetName)» файла \(rowRemoval.relativePath): строк исчезло из файла — из базы удалено документов: \(ids.count.plainDigits)")
            return ids.count
        }
    }

    // MARK: - Helpers

    /// Deletes one file's chunks by filter, falling back to the remembered ids.
    ///
    /// The filter is `source_id AND source_file`: two sources pointed at the same
    /// collection can hold files with the same relative path, and only the pair
    /// identifies one of them.
    private func deleteChunks(
        ofFile relativePath: String,
        sourceID: UUID,
        collectionName: String,
        knownIDs: [String],
        collectionIDs: inout [String: String],
        chroma: any SyncDatabase
    ) async throws -> Int {
        let id: String
        if let cached = collectionIDs[collectionName] {
            id = cached
        } else {
            guard let resolved = try? await chroma.resolveID(of: collectionName) else {
                // The collection is gone: nothing to delete, and that is not an error.
                return 0
            }
            collectionIDs[collectionName] = resolved
            id = resolved
        }

        do {
            // Формы записи пути перебираются по очереди: чанки, лежащие
            // в базе с прежних сборок, записаны так, как путь отдала файловая
            // система, а спрашиваем мы теперь каноничной формой. Не найти их
            // здесь — значит оставить в коллекции чанки удалённого файла.
            var deleted = 0
            for variant in FilePathKey.variants(relativePath) {
                let filter = DocumentFilter(conditions: [
                    MetadataCondition(field: "source_id", op: .equals, value: sourceID.uuidString),
                    MetadataCondition(field: "source_file", op: .equals, value: variant),
                ])
                deleted = try await chroma.deleteDocuments(collectionID: id, filter: filter)
                if deleted > 0 { break }
            }
            return deleted
        } catch {
            // Older or stricter servers might refuse the filter; the ids we
            // remembered still let us clean up.
            guard !knownIDs.isEmpty else { throw error }
            try await chroma.deleteDocuments(collectionID: id, ids: knownIDs)
            return knownIDs.count
        }
    }

    /// Строка контекста, которая уходит в модель перед текстом чанка.
    ///
    /// «Документ → Раздел → Подраздел». Имя документа — заголовок из его
    /// метаданных, а если его нет, имя файла без расширения: чанк из файла
    /// «Регламент отпусков» должен находиться по слову «отпуск», даже если
    /// внутри абзаца этого слова нет.
    ///
    /// `nil`, когда сказать нечего: приписывать к тексту пустую стрелку —
    /// это шум в векторе, а не контекст.
    static func contextPrefix(
        title: String?, headingPath: String?, listLeadIn: String? = nil,
        separator: String = " → "
    ) -> String? {
        var parts: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            parts.append(title)
        }
        if let headingPath, !headingPath.isEmpty {
            // Путь заголовков внутри документа приходит со своим разделителем
            // — приводим к одному виду, чтобы строка читалась целиком.
            parts += headingPath.components(separatedBy: " > ").filter { !$0.isEmpty }
        }
        // Вводная фраза списка — последней и на своей строке.
        //
        // Не в один ряд со стрелками: заголовки — это адрес, а вводная фраза
        // — предложение, и «Регламент → 5.2 → Исполнитель обязан обеспечить:»
        // читается как ещё один уровень адреса, которым она не является.
        let lead = listLeadIn?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parts.isEmpty || !(lead ?? "").isEmpty else { return nil }
        let address = parts.joined(separator: separator)
        guard let lead, !lead.isEmpty else { return address }
        return address.isEmpty ? lead : address + "\n" + lead
    }

    /// Сколько знаков отводится под адреса. Дальше метаданное перестаёт быть
    /// подписью и становится свалкой: страница-оглавление несёт сотни ссылок,
    /// и записать их все — это раздуть каждую запись в базе.
    static let urlLineLimit = 1000

    /// Адреса одной строкой через пробел — массивов в метаданных ChromaDB
    /// не бывает. `nil`, когда адресов нет.
    ///
    /// Пробел разделителем годится потому, что в адресе его быть не может:
    /// строка разбирается обратно без потерь и без выдуманного синтаксиса.
    static func urlLine(_ urls: [String], limit: Int = urlLineLimit) -> String? {
        var result = ""
        for url in urls {
            let candidate = result.isEmpty ? url : result + " " + url
            guard candidate.count <= limit else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    /// Заголовок документа для строки контекста.
    static func documentTitle(metadata: ChromaMetadata, relativePath: String) -> String? {
        if case .string(let title)? = metadata["title"],
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        // Та же починка кодировки, что у `file_name`, и по той же
        // причине, только цена ошибки здесь выше: этот заголовок уходит
        // приставкой в **вектор** чанка. Без починки в вектор
        // попадало бы «Рг°®в•е_ѓа®Ђ» — строка, не значащая ничего ни для
        // одной модели.
        let name = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : FileNameEncoding.repaired(name)
    }

    private func flush(
        _ chunks: [TextChunk],
        relativePath: String,
        baseMetadata: ChromaMetadata,
        placements: [Int: ChunkPlacement],
        contextPrefixEnabled: Bool,
        enrichment: ContextEnricher?,
        schema: MetadataSchema?,
        collectionID: String,
        model: String,
        dimension: Int,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider,
        binding: ModelBindingService?
    ) async throws {
        if Task.isCancelled { throw SyncError.cancelled }
        let embeddingStarted = Date()
        // Контекст уходит **в модель**, но не в текст документа:
        // человек и агент читают чанк как он есть, а вектор считается от
        // строки «Документ → Раздел» плюс текст.
        let title = Self.documentTitle(metadata: baseMetadata, relativePath: relativePath)
        var texts = chunks.map { chunk -> String in
            guard contextPrefixEnabled,
                  let prefix = Self.contextPrefix(
                      title: title,
                      headingPath: placements[chunk.index]?.headingPath,
                      listLeadIn: placements[chunk.index]?.listLeadIn
                  )
            else { return chunk.text }
            return prefix + "\n\n" + chunk.text
        }
        // Обогащение чат-моделью — по вызову на чанк. Идёт туда же,
        // куда структурная строка: в текст **для вектора**, не в документ.
        // Раздел передаётся вместе с заголовком документа: без него модель
        // не может ответить на вторую половину вопроса — где в документе
        // этот фрагмент.
        if let enrichment {
            texts = try await enrichment.enriched(
                chunks: chunks, texts: texts, documentTitle: title,
                headingPaths: placements.compactMapValues(\.headingPath)
            )
        }
        // Модель читает не всё, что ей дают, и молчит об этом.
        // Проверяется только подозрительно длинный текст, и предел меряется
        // один раз на модель: обычный прогон не платит за это ничего.
        if let longest = texts.max(by: { $0.count < $1.count }),
           longest.count >= EmbeddingInputProbe.suspiciousCharacters,
           let binding,
           let limit = await binding.measuredInputLimit(of: model, embeddings: embeddings),
           longest.count > limit {
            throw SyncError.longerThanModelReads(
                path: relativePath, characters: longest.count, limit: limit, model: model
            )
        }
        let vectors = try await embeddings.embed(texts: texts, model: model)
        await metrics?.recordEmbedding(
            model: model,
            texts: chunks.count,
            duration: Date().timeIntervalSince(embeddingStarted)
        )
        guard vectors.count == chunks.count else { throw LMStudioError.emptyResponse }
        if let unexpected = vectors.first(where: { $0.count != dimension }) {
            throw BindingError.dimensionConflict(collection: collectionID, stored: dimension, model: unexpected.count)
        }

        let records = zip(chunks, vectors).map { chunk, vector -> EmbeddedRecord in
            var metadata = baseMetadata
            metadata["chunk_index"] = .int(chunk.index)
            metadata["chunk_estimated_tokens"] = .int(chunk.estimatedTokens)
            // Hierarchical chunking puts parents and children in one collection,
            // so the level and the link to the parent have to be queryable.
            metadata["chunk_level"] = .int(chunk.level)
            if let parentIndex = chunk.parentIndex {
                metadata["parent_chunk_id"] = .string(Self.documentID(relativePath: relativePath, chunkIndex: parentIndex))
            }
            // Where in the document this chunk came from. Written only
            // for chunks that were actually found back in the text: a page
            // number nobody can trust is worse than none, because E2 and D3.1
            // build range filters on it.
            if let placement = placements[chunk.index] {
                if let page = placement.pageNumber { metadata["page_number"] = .int(page) }
                if let path = placement.headingPath { metadata["heading_path"] = .string(path) }
                // Адреса, на которые ссылается этот кусок. В метаданные,
                // а не в текст: адрес — ссылка на источник, а не слова,
                // по которым ищут, и в векторе он даёт набор цифр.
                //
                // Одной строкой через пробел: массивов в метаданных ChromaDB
                // не бывает, а пробел в адресе невозможен —
                // значит строка разбирается обратно без потерь.
                if let urls = Self.urlLine(placement.links) {
                    metadata["source_urls"] = .string(urls)
                }
                // A chapter or a slide, named the way names it for its
                // format — one field per kind, so a filter over books and a
                // filter over presentations never collide.
                switch placement.part?.kind {
                case .spine:
                    metadata["spine_index"] = .int(placement.part?.index ?? 0)
                    if let id = placement.part?.id, !id.isEmpty { metadata["chapter_id"] = .string(id) }
                case .slide:
                    metadata["slide_number"] = .int((placement.part?.index ?? 0) + 1)
                case nil:
                    break
                }
            }
            if let note = chunk.note {
                metadata["_cdbm_chunk_note"] = .string(note)
            }
            // Язык и ключевые слова — средствами системы. Считаются
            // по тексту чанка, а не документа: в многоязычном файле фильтр
            // по языку нужен именно на уровне того, что нашлось.
            //
            // Короткому чанку язык достаётся от документа: «Итого: 42»
            // определяется как русский с уверенностью 1.00, и уверенность эта
            // ни о чём.
            let language = TextLinguistics.language(of: chunk.text)
                ?? { if case .string(let value)? = baseMetadata["document_language"] { return value }
                     return nil }()
            if let language { metadata["language"] = .string(language) }
            if let keywords = TextLinguistics.keywordLine(in: chunk.text, language: language) {
                metadata["keywords"] = .string(keywords)
            }
            if let schema {
                // Same normalisation as a hand-typed document: defaults filled
                // in, dates mirrored into `<key>_ts`.
                metadata = validator.normalised(metadata, schema: schema)
            }
            return EmbeddedRecord(
                id: Self.documentID(relativePath: relativePath, chunkIndex: chunk.index),
                document: chunk.text,
                embedding: vector,
                metadata: metadata
            )
        }
        try await chroma.upsert(
            collectionID: collectionID,
            records: try await Self.keepingMarks(of: records, in: collectionID, chroma: chroma)
        )
    }

    /// Ручные пометки человека переживают перезапись чанка.
    ///
    /// Синхронизация пишет чанк целиком: изменился файл — метаданные собраны
    /// заново, и «закреплено» вместе с тегами и заметкой исчезло бы. Причём
    /// исчезло бы молча и ровно тогда, когда человек о пометках не думает, —
    /// он правил документ, а не разметку.
    ///
    /// Старые записи читаются одним запросом на батч и **только по тем
    /// идентификаторам**, которые сейчас переписываются. На коллекции без
    /// единой пометки это стоит одного чтения без векторов на батч; платить
    /// за сохранность чужой разметки дешевле, чем терять её.
    static func keepingMarks(
        of records: [EmbeddedRecord], in collectionID: String, chroma: any SyncDatabase
    ) async throws -> [EmbeddedRecord] {
        guard !records.isEmpty else { return records }
        guard let previous = try? await chroma.documents(
            collectionID: collectionID, ids: records.map(\.id)
        ), !previous.isEmpty else { return records }

        let marked = previous.reduce(into: [String: ChromaMetadata]()) { result, record in
            guard let metadata = record.metadata,
                  !DocumentMarks(metadata: metadata).isEmpty else { return }
            result[record.id] = metadata
        }
        guard !marked.isEmpty else { return records }

        return records.map { record in
            guard let old = marked[record.id] else { return record }
            return EmbeddedRecord(
                id: record.id,
                document: record.document,
                embedding: record.embedding,
                metadata: DocumentMarks.carriedOver(from: old, to: record.metadata)
            )
        }
    }

    private func metadata(
        for item: SyncPlanItem,
        text: String,
        hash: String,
        source: DataSource,
        embeddingModel: String,
        totalChunks: Int,
        attention: String?,
        extracted: ExtractedDocument
    ) -> ChromaMetadata {
        var metadata: ChromaMetadata = [
            DocumentOrigin.metadataKey: DocumentOrigin.source.value,
            "source_id": .string(source.id.uuidString),
            "source_file": .string(item.relativePath),
            // Отпечаток файла — то, чем агент просит документ целиком.
            // Путь для этого плох: его перепечатывают в другой форме записи,
            // теряют верхние папки, ломают кодировкой. Шестнадцать
            // шестнадцатеричных знаков так не испортишь.
            "file_id": .string(Self.fileFingerprint(item.relativePath)),
            "content_hash": .string(hash),
            "chunk_count": .int(totalChunks),
            "_cdbm_source_name": .string(source.name),
            "_cdbm_model": .string(embeddingModel),
            // Which extractor produced this text and how it was cut.
            // `extractor_version` is an int on purpose: compares it, and a
            // string comparison would put version 10 before version 9.
            "extractor_id": .string(extracted.extractorID),
            "extractor_version": .int(extracted.extractorVersion),
            "container_format": .string(extracted.containerFormat),
            "structure_source": .string(extracted.structureSource.rawValue),
        ]
        // У страницы из сети нет ни имени файла, ни времени изменения на диске:
        // временный файл с телом ответа — наш, а не пользователя, и выдавать
        // его имя за имя документа значит врать. Что есть у страницы, пишет
        // `routeMetadata` — `source_url`, `page_title`, `fetched_at` и прочее
        // из I1.2.
        if !item.isRemote {
            metadata["file_ext"] = .string(item.url.pathExtension.lowercased())
            metadata["file_mtime"] = .string(ISO8601DateFormatter().string(from: item.modifiedAt))
            metadata["file_size"] = .int(Int(item.size))
            // Имя, а не путь: испорченную кодировку из чужого архива чиним
            // здесь, а `source_file` оставляем как на диске.
            metadata["file_name"] = .string(FileNameEncoding.repaired(item.url.lastPathComponent))
        }
        // ChromaDB metadata has no arrays: a flat string with a
        // separator, not a list.
        // Язык документа целиком: короткому чанку он достаётся
        // отсюда, а фильтр «все документы на английском» строится по нему.
        if let language = TextLinguistics.language(of: text) {
            metadata["document_language"] = .string(language)
        }
        if !extracted.warnings.isEmpty {
            metadata["extraction_warnings"] = .string(extracted.warnings.map(\.text).joined(separator: "; "))
            // Отдельным полем, а не только словами в оговорке: по
            // нему выдача агенту приписывает предупреждение, а проверка
            // коллекции находит файлы, где числам верить нельзя. Разбирать
            // ради этого русскую фразу — способ однажды её не узнать.
            if extracted.warnings.contains(where: { if case .tablesNotAssembled = $0 { return true } else { return false } }) {
                metadata["tables_flat"] = .bool(true)
            }
        }
        if let pageCount = extracted.pageCount {
            metadata["page_count"] = .int(pageCount)
        }
        // Written only by extractors that actually look for tables: `false` from
        // one that never checked would be a claim, not a fact.
        if let hasTables = extracted.hasTables {
            metadata["has_tables"] = .bool(hasTables)
        }
        // recognised text is not the same thing as read text, and a
        // search result deserves to say which it is.
        if let ocrUsed = extracted.ocrUsed {
            metadata["ocr_used"] = .bool(ocrUsed)
            if let confidence = extracted.ocrConfidence {
                metadata["ocr_confidence_avg"] = .double((confidence * 1000).rounded() / 1000)
            }
        }
        // Title, author, creation date — only when the source asked for them.
        for (key, value) in extracted.documentMetadata where !key.isEmpty {
            metadata[key] = .string(value)
        }
        for (key, value) in item.routeMetadata { metadata[key] = value }
        for (key, value) in source.customMetadata where !key.isEmpty {
            metadata[key] = .inferred(from: value)
        }
        if let attention {
            metadata["_cdbm_attention"] = .string(attention)
        }
        return metadata
    }

    // MARK: - Identity

    /// `id = <sha256(relative_path) первые 16 hex>-<chunk_index>`, fixed by the
    /// spec: re-indexing a file replaces its chunks instead of duplicating them.
    ///
    /// Хеш берётся от каноничной формы пути: sha256 считает байты, и
    /// одно и то же имя, записанное разложенным и слитным, дало бы файлу два
    /// разных отпечатка — то есть два набора чанков вместо замены прежних.
    public static func documentID(relativePath: String, chunkIndex: Int) -> String {
        "\(fileFingerprint(relativePath))-\(chunkIndex)"
    }

    /// Отпечаток файла — то, чем его чанки отличаются от чужих.
    ///
    /// Шестнадцать шестнадцатеричных знаков: их нельзя перепечатать «в другой
    /// форме», потерять верхние папки или испортить кодировкой, и потому
    /// именно он отдаётся агенту как способ спросить файл целиком.
    public static func fileFingerprint(_ relativePath: String) -> String {
        let digest = SHA256.hash(data: Data(FilePathKey.canonical(relativePath).utf8))
        return String(digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// SHA-256 of the extracted text.
    /// does the collection's recorded recipe disagree with the one this run
    /// writes with?
    ///
    /// A collection with no hash, or one written under an older schema version,
    /// is simply brought up to date: the set of fields feeding the digest grew,
    /// the contents did not change, and warning about that would send the user
    /// re-indexing for nothing. A real disagreement is reported and **left
    /// alone** — the stored value keeps describing what the collection was
    /// filled with, so the warning comes back on every run until the user
    /// re-indexes or clones. The app never re-indexes on its own (Приложение 5).
    private func isHeterogeneous(
        _ collection: ChromaCollection,
        chunking: ChunkingConfiguration,
        chroma: SyncDatabase
    ) async throws -> Bool {
        let current = StrategyParamsHash.of(chunking)
        switch StrategyParamsHash.compare(stored: StrategyParamsHash.parse(collection.metadata), current: current) {
        case .matches:
            return false
        case .migrate:
            var metadata = collection.metadata ?? [:]
            metadata[CollectionBindingKeys.strategyParamsHash] = current.value
            metadata[CollectionBindingKeys.chunkingStrategy] = .string(chunking.strategy.rawValue)
            // The readable predecessor is not carried forward; a collection that
            // still has it keeps it as a record of how it was filled.
            try await chroma.updateCollection(id: collection.id, newName: nil, metadata: metadata)
            return false
        case .differs:
            log(.warning, "Источники",
                "Коллекция «\(collection.name)»: параметры чанкинга отличаются от записанных при наполнении — коллекция станет неоднородной. Приложение ничего не переиндексирует само: нужна переиндексация или клонирование.")
            return true
        }
    }

    /// Подменена ли выбранная стратегия на этом документе — и почему.
    ///
    /// Отдельным типом, а не флажком внутри нарезки: подмену надо не только
    /// применить, но и показать — в сводке прогона, в инспекторе и на самом
    /// чанке. Пока это решение жило выражением `recognised ? ocrPipeline :
    /// pipeline`, наружу от него доставалась одна пометка в метаданных, куда
    /// никто не заглядывает.
    public enum ChunkingSubstitution: Sendable, Hashable {
        /// Презентация: слайд — уже единица мысли, дробить его дальше значит
        /// делать фрагменты, которые сами по себе ничего не значат.
        case slides
        /// Структурная стратегия на документе без структуры: резать по
        /// угаданным заголовкам — догадка поверх догадки.
        case noStructure(ChunkStrategy)

        public var note: String {
            switch self {
            case .slides:
                return String(localized: "презентация: один слайд — один чанк")
            case .noStructure(let strategy):
                return String(localized: "структура в документе не найдена — вместо «\(strategy.title)» использован Recursive")
            }
        }
    }

    /// Решение о подмене. Одно место, и его же спрашивают сводка и предпросмотр.
    ///
    /// **Проверяется наличие структуры, а не происхождение текста.** Раньше
    /// условием было `document.ocrUsed == true`, и оно подменяло стратегию
    /// **всем шести**. Но структуру получают только две из них — documentBased
    /// и hierarchical; semantic, llmBased, adaptive, fixed и recursive её не
    /// видят вовсе. Semantic и llmBased на распознанном тексте как раз ценнее
    /// прочих: вёрстка потеряна, а смысл остался, — и именно их подменяли на
    /// резку по разделителям, которых в OCR-выводе меньше всего.
    ///
    /// Заодно условие стало последовательным: PDF с текстовым слоем, но без
    /// оглавления тоже приходит без структуры, и раньше там documentBased
    /// спокойно работал по угаданным секциям. Разрешать догадку всем, кроме
    /// распознанных, было непоследовательно.
    public static func substitution(
        for configuration: ChunkingConfiguration,
        document: ExtractedDocument
    ) -> ChunkingSubstitution? {
        if !document.parts.filter({ $0.kind == .slide }).isEmpty { return .slides }
        switch configuration.strategy {
        case .documentBased:
            // Спрашивается не «есть ли структура **у документа**», а «найдёт ли
            // границы **эта стратегия**». Разница на живом прогоне
            // стоила всей стратегии: у Markdown экстрактор структуру не
            // заполняет никогда — её там некому взять, — а сам чанкер режет
            // по заголовкам `#` из текста и делает это правильно. По прежнему
            // правилу Document-based подменялась на **каждом** `.md`, то есть
            // не работала там, где нужна больше всего.
            //
            // Разметка самого документа по-прежнему главнее всего: если она
            // есть, стратегия работает как выбрана, даже когда раздел в ней
            // один — большой раздел дорежет запасной механизм, а сказать
            // «структуры нет» про документ, у которого она есть, нельзя.
            guard document.structure.isEmpty else { return nil }
            let chunker = DocumentBasedChunker(
                configuration: configuration,
                fileExtension: document.containerFormat,
                structure: []
            )
            return chunker.findsSections(in: document.plainText) ? nil : .noStructure(configuration.strategy)
        case .hierarchical:
            // Ей структура не нужна вовсе: родители режутся по размеру, дети —
            // внутри родителей. Подменять её было не за что, и подмена лишала
            // коллекцию родительских чанков и связи `parent_chunk_id`.
            return nil
        case .fixed, .recursive, .semantic, .llmBased, .adaptive:
            return nil
        }
    }

    /// How this document is cut — the one place that decides it.
    ///
    /// Shared with the extraction preview on purpose: a preview that
    /// runs a different rule than the sync is worse than no preview, because it
    /// is believed. A Keynote deck previewed through the plain pipeline would
    /// show paragraphs where the collection ends up with slides.
    public static func plannedChunks(
        of document: ExtractedDocument,
        fileExtension: String?,
        pipeline: ChunkingPipeline,
        ocrPipeline: ChunkingPipeline,
        configuration: ChunkingConfiguration
    ) async throws -> [TextChunk] {
        let substitution = substitution(for: configuration, document: document)

        if case .slides = substitution, let slides = slideChunks(of: document) { return slides }

        let structural = substitution.map { if case .noStructure = $0 { true } else { false } } ?? false
        return try await (structural ? ocrPipeline : pipeline).chunks(
            from: document.plainText,
            fileExtension: fileExtension,
            structure: document.structure
        ).map { chunk -> TextChunk in
            guard let substitution, chunk.note == nil else { return chunk }
            var marked = chunk
            marked.note = substitution.note
            return marked
        }
    }

    /// One slide, one chunk — `nil` for anything that is not a presentation.
    static func slideChunks(of document: ExtractedDocument) -> [TextChunk]? {
        let slides = document.parts.filter { $0.kind == .slide }.sorted { $0.start < $1.start }
        guard !slides.isEmpty else { return nil }

        let text = document.plainText
        var result: [TextChunk] = []
        for (position, slide) in slides.enumerated() {
            let end = position + 1 < slides.count ? slides[position + 1].start : text.count
            guard end > slide.start, slide.start <= text.count else { continue }
            let from = text.index(text.startIndex, offsetBy: slide.start)
            let to = text.index(text.startIndex, offsetBy: min(end, text.count))
            let piece = text[from..<to].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            result.append(TextChunk(
                index: result.count,
                text: piece,
                note: String(localized: "презентация: один слайд — один чанк")
            ))
        }
        return result.isEmpty ? nil : result
    }

    /// The user's chunking settings with the strategy forced to Recursive.
    ///
    /// Sizes, overlap and separators are kept: the user chose those, and OCR is
    /// a reason to stop trusting *structure*, not to start ignoring everything
    /// they set.
    public static func recursiveEquivalent(of configuration: ChunkingConfiguration) -> ChunkingConfiguration {
        var result = configuration
        result.strategy = .recursive
        return result
    }

    public static func contentHash(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the bytes on disk. `nil` for a document package — a directory
    /// has no bytes of its own, and its text hash answers the same question.
    ///
    /// Streamed rather than loaded: a 50 MB file has no business being in memory
    /// twice just to be hashed.
    public static func fileHash(of url: URL) -> String? {
        guard !ExtractorRegistry.isDocumentPackage(url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Which extractor would read this file today, without reading it —
    /// compares versions on files it deliberately does not open.
    ///
    /// `storedID` — тот, что записан у файла в манифесте: сравнивать надо
    /// с его же экстрактором, а не с первым подходящим.
    static func stamp(
        of url: URL, storedID: String = "", registry: ExtractorRegistry,
        options: ExtractionOptions = ExtractionOptions()
    ) -> ExtractorStamp {
        guard let type = ExtractorRegistry.type(of: url) else {
            return ExtractorStamp(id: "", version: 0)
        }
        return registry.currentStamp(for: type, storedID: storedID, options: options)
    }

    /// Файлы, чей текст в базе получен прежней версией того же экстрактора
    /// — по манифесту, без обхода папки и без чтения файлов.
    ///
    /// Это тот же список, что собирает план, но доступный **до** него: смена
    /// версии приходит с обновлением приложения, то есть с его перезапуском,
    /// а список плана жил только в памяти экрана и после перезапуска исчезал.
    /// Человек видел карточку без единого слова о том, что 4522 файла в базе
    /// прочитаны позапрошлой читалкой.
    ///
    /// Тип берётся по расширению записи, а не с диска: это ответ на вопрос
    /// «чем читали и чем читают», а не «что сейчас лежит по этому пути», и
    /// четыре с половиной тысячи обращений к файловой системе ради него платить
    /// незачем. Штамп на расширение считается один раз.
    public func staleExtractions(in manifest: SourceManifest, source: DataSource) -> [StaleExtraction] {
        let options = Self.extractionOptions(for: source)
        var stamps: [String: ExtractorStamp] = [:]
        var result: [StaleExtraction] = []
        for entry in manifest.entries.values {
            let stored = entry.extractorStamp
            guard !stored.isUnknown else { continue }
            let ext = (entry.relativePath as NSString).pathExtension.lowercased()
            let key = "\(ext)|\(stored.id)"
            let current: ExtractorStamp
            if let cached = stamps[key] {
                current = cached
            } else {
                current = UTType(filenameExtension: ext)
                    .map { registry.currentStamp(for: $0, storedID: stored.id, options: options) }
                    ?? ExtractorStamp(id: "", version: 0)
                stamps[key] = current
            }
            guard SyncDecisionRules.isStale(stored: stored, current: current) else { continue }
            result.append(StaleExtraction(
                relativePath: entry.relativePath,
                collectionName: entry.collectionName,
                previous: stored,
                current: current
            ))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    /// Путь файла внутри источника — в единой форме записи.
    ///
    /// Файловая система macOS отдаёт имена разложенными: «й» приходит двумя
    /// знаками. Для Swift это та же строка, а для ChromaDB, JSON и sha256 —
    /// другие байты, и путь, попавший в базу в таком виде, не находился ни
    /// фильтром человека, ни `get_file` агента. Форма выбирается здесь, в
    /// одном месте, — дальше по коду путь идёт уже слитным.
    public static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return FilePathKey.canonical(url.lastPathComponent) }
        return FilePathKey.canonical(
            String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }
}

extension SourceSyncService {
    /// Rows of one table file that would reach the model.
    ///
    /// Reading a workbook is cheap next to embedding one row of it, and the
    /// number cannot be had any other way: a 2 MB file may hold fifty rows or
    /// fifty thousand. A file that cannot be read contributes nothing rather
    /// than a guess — the run will report the failure with its reason anyway.
    func countTableRows(
        file: URL,
        relativePath: String,
        source: DataSource,
        collectionName: String,
        manifest: TableFileManifest
    ) async -> Int {
        guard let read = try? await TableSyncService.read(url: file) else { return 0 }
        defer { read.temporary.map { try? fileManager.removeItem(at: $0) } }

        let context = TableSyncService.Context(
            sourceID: source.id, relativePath: relativePath,
            collectionID: "", collectionName: collectionName,
            embeddingModel: "", dimension: 0, profiles: tableProfiles(of: source),
            assignedProfileID: source.tableProfileAssignments[relativePath]
        )
        let planned = await tables.plan(sheets: read.sheets, manifest: manifest, context: context)
        return planned.plans.reduce(0) { $0 + $1.plan.embeddings }
    }
}
