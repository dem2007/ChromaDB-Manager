import Foundation
import CryptoKit

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
/// shown to the user before anything is written or embedded.
public struct SyncPlan {
    public let sourceID: UUID
    public let sourceName: String
    public let items: [SyncPlanItem]
    /// Files in the manifest that are no longer on disk, newly noticed now.
    public let newlyMissing: [PendingRemoval]
    /// Everything awaiting a decision, including what earlier syncs found.
    public let pendingRemovals: [PendingRemoval]
    /// Files whose text came from an older version of the extractor that reads
    /// them today. Deliberately **not** part of `items`: forbids queueing
    /// them, and anything inside `items` is work this run intends to do.
    public let staleExtraction: [StaleExtraction]
    /// Rows a table source would send to the model. Counted during the
    /// plan, because the price of a sheet cannot be guessed from its file size.
    public let tableRowsToEmbed: Int

    public init(
        sourceID: UUID,
        sourceName: String,
        items: [SyncPlanItem],
        newlyMissing: [PendingRemoval],
        pendingRemovals: [PendingRemoval],
        staleExtraction: [StaleExtraction] = [],
        tableRowsToEmbed: Int = 0
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.items = items
        self.newlyMissing = newlyMissing
        self.pendingRemovals = pendingRemovals
        self.staleExtraction = staleExtraction
        self.tableRowsToEmbed = tableRowsToEmbed
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

    /// whether a manual run of this size should show itself and wait for a
    /// confirmation first.
    ///
    /// Read the threshold exactly as the UI states it — «показывать план, если
    /// файлов больше N» — so 0 means every run that writes anything stops to be
    /// looked at. It used to be special-cased as «выключено», which made the
    /// setting say one thing and do the opposite.
    public func needsConfirmation(threshold: Int) -> Bool {
        writeItems.count > max(0, threshold)
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
    public var heterogeneousCollections: [String] = []
    /// Files whose text an older version of the extractor produced. Reported,
    /// never queued: forbids an app update from starting hours of local
    /// model time on its own.
    public var staleExtraction: [StaleExtraction] = []

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
        return [base, recoveryLine, heterogeneityLine, staleExtractionLine].compactMap { $0 }.joined(separator: "; ")
    }
}

public enum SyncError: LocalizedError {
    case folderMissing(String)
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
    private let fileManager = FileManager.default
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

    public init(
        manifests: ManifestStore? = nil,
        metrics: MetricsStore? = nil,
        journal: SyncJournal? = nil,
        registry: ExtractorRegistry? = nil,
        passwords: DocumentPasswordStore = DocumentPasswordStore(),
        tableManifests: TableManifestStore? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.log = log
        self.manifests = manifests ?? ManifestStore(log: log)
        self.metrics = metrics
        self.journal = journal ?? SyncJournal(log: log)
        self.registry = registry ?? ExtractorRegistry.standard(log: log)
        self.passwords = passwords
        self.tableManifests = tableManifests ?? TableManifestStore(log: log)
        self.tables = TableSyncService(metrics: metrics, log: log)
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
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return true
        }
        return ExtractorRegistry.isDocumentPackage(url)
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
        "source_id", "source_file", "chunk_index", "content_hash",
        "file_ext", "file_mtime", "file_size",
    ]

    /// What extraction adds to every chunk. Kept apart from
    /// `autoMetadataKeys`, which is the fixed minimum incremental sync depends
    /// on: these describe where the text came from, not how to find it again.
    public static let extractionMetadataKeys = [
        "extractor_id", "extractor_version", "container_format", "structure_source",
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
        return SyncPlan(
            sourceID: plan.sourceID, sourceName: plan.sourceName, items: items,
            newlyMissing: plan.newlyMissing, pendingRemovals: plan.pendingRemovals,
            // The list is kept as it was: a run that re-extracts part of it
            // should still report what is left.
            staleExtraction: plan.staleExtraction.filter { !paths.contains($0.relativePath) }
        )
    }

    public func isRunning(sourceID: UUID) -> Bool { running.contains(sourceID) }

    public func manifest(for sourceID: UUID) -> SourceManifest { manifests.load(sourceID: sourceID) }

    public func removeManifest(for sourceID: UUID) { manifests.remove(sourceID: sourceID) }

    /// Записать манифест, изменённый снаружи.
    ///
    /// Нужно ровно для переноса чанков при переименовании: он меняет
    /// базу до запуска синхронизации, и манифест обязан догнать её сразу —
    /// прерванный на этом месте запуск не должен искать чанки по старому имени.
    public func save(manifest: SourceManifest) { manifests.save(manifest) }

    // MARK: - Scanning

    public func scanFiles(source: DataSource) throws -> [URL] {
        let root = source.url
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.folderMissing(root.path)
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

    // MARK: - Plan

    /// Compares the folder with the manifest. Reads only the files that might
    /// have changed and never calls the embedding model, so it is safe to run
    /// just to look at what a sync would do.
    public func plan(source: DataSource, embeddingModel: String) async throws -> SyncPlan {
        if source.mapping.needsRule,
           let problem = CollectionRouter.ruleProblem(pattern: source.rulePattern, template: source.ruleTemplate) {
            throw SyncError.ruleInvalid(problem)
        }

        let files = try scanFiles(source: source)
        let manifest = manifests.load(sourceID: source.id)
        let signature = source.chunking.signature
        let extractionSignature = source.extractionSignature
        var items: [SyncPlanItem] = []
        var staleExtraction: [StaleExtraction] = []
        var seenPaths: Set<String> = []
        let tableFiles = tableManifests.load(sourceID: source.id)
        let currentProfilesSignature = TableSyncService.profilesSignature(source.tableProfiles)
        var tableRowsToEmbed = 0

        let excluded = Set(source.excludedPaths)
        for file in files {
            let relativePath = Self.relative(file, to: source.url)
            // Not added to `seenPaths`: from the source's point of view the file
            // is no longer there, so an entry left in the manifest becomes
            // «требует решения» rather than being quietly forgotten.
            if excluded.contains(relativePath) { continue }
            seenPaths.insert(relativePath)

            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date) ?? Date()

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
            let currentExtractor = Self.stamp(of: file, registry: registry)

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

        if !staleExtraction.isEmpty {
            // Said once, in the plan and in the log; never turned into work.
            // An app update must not start hours of local model time by itself
            // (rule 1 of Приложение 5).
            log(.info, "Источники",
                "Источник «\(source.name)»: файлов, извлечённых прежней версией экстрактора: \(staleExtraction.count). Автоматически ничего не пересчитывается — операция «переизвлечь и переэмбедить» запускается вручную.")
        }

        return SyncPlan(
            sourceID: source.id,
            sourceName: source.name,
            items: items,
            newlyMissing: newlyMissing,
            pendingRemovals: pending,
            staleExtraction: staleExtraction,
            tableRowsToEmbed: tableRowsToEmbed
        )
    }

    // MARK: - Schema hookup

    /// Which schema fields the source closes and which it leaves open.
    ///
    /// Static on purpose: auto fields and the source's own key-values are the
    /// same for every file, so the answer is known before the first byte is read
    /// and a mismatch can stop the run instead of surfacing halfway through.
    public func coverage(source: DataSource, schema: MetadataSchema) -> SourceSchemaCoverage {
        var provided = Set(Self.autoMetadataKeys)
        provided.formUnion(["file_name", "chunk_count", "chunk_estimated_tokens", "chunk_level"])
        // Written for every chunk of every file. `page_number`,
        // `heading_path` and the warnings are *not* here: they depend on what is
        // in the file, and a required schema field must not be satisfied by a
        // promise the pipeline can only sometimes keep.
        provided.formUnion(["extractor_id", "extractor_version", "container_format", "structure_source"])
        if source.chunking.strategy.producesLevels { provided.insert("parent_chunk_id") }
        if source.mapping != .folderToCollection { provided.insert("relative_path") }
        provided.formUnion(source.customMetadata.keys.filter { !$0.isEmpty })

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
        let problems = validator.validate(probe, against: schema).violations
            .filter { $0.kind == .wrongType }

        return SourceSchemaCoverage(
            collectionName: schema.collectionName,
            providedKeys: provided.sorted(),
            uncoveredRequiredFields: uncovered,
            typeProblems: problems
        )
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
        if let preparedPlan {
            plan = preparedPlan
        } else {
            plan = try await self.plan(source: source, embeddingModel: embeddingModel)
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
                staleExtraction: plan.staleExtraction
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
        let signature = source.chunking.signature
        var added = 0
        var updated = 0
        var chunksWritten = 0
        var chunksDeleted = 0
        var marked: [String] = []
        var substituted: [(file: String, reason: String)] = []
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
        var tableReports: [TableSyncReport] = []

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
                            profiles: source.tableProfiles,
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
                    tableReports.append(report)
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
            let chunks = try await Self.plannedChunks(
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
            if let oversized = chunks.first(where: {
                ContextBudget.check($0.text, contextLength: contextLength).blocksSending
            }) {
                let verdict = ContextBudget.check(oversized.text, contextLength: contextLength)
                let tokens = TokenEstimator.estimatedTokens(oversized.text)
                let reason = String(localized: "чанк \(oversized.index + 1) длиннее контекста модели (≈\(tokens) токенов): \(verdict.message ?? "")")
                skipped.append((item.relativePath, reason))
                // «Повторить» after the chunk size has been changed — the reason
                // says what to change, the action is what to do afterwards.
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
                modifiedAt: item.modifiedAt,
                size: item.size,
                chunkingSignature: signature,
                embeddingModel: embeddingModel,
                warnings: extracted.warnings.map(\.text)
            )
            // The intent reaches the disk **before** the database is touched.
            // Everything below can be interrupted; only a record written first
            // makes the interruption recoverable.
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
                        schema: schema, collectionID: collectionID, model: embeddingModel,
                        dimension: dimension, chroma: chroma, embeddings: embeddings
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
                    schema: schema, collectionID: collectionID, model: embeddingModel,
                    dimension: dimension, chroma: chroma, embeddings: embeddings
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
        }

        progress(SyncProgress(
            stage: String(localized: "Готово"),
            processedFiles: writeItems.count, totalFiles: writeItems.count,
            chunksWritten: chunksWritten
        ))

        // Replaced wholesale rather than merged: a file that read cleanly this
        // time is not still broken because it was broken last week.
        manifest.problems = runProblems
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
            heterogeneousCollections: heterogeneous,
            staleExtraction: plan.staleExtraction
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

        let filter = DocumentFilter(conditions: [
            MetadataCondition(field: "source_id", op: .equals, value: sourceID.uuidString),
            MetadataCondition(field: "source_file", op: .equals, value: relativePath),
        ])
        do {
            return try await chroma.deleteDocuments(collectionID: id, filter: filter)
        } catch {
            // Older or stricter servers might refuse the filter; the ids we
            // remembered still let us clean up.
            guard !knownIDs.isEmpty else { throw error }
            try await chroma.deleteDocuments(collectionID: id, ids: knownIDs)
            return knownIDs.count
        }
    }

    private func flush(
        _ chunks: [TextChunk],
        relativePath: String,
        baseMetadata: ChromaMetadata,
        placements: [Int: ChunkPlacement],
        schema: MetadataSchema?,
        collectionID: String,
        model: String,
        dimension: Int,
        chroma: any SyncDatabase,
        embeddings: EmbeddingProvider
    ) async throws {
        if Task.isCancelled { throw SyncError.cancelled }
        let embeddingStarted = Date()
        let vectors = try await embeddings.embed(texts: chunks.map(\.text), model: model)
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
        try await chroma.upsert(collectionID: collectionID, records: records)
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
            metadata["file_name"] = .string(item.url.lastPathComponent)
        }
        // ChromaDB metadata has no arrays: a flat string with a
        // separator, not a list.
        if !extracted.warnings.isEmpty {
            metadata["extraction_warnings"] = .string(extracted.warnings.map(\.text).joined(separator: "; "))
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
    public static func documentID(relativePath: String, chunkIndex: Int) -> String {
        let digest = SHA256.hash(data: Data(relativePath.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(hash)-\(chunkIndex)"
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
        case .documentBased, .hierarchical:
            return document.structure.isEmpty ? .noStructure(configuration.strategy) : nil
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
    static func stamp(of url: URL, registry: ExtractorRegistry) -> ExtractorStamp {
        guard let type = ExtractorRegistry.type(of: url),
              let extractor = registry.all.first(where: { $0.canHandle(type) }) else {
            return ExtractorStamp(id: "", version: 0)
        }
        return ExtractorStamp(id: extractor.id, version: extractor.version)
    }

    public static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
            embeddingModel: "", dimension: 0, profiles: source.tableProfiles,
            assignedProfileID: source.tableProfileAssignments[relativePath]
        )
        let planned = await tables.plan(sheets: read.sheets, manifest: manifest, context: context)
        return planned.plans.reduce(0) { $0 + $1.plan.embeddings }
    }
}
