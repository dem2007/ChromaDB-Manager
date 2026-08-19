import Foundation

/// Тип исходного файла — так, как о нём спрашивает человек.
///
/// Агенту нужно «данные из Excel» или «требования из Word», а в базе лежит
/// поле `file_ext` со значениями `xlsx`, `xls`, `ods`, `numbers`… Знать этот
/// перечень наизусть агент не может и не должен: он либо спросит схему
/// коллекции лишним вызовом, либо угадает одно расширение из шести и молча
/// потеряет остальные файлы.
///
/// Поэтому у поиска есть свой параметр с человеческими именами, а перевод
/// в расширения живёт здесь — в одном месте на приложение.
public enum DocumentKind: String, CaseIterable, Sendable {
    /// Что вышло из разбора списка типов: расширения или внятный отказ.
    ///
    /// Своим типом, а не `Result` со строкой: `String` не является ошибкой
    /// в смысле Swift, а заводить ради одного места отдельный тип ошибки —
    /// лишнее. Отказ здесь уходит агенту текстом и должен читаться как совет.
    ///
    /// Вложен в `DocumentKind`: вне его этот тип не значит ничего, а имя
    /// `KindsParsed` посреди сотни публичных типов `ChromaCore` не говорило
    /// бы, к чему относится.
    public enum Parsed: Sendable, Equatable {
        case extensions([String])
        case unknown(String)
    }

    case word
    case excel
    case pdf
    case presentation
    case text
    case web
    case book
    case code
    case data

    /// Расширения, которые приложение считает этим типом — и **умеет читать**.
    ///
    /// Отсев по `TextExtractor.supportedExtensions` не украшение, а условие
    /// осмысленности ответа. В первой версии `presentation` перечислял
    /// `pptx`, `ppt` и `odp`; первые два стоят в `unsupportedExtensions`
    /// прямым текстом, третьего нет ни в одном списке. Агент прочитал бы
    /// в описании инструмента, что PowerPoint поддержан, получил бы пустую
    /// выдачу и сказал человеку «презентаций в коллекции нет» — тогда как их
    /// нет ровно потому, что сборка их не индексирует.
    ///
    /// Теперь обещание сводится к возможностям само собой: перечень
    /// пересекается с тем, что читают экстракторы, и разойтись они не могут.
    public var extensions: [String] {
        let claimed = Self.claimedExtensions(self)
        let readable = Set(TextExtractor.supportedExtensions)
        return claimed.filter(readable.contains)
    }

    /// Что этот тип означает по-человечески, до сверки с возможностями сборки.
    private static func claimedExtensions(_ kind: DocumentKind) -> [String] {
        switch kind {
        case .word: return ["docx", "doc", "odt", "rtf", "pages"]
        case .excel: return ["xlsx", "xls", "xlsm", "ods", "numbers", "csv", "tsv"]
        case .pdf: return ["pdf"]
        case .presentation: return ["key", "pptx", "ppt", "odp"]
        case .text: return ["txt", "md", "markdown"]
        case .web: return ["html", "htm"]
        case .book: return ["epub"]
        case .code: return ["swift", "py", "js", "ts", "sh", "sql"]
        case .data: return ["json", "xml", "yaml", "yml"]
        }
    }

    public var title: String {
        switch self {
        case .word: return String(localized: "документы Word")
        case .excel: return String(localized: "таблицы Excel")
        case .pdf: return String(localized: "PDF")
        case .presentation: return String(localized: "презентации")
        case .text: return String(localized: "простой текст")
        case .web: return String(localized: "веб-страницы")
        case .book: return String(localized: "книги")
        case .code: return String(localized: "исходный код")
        case .data: return String(localized: "структурированные данные")
        }
    }

    /// Понимает и имя типа, и голое расширение.
    ///
    /// Второе — не послабление ради удобства, а признание того, что агент
    /// видит расширения в выдаче: у каждого найденного документа в
    /// метаданных стоит `file_ext`. Запретить передать обратно то, что
    /// только что показали, было бы странно.
    ///
    /// Точка в начале снимается: `.docx` и `docx` — одно и то же, а
    /// отвечать на такое пустой выдачей значило бы наказывать за опечатку.
    public static func extensions(for names: [String]) -> Parsed {
        var result: [String] = []
        var unknown: [String] = []
        for name in names {
            let cleaned = name.trimmingCharacters(in: .whitespaces)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !cleaned.isEmpty else { continue }
            if let kind = DocumentKind(rawValue: cleaned) {
                result.append(contentsOf: kind.extensions)
            } else if cleaned.count <= 8,
                      cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                // Только латиница и цифры: расширений кириллицей не бывает,
                // а без этой проверки русское слово вроде «табличка»
                // принималось за расширение и давало пустую выдачу вместо
                // подсказки, что за типы вообще бывают.
                result.append(cleaned)
            } else {
                unknown.append(name)
            }
        }
        guard unknown.isEmpty else {
            return .unknown(String(localized: "не понял тип файла: \(unknown.joined(separator: ", ")). Возможные: \(DocumentKind.allCases.map(\.rawValue).joined(separator: ", ")) — или расширение файла, например «docx»."))
        }
        // Порядок сохраняется, повторы убираются: «excel, xlsx» не должно
        // превращаться в условие с двумя одинаковыми значениями.
        var seen = Set<String>()
        return .extensions(result.filter { seen.insert($0).inserted })
    }

    /// Условие для ChromaDB — по тому же полю, которое пишет индексация.
    public static func whereClause(extensions: [String]) -> String? {
        guard !extensions.isEmpty else { return nil }
        let values = extensions.map { "\"\($0)\"" }.joined(separator: ", ")
        return "{\"file_ext\": {\"$in\": [\(values)]}}"
    }
}
