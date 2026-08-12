import Foundation
import AppKit

/// Глава EPUB для просмотрщика.
///
/// **Показывается одна глава, а не книга целиком.** Метаданные чанка называют
/// именно её (`chapter_id`, `spine_index`), собирать весь текст ради одного
/// абзаца незачем, а на книге в тысячу страниц это ещё и заметно.
///
/// Читается тем же `ZIPContainerReader` и тем же разбором пакета, что
/// извлечение: панель обязана открыть ровно тот файл, из которого
/// чанк был извлечён.
public enum EPUBChapterLoader {

    /// `@unchecked`: `NSAttributedString` не помечен `Sendable`, хотя
    /// неизменяем. Глава собирается один раз при чтении файла и дальше только
    /// читается — ни одна ссылка на неё не меняется. Проверять это должен
    /// человек, отсюда и «unchecked».
    public struct Chapter: @unchecked Sendable {
        public let text: NSAttributedString
        /// Название главы из оглавления, если оно там есть.
        public let title: String?
        /// Номер в порядке чтения, с единицы — как его назвали бы человеку.
        public let number: Int
        public let totalChapters: Int

        public init(text: NSAttributedString, title: String?, number: Int, totalChapters: Int) {
            self.text = text
            self.title = title
            self.number = number
            self.totalChapters = totalChapters
        }

        public var line: String {
            let name = title.map { "«\($0)»" } ?? String(localized: "без названия")
            return String(localized: "глава \(number) из \(totalChapters), \(name)")
        }
    }

    public enum LoadError: LocalizedError {
        case notAnEPUB
        case chapterMissing

        public var errorDescription: String? {
            switch self {
            case .notAnEPUB:
                return String(localized: "Файл не открылся как EPUB — возможно, он повреждён.")
            case .chapterMissing:
                return String(localized: "Главы, из которой взят фрагмент, в книге больше нет.")
            }
        }
    }

    /// Достаёт главу по идентификатору или по номеру в порядке чтения.
    ///
    /// Идентификатор надёжнее номера: книга могла быть пересобрана, и порядок
    /// сместился бы. Поэтому сначала он, а номер — запасной путь.
    @MainActor
    public static func chapter(
        at url: URL, chapterID: String?, spineIndex: Int?
    ) throws -> Chapter {
        guard let reader = try? ZIPContainerReader(url: url) else { throw LoadError.notAnEPUB }
        guard let packagePath = try? EPUBExtractor.packagePath(in: reader),
              let package = try? EPUBExtractor.readPackage(at: packagePath, reader: reader),
              !package.spine.isEmpty
        else { throw LoadError.notAnEPUB }

        let index: Int
        if let chapterID, let found = package.spine.firstIndex(where: { $0.id == chapterID }) {
            index = found
        } else if let spineIndex, spineIndex >= 0, spineIndex < package.spine.count {
            index = spineIndex
        } else {
            throw LoadError.chapterMissing
        }

        guard let data = try? reader.read(package.spine[index].path),
              let rendered = try? EPUBExtractor.renderHTML(data)
        else { throw LoadError.chapterMissing }

        return Chapter(
            text: rendered,
            title: title(of: package.spine[index].path, package: package, reader: reader),
            number: index + 1,
            totalChapters: package.spine.count
        )
    }

    /// Название главы из оглавления книги — там, где оно есть.
    ///
    /// Оглавления может не быть вовсе, и это не повод отказываться показывать
    /// главу: «глава 7 без названия» — нормальная подпись.
    @MainActor
    static func title(
        of path: String, package: EPUBExtractor.Package, reader: ZIPContainerReader
    ) -> String? {
        var entries: [EPUBExtractor.TOCEntry] = []
        if let navigation = package.navigationPath, let data = try? reader.read(navigation) {
            entries = EPUBExtractor.navigationEntries(
                data, base: (navigation as NSString).deletingLastPathComponent
            )
        }
        if entries.isEmpty, let ncx = package.ncxPath, let data = try? reader.read(ncx) {
            entries = EPUBExtractor.ncxEntries(data, base: (ncx as NSString).deletingLastPathComponent)
        }
        return entries.first { $0.path == path }?.title
    }
}
