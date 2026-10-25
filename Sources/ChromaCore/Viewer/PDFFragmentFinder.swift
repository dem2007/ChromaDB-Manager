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
        /// Диапазон на этой странице в единицах UTF-16, или `nil` — открыть без
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
        /// Где кончается фрагмент, перешедший на следующие страницы:
        /// индекс страницы и конец на ней в единицах UTF-16. `nil` — фрагмент
        /// на одной странице, и конец — у `characterRange`.
        public let end: (pageIndex: Int, character: Int)?

        public init(
            pageIndex: Int,
            characterRange: Range<Int>?,
            strategy: FragmentLocator.Strategy?,
            pageDiffersFromMetadata: Bool = false,
            end: (pageIndex: Int, character: Int)? = nil
        ) {
            self.pageIndex = pageIndex
            self.characterRange = characterRange
            self.strategy = strategy
            self.pageDiffersFromMetadata = pageDiffersFromMetadata
            self.end = end
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
    ///
    /// **Ячейки таблицы — только на названной странице и рядом с ней**
    ///. Шаг слабый: узнаваемая ячейка вроде «Контроллер Альфа
    /// 7848R» стоит на многих страницах. Порядок такой:
    /// - названная страница — всеми шагами: номер пишет само извлечение, и
    ///   кусок начинается именно там (замер: из 28 кусков, которые иначе
    ///   уходили на соседнюю страницу, у 18 таблица верно находилась на
    ///   названной, а на соседней совпадал хвост куска);
    /// - соседние страницы — сначала текстом, потом ячейками: ячейка на одной
    ///   из них не должна опережать текст куска на другой;
    /// - остальной документ — только текстом: дальняя ячейка — уже чужая
    ///   таблица. И ради куска таблицы, который текстом не находится нигде,
    ///   весь документ не обходится, если таблица нашлась рядом.
    public static func locate(
        chunk: String,
        in document: PDFDocument,
        startingAt page: Int?
    ) -> Location? {
        guard document.pageCount > 0 else { return nil }
        let hinted = page.map { max(0, min($0 - 1, document.pageCount - 1)) }
        let order = searchOrder(hint: hinted, pageCount: document.pageCount)
        let others = order.filter { $0 != hinted }
        let isNear: (Int) -> Bool = { index in hinted.map { abs(index - $0) <= tableCellsPageRadius } ?? true }
        let near = others.filter(isNear)
        // Текстом — окном из страницы и двух следующих: кусок,
        // начатый внизу страницы, кончается на следующей, и на одной
        // странице находилось только его предложение. Окно — только у
        // названной страницы и соседних: дальние страницы, как и весь
        // документ, когда номера нет, — по одной. Там ищется кусок с неверным
        // номером, и втрое больше текста на каждую — это секунды на документе
        // в пятьсот страниц.
        let windowed = hinted != nil
        var passes: [(pages: [Int], byTableCells: Bool, windowed: Bool)] = []
        if let hinted { passes += [([hinted], false, true), ([hinted], true, false)] }
        passes += [(near, false, windowed), (near, true, false), (others.filter { !isNear($0) }, false, false)]

        var texts: [Int: String] = [:]
        func text(of index: Int) -> String {
            if let ready = texts[index] { return ready }
            let text = document.page(at: index)?.string ?? ""
            texts[index] = text
            return text
        }

        /// Совпадение в тексте страниц `window`, склеенных через перевод строки.
        func match(in window: [Int], byTableCells: Bool) -> (match: FragmentLocator.Match, joined: String, offsets: [Int], first: Int, last: Int)? {
            var offsets: [Int] = []
            var joined = ""
            for page in window {
                if !joined.isEmpty { joined += "\n" }
                offsets.append(joined.utf16.count)
                joined += text(of: page)
            }
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let found = byTableCells
                ? FragmentLocator.locateByTableCells(chunk: chunk, in: joined)
                : FragmentLocator.locate(chunk: chunk, in: joined, includingTableCells: false)
            guard let found else { return nil }
            let range = NSRange(found.range, in: joined)
            let first = offsets.lastIndex { $0 <= range.location } ?? 0
            let last = offsets.lastIndex { $0 < NSMaxRange(range) } ?? first
            return (found, joined, offsets, first, last)
        }

        for pass in passes {
            for index in pass.pages {
                let window = pass.windowed ? Array(index..<min(document.pageCount, index + pageWindow)) : [index]
                guard var found = match(in: window, byTableCells: pass.byTableCells) else { continue }
                // Засчитывается совпадение, начатое на самой странице, а не
                // на следующих: те проверяются в свой черёд. Иначе хвост
                // куска на следующей странице, найденный самым длинным
                // предложением, опережал таблицу на названной — то, что
                // чинил (ревью…). Начатое дальше — повод
                // посмотреть одну эту страницу, как и до окна.
                if found.first > 0 {
                    guard let single = match(in: [index], byTableCells: pass.byTableCells) else { continue }
                    found = single
                }
                // Единицы UTF-16, а не знаки Swift: `PDFPage.selection(for:)`
                // считает ими, и знак из нескольких единиц перед совпадением
                // сдвигал выделение.
                let range = NSRange(found.match.range, in: found.joined)
                let startPage = window[found.first]
                let lower = range.location - found.offsets[found.first]
                let upper = NSMaxRange(range) - found.offsets[found.last]
                let spansPages = found.last > found.first
                return Location(
                    pageIndex: startPage,
                    characterRange: lower..<(spansPages ? text(of: startPage).utf16.count : upper),
                    strategy: found.match.strategy,
                    pageDiffersFromMetadata: hinted != nil && hinted != startPage,
                    end: spansPages ? (window[found.last], upper) : nil
                )
            }
        }

        // Не нашлось нигде — открываем названную страницу без подсветки.
        // Это исход, а не ошибка (шаг 4).
        return Location(
            pageIndex: hinted ?? 0, characterRange: nil, strategy: nil
        )
    }

    /// Сколько страниц подряд просматривается текстом за раз: кусок длиной
    /// до шести тысяч знаков занимает две-три страницы.
    static let pageWindow = 3

    /// На сколько страниц от названной ищется таблица по ячейкам: кусок
    /// таблицы, начатый на одной странице, кончается на следующей.
    static let tableCellsPageRadius = 2

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
        if let end = location.end, end.character > 0, let last = document.page(at: end.pageIndex) {
            // Индекс конца у PDFKit — последний знак, а не за ним.
            return document.selection(
                from: page, atCharacterIndex: range.lowerBound,
                to: last, atCharacterIndex: end.character - 1
            )
        }
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
