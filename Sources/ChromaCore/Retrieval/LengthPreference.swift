import Foundation

/// Длина кандидата как часть его оценки.
///
/// **Замер, ради которого это сделано.** Косинус меряет совпадение темы,
/// а не полезность ответа. Чанк из одного слова «Сервер» даёт вектор,
/// совпадающий с вектором запроса «сервер» дословно — схожесть 1.000,
/// выиграть у него нельзя ничем. Хуже того, короткая обезличенная строка
/// садится в середину облака и оказывается близка **к любому** запросу:
/// шапка таблицы «КРИТЕРИЙ РЕЗУЛЬТАТ ОЦЕНКИ РИСКИ» на живой модели
/// `nomic-embed-text-v1.5` даёт 0.701 запросу «сервер», 0.692 — «СКАЛА-Р»
/// и 0.738 — «отпуск сотрудника», обгоняя на этих запросах содержательный
/// текст про конфигурацию сервера (0.678, 0.644, 0.737).
///
/// Штраф за длину переставляет этот порядок правильно и стоит ноль
/// пересчётов: `score = схожесть × min(1, длина / цель)^степень`. На тех же
/// пяти запросах содержательные куски получают 0.43–0.69, мусор — 0.10–0.24.
///
/// **Почему не только фильтр.** Жёсткая отсечка по длине выбрасывает и те
/// короткие чанки, которые изредка правда нужны — артикул, код ошибки,
/// номер постановления. Поэтому отсечка отдельным параметром и по умолчанию
/// выключена, а штраф — мягкий: он двигает список, а не режет его.
public enum LengthPreference {
    /// Во сколько раз урезать оценку куска такой длины.
    ///
    /// Единица начинается с `target`: у текста длиннее цели штрафа нет вовсе.
    public static func factor(length: Int, target: Int, power: Double) -> Double {
        guard target > 0, length >= 0 else { return 1 }
        guard length < target else { return 1 }
        let share = Double(length) / Double(target)
        guard power > 0 else { return 1 }
        return pow(share, power)
    }

    /// Кандидат с посчитанной оценкой. Отдельным типом, а не кортежем:
    /// кортеж из трёх полей в цепочке `map`/`sorted` компилятор Swift
    /// разбирает минутами.
    private struct Scored {
        let position: Int
        let hit: RetrievalHit
        let score: Double
    }

    /// Что стало с кандидатами и что об этом сказать в панели «Как получен
    /// этот результат».
    public struct Outcome: Sendable {
        public var hits: [RetrievalHit]
        /// Отброшено отсечкой по длине.
        public var dropped: Int
        /// Сдвинулись ли места после штрафа.
        public var moved: Int
        public var note: String?
    }

    /// Отсечка и штраф — обе поверх **одного** списка кандидатов, до слияния.
    ///
    /// Порядок стадий из E0.1 не меняется: это работа внутри стадии 1, а не
    /// новая стадия в середине конвейера. Так и должно быть — стадии 3–7
    /// ничего не могут сделать с чанком, которого нет во входе стадии 1.
    ///
    /// `metric` нужна, чтобы превратить расстояние в схожесть, и честно
    /// умеет это только косинус. На других метриках штраф **не
    /// применяется**, и об этом говорится вслух: домножать на догадку —
    /// это ранжирование, которого никто не сможет объяснить.
    public static func applied(
        to hits: [RetrievalHit],
        minimumCharacters: Int,
        penalty: Bool,
        target: Int,
        power: Double,
        metric: DistanceMetric?
    ) -> Outcome {
        var result = hits
        var notes: [String] = []
        var dropped = 0

        if minimumCharacters > 0 {
            let before = result.count
            result = result.filter { ($0.document?.count ?? 0) >= minimumCharacters }
            dropped = before - result.count
            if dropped > 0 {
                notes.append(String(localized: "отброшено \(dropped.plainDigits) короче \(minimumCharacters.plainDigits) знаков"))
            }
            if result.isEmpty && before > 0 {
                // Пустая выдача — это ответ, но только если сказано, почему.
                notes.append(String(localized: "все кандидаты оказались короче порога"))
            }
        }

        // Пустому списку штраф ничего не делает — и рассказывать о работе,
        // которой не было, панели «Как получен этот результат» нельзя.
        guard penalty, !result.isEmpty else {
            return Outcome(hits: result, dropped: dropped, moved: 0, note: notes.joined(separator: ", ").ifNotEmpty)
        }
        // Оценка кандидата: своя, если её уже посчитали (так приходят слияние
        // и текстовая половина), иначе из расстояния, и только
        // на косинусе.
        func base(_ hit: RetrievalHit) -> Double? {
            if let relevance = hit.relevance { return relevance }
            guard let metric, metric == .cosine, let distance = hit.distance else { return nil }
            return metric.similarity(forDistance: distance)
        }
        // Оценки нет ни у кого — штраф не применяется, и об этом говорится.
        guard result.contains(where: { base($0) != nil }) else {
            notes.append(String(localized: "штраф за длину не применён: метрика не даёт схожести"))
            return Outcome(hits: result, dropped: dropped, moved: 0, note: notes.joined(separator: ", ").ifNotEmpty)
        }

        // Кандидат без оценки не отменяет штраф всему списку: он остаётся
        // на своём месте среди оценённых — по тому же правилу, по которому
        // стадия разнообразия расставляет кандидатов без вектора.
        var scored: [Scored] = []
        var unscored: [Int: [Scored]] = [:]
        scored.reserveCapacity(result.count)
        for (position, hit) in result.enumerated() {
            guard let similarity = base(hit) else {
                unscored[scored.count, default: []].append(Scored(position: position, hit: hit, score: 0))
                continue
            }
            let length: Int = hit.document?.count ?? 0
            let share: Double = factor(length: length, target: target, power: power)
            // Оценка не только переставляет список, но и **остаётся при
            // кандидате**: стадии ниже считают релевантность сами,
            // и без этого поля MMR возвращал прежний порядок целиком.
            var penalised = hit
            penalised.relevance = similarity * share
            scored.append(Scored(position: position, hit: penalised, score: similarity * share))
        }
        // Сортировка устойчивая: у одинаковых оценок порядок остаётся тем,
        // что дала база, — иначе выдача менялась бы между двумя одинаковыми
        // запросами.
        scored.sort { left, right in
            left.score == right.score ? left.position < right.position : left.score > right.score
        }

        var merged: [Scored] = unscored[0] ?? []
        merged.reserveCapacity(result.count)
        for (index, entry) in scored.enumerated() {
            merged.append(entry)
            merged += unscored[index + 1] ?? []
        }
        // Сдвиг считается по исходным местам, которые кандидаты и так несут:
        // второй массив идентификаторов ради этого счётчика — лишняя копия
        // на каждый поиск.
        let moved = merged.enumerated().filter { $0.offset != $0.element.position }.count
        result = merged.map(\.hit)

        notes.append(String(localized: "штраф за длину: цель \(target.plainDigits) знаков, степень \(String(format: "%.2f", power)), сдвинуто мест \(moved.plainDigits)"))
        return Outcome(hits: result, dropped: dropped, moved: moved, note: notes.joined(separator: ", ").ifNotEmpty)
    }
}

private extension String {
    var ifNotEmpty: String? { isEmpty ? nil : self }
}
