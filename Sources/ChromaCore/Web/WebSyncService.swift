import Foundation

/// Готовит веб-источник к синхронизации (I1.1–I1.4).
///
/// Обход, загрузка и разбор кончаются здесь: дальше страницы идут ровно тем же
/// путём, что и файлы с диска, — тот же план, тот же манифест, тот же журнал,
/// те же стратегии чанкинга. Это не экономия сил, а требование: два разных пути
/// записи в базу разошлись бы через месяц, и разошлись бы молча.
public final class WebSyncService {
    /// Всё, что нужно синхронизации, чтобы записать страницы как файлы.
    public struct Preparation {
        public var plan: SyncPlan
        public var crawl: CrawlSummary
        /// Что запомнить о страницах до следующего раза. Сохраняется **после**
        /// удачной записи, а не сразу: иначе прерванный запуск научил бы
        /// приложение отвечать «не менялось» о странице, которой в базе нет.
        public var records: [String: WebPageRecord]
        /// Временная папка с телами страниц. Живёт ровно один запуск.
        public var cacheDirectory: URL

        public func discardCache() {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    private let registry: ExtractorRegistry
    private let pages: WebPageStore
    private let crawler: (WebSourceSettings) -> SiteCrawler
    private let log: LogHandler

    public init(
        registry: ExtractorRegistry = .standard(),
        pages: WebPageStore = WebPageStore(),
        version: String = "1.0",
        crawler: ((WebSourceSettings) -> SiteCrawler)? = nil,
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.registry = registry
        self.pages = pages
        self.log = log
        let agent = WebFetcher.userAgent(version: version)
        self.crawler = crawler ?? { settings in
            SiteCrawler(
                fetcher: WebFetcher(
                    userAgent: agent,
                    limits: WebFetcher.Limits(maxBytes: max(1, settings.maxTotalMegabytes) * 1024 * 1024)
                ),
                userAgent: agent,
                log: log
            )
        }
    }

    public func history(sourceID: UUID) -> [String: WebPageRecord] { pages.load(sourceID: sourceID) }

    public func saveHistory(_ records: [String: WebPageRecord], sourceID: UUID) {
        pages.save(records, sourceID: sourceID)
    }

    public func forget(sourceID: UUID) { pages.remove(sourceID: sourceID) }

    public enum WebSyncError: LocalizedError {
        case notWeb(String)
        case misconfigured(String)

        public var errorDescription: String? {
            switch self {
            case .notWeb(let name):
                return String(localized: "Источник «\(name)» — не веб-источник.")
            case .misconfigured(let reason):
                return reason
            }
        }
    }

    /// Обходит источник и строит план — тот же самый, что строит папка.
    public func prepare(
        source: DataSource,
        embeddingModel: String,
        manifest: SourceManifest,
        progress: ((_ processed: Int, _ queued: Int, _ current: String) -> Void)? = nil
    ) async throws -> Preparation {
        guard let settings = source.web else { throw WebSyncError.notWeb(source.name) }
        if let problem = settings.problem { throw WebSyncError.misconfigured(problem) }
        guard let start = settings.start else {
            throw WebSyncError.misconfigured(String(localized: "Стартовый адрес не разобрался."))
        }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromadb-web-\(source.id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let known = pages.load(sourceID: source.id)
        let signature = source.chunking.signature
        let extractionSignature = source.extractionSignature

        var items: [SyncPlanItem] = []
        var records: [String: WebPageRecord] = [:]
        var visitedKeys: Set<String> = []

        let summary = await crawler(settings).crawl(
            from: start,
            limits: settings.limits,
            history: { url in known[SiteCrawler.normalise(url)]?.history },
            also: settings.seeds,
            progress: { done, queued in progress?(done, queued, "") }
        ) { page in
            let key = Self.key(of: page)
            guard visitedKeys.insert(key).inserted else { return }
            progress?(visitedKeys.count, 0, key)

            let previous = known[SiteCrawler.normalise(page.url)] ?? known[key]

            // Сервер сказал «не менялось» — это самый дешёвый ответ из
            // возможных, и пересчитывать по нему нечего.
            if page.resource.isNotModified {
                if var record = previous {
                    record.fetchedAt = Date()
                    record.status = 304
                    records[key] = record
                    items.append(Self.item(
                        key: key, page: page, record: record, kind: .unchanged,
                        collectionName: source.collectionName, cache: nil, textLength: nil
                    ))
                }
                return
            }

            do {
                let file = try Self.write(page: page, to: cacheDirectory)
                let extracted: ExtractedDocument
                if let parsed = page.page {
                    // HTML уже разобран ради ссылок — второй раз незачем.
                    extracted = HTMLExtractor.document(from: parsed)
                } else {
                    // Не-HTML уходит в реестр экстракторов этапа 4 — по типу
                    // ответа, а не по расширению в адресе.
                    extracted = try await registry.extract(from: file, options: ExtractionOptions())
                }
                guard !extracted.plainText.trimmed.isEmpty else {
                    throw ExtractionError.empty
                }

                let hash = SourceSyncService.contentHash(of: extracted.plainText)
                let entry = manifest.entries[key]
                let recipeMismatch = Self.recipeMismatch(
                    entry: entry, signature: signature, embeddingModel: embeddingModel,
                    extractionSignature: extractionSignature, collectionName: source.collectionName
                )
                let kind: SyncItemKind
                switch SyncDecisionRules.decideRead(entry: entry, contentHash: hash, recipeMismatch: recipeMismatch) {
                case .new: kind = .new
                case .reindex(let reason): kind = .changed(reason: reason)
                case .touch, .skip, .needsReextraction: kind = .unchanged
                }

                var record = WebPageRecord(
                    url: page.url.absoluteString,
                    canonicalURL: page.page?.canonicalURL,
                    etag: page.resource.etag,
                    lastModified: page.resource.lastModified,
                    contentHash: hash,
                    title: page.page?.title,
                    contentType: page.resource.contentType,
                    status: page.resource.status,
                    fetchedAt: Date(),
                    links: page.page?.links ?? []
                )
                // Ключ — это адрес, под которым страница живёт в базе. Если он
                // канонический, помнить надо и его: спрашивать сервер придётся
                // о том адресе, по которому мы ходили.
                record.url = page.url.absoluteString
                records[key] = record
                if SiteCrawler.normalise(page.url) != key { records[SiteCrawler.normalise(page.url)] = record }

                items.append(Self.item(
                    key: key, page: page, record: record, kind: kind,
                    collectionName: source.collectionName, cache: file,
                    textLength: extracted.plainText.count, contentHash: hash
                ))
            } catch {
                items.append(Self.item(
                    key: key, page: page,
                    record: WebPageRecord(url: page.url.absoluteString, status: page.resource.status),
                    kind: .skipped(
                        reason: SourceSyncService.reason(for: error),
                        remedy: FileProblem.remedy(for: error)
                    ),
                    collectionName: source.collectionName, cache: nil, textLength: nil
                ))
            }
        }

        // Страницы, которые обход не смог взять, — это не пропавшие страницы,
        // а известные беды с точной причиной.
        for problem in summary.problems {
            guard !visitedKeys.contains(SiteCrawler.normalise(URL(string: problem.url) ?? start)) else { continue }
            items.append(SyncPlanItem(
                relativePath: problem.url,
                url: URL(string: problem.url) ?? start,
                kind: .skipped(reason: problem.reason, remedy: .retry),
                collectionName: source.collectionName,
                size: 0, modifiedAt: Date(), isRemote: true
            ))
        }

        // Страница, которой в этот раз не нашлось, из базы не удаляется:
        // решение за человеком (правило 1 приложения 5, общее правило 8.4).
        let planned = Set(items.map(\.relativePath))
        var newlyMissing: [PendingRemoval] = []
        var pendingRemovals = manifest.pendingRemovals
        for (path, entry) in manifest.entries where !planned.contains(path) {
            guard !entry.isOrphaned else { continue }
            guard !pendingRemovals.contains(where: { $0.relativePath == path }) else { continue }
            let removal = PendingRemoval(
                relativePath: path, collectionName: entry.collectionName, chunkIDs: entry.chunkIDs
            )
            newlyMissing.append(removal)
            pendingRemovals.append(removal)
        }

        let plan = SyncPlan(
            sourceID: source.id,
            sourceName: source.name,
            items: items.sorted { $0.relativePath < $1.relativePath },
            newlyMissing: newlyMissing,
            pendingRemovals: pendingRemovals
        )
        log(.info, "Веб", "Источник «\(source.name)»: страниц \(summary.visited.count.plainDigits), к записи \(plan.writeItems.count.plainDigits), проблем \(summary.problems.count.plainDigits)")
        return Preparation(plan: plan, crawl: summary, records: records, cacheDirectory: cacheDirectory)
    }

    // MARK: - Мелочи

    /// Адрес, под которым страница живёт в базе.
    ///
    /// Канонический, если страница его объявила: одна и та же статья по трём
    /// адресам иначе станет тремя документами.
    static func key(of page: CrawledPage) -> String {
        if let canonical = page.page?.canonicalURL,
           let url = URL(string: canonical), url.host != nil {
            return SiteCrawler.normalise(url)
        }
        return SiteCrawler.normalise(page.url)
    }

    private static func recipeMismatch(
        entry: ManifestEntry?, signature: String, embeddingModel: String,
        extractionSignature: String, collectionName: String
    ) -> String? {
        guard let entry else { return nil }
        if entry.chunkingSignature != signature { return String(localized: "изменились параметры чанкинга") }
        if entry.embeddingModel != embeddingModel { return String(localized: "сменилась модель эмбеддинга") }
        if !entry.extractionSignature.isEmpty, entry.extractionSignature != extractionSignature {
            return String(localized: "изменились параметры извлечения")
        }
        if entry.collectionName != collectionName { return String(localized: "сменилась коллекция назначения") }
        return nil
    }

    private static func item(
        key: String, page: CrawledPage, record: WebPageRecord, kind: SyncItemKind,
        collectionName: String, cache: URL?, textLength: Int?, contentHash: String? = nil
    ) -> SyncPlanItem {
        SyncPlanItem(
            relativePath: key,
            url: cache ?? page.url,
            kind: kind,
            collectionName: collectionName,
            size: Int64(page.resource.data.count),
            modifiedAt: record.fetchedAt,
            contentHash: contentHash,
            textLength: textLength,
            // Метаданные чанков веб-страницы, как их перечисляет I1.2.
            routeMetadata: Self.metadata(key: key, page: page, record: record),
            isRemote: true
        )
    }

    static func metadata(key: String, page: CrawledPage, record: WebPageRecord) -> ChromaMetadata {
        var metadata: ChromaMetadata = [
            "source_url": .string(page.url.absoluteString),
            "fetched_at": .string(ISO8601DateFormatter().string(from: record.fetchedAt)),
            "http_status": .int(record.status),
        ]
        if let title = record.title, !title.isEmpty { metadata["page_title"] = .string(title) }
        if let type = record.contentType, !type.isEmpty { metadata["content_type"] = .string(type) }
        if let canonical = record.canonicalURL, !canonical.isEmpty {
            metadata["canonical_url"] = .string(canonical)
        }
        return metadata
    }

    /// Кладёт тело страницы в файл — экстракторам этапа 4 нужен файл, а не байты.
    static func write(page: CrawledPage, to directory: URL) throws -> URL {
        let name = SourceSyncService.documentID(relativePath: key(of: page), chunkIndex: 0)
        let file = directory.appendingPathComponent("\(name).\(Self.extension(for: page.resource))")
        try page.resource.data.write(to: file, options: .atomic)
        return file
    }

    /// Расширение по типу ответа, а не по адресу: за `report.html` регулярно
    /// лежит PDF.
    static func `extension`(for resource: WebResource) -> String {
        switch resource.mediaType {
        case "text/html", "application/xhtml+xml": return "html"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "application/epub+zip": return "epub"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "text/csv": return "csv"
        case "application/rtf", "text/rtf": return "rtf"
        default:
            return resource.url.pathExtension.isEmpty ? "bin" : resource.url.pathExtension.lowercased()
        }
    }
}
