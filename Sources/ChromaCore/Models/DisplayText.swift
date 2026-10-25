import Foundation

/// Текст документа — для показа на экране.
///
/// Инспектор отдавал в `Text` весь документ целиком, и на документе из
/// 619 тысяч знаков — двоичный `.docx`, попавший в базу как «текст»,
/// 75 тысяч управляющих символов — раскладка строки заняла главный поток
/// на минуты: приложение «намертво зависло» от щелчка по строке таблицы.
/// Экран показывает начало, без управляющих символов, а двоичное — словами.
/// Скопировать по-прежнему можно всё.
public enum DisplayText {
    /// Сколько знаков показывается сразу: длинный чанк — несколько тысяч,
    /// и до этого предела показ не меняется.
    public static let defaultLimit = 8_000

    public struct Preview: Sendable, Hashable {
        /// Что показать.
        public let text: String
        /// Сколько знаков в документе всего.
        public let totalCharacters: Int
        /// Показано не всё.
        public let isTruncated: Bool
        /// Похоже на двоичные данные, а не на текст.
        public let looksBinary: Bool
        /// Управляющих символов в проверенном начале.
        public let controlCharacters: Int
    }

    /// Начало строки, по которому решается «двоичное или нет».
    static let sampleScalars = 20_000

    public static func preview(_ text: String?, limit: Int = defaultLimit) -> Preview {
        let text = text ?? ""
        var shown = String.UnicodeScalarView()
        // Счёт — своим числом: `count` у набора скаляров — проход по нему,
        // и на каждом знаке это давало квадрат от предела.
        var shownCount = 0
        var controls = 0
        var replacements = 0
        var sampled = 0
        for scalar in text.unicodeScalars {
            if sampled >= max(limit, sampleScalars) { break }
            sampled += 1
            let isControl = (scalar.value < 0x20 && scalar != "\n" && scalar != "\t")
                || (0x7F...0x9F).contains(scalar.value)
            if isControl { controls += 1 }
            if scalar == "\u{FFFD}" { replacements += 1 }
            if shownCount < limit {
                shown.append(isControl ? " " : scalar)
                shownCount += 1
            }
        }
        let total = text.unicodeScalars.count
        // Две сотых — с запасом: в настоящем тексте управляющих символов нет
        // вовсе, а в архиве, прочитанном как текст, их каждый десятый.
        let looksBinary = sampled > 200 && Double(controls + replacements) / Double(sampled) > 0.02
        return Preview(
            text: String(shown),
            totalCharacters: total,
            isTruncated: total > shownCount,
            looksBinary: looksBinary,
            controlCharacters: controls
        )
    }
}
