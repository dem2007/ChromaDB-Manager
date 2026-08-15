import Foundation
import UniformTypeIdentifiers

/// HTML как документ, а не как текст с разметкой.
///
/// До него `.html` доставался обычному текстовому экстрактору, и в базу
/// попадали теги: искать по такому чанку бесполезно, а прочитать его человеку
/// невозможно. Здесь же берётся тот же разбор, что и для веб-страниц, — с
/// заголовками `h1`–`h6` в `structure`, а значит, для HTML работают
/// Document-based и Hierarchical чанкинг.
public struct HTMLExtractor: DocumentTextExtractor {
    public let id = "html"
    /// 3 — пункты перечислений получают маркер, а адреса ссылок доходят
    /// до метаданных чанка: до этого пункт `<li>` приходил
    /// голым текстом, и правило «вводная фраза списка» его не узнавало.
    ///
    /// 2 — таблицы страницы приходят разметкой Markdown, а не ячейками через
    /// пробел, и ставится `has_tables`.
    public let version = 3

    public init() {}

    public func canHandle(_ type: UTType) -> Bool {
        type.conforms(to: .html) || type.identifier == "public.xhtml"
    }

    public func extract(from url: URL, options: ExtractionOptions) async throws -> ExtractedDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= options.maxFileSize else {
            throw ExtractionError.tooLarge(size: size, limit: options.maxFileSize)
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ExtractionError.corrupted(String(localized: "файл не читается"))
        }
        let extracted = try Self.document(from: data, contentType: nil, baseURL: url)
        guard !extracted.plainText.isEmpty else { throw ExtractionError.empty }
        return extracted
    }

    /// Разбор без файла — им пользуется веб-источник, у которого страница уже
    /// в руках и второй раз с диска её читать незачем.
    public static func document(from data: Data, contentType: String?, baseURL: URL?) throws -> ExtractedDocument {
        let page = try HTMLParser.parse(data, contentType: contentType, baseURL: baseURL)
        return document(from: page)
    }

    public static func document(from page: HTMLPage) -> ExtractedDocument {
        let text = page.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata: [String: String] = [:]
        if let title = page.title, !title.isEmpty { metadata["title"] = title }
        if let language = page.language, !language.isEmpty { metadata["language"] = language }
        if let summary = page.summary, !summary.isEmpty { metadata["description"] = summary }

        return ExtractedDocument(
            plainText: text,
            structure: page.headings,
            links: page.placedLinks,
            // Заголовки размечены в самом документе — это не догадка по размеру
            // шрифта, а объявленная структура.
            structureSource: page.headings.isEmpty ? .none : .headings,
            containerFormat: "html",
            extractorID: "html",
            extractorVersion: 3,
            hasTables: page.hasTables,
            documentMetadata: metadata
        )
    }
}
