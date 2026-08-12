import Foundation

/// Что известно о странице с прошлой синхронизации.
///
/// Рядом с манифестом, а не внутри него: манифест отвечает на вопрос «что мы
/// записали в базу», а здесь — «о чём и как спрашивать сервер в следующий раз».
public struct WebPageRecord: Codable, Hashable, Sendable {
    /// Адрес, под которым страница живёт в манифесте и в идентификаторах.
    public var url: String
    /// Адрес, который страница объявила своим (`link rel="canonical"`).
    public var canonicalURL: String?
    public var etag: String?
    public var lastModified: String?
    /// SHA-256 извлечённого текста — на случай, если сервер условных запросов
    /// не поддерживает: тогда сравнивать приходится содержимое.
    public var contentHash: String
    public var title: String?
    public var contentType: String?
    public var status: Int
    public var fetchedAt: Date
    /// Ссылки этой страницы: на ответ 304 брать их больше неоткуда.
    public var links: [String]

    public init(
        url: String,
        canonicalURL: String? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        contentHash: String = "",
        title: String? = nil,
        contentType: String? = nil,
        status: Int = 200,
        fetchedAt: Date = Date(),
        links: [String] = []
    ) {
        self.url = url
        self.canonicalURL = canonicalURL
        self.etag = etag
        self.lastModified = lastModified
        self.contentHash = contentHash
        self.title = title
        self.contentType = contentType
        self.status = status
        self.fetchedAt = fetchedAt
        self.links = links
    }

    public var history: CrawlHistory {
        CrawlHistory(etag: etag, lastModified: lastModified, links: links)
    }
}

/// Файл на источник, ключ — адрес страницы.
public struct WebPageStore: Sendable {
    private let directory: URL

    public init(directory: URL = AppPaths.webPagesDirectory) {
        self.directory = directory
    }

    public func fileURL(for sourceID: UUID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    public func load(sourceID: UUID) -> [String: WebPageRecord] {
        guard let data = try? Data(contentsOf: fileURL(for: sourceID)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Испорченный файл — это одна лишняя перезагрузка страниц, а не потеря
        // данных: в базе всё на месте, сравнение просто пойдёт по содержимому.
        return (try? decoder.decode([String: WebPageRecord].self, from: data)) ?? [:]
    }

    public func save(_ records: [String: WebPageRecord], sourceID: UUID) {
        do {
            try AppPaths.ensureDirectory(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL(for: sourceID), options: .atomic)
        } catch {
            // Не записалось — в следующий раз просто спросим сервер без
            // условных заголовков. Ронять из-за этого синхронизацию нельзя.
        }
    }

    public func remove(sourceID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: sourceID))
    }
}
