import Foundation
import PDFKit

/// Где в PDF стоит фрагмент и что подсветить.
///
/// Отдельно от вьюхи, потому что это решение, а не отрисовка: какую страницу
/// открыть, что выделить и что при этом честно сказать человеку. Проверяется
/// тестом на настоящем `PDFDocument`, собранном тут же.
public enum PDFFragmentFinder {

    public struct Location: Sendable {
        /// Индекс страницы с нуля — как их нумерует PDFKit.
        public let pageIndex: Int
        /// Диапазон символов на этой странице, или `nil` — открыть без
        /// подсветки (четвёртый исход H1.2).
        public let characterRange: Range<Int>?
        public let strategy: FragmentLocator.Strategy?
        /// Страница, названная метаданными, не совпала с найденной.
        ///
        /// Обычное дело: у книги есть обложка и римская нумерация, и
        /// `page_number` из извлечения может отличаться от того, что показывает
        /// просмотрщик. Молчать об этом нельзя — человек решит, что приложение
        /// показало не тот документ.
        public let pageDiffersFromMetadata: Bool

        public init(
            pageIndex: Int,
            characterRange: Range<Int>?,
            strategy: FragmentLocator.Strategy?,
            pageDiffersFromMetadata: Bool = false
        ) {
            self.pageIndex = pageIndex
            self.characterRange = characterRange
            self.strategy = strategy
            self.pageDiffersFromMetadata = pageDiffersFromMetadata
        }

        /// Что написать под просмотрщиком. `nil` — всё точно, говорить нечего.
        public var note: String? {
            guard let strategy else {
                return String(localized: "Точное место в документе определить не удалось — открыта страница \(pageIndex + 1) целиком.")
            }
            var parts: [String] = []
            if !strategy.isExact { parts.append(strategy.title) }
            if pageDiffersFromMetadata {
                parts.append(String(localized: "фрагмент найден на странице \(pageIndex + 1), хотя при индексации записана другая"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ").capitalizedFirst
        }
    }

    /// Ищет фрагмент, начиная со страницы из метаданных.
    ///
    /// **Почему поиск не ограничен этой страницей.** Номер страницы приходит
    /// из извлечения, а оно нумерует страницы своим счётом; расхождение на
    /// обложку — обычное дело. Ограничься мы одной страницей, функция
    /// работала бы «через раз» ровно на тех документах, ради которых
    /// затевалась. Поэтому: сначала названная страница, потом соседние,
    /// потом весь документ.
    public static func locate(
        chunk: String,
        in document: PDFDocument,
        startingAt page: Int?
    ) -> Location? {
        guard document.pageCount > 0 else { return nil }
        let hinted = page.map { max(0, min($0 - 1, document.pageCount - 1)) }

        for index in searchOrder(hint: hinted, pageCount: document.pageCount) {
            guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
            guard let match = FragmentLocator.locate(chunk: chunk, in: text) else { continue }
            let range = text.distance(from: text.startIndex, to: match.range.lowerBound)
                ..< text.distance(from: text.startIndex, to: match.range.upperBound)
            return Location(
                pageIndex: index,
                characterRange: range,
                strategy: match.strategy,
                pageDiffersFromMetadata: hinted != nil && hinted != index
            )
        }

        // Не нашлось нигде — открываем названную страницу без подсветки.
        // Это исход, а не ошибка (шаг 4).
        return Location(
            pageIndex: hinted ?? 0, characterRange: nil, strategy: nil
        )
    }

    /// Порядок обхода: названная страница, затем соседние по расширяющемуся
    /// кольцу, затем всё остальное по порядку.
    ///
    /// Кольцом, а не подряд с начала: если номер сдвинут, то на единицы,
    /// и правильная страница найдётся первой же — на документе в тысячу
    /// страниц это разница между мгновением и секундами.
    static func searchOrder(hint: Int?, pageCount: Int) -> [Int] {
        guard let hint else { return Array(0..<pageCount) }
        var order = [hint]
        var seen: Set<Int> = [hint]
        for distance in 1..<max(pageCount, 2) {
            for candidate in [hint - distance, hint + distance]
            where candidate >= 0 && candidate < pageCount && !seen.contains(candidate) {
                order.append(candidate)
                seen.insert(candidate)
            }
            if order.count == pageCount { break }
        }
        return order
    }

    /// Выделение PDFKit для найденного места.
    public static func selection(for location: Location, in document: PDFDocument) -> PDFSelection? {
        guard let range = location.characterRange,
              let page = document.page(at: location.pageIndex)
        else { return nil }
        return page.selection(for: NSRange(location: range.lowerBound, length: range.count))
    }
}

extension String {
    /// Первая буква прописной — для строк, собранных из кусков.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
