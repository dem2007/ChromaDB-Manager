import Foundation

/// Сколько текста модель эмбеддинга **на самом деле** читает.
///
/// Числа, которые сообщает LM Studio, этому вопросу не отвечают. Замер
/// на `text-embedding-qwen3-embedding-0.6b`: сообщается `max_context 32768`
/// и `loaded_context 2048`, а вектор перестаёт меняться после **21 400
/// знаков** — примерно 8000 настоящих токенов. Ни одно из двух чисел
/// не совпало с поведением.
///
/// Хуже того, отказа нет: текст в 200 000 знаков модель принимает и отдаёт
/// нормальный вектор длиной 1024. То есть чанк сверх предела попадает в базу
/// вектором своего начала, а хвост не закодирован — и узнать об этом
/// по ответу нельзя ничем.
///
/// Поэтому предел не спрашивается, а **измеряется**: вектор длинного текста
/// сравнивается с векторами его же префиксов. Там, где вектор перестал
/// меняться, модель перестала читать.
public enum EmbeddingInputProbe {
    /// Ниже этой длины чанк не проверяется вовсе.
    ///
    /// Самый скромный предел, какой встречается у моделей эмбеддинга, —
    /// 512 токенов; при двух знаках на токен это 1024 знака. Шесть тысяч
    /// с запасом выше всего, что приложение нарезает по умолчанию (2048
    /// «токенов» по его же оценке — 7168 знаков), и заметно ниже любого
    /// настоящего обрыва.
    public static let suspiciousCharacters = 6000

    /// Докуда искать. Дальше — уже не «чанк великоват», а «документ целиком».
    public static let maximumProbeCharacters = 64_000

    /// Два вектора считаются одинаковыми с этого сходства. Не единица:
    /// у чисел с плавающей точкой её не бывает даже у одинакового входа.
    public static let identical = 0.9999

    /// Найденный предел в знаках или `nil`, если до `maximumProbeCharacters`
    /// обрыва нет.
    ///
    /// Стоит семь-восемь вызовов модели и делается **один раз на модель**,
    /// да и то лишь когда в прогоне встретился подозрительно длинный чанк.
    /// Обычная синхронизация не платит за это ничего.
    /// Чем кончилась проба.
    ///
    /// Три исхода, и путать их нельзя: «предела не нашлось» и «модель
    /// не ответила» — противоположные ответы, а от второго ещё и зависит,
    /// стоит ли пробовать снова.
    public enum Outcome: Sendable, Equatable {
        case measured(Int)
        /// До `maximumProbeCharacters` обрыва нет — сравнивать не с чем.
        case noLimitFound
        /// Модель не ответила: измерения не было вовсе.
        case failed
    }

    /// Найденный предел в знаках или `nil`, если до `maximumProbeCharacters`
    /// обрыва нет **или** модель не ответила. Кому важна разница — зовёт
    /// `measureOutcome`.
    public static func measure(
        embed: (String) async throws -> [Double],
        maximumCharacters: Int = maximumProbeCharacters
    ) async -> Int? {
        if case .measured(let value) = await measureOutcome(
            embed: embed, maximumCharacters: maximumCharacters
        ) {
            return value
        }
        return nil
    }

    public static func measureOutcome(
        embed: (String) async throws -> [Double],
        maximumCharacters: Int = maximumProbeCharacters
    ) async -> Outcome {
        let text = sample(ofLength: maximumCharacters)
        guard text.count >= 2000 else { return .noLimitFound }
        guard let full = try? await embed(text) else { return .failed }

        // Если вектор половины уже неотличим от целого — обрыв где-то раньше;
        // если отличим — до предела текста не добрались, и мерить нечего.
        var low = 1000
        var high = text.count
        guard let half = try? await embed(String(text.prefix(high / 2))) else { return .failed }
        guard cosine(full, half) >= identical else { return .noLimitFound }
        high /= 2

        // Инвариант: на `high` вектор уже неотличим от целого, на `low` — нет.
        guard let lowest = try? await embed(String(text.prefix(low))) else { return .failed }
        guard cosine(full, lowest) < identical else { return .measured(low) }

        while high - low > 500 {
            let middle = (low + high) / 2
            // Сорвавшийся вызов — это «не измерилось», а не «предел равен
            // текущему `high`». Вернуть `high` значило бы записать в файл
            // завышенное число: на третьем шаге бисекции оно ещё 32 000
            // при настоящем пределе 8 000, и с ним проверка пропустит
            // ровно те чанки, ради которых заводилась.
            guard let vector = try? await embed(String(text.prefix(middle))) else { return .failed }
            if cosine(full, vector) >= identical { high = middle } else { low = middle }
        }
        return .measured(high)
    }

    /// Текст для пробы: **разный** от абзаца к абзацу и **только русский**.
    ///
    /// Разный — потому что на повторе одной фразы вектор префикса совпадает
    /// с вектором целого просто от однородности, и проба объявила бы обрывом
    /// первую же тысячу знаков.
    ///
    /// Русский — потому что предел меряется в знаках, а модель считает
    /// токены, и знаков на токен у языков разное число: замерено 2.68
    /// для русского против 3.5–4 для английского. Значит на русском тексте
    /// предел в знаках **наименьший**, и измеренный на нём годится для любого
    /// другого — с запасом, а не впритык. На смешанном образце проба давала
    /// 25 218 знаков там, где ручной замер на русской Википедии показывал
    /// 21 400: разница ровно в плотности.
    static func sample(ofLength length: Int) -> String {
        let paragraphs = [
            "Договор считается заключённым с момента подписания обеими сторонами и действует до полного исполнения обязательств.",
            "Плотность потока энергии убывает обратно пропорционально квадрату расстояния от источника излучения.",
            "Кот сидел на подоконнике и смотрел, как во дворе разгружают машину с песком.",
            "Функция возвращает пустой массив, если ни одна запись не удовлетворяет условию фильтра.",
            "Урожай пшеницы в этом сезоне оказался ниже прошлогоднего из-за поздних заморозков в мае.",
            "Заявление подаётся не позднее чем за две недели до предполагаемой даты начала отпуска.",
        ]
        var text = ""
        var index = 0
        while text.count < length {
            text += "\(index + 1). " + paragraphs[index % paragraphs.count] + "\n\n"
            index += 1
        }
        return String(text.prefix(length))
    }

    static func cosine(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var dot = 0.0, leftLength = 0.0, rightLength = 0.0
        for index in left.indices {
            dot += left[index] * right[index]
            leftLength += left[index] * left[index]
            rightLength += right[index] * right[index]
        }
        guard leftLength > 0, rightLength > 0 else { return 0 }
        return dot / (leftLength.squareRoot() * rightLength.squareRoot())
    }
}
