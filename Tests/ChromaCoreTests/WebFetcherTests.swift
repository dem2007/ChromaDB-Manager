import XCTest
@testable import ChromaCore

/// Сеть, которой распоряжается тест.
///
/// Свой `URLProtocol`, а не поход в интернет: тест, зависящий от чужого сайта,
/// начинает падать не тогда, когда сломался код.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    /// Что отвечать и что при этом спросили. `nonisolated(unsafe)` —
    /// тестовый стенд однопоточный по построению.
    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.reply.status,
            httpVersion: "HTTP/1.1", headerFields: Self.reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.reply.body.isEmpty { client?.urlProtocol(self, didLoad: Self.reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// §I1.2, I1.4 — загрузка страницы и условные запросы.
final class WebFetcherTests: XCTestCase {
    private let url = URL(string: "https://example.org/page")!

    private func fetcher(maxBytes: Int = 10 * 1024 * 1024) -> WebFetcher {
        WebFetcher(
            session: StubProtocol.session(),
            userAgent: WebFetcher.userAgent(version: "1.2.3"),
            limits: .init(maxBytes: maxBytes)
        )
    }

    override func setUp() {
        StubProtocol.reply = .init()
        StubProtocol.lastRequest = nil
    }

    func testTheRequestIntroducesItself() async throws {
        StubProtocol.reply = .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8))
        _ = try await fetcher().fetch(url)

        let agent = try XCTUnwrap(StubProtocol.lastRequest?.value(forHTTPHeaderField: "User-Agent"))
        // Администратор сайта должен понимать, кто к нему пришёл, и какой
        // версии: без версии жалоба «ваш робот сломал мне сервер» неразрешима.
        XCTAssertTrue(agent.hasPrefix("ChromaDBManager/1.2.3"), agent)
    }

    func testConditionalHeadersAreSentAndAnswerIsUnderstood() async throws {
        StubProtocol.reply = .init(status: 304, headers: [:], body: Data())
        let resource = try await fetcher().fetch(
            url, etag: "\"abc\"", lastModified: "Wed, 21 Oct 2026 07:28:00 GMT"
        )

        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        XCTAssertEqual(
            StubProtocol.lastRequest?.value(forHTTPHeaderField: "If-Modified-Since"),
            "Wed, 21 Oct 2026 07:28:00 GMT"
        )
        XCTAssertTrue(resource.isNotModified)
        XCTAssertTrue(resource.data.isEmpty)
    }

    /// Найдено на живом сервере: с общей сессией условные запросы не работают
    /// вовсе. `URLSession` держит свой кэш, сам спрашивает сервер, получает 304
    /// и отдаёт нам 200 с телом из кэша — отличить «не менялось» от «менялось»
    /// становится нечем. Своя сессия без кэша — единственный способ, чтобы
    /// валидаторы из I1.4 вообще что-то значили.
    func testOurOwnValidatorsAreNotOverriddenByTheSystemCache() async throws {
        let session = WebFetcher.makeSession(timeout: 30)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        StubProtocol.reply = .init(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html/>".utf8))
        _ = try await fetcher().fetch(url)
        XCTAssertEqual(StubProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testValidatorsComeBackForNextTime() async throws {
        StubProtocol.reply = .init(
            status: 200,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "ETag": "\"v2\"",
                "Last-Modified": "Thu, 01 Jan 2026 00:00:00 GMT",
            ],
            body: Data("<html><body><p>Текст</p></body></html>".utf8)
        )
        let resource = try await fetcher().fetch(url)

        XCTAssertEqual(resource.etag, "\"v2\"")
        XCTAssertEqual(resource.lastModified, "Thu, 01 Jan 2026 00:00:00 GMT")
        XCTAssertTrue(resource.isHTML)
        XCTAssertEqual(resource.mediaType, "text/html")
    }

    /// Без предела один архив по ссылке съедает память приложения. Обрыв
    /// обязан случиться **во время** чтения, а не после.
    func testAnOversizedBodyIsRefusedRatherThanLoaded() async {
        StubProtocol.reply = .init(
            status: 200, headers: ["Content-Type": "application/zip"],
            body: Data(repeating: 0x41, count: 200_000)
        )
        do {
            _ = try await fetcher(maxBytes: 50_000).fetch(url)
            XCTFail("огромный ответ принят")
        } catch let error as WebFetcher.FetchError {
            XCTAssertEqual(error, .tooLarge(limit: 50_000))
            // Причина обязана быть читаемой: её увидит человек в списке
            // «требуют решения», а не программист в отладчике.
            XCTAssertTrue(error.localizedDescription.contains("больше разрешённого"), error.localizedDescription)
        } catch {
            XCTFail("не та ошибка: \(error)")
        }
    }

    /// Исчезнувшая страница — не повод удалять её чанки (правило 1
    /// приложения 5, общее правило 8.4).
    func testAGonePageIsRecognisedButNotTreatedAsDeletion() async throws {
        StubProtocol.reply = .init(status: 404, headers: [:], body: Data())
        let resource = try await fetcher().fetch(url)
        XCTAssertTrue(resource.isGone)
        XCTAssertFalse(resource.isSuccess)
    }

    func testNonHTMLIsRecognisedByTypeNotByExtension() async throws {
        StubProtocol.reply = .init(
            status: 200, headers: ["Content-Type": "application/pdf"], body: Data("%PDF-1.4".utf8)
        )
        // Адрес заканчивается на `.html`, а по ссылке PDF: расширение в URL
        // ничего не решает.
        let resource = try await fetcher().fetch(URL(string: "https://example.org/report.html")!)
        XCTAssertFalse(resource.isHTML)
        XCTAssertEqual(resource.mediaType, "application/pdf")
    }
}
