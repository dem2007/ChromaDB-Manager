import Foundation

/// Что вернула страница.
public struct WebResource: Sendable {
    /// Адрес, на котором мы оказались, — после всех переадресаций. Именно он
    /// становится базой для относительных ссылок: переадресация на другой
    /// каталог иначе развернула бы их не туда.
    public let url: URL
    public let status: Int
    public let data: Data
    public let contentType: String?
    /// `ETag` и `Last-Modified` сохраняются, чтобы в следующий раз спросить
    /// «а изменилось ли» одним запросом.
    public let etag: String?
    public let lastModified: String?

    public init(
        url: URL, status: Int, data: Data, contentType: String?,
        etag: String?, lastModified: String?
    ) {
        self.url = url
        self.status = status
        self.data = data
        self.contentType = contentType
        self.etag = etag
        self.lastModified = lastModified
    }

    /// Сервер сказал «не менялось» — пересчитывать нечего.
    public var isNotModified: Bool { status == 304 }
    public var isSuccess: Bool { (200...299).contains(status) }
    /// Страница исчезла. **Не повод удалять** её чанки: по правилу 8.4 это
    /// попадает в «требуют решения».
    public var isGone: Bool { status == 404 || status == 410 }

    /// Тип без параметров: `text/html; charset=utf-8` → `text/html`.
    public var mediaType: String? {
        contentType?.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    public var isHTML: Bool {
        guard let mediaType else { return false }
        return mediaType == "text/html" || mediaType == "application/xhtml+xml"
    }
}

/// Загрузка страниц.
///
/// Отдельно от разбора и от обхода: в тесте нужно уметь подсунуть ответ, а
/// в приложении — настоящую сеть, и это единственное место, где она нужна.
public struct WebFetcher: Sendable {
    public struct Limits: Sendable, Hashable {
        /// Предел на одну страницу. Без него один архив по ссылке съедает
        /// память приложения.
        public var maxBytes: Int
        public var timeout: TimeInterval

        public init(maxBytes: Int = 10 * 1024 * 1024, timeout: TimeInterval = 30) {
            self.maxBytes = max(1024, maxBytes)
            self.timeout = max(1, timeout)
        }
    }

    public enum FetchError: LocalizedError, Equatable {
        case tooLarge(limit: Int)
        case notHTTP

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
                return String(localized: "Страница больше разрешённого размера (\(size)) — загрузка прервана.")
            case .notHTTP:
                return String(localized: "Ответ не по HTTP — такой адрес не индексируется.")
            }
        }
    }

    private let session: URLSession
    private let userAgent: String
    public let limits: Limits

    public init(session: URLSession? = nil, userAgent: String, limits: Limits = Limits()) {
        self.session = session ?? Self.makeSession(timeout: limits.timeout)
        self.userAgent = userAgent
        self.limits = limits
    }

    /// Своя сессия — **без** кэша `URLSession`.
    ///
    /// Найдено проверкой на живом сервере, а не выведено из документации:
    /// с общей сессией `ETag` из I1.4 не работает вовсе. `URLSession` держит
    /// свой кэш, сам делает условный запрос, получает 304 — и отдаёт нам
    /// **200 с телом из кэша**. Отличить «не менялось» от «менялось» становится
    /// нечем, и весь смысл условных запросов пропадает: тело приезжает каждый
    /// раз. Кэш здесь и не нужен: что менялось, а что нет, решает манифест.
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    /// Свой `User-Agent` с именем приложения и версией — так требует I1.2
    /// и так принято: администратор сайта должен понимать, кто к нему пришёл.
    public static func userAgent(version: String) -> String {
        "ChromaDBManager/\(version) (+локальная индексация; macOS)"
    }

    public func fetch(
        _ url: URL, etag: String? = nil, lastModified: String? = nil
    ) async throws -> WebResource {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: limits.timeout
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Условные заголовки — точный аналог правила «файл не менялся»
        // и работает дешевле него: сервер отвечает 304 без тела.
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }

        // Тело читается потоком с пределом: `data(for:)` сначала скачает
        // гигабайт и только потом даст на него посмотреть.
        var data = Data()
        if http.statusCode != 304 {
            data.reserveCapacity(min(limits.maxBytes, 64 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count > limits.maxBytes { throw FetchError.tooLarge(limit: limits.maxBytes) }
            }
        }

        return WebResource(
            url: http.url ?? url,
            status: http.statusCode,
            data: data,
            contentType: header(http, "Content-Type"),
            etag: header(http, "ETag"),
            lastModified: header(http, "Last-Modified")
        )
    }

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
