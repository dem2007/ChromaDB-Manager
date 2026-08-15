import Foundation

/// Чанки без единого слова.
///
/// Нарезка любой стратегией может оставить кусок, в котором нет ни буквы, ни
/// цифры: закрывающая скобка, точка, `]` — хвост абзаца, отрезанный по границе.
/// Выглядит это безобидно, а стоит дорого, и вот почему.
///
/// **Такой чанк — универсальный ложный положительный.** Живой замер на
/// `text-embedding-qwen3-embedding-0.6b`: расстояние от «услуги связи» до
/// чанка `)` — **0.335**, а до предложения «Оператор предоставляет услуги
/// мобильной связи и широкополосного доступа в интернет» — 0.424. То есть
/// скобка ближе к запросу, чем текст ровно про запрос. И так по любому
/// запросу: до «квантовая запутанность» — 0.350, до «договор аренды
/// помещения» — 0.400, до «history of the Roman Empire» — 0.404. У текста
/// без слов нет направления в пространстве смыслов, и он оказывается рядом
/// со всем сразу.
///
/// Дело **не в длине**: `== Примечания ==` — те же шестнадцать знаков, но
/// в них есть слово, и расстояние до тех же запросов 0.80–0.87, то есть
/// честное «не про это». Поэтому проверка спрашивает про слова, а не про
/// размер.
public enum ChunkHygiene {
    /// Есть ли в тексте хоть одна буква или цифра.
    public static func carriesMeaning(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Приклеивает бессловесные куски к соседу — **того же уровня и того же
    /// родителя**.
    ///
    /// Приклеивает, а не выбрасывает: эти знаки есть в файле, и молча терять
    /// их при нарезке нельзя — текст документа должен собираться из чанков
    /// обратно. Сосед ищется среди своих: у иерархической нарезки чужой
    /// родитель означал бы кусок текста, уехавший в другой раздел.
    ///
    /// Номера чанков пересчитываются подряд, а `parentIndex` переставляется
    /// вслед за ними: разрыв в нумерации — это отдельная находка инспектора,
    /// и делать её из починки было бы обменом одной беды на другую.
    public static func merged(_ chunks: [TextChunk]) -> [TextChunk] {
        // Обычный случай — все чанки со словами: ни одной перестройки массива.
        guard chunks.contains(where: { !carriesMeaning($0.text) }) else { return chunks }

        struct Group: Hashable {
            let level: Int
            let parentIndex: Int?
        }
        func group(_ chunk: TextChunk) -> Group {
            Group(level: chunk.level, parentIndex: chunk.parentIndex)
        }

        var texts = chunks.map(\.text)
        var dropped = Set<Int>()
        // Куда приклеился каждый бессловесный кусок: сначала ищем предыдущего
        // соседа, потом следующего.
        var lastKept: [Group: Int] = [:]
        var pending: [Int] = []

        for (position, chunk) in chunks.enumerated() {
            let key = group(chunk)
            guard carriesMeaning(chunk.text) else {
                if let target = lastKept[key] {
                    texts[target] = joined(texts[target], chunks[position].text)
                    dropped.insert(position)
                } else {
                    // Своих впереди ещё не было — попробуем прицепиться назад.
                    pending.append(position)
                }
                continue
            }
            // Всё, что ждало впереди идущего соседа, уезжает в него.
            for waiting in pending where group(chunks[waiting]) == key {
                texts[position] = joined(chunks[waiting].text, texts[position])
                dropped.insert(waiting)
            }
            pending.removeAll { dropped.contains($0) }
            lastKept[key] = position
        }

        // Осталось непристроенным — значит в его группе слов нет вовсе.
        // Такой кусок остаётся как есть: документ, в котором нет ни одного
        // слова, — это по-прежнему документ, и решать про него человеку.
        guard !dropped.isEmpty else { return chunks }

        var newIndex: [Int: Int] = [:]
        var next = 0
        for position in chunks.indices where !dropped.contains(position) {
            newIndex[position] = next
            next += 1
        }

        return chunks.indices.compactMap { position -> TextChunk? in
            guard let index = newIndex[position] else { return nil }
            let chunk = chunks[position]
            // Родитель по построению всегда идёт впереди своих детей и слова
            // в нём есть — но если его всё же не стало, ссылка снимается,
            // а не указывает в пустоту.
            let parent = chunk.parentIndex.flatMap { newIndex[$0] }
            return TextChunk(
                index: index,
                text: texts[position],
                level: chunk.level,
                parentIndex: parent,
                note: chunk.note
            )
        }
    }

    /// Склейка двух кусков: ровно один пробел между ними.
    ///
    /// Какой разделитель стоял в файле, нарезка уже не знает — стратегии
    /// режут по границам и обрезают пробелы. Пробел — то же, чем склеивает
    /// предложения семантическая нарезка.
    static func joined(_ left: String, _ right: String) -> String {
        let leading = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if leading.isEmpty { return trailing }
        if trailing.isEmpty { return leading }
        return leading + " " + trailing
    }
}
