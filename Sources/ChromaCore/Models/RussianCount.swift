import Foundation

/// Nouns that follow a number.
///
/// Russian counts one thing one way, two another and five a third. A line that
/// reads «свёрнуто 1 дочерних чанков в 1 разделов» looks like a bug in
/// everything else on the screen, and the diagnostics panel is precisely the
/// place a reader is already suspicious.
///
/// Deliberately a plain function rather than a localisation table: the app has
/// one language (Приложение 5, правило 6 leaves no room for a plural library),
/// and the three forms are the whole rule.
public enum RussianCount {
    /// - Parameters:
    ///   - one: the form for 1, 21, 101 — «раздел»
    ///   - few: the form for 2–4, 22–24 — «раздела»
    ///   - many: the form for 0, 5–20, 25–30 — «разделов»
    public static func word(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let hundreds = abs(count) % 100
        // The teens are the exception the last digit alone gets wrong: 11 and
        // 111 take «разделов», not «раздел».
        if (11...14).contains(hundreds) { return many }
        switch hundreds % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }

    /// The number and its noun together.
    public static func phrase(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count) \(word(count, one, few, many))"
    }

    /// То же, но с разделением разрядов: «3 400 записей».
    ///
    /// Отдельно от `phrase`, потому что разделять разряды нужно не всегда:
    /// там, где число — идентификатор, `plainDigits` существует ровно затем,
    /// чтобы порт 8000 не стал «8 000».
    public static func grouped(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count.formatted()) \(word(count, one, few, many))"
    }
}
