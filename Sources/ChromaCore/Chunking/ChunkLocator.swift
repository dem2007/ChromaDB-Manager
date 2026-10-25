import Foundation

/// Where a chunk sits in the document it came from.
public struct ChunkPlacement: Hashable, Sendable {
    /// Character offset in `plainText`.
    public var start: Int
    public var pageNumber: Int?
    public var headingPath: String?
    /// The chapter or slide this chunk came from.
    public var part: DocumentPart?
    /// Вводная фраза списка, внутри которого начинается чанк.
    ///
    /// Уходит в строку контекста — то есть **в вектор, но не в документ**,
    /// по тому же правилу, что заголовок раздела.
    public var listLeadIn: String?
    /// Адреса, на которые ссылается этот кусок документа.
    ///
    /// В метаданные, **не в текст и не в вектор**: адрес — это ссылка
    /// на источник, а не слова, по которым ищут.
    public var links: [String]

    public init(
        start: Int, pageNumber: Int? = nil, headingPath: String? = nil,
        part: DocumentPart? = nil, listLeadIn: String? = nil, links: [String] = []
    ) {
        self.start = start
        self.pageNumber = pageNumber
        self.headingPath = headingPath
        self.part = part
        self.listLeadIn = listLeadIn
        self.links = links
    }

    /// Nothing to write into the chunk metadata.
    ///
    /// Вводная фраза здесь не считается: в метаданные она не пишется вовсе,
    /// и размещение, где есть только она, писать в базу нечем — но строку
    /// контекста оно всё равно даёт, поэтому пустым не считается.
    public var isEmpty: Bool {
        pageNumber == nil && headingPath == nil && part == nil
            && listLeadIn == nil && links.isEmpty
    }
}

/// Finds each chunk back in its source text, so `page_number` and
/// `heading_path` can be written for every strategy rather than only for
/// the two that happen to know their offsets.
///
/// By matching the text, not by trusting arithmetic: chunkers trim, join and
/// overlap, and a computed offset would drift silently. A chunk that cannot be
/// found verbatim — the LLM strategy is allowed to rewrite what it returns —
/// gets **no** placement at all. A missing page number is a gap; a wrong one is
/// a lie the user has no way to spot.
public enum ChunkLocator {
    /// Offsets keyed by `TextChunk.index`. Absent means «not found, say nothing».
    public static func offsets(of chunks: [TextChunk], in text: String) -> [Int: Int] {
        guard !text.isEmpty else { return [:] }

        // Hierarchical children live inside their parent, and a parent overlaps
        // the one before it — walking the whole list forward would send the
        // search past a boundary it still needs. Parents are located in order;
        // each child is then searched inside its own parent's span.
        let parents = chunks.filter { $0.parentIndex == nil }
        let length = text.count
        var result = locate(parents, in: text, from: 0, to: length)

        let children = Dictionary(grouping: chunks.filter { $0.parentIndex != nil }, by: { $0.parentIndex! })
        for (parentIndex, group) in children {
            guard let parentStart = result[parentIndex],
                  let parent = chunks.first(where: { $0.index == parentIndex }) else { continue }
            // Окно — с запасом в половину родителя: в файле родитель бывает
            // длиннее своего текста (гигиена убирает пустые строки и
            // повторы, у куска таблицы опора — строки данных, а не начало),
            // и дети из его хвоста оставались без места. Ищутся они всё
            // равно вперёд от начала родителя, по порядку.
            let located = locate(
                group.sorted { $0.index < $1.index },
                in: text,
                from: parentStart,
                to: min(length, parentStart + parent.text.count + parent.text.count / 2)
            )
            result.merge(located) { current, _ in current }
        }
        return result
    }

    /// Placement plus what the document says about that offset.
    public static func placements(of chunks: [TextChunk], in document: ExtractedDocument) -> [Int: ChunkPlacement] {
        let offsets = offsets(of: chunks, in: document.plainText)
        // Списки размечаются один раз на документ, а не на каждый чанк:
        // это один проход по блокам, а чанков бывают тысячи.
        let leadIns = ListLeadIns.leadIns(in: document.plainText)
        // Ссылки перебираются по одному разу на чанк, а не на знак: их
        // единицы даже в документе с оглавлением.
        let links = document.links.sorted { $0.start < $1.start }
        let texts = Dictionary(chunks.map { ($0.index, $0.text) }, uniquingKeysWith: { first, _ in first })
        let lengths = texts.mapValues(\.count)
        let boundaries = Array(Set(document.structure.map(\.start))).sorted()

        var result: [Int: ChunkPlacement] = [:]
        for (index, start) in offsets {
            let end = start + (lengths[index] ?? 0)
            let placement = ChunkPlacement(
                start: start,
                pageNumber: document.pageNumber(forCharacter: start),
                headingPath: dominantPath(from: start, to: end, boundaries: boundaries, in: document),
                part: dominantPart(from: start, to: end, in: document),
                listLeadIn: ListLeadIns.leadIn(from: start, to: end, text: texts[index] ?? "", in: leadIns),
                // Адрес принадлежит чанку, если ссылка стоит **внутри** его
                // текста. У чанков есть перекрытие, и один адрес может
                // достаться двоим — так и есть на самом деле: обоим он
                // источник.
                links: Self.distinct(links.filter { $0.start >= start && $0.start < end }.map(\.url))
            )
            guard !placement.isEmpty else { continue }
            result[index] = placement
        }
        return result
    }

    /// Раздел, к которому относится кусок, — не по его первому знаку.
    ///
    /// Раньше путь брался по началу куска. Начало же часто стоит в чужом
    /// разделе: перекрытие несёт хвост предыдущего, адаптивная нарезка
    /// приклеивает короткий раздел к следующему. Замер на 19 документах
    /// со структурой: так ошибались от 1,6 % (рекурсивная) до 7,6 %
    /// (по структуре) кусков.
    ///
    /// Теперь считается, какую долю куска покрывает каждый путь вместе со
    /// своими подразделами, и берётся **самый глубокий путь, покрывающий
    /// больше половины**. Кусок раздела «2» с подразделами 2.1 и 2.2 остаётся
    /// «2», а не становится «2 > 2.2»; кусок из хвоста 2.4 и раздела 2.5 —
    /// «2.5». Если больше половины не покрывает никто — путь с наибольшим
    /// покрытием.
    static func dominantPath(
        from start: Int, to end: Int, boundaries: [Int], in document: ExtractedDocument
    ) -> String? {
        let separator = " > "
        // Разделы внутри куска — по началам заголовков.
        var first = boundaries.partitioningIndex { $0 > start }
        var points = [start]
        while first < boundaries.count, boundaries[first] < end {
            points.append(boundaries[first])
            first += 1
        }
        guard points.count > 1 else { return document.headingPath(forCharacter: start) }

        var coverage: [[String]: Int] = [:]
        var order: [[String]] = []
        for (position, point) in points.enumerated() {
            let length = (position + 1 < points.count ? points[position + 1] : end) - point
            let path = document.headingPath(forCharacter: point, separator: separator)
                .map { $0.components(separatedBy: separator) } ?? []
            for depth in 0...path.count {
                let prefix = Array(path.prefix(depth))
                if coverage[prefix] == nil { order.append(prefix) }
                coverage[prefix, default: 0] += length
            }
        }
        let total = end - start
        // Корень покрывает всё и в выбор не идёт: кусок поровну из трёх
        // разделов остался бы без раздела вовсе.
        let sections = order.filter { !$0.isEmpty }
        let chosen = sections
            .filter { coverage[$0, default: 0] * 2 > total }
            .max { $0.count < $1.count }
            ?? sections.max { coverage[$0, default: 0] < coverage[$1, default: 0] }
        return chosen?.joined(separator: separator)
    }

    /// Глава или слайд, которые занимают больше всего куска, — а не тот,
    /// на котором он начался: перекрытие несёт хвост предыдущего слайда,
    /// и кусок про слайд 4 получал номер 3.
    static func dominantPart(from start: Int, to end: Int, in document: ExtractedDocument) -> DocumentPart? {
        let initial = document.part(forCharacter: start)
        let inside = document.parts.filter { $0.start > start && $0.start < end }.sorted { $0.start < $1.start }
        guard !inside.isEmpty else { return initial }
        var best = initial
        var bestLength = initial == nil ? 0 : inside[0].start - start
        for (position, part) in inside.enumerated() {
            let length = (position + 1 < inside.count ? inside[position + 1].start : end) - part.start
            if length > bestLength {
                best = part
                bestLength = length
            }
        }
        return best
    }

    /// Адреса без повторов, в порядке появления: одна и та же ссылка стоит
    /// в документе по многу раз, а в метаданных нужна один.
    static func distinct(_ urls: [String]) -> [String] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0).inserted }
    }

    /// Где стоит чанк, текст которого в документе дословно не встречается.
    ///
    /// Такие чанки делает сам конвейер: семантическая нарезка склеивает
    /// предложения пробелом там, где в файле был перевод строки, а чанк
    /// таблицы получает приписанную сверху строку шапки. Искать их целиком
    /// бесполезно — и они оставались без страницы, раздела и ссылок.
    ///
    /// Ищется **опорная строка**, которая в файле есть дословно: у таблицы
    /// с приписанной шапкой — строки данных под ней (иначе чанк встал бы
    /// к началу таблицы), у остального — вторая строка, затем первая.
    /// Короче двенадцати знаков опора не годится: такое совпадёт где угодно.
    static func anchorRange(
        of chunk: String, in text: String, range: Range<String.Index>
    ) -> Range<String.Index>? {
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Дописанная шапка — две строки, подпись колонок и разделитель
        // `| --- |`, и в этом месте файла их нет. Раньше опорой
        // бралась вторая строка, то есть разделитель: он находился в начале
        // той же таблицы или у следующей, кусок вставал не туда, а курсор
        // уезжал вперёд, и следующие куски не находились вовсе.
        if lines.count > 2, TableText.isSeparator(lines[1]) {
            lines.removeFirst(2)
            return anchor(lines.prefix(2), in: text, range: range)
                ?? anchor(cellFragments(of: lines.prefix(3)), in: text, range: range)
        }
        let candidates = lines.count > 1 ? [lines[1], lines[0]] : Array(lines.prefix(1))
        return anchor(candidates, in: text, range: range)
            ?? anchor(cellFragments(of: lines.prefix(3)), in: text, range: range)
    }

    /// Первая из строк, найденная в файле дословно своим началом.
    private static func anchor<Lines: Sequence>(
        _ candidates: Lines, in text: String, range: Range<String.Index>
    ) -> Range<String.Index>? where Lines.Element == String {
        for line in candidates {
            // Начало строки — до шестидесяти знаков: дальше в семантическом
            // чанке начинается склейка, которой в файле нет.
            let anchor = String(line.prefix(60))
            guard anchor.count >= 12 else { continue }
            // Опора без слов и чисел — «|  |  |  |» пустых ячеек — найдётся
            // в любой таблице документа и уведёт курсор не туда.
            guard anchor.filter({ $0.isLetter || $0.isNumber }).count >= 6 else { continue }
            if let found = text.range(of: anchor, range: range) { return found }
        }
        return nil
    }

    /// Куски ячеек строк таблицы, годные в опору, — для продолжений длинной
    /// строки.
    ///
    /// Продолжение несёт ключевые ячейки строки и начало названия позиции,
    /// а пропуск помечен «…»: в файле такой строки нет, и кусок оставался без
    /// места. Сами значения ячеек между пропусками — дословные. Первыми идут
    /// куски **после** «…»: начало названия повторяется в каждом продолжении
    /// той же строки, и по нему все они встали бы в одно место.
    static func cellFragments<Lines: Sequence>(of lines: Lines) -> [String] where Lines.Element == String {
        var tails: [String] = []
        var heads: [String] = []
        for line in lines where TableText.isRow(line) && !TableText.isSeparator(line) {
            for cell in TableText.cells(of: line) {
                for (position, piece) in cell.components(separatedBy: "…").enumerated() {
                    // Ячейка прочитана без экранирования, а в тексте файла
                    // `|` внутри ячейки записан как `\|`.
                    let fragment = TableText.escape(
                        piece.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    )
                    guard fragment.count >= 20 else { continue }
                    if position > 0 { tails.append(fragment) } else { heads.append(fragment) }
                }
            }
        }
        return tails.sorted { $0.count > $1.count } + heads.sorted { $0.count > $1.count }
    }

    /// Chunks in document order, each searched from just after the previous one
    /// started — never from where it ended, because chunks overlap.
    private static func locate(_ chunks: [TextChunk], in text: String, from lower: Int, to upper: Int) -> [Int: Int] {
        var result: [Int: Int] = [:]
        guard lower < upper else { return result }
        // Курсор — индексом строки, а не числом: `index(offsetBy:)` от начала
        // текста на каждый чанк проходил документ заново, и файл в тысячу
        // чанков обходился тысячей проходов. Число знаков считается по ходу,
        // от прошлой находки.
        var cursor = lower
        var cursorIndex = text.index(text.startIndex, offsetBy: lower)
        let searchEnd = text.index(cursorIndex, offsetBy: upper - lower)
        for chunk in chunks {
            guard !chunk.text.isEmpty, cursorIndex < searchEnd else { continue }
            guard let found = text.range(of: chunk.text, range: cursorIndex..<searchEnd)
                    ?? anchorRange(of: chunk.text, in: text, range: cursorIndex..<searchEnd)
            else { continue }
            let offset = cursor + text.distance(from: cursorIndex, to: found.lowerBound)
            result[chunk.index] = offset
            cursorIndex = text.index(after: found.lowerBound)
            cursor = offset + 1
        }
        return result
    }
}

private extension Array where Element == Int {
    /// Первый номер, на котором условие выполняется (массив по возрастанию).
    func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
