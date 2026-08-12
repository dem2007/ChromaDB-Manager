import XCTest
import AppKit
import PDFKit
@testable import ChromaCore

/// §I1.1, I1.2, I1.4 — веб-источник готовится к синхронизации так же, как папка.
final class WebSyncServiceTests: XCTestCase {
    private var directory: URL!
    private var store: WebPageStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WebPageStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Подставной сайт

    private final class FakeSite: @unchecked Sendable {
        struct Reply {
            var status = 200
            var type: String? = "text/html; charset=utf-8"
            var body = Data()
            var etag: String?
        }

        var replies: [String: Reply] = [:]
        /// Адреса, о которых сервер отвечает «не менялось», если спросить
        /// условным запросом.
        var unchangedIfAsked: Set<String> = []
        private(set) var asked: [String] = []

        func html(_ path: String, title: String = "Страница", body: String, canonical: String? = nil, etag: String? = nil) {
            let head = canonical.map { "<link rel=\"canonical\" href=\"\($0)\">" } ?? ""
            replies[path] = Reply(
                body: Data("<html><head><title>\(title)</title>\(head)</head><body><h1>\(title)</h1><p>\(body)</p></body></html>".utf8),
                etag: etag
            )
        }

        func fetch(_ url: URL, _ etag: String?, _ lastModified: String?) async throws -> WebResource {
            asked.append(url.absoluteString)
            let path = url.path.isEmpty ? "/" : url.path
            guard let reply = replies[path] else {
                return WebResource(url: url, status: 404, data: Data(), contentType: nil, etag: nil, lastModified: nil)
            }
            if etag != nil, unchangedIfAsked.contains(path) {
                return WebResource(url: url, status: 304, data: Data(), contentType: nil, etag: etag, lastModified: nil)
            }
            return WebResource(
                url: url, status: reply.status, data: reply.body,
                contentType: reply.type, etag: reply.etag, lastModified: nil
            )
        }
    }

    private func service(_ site: FakeSite) -> WebSyncService {
        WebSyncService(
            pages: store,
            crawler: { _ in
                SiteCrawler(
                    userAgent: "ChromaDBManager/1.0",
                    fetch: { try await site.fetch($0, $1, $2) },
                    pause: { _ in }
                )
            }
        )
    }

    private func source(_ settings: WebSourceSettings) -> DataSource {
        DataSource(name: "Сайт", path: settings.startURL, collectionName: "web", web: settings)
    }

    private let singlePage = WebSourceSettings(kind: .page, startURL: "https://example.org/note")

    // MARK: - Первая индексация

    func testAPageBecomesAPlanItemWithItsOwnMetadata() async throws {
        let site = FakeSite()
        site.html("/note", title: "Заметка о базах", body: "Достаточно длинный текст про хранение данных.")

        let preparation = try await service(site).prepare(
            source: source(singlePage), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        let item = try XCTUnwrap(preparation.plan.items.first)
        XCTAssertEqual(item.relativePath, "https://example.org/note")
        XCTAssertEqual(item.kind, .new)
        XCTAssertTrue(item.isRemote)
        XCTAssertEqual(item.routeMetadata["source_url"], .string("https://example.org/note"))
        XCTAssertEqual(item.routeMetadata["page_title"], .string("Заметка о базах"))
        XCTAssertEqual(item.routeMetadata["http_status"], .int(200))
        XCTAssertEqual(item.routeMetadata["content_type"], .string("text/html; charset=utf-8"))
        XCTAssertNotNil(item.routeMetadata["fetched_at"])
    }

    /// Идентификатор считается от адреса — та же схема, что и для файлов,
    /// с URL вместо относительного пути.
    func testTheIdentifierComesFromTheAddress() async throws {
        let site = FakeSite()
        site.html("/note", body: "Достаточно длинный текст про хранение данных.")

        let preparation = try await service(site).prepare(
            source: source(singlePage), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        let id = SourceSyncService.documentID(relativePath: "https://example.org/note", chunkIndex: 0)
        XCTAssertTrue(id.hasSuffix("-0"))
        XCTAssertEqual(id.count, 18)
    }

    /// Одна и та же статья по трём адресам иначе стала бы тремя документами.
    func testACanonicalAddressWinsOverTheOneWeCameBy() async throws {
        let site = FakeSite()
        site.html(
            "/note", body: "Достаточно длинный текст про хранение данных.",
            canonical: "https://example.org/canonical-note"
        )

        let preparation = try await service(site).prepare(
            source: source(WebSourceSettings(kind: .page, startURL: "https://example.org/note?utm_source=письмо")),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        XCTAssertEqual(preparation.plan.items.first?.relativePath, "https://example.org/canonical-note")
        XCTAssertEqual(
            preparation.plan.items.first?.routeMetadata["canonical_url"],
            .string("https://example.org/canonical-note")
        )
    }

    // MARK: - Повторная синхронизация

    /// Ответ 304 — страница не менялась, пересчитывать нечего.
    func testAnUnchangedPageIsNotReembedded() async throws {
        let site = FakeSite()
        site.html("/note", body: "Достаточно длинный текст про хранение данных.", etag: "\"v1\"")
        let source = source(singlePage)
        let service = service(site)

        let first = try await service.prepare(
            source: source, embeddingModel: "e5", manifest: SourceManifest(sourceID: source.id)
        )
        first.discardCache()
        service.saveHistory(first.records, sourceID: source.id)

        // Манифест такой, каким его оставила бы удачная запись.
        var manifest = SourceManifest(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "https://example.org/note",
            contentHash: first.records["https://example.org/note"]?.contentHash ?? "",
            modifiedAt: Date(), size: 100, chunkIDs: ["a-0"], collectionName: "web",
            chunkingSignature: source.chunking.signature, embeddingModel: "e5",
            extractionSignature: source.extractionSignature
        ))

        site.unchangedIfAsked = ["/note"]
        let second = try await service.prepare(source: source, embeddingModel: "e5", manifest: manifest)
        defer { second.discardCache() }

        XCTAssertEqual(second.plan.items.first?.kind, .unchanged)
        XCTAssertTrue(second.plan.writeItems.isEmpty, "векторы не пересчитываются")
    }

    /// Сервер без условных запросов: сравнивать приходится содержимое, и вывод
    /// тот же — не менялось.
    func testWithoutValidatorsTheTextItselfIsCompared() async throws {
        let site = FakeSite()
        site.html("/note", body: "Достаточно длинный текст про хранение данных.")
        let source = source(singlePage)
        let service = service(site)

        let first = try await service.prepare(
            source: source, embeddingModel: "e5", manifest: SourceManifest(sourceID: source.id)
        )
        first.discardCache()

        var manifest = SourceManifest(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "https://example.org/note",
            contentHash: first.plan.items.first?.contentHash ?? "",
            modifiedAt: Date(), size: 100, chunkIDs: ["a-0"], collectionName: "web",
            chunkingSignature: source.chunking.signature, embeddingModel: "e5",
            extractionSignature: source.extractionSignature
        ))

        let second = try await service.prepare(source: source, embeddingModel: "e5", manifest: manifest)
        defer { second.discardCache() }
        XCTAssertEqual(second.plan.items.first?.kind, .unchanged)
    }

    func testAnEditedPageIsPlannedAsChanged() async throws {
        let site = FakeSite()
        site.html("/note", body: "Достаточно длинный текст про хранение данных.")
        let source = source(singlePage)

        var manifest = SourceManifest(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "https://example.org/note",
            contentHash: "старое-содержимое",
            modifiedAt: Date(), size: 100, chunkIDs: ["a-0"], collectionName: "web",
            chunkingSignature: source.chunking.signature, embeddingModel: "e5",
            extractionSignature: source.extractionSignature
        ))

        let preparation = try await service(site).prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        )
        defer { preparation.discardCache() }
        guard case .changed = preparation.plan.items.first?.kind else {
            return XCTFail("страница с другим текстом должна попасть в план")
        }
    }

    /// Страница исчезла — из базы её никто не удаляет, решение за человеком
    /// (правило 1 приложения 5, общее правило 8.4).
    func testAVanishedPageWaitsForADecisionInsteadOfBeingDeleted() async throws {
        let site = FakeSite()
        site.html("/note", body: "Достаточно длинный текст про хранение данных.")
        let source = source(singlePage)

        var manifest = SourceManifest(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "https://example.org/ушла",
            contentHash: "x", modifiedAt: Date(), size: 1, chunkIDs: ["b-0", "b-1"],
            collectionName: "web", chunkingSignature: source.chunking.signature, embeddingModel: "e5"
        ))

        let preparation = try await service(site).prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        )
        defer { preparation.discardCache() }

        XCTAssertEqual(preparation.plan.newlyMissing.map(\.relativePath), ["https://example.org/ушла"])
        XCTAssertEqual(preparation.plan.pendingRemovals.first?.chunkIDs, ["b-0", "b-1"])
    }

    // MARK: - Не-HTML и особые случаи

    /// PDF по ссылке обрабатывается экстрактором этапа 4, и решает это тип
    /// ответа, а не расширение в адресе.
    @MainActor
    func testAPDFBehindAnHTMLAddressGoesToTheStageFourExtractor() async throws {
        let site = FakeSite()
        site.replies["/report.html"] = FakeSite.Reply(
            type: "application/pdf", body: try Self.pdf(text: "Годовой отчёт о работе хранилища.")
        )

        let preparation = try await service(site).prepare(
            source: source(WebSourceSettings(kind: .page, startURL: "https://example.org/report.html")),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        let item = try XCTUnwrap(preparation.plan.items.first)
        XCTAssertEqual(item.kind, .new)
        XCTAssertEqual(item.url.pathExtension, "pdf", "тип ответа, а не расширение адреса")
        XCTAssertEqual(item.routeMetadata["content_type"], .string("application/pdf"))
        XCTAssertNotNil(item.textLength)
    }

    /// Страница, которую рисует скрипт, попадает в «требуют решения» с точной
    /// причиной, а не индексируется пустой.
    func testAScriptRenderedPageIsReportedWithItsReason() async throws {
        let site = FakeSite()
        site.replies["/app"] = FakeSite.Reply(body: Data("<html><body><div id=\"root\"></div></body></html>".utf8))

        let preparation = try await service(site).prepare(
            source: source(WebSourceSettings(kind: .page, startURL: "https://example.org/app")),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        let item = try XCTUnwrap(preparation.plan.items.first)
        guard case .skipped(let reason, _) = item.kind else { return XCTFail("ожидался пропуск: \(item.kind)") }
        XCTAssertTrue(reason.contains("рисуется скриптом"), reason)
        XCTAssertTrue(preparation.plan.writeItems.isEmpty)
    }

    /// Список адресов — это список, а не обход: ходят ровно туда, куда сказали.
    func testAListOfAddressesReadsExactlyWhatItWasGiven() async throws {
        let site = FakeSite()
        site.html("/one", body: "Достаточно длинный текст первой страницы списка.")
        site.html("/two", body: "Достаточно длинный текст второй страницы списка.")

        let settings = WebSourceSettings(
            kind: .list, startURL: "https://example.org/one",
            additionalURLs: ["https://example.org/two"]
        )
        let preparation = try await service(site).prepare(
            source: source(settings), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        )
        defer { preparation.discardCache() }

        XCTAssertEqual(
            preparation.plan.items.map(\.relativePath),
            ["https://example.org/one", "https://example.org/two"]
        )
        XCTAssertFalse(site.asked.contains("https://example.org/sitemap.xml"), "список — не обход")
    }

    func testASourceWithoutAnAddressRefusesToRunRatherThanCrawlNothing() async {
        let site = FakeSite()
        do {
            _ = try await service(site).prepare(
                source: source(WebSourceSettings(kind: .page, startURL: "не адрес вовсе")),
                embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
            )
            XCTFail("источник без адреса запустился")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http"), error.localizedDescription)
        }
    }

    // MARK: - Мелочи

    func testTheExtensionComesFromTheAnswerType() {
        func resource(_ type: String, url: String = "https://example.org/x") -> WebResource {
            WebResource(
                url: URL(string: url)!, status: 200, data: Data(),
                contentType: type, etag: nil, lastModified: nil
            )
        }
        XCTAssertEqual(WebSyncService.extension(for: resource("text/html; charset=utf-8")), "html")
        XCTAssertEqual(WebSyncService.extension(for: resource("application/pdf")), "pdf")
        XCTAssertEqual(WebSyncService.extension(for: resource("text/plain")), "txt")
    }

    @MainActor
    private static func pdf(text: String) throws -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        var box = bounds
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            in: box.insetBy(dx: 60, dy: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
