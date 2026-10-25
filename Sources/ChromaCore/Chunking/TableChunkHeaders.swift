import Foundation

/// Шапка таблицы — в каждом её куске.
///
/// **Зачем.** Кусок из середины таблицы — это сетка значений без единого
/// названия колонки: «АРТ-1024 | Кабель UTP 5e | 24 | 30000 ₽» и ещё двадцать
/// таких же. Ни человек, ни модель по нему не скажут, что 24 — это количество,
/// а не цена. Замер на таблице из шестидесяти строк при заводских настройках:
/// три куска, строка заголовков — **только в первом**.
///
/// Для книг Excel это правило действует с самого начала и записано там
/// как обязательное. Здесь оно распространяется на **все** источники сразу:
/// таблица из Word, из PDF и с веб-страницы теперь пишется тем же видом
/// (11.13), а значит, шапку у неё можно узнать машинно — по разделителю.
public enum TableChunkHeaders {
    /// Пометка на куске: она объясняет человеку, откуда в тексте строка,
    /// которой в этом месте файла нет.
    public static let note = String(localized: "строка заголовков повторена — без неё чанк таблицы не читается")

    /// Поле метаданных: сколько знаков в начале куска — повторённая шапка
    ///.
    public static let lengthKey = "repeated_header_chars"

    /// Дописывает шапку тем кускам, которые начались в середине таблицы.
    public static func applied(to chunks: [TextChunk], in text: String) -> [TextChunk] {
        guard chunks.count > 1, text.contains("|") else { return chunks }
        let headers = headers(in: text)
        guard !headers.isEmpty else { return chunks }

        return chunks.map { chunk in
            let lines = chunk.text.components(separatedBy: "\n")
            // Первая строка таблицы в куске: шапка (под ней разделитель) —
            // дописывать нечего; строка данных — кусок начался в середине
            // таблицы. Разделитель где-то ниже ничего не говорит:
            // это шапка следующей таблицы или продолжения со следующей
            // страницы, а строки над ним оставались без названий колонок.
            guard let first = lines.indices.first(where: { TableText.isRow(lines[$0]) }) else { return chunk }
            // Кусок начался с разделителя: строку подписей над ним нарезка
            // оставила в предыдущем куске (граница смысла или знаков легла
            // между ними). Подписи дописываются, разделитель уже есть.
            if first == 0, TableText.isSeparator(lines[0]) {
                let rows = lines.dropFirst().prefix(while: { !TableText.isSeparator($0) })
                guard let header = Self.header(of: rows, in: headers),
                      let labels = header.components(separatedBy: "\n").first else { return chunk }
                var headed = TextChunk(
                    index: chunk.index, text: labels + "\n" + chunk.text,
                    level: chunk.level, parentIndex: chunk.parentIndex, note: chunk.note ?? note
                )
                headed.repeatedHeaderLength = labels.count + 1
                return headed
            }
            if TableText.isSeparator(lines[first]) { return chunk }
            if first + 1 < lines.count, TableText.isSeparator(lines[first + 1]) { return chunk }
            // Первая строка куска может быть обрезана перекрытием, поэтому
            // ищется первая **целая** строка таблицы, какую удалось опознать.
            let rows = lines[first...].prefix(while: { !TableText.isSeparator($0) })
            guard let header = Self.header(of: rows, in: headers) else { return chunk }
            return prepending(header, to: chunk)
        }
    }

    /// Шапка таблицы, которой принадлежат строки куска.
    ///
    /// Строка, встреченная в нескольких таблицах («| 1 | | |», «| Итого | |»),
    /// одна таблицу не определяет: решают остальные строки куска — берётся
    /// шапка, общая для всех опознанных. Не нашлось общей — шапка первой
    /// таблицы первой опознанной строки, как и раньше.
    static func header(of rows: ArraySlice<String>, in headers: [String: [String]]) -> String? {
        var common: [String]?
        var fallback: String?
        for row in rows {
            guard let owners = headers[row] else { continue }
            if fallback == nil { fallback = owners.first }
            let narrowed = common.map { current in current.filter(owners.contains) } ?? owners
            if narrowed.isEmpty { break }
            common = narrowed
            if narrowed.count == 1 { break }
        }
        return common?.first ?? fallback
    }

    /// Строка таблицы → шапка той таблицы, которой она принадлежит.
    ///
    /// Разбор по тексту, а не по смещениям: у куска смещения нет, а строка
    /// таблицы в документе почти всегда своя. Строка, встреченная в
    /// нескольких таблицах, знает шапки всех — по порядку; какая из них
    /// её, решают соседние строки куска (`header(of:in:)`).
    static func headers(in text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard index > 0, TableText.isSeparator(lines[index]), TableText.isRow(lines[index - 1]) else {
                index += 1
                continue
            }
            let header = lines[index - 1] + "\n" + lines[index]
            var row = index + 1
            // Строка, под которой стоит разделитель, — уже шапка **следующей**
            // таблицы, а не последняя строка этой. Без этой оговорки две
            // таблицы, записанные вплотную, отдавали куску чужую шапку.
            while row < lines.count, TableText.isRow(lines[row]), !TableText.isSeparator(lines[row]),
                  !(row + 1 < lines.count && TableText.isSeparator(lines[row + 1])) {
                if !(result[lines[row]]?.contains(header) ?? false) { result[lines[row], default: []].append(header) }
                row += 1
            }
            index = max(row, index + 1)
        }
        return result
    }

    /// Кусок с дописанной шапкой. Своя пометка куска, если она есть,
    /// не затирается: она объясняет что-то другое и тоже нужна.
    public static func prepending(_ header: String, to chunk: TextChunk) -> TextChunk {
        guard !header.isEmpty, !chunk.text.hasPrefix(header) else { return chunk }
        var headed = TextChunk(
            index: chunk.index,
            text: header + "\n" + chunk.text,
            level: chunk.level,
            parentIndex: chunk.parentIndex,
            note: chunk.note ?? note
        )
        headed.repeatedHeaderLength = header.count + 1
        return headed
    }
}
