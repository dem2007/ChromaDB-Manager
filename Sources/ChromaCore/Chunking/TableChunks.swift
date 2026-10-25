import Foundation

/// Кусок таблицы — в свой размер вместе с шапкой.
///
/// **Что было.**
/// - Шапку куску таблицы дописывает конвейер, а размер куска её
///   не учитывал: у фиксированной нарезки 1072 куска из 4585 выходили
///   больше заказанного, вплоть до 4023 знаков при 1792.
/// - Строка длиннее куска резалась нарезкой посередине, по точке или
/// пробелу. Сведённая запись — сервер с дюжиной комплектующих —
///   бывает длиннее куска: в корпусе 36 строк длиннее 512 токенов.
///   Продолжение уходило без шапки, без номера и без названия позиции.
///
/// **Как теперь.** Кусок, в котором есть таблица и который вместе с шапкой
/// длиннее своего размера, делится по строкам: каждая часть — шапка
/// и столько целых строк, сколько влезает. Строка, которая сама не влезает,
/// делится по ячейкам на строки-продолжения:
/// - короткие первые ячейки (номер позиции) повторяются в каждой;
/// - длинная ячейка режется по «;», предложениям и словам, а продолжение
///   начинается с её начала до первого «:» или «;» — названия позиции —
///   и знака « … »: «Сервер Тип 3 в составе: … RAM 64GB (Кол-во, шт.: 16)».
///
/// Ничего не придумывается: всё, что стоит в продолжении, — слова той же
/// строки, а « … » только показывает, что начало ячейки — выше.
public enum TableChunks {
    /// Длинная ячейка режется на куски не длиннее этой доли размера:
    /// иначе в продолжение не влезло бы ничего, кроме неё.
    static let cellShare = 0.5

    /// Начало ячейки, повторяемое в продолжении, — не длиннее этого.
    static let maximumHead = 120

    /// Короткая первая ячейка — номер, код позиции: повторяется целиком.
    static let maximumKey = 24

    /// Насколько кусок с дописанной шапкой может выйти за размер, прежде
    /// чем его делить. Размер куска — ориентир; жёсткий предел — контекст
    /// модели, и за ним следит `OversizeChunks`. Без допуска кусок,
    /// вылезший на длину шапки, делился пополам, и у фиксированной нарезки
    /// кусков становилось почти вдвое больше.
    static let tolerance = 0.10

    /// Куски, у которых таблица вместе с шапкой влезает в `limit`.
    /// - Parameter limit: размер куска в знаках по его уровню; `nil` —
    ///   у куска размера нет, и он не трогается.
    public static func fitted(
        _ chunks: [TextChunk], in text: String, limit: (TextChunk) -> Int?
    ) -> [TextChunk] {
        guard text.contains("|") else { return chunks }
        let headers = TableChunkHeaders.headers(in: text)
        return ChunkRenumbering.expanded(chunks) { chunk in
            guard let size = limit(chunk), size > 0,
                  Double(chunk.text.count) > Double(size) * (1 + tolerance),
                  containsTable(chunk.text) else { return nil }
            let pieces = headedPieces(of: chunk, limit: size, headers: headers)
            return pieces.count > 1 || pieces.first?.text != chunk.text ? pieces : nil
        }
    }

    /// Части куска — с длиной шапки, дописанной в начало каждой.
    ///
    /// Шапка в начале второй и дальше частей в файле на этом месте не стоит,
    /// и `get_file` по этой длине снимает её на стыке. Части собирались
    /// заново без неё, и на каждом стыке читатель видел шапку ещё раз.
    /// Первая часть начинается там же, где кусок, — с его же дописанной
    /// шапкой, если она была.
    static func headedPieces(
        of chunk: TextChunk, limit: Int, headers: [String: [String]]
    ) -> [TextChunk] {
        splitWithHeaders(chunk.text, limit: limit, headers: headers).enumerated().map { position, piece in
            var part = TextChunk(
                index: chunk.index, text: piece.text,
                level: chunk.level, parentIndex: chunk.parentIndex, note: chunk.note
            )
            part.repeatedHeaderLength = position == 0 && chunk.repeatedHeaderLength > 0
                ? chunk.repeatedHeaderLength
                : piece.repeatedHeader
            return part
        }
    }

    /// Есть ли в тексте строка таблицы Markdown. Одного знака `|` мало:
    /// он бывает и в прозе, и в коде (`a || b`), а их эта раскладка резала
    /// бы по строкам вопреки стратегии.
    static func containsTable(_ text: String) -> Bool {
        text.contains("|") && text.split(separator: "\n").contains { line in
            let row = String(line)
            return TableText.isRow(row) && !TableText.isSeparator(row)
        }
    }

    /// Текст куска — частями не длиннее `limit` (кроме того, что не делится:
    /// строки прозы длиннее предела остаются целыми, их дорежет
    /// `OversizeChunks`, если они не влезут в модель), с длиной шапки,
    /// дописанной в начало части (0 — не дописывалась).
    static func splitWithHeaders(
        _ text: String, limit: Int, headers: [String: [String]]
    ) -> [(text: String, repeatedHeader: Int)] {
        let lines = text.components(separatedBy: "\n")
        // Строки, с которых кусок начался без своей шапки, — шапкой той
        // таблицы, которую подтверждают все они, а не первой попавшейся.
        let leading = TableChunkHeaders.header(
            of: lines.prefix { !TableText.isSeparator($0) }.filter(TableText.isRow)[...], in: headers
        )
        func owner(of row: String) -> String? {
            guard let owners = headers[row] else { return nil }
            return leading.flatMap { owners.contains($0) ? $0 : nil } ?? owners.first
        }
        // Единицы: строка прозы, шапка таблицы (две строки) или строка таблицы
        // со своей шапкой.
        enum Unit {
            case line(String)
            case header(String)
            case row(String, header: String?)
        }
        var units: [Unit] = []
        var currentHeader: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count, TableText.isRow(line), TableText.isSeparator(lines[index + 1]) {
                let header = line + "\n" + lines[index + 1]
                units.append(.header(header))
                currentHeader = header
                index += 2
                continue
            }
            if TableText.isRow(line), !TableText.isSeparator(line) {
                units.append(.row(line, header: currentHeader ?? owner(of: line)))
            } else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { currentHeader = nil }
                units.append(.line(line))
            }
            index += 1
        }

        // Части — поровну: кусок, вылезший за размер на одну строку, иначе
        // делился на почти целый кусок и обрывок «шапка и одна строка».
        let headerLength = units.compactMap { unit -> Int? in
            if case .header(let header) = unit { return header.count + 1 }
            if case .row(_, let header?) = unit { return header.count + 1 }
            return nil
        }.max() ?? 0
        let parts = Int((Double(text.count) / Double(max(1, limit - headerLength))).rounded(.up))
        let soft = parts > 1 ? min(limit, text.count / parts + headerLength + 1) : limit

        var pieces: [(text: String, repeatedHeader: Int)] = []
        var current: [String] = []
        var length = 0
        /// Шапка таблицы, внутри которой сейчас кусок.
        var openHeader: String?
        /// Длина шапки, дописанной в начало текущей части.
        var prepended = 0

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pieces.append((text, prepended)) }
            current = []
            length = 0
            prepended = 0
        }
        func append(_ line: String) {
            length += (current.isEmpty ? 0 : 1) + line.count
            current.append(line)
        }
        /// Строка таблицы с шапкой в начале куска, если кусок с неё начнётся.
        func place(_ row: String, header: String?) {
            let extra = (current.isEmpty ? 0 : 1) + row.count
            if !current.isEmpty, length + extra > soft {
                // Шапка, под которой в этом куске не осталось ни строки,
                // переезжает в следующий вместе со строкой. В куске она
                // лежит одним элементом — так её кладёт `append(header)`;
                // сверка двух последних элементов с ней не сходилась
                // никогда, и шапка оставалась в конце куска, а начавшая
                // кусок — уходила с ним как «кусок из одной шапки», и
                // следующий получал её же дописанной (ревью…).
                var carried = false
                if let header, current.last == header {
                    current.removeLast()
                    length = current.isEmpty ? 0 : current.joined(separator: "\n").count
                    carried = true
                }
                flush()
                // Шапка, переехавшая вместе со строкой, стоит в файле прямо
                // перед ней — она не дописана, а перенесена.
                if carried, let header {
                    append(header)
                    append(row)
                    return
                }
            }
            if current.isEmpty, let header {
                append(header)
                prepended = header.count + 1
            }
            append(row)
        }

        for unit in units {
            switch unit {
            case .line(let line):
                openHeader = line.trimmingCharacters(in: .whitespaces).isEmpty ? openHeader : nil
                if !current.isEmpty, length + 1 + line.count > soft { flush() }
                append(line)
            case .header(let header):
                openHeader = header
                // Шапка без единой строки под ней в куске не остаётся одна:
                // если после неё строке места нет, она переходит в следующий.
                if !current.isEmpty, length + 1 + header.count > soft { flush() }
                append(header)
            case .row(let row, let header):
                let header = openHeader ?? header
                let budget = limit - (header.map { $0.count + 1 } ?? 0)
                if row.count <= budget || budget < limit / 4 {
                    place(row, header: header)
                } else {
                    for part in continuationRows(of: row, budget: budget) {
                        place(part, header: header)
                    }
                }
            }
        }
        flush()
        // Кусок из одной шапки — не кусок.
        return pieces.filter { piece in
            let rows = piece.text.components(separatedBy: "\n")
            return !(rows.count == 2 && TableText.isSeparator(rows[1]))
        }
    }

    /// Строка таблицы, разложенная на строки не длиннее `budget`.
    static func continuationRows(of row: String, budget: Int) -> [String] {
        let cells = TableText.cells(of: row)
        guard cells.count > 1 else { return [row] }
        // Короткие первые ячейки — номер позиции — повторяются в каждой.
        var keys: [Int] = []
        for index in cells.indices.prefix(2) {
            guard !cells[index].isEmpty, cells[index].count <= maximumKey else { break }
            keys.append(index)
        }
        let blank = cells.indices.map { keys.contains($0) ? cells[$0] : "" }
        let sliceLimit = max(40, Int(Double(budget) * cellShare))

        // Куски ячеек по порядку.
        var units: [(cell: Int, text: String, first: Bool)] = []
        var heads: [Int: String] = [:]
        for index in cells.indices where !keys.contains(index) && !cells[index].isEmpty {
            let value = cells[index]
            let slices = value.count <= sliceLimit ? [value]
                : RecursiveChunker(size: sliceLimit, overlap: 0, separators: ["; ", ". ", ", ", " "])
                    .chunks(from: value).map(\.text)
            if slices.count > 1 { heads[index] = head(of: value) }
            for (offset, slice) in slices.enumerated() {
                units.append((index, slice, offset == 0))
            }
        }

        var result: [String] = []
        var current = blank
        var filled = false
        func text(for unit: (cell: Int, text: String, first: Bool), in row: [String]) -> String {
            if !row[unit.cell].isEmpty { return row[unit.cell] + " " + unit.text }
            if !unit.first, let head = heads[unit.cell], !unit.text.hasPrefix(head) { return head + " … " + unit.text }
            return unit.text
        }
        for unit in units {
            var candidate = current
            candidate[unit.cell] = text(for: unit, in: current)
            if filled, TableText.row(candidate).count > budget {
                result.append(TableText.row(current))
                current = blank
                current[unit.cell] = text(for: unit, in: current)
            } else {
                current = candidate
            }
            filled = true
        }
        if filled { result.append(TableText.row(current)) }
        return result.isEmpty ? [row] : result
    }

    /// Начало ячейки до первого «:» или «;» — название позиции, которое
    /// повторяется в продолжении. Слишком длинное — не название.
    static func head(of value: String) -> String? {
        guard let end = value.firstIndex(where: { $0 == ":" || $0 == ";" }) else {
            let words = value.split(separator: " ").prefix(6).joined(separator: " ")
            return words.count <= maximumHead ? words : nil
        }
        let head = value[...end].trimmingCharacters(in: .whitespaces)
        return head.count <= maximumHead ? head : nil
    }
}

/// Куски, часть которых разложена на несколько, — с номерами подряд
/// и ссылками на родителя, переведёнными на новые номера.
///
/// Номер куска уходит в идентификатор документа, и дырка в нумерации
/// выглядела бы как след прерванной синхронизации; родитель
/// иерархической нарезки указывает на номер, и после раскладки он сдвигается.
enum ChunkRenumbering {
    static func expanded(_ chunks: [TextChunk], pieces: (TextChunk) -> [TextChunk]?) -> [TextChunk] {
        var result: [TextChunk] = []
        var renumbered: [Int: Int] = [:]
        var changed = false
        for chunk in chunks {
            renumbered[chunk.index] = result.count
            guard let parts = pieces(chunk), !parts.isEmpty else {
                result.append(chunk)
                continue
            }
            changed = true
            for part in parts {
                result.append(part.renumbered(result.count, parentIndex: part.parentIndex))
            }
        }
        guard changed else { return chunks }
        return result.enumerated().map { position, chunk in
            chunk.renumbered(position, parentIndex: chunk.parentIndex.flatMap { renumbered[$0] })
        }
    }
}
