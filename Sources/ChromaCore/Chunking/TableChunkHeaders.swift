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

    /// Дописывает шапку тем кускам, которые начались в середине таблицы.
    public static func applied(to chunks: [TextChunk], in text: String) -> [TextChunk] {
        guard chunks.count > 1, text.contains("|") else { return chunks }
        let headers = headers(in: text)
        guard !headers.isEmpty else { return chunks }

        return chunks.map { chunk in
            let lines = chunk.text.components(separatedBy: "\n")
            // Шапка уже внутри — дописывать нечего.
            guard !lines.contains(where: TableText.isSeparator) else { return chunk }
            // Первая строка куска может быть обрезана перекрытием, поэтому
            // ищется первая **целая** строка таблицы, какую удалось опознать.
            guard let header = lines.lazy.compactMap({ headers[$0] }).first else { return chunk }
            return prepending(header, to: chunk)
        }
    }

    /// Строка таблицы → шапка той таблицы, которой она принадлежит.
    ///
    /// Разбор по тексту, а не по смещениям: у куска смещения нет, а строка
    /// таблицы в документе почти всегда своя. Если одна и та же строка
    /// встретилась в двух таблицах, берётся шапка первой — обе одинаково
    /// правдоподобны, и молча выбрать вторую было бы не лучше.
    static func headers(in text: String) -> [String: String] {
        var result: [String: String] = [:]
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
                if result[lines[row]] == nil { result[lines[row]] = header }
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
        return TextChunk(
            index: chunk.index,
            text: header + "\n" + chunk.text,
            level: chunk.level,
            parentIndex: chunk.parentIndex,
            note: chunk.note ?? note
        )
    }
}
