import Foundation

/// Группы расширений для выбора в источнике.
///
/// Поле «расширения через запятую» требовало помнить два десятка расширений
/// и не говорило, какие из них в папке вообще есть. Группы — то, как о файлах
/// думает человек: «документы и таблицы, без кода», — а внутри группы каждое
/// расширение отмечается отдельно, с числом таких файлов в папке.
///
/// Группы покрывают `TextExtractor.supportedExtensions` целиком и не
/// пересекаются — это проверяет тест: новый формат, добавленный в список
/// и забытый здесь, иначе не появился бы в редакторе вовсе.
public enum ExtensionGroup: String, CaseIterable, Identifiable, Sendable {
    case documents
    case tables
    case presentations
    case text
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .documents: return String(localized: "Документы")
        case .tables: return String(localized: "Таблицы")
        case .presentations: return String(localized: "Презентации")
        case .text: return String(localized: "Текст и разметка")
        case .code: return String(localized: "Код")
        }
    }

    public var extensions: [String] {
        switch self {
        case .documents: return ["pdf", "docx", "doc", "odt", "rtf", "pages", "epub"]
        case .tables: return TabularFormat.allExtensions.filter { !TextExtractor.unsupportedExtensions.contains($0) }
        case .presentations: return ["pptx", "key"]
        case .text: return ["md", "markdown", "txt", "html", "htm", "json", "xml", "yaml", "yml"]
        case .code: return ["swift", "py", "js", "ts", "sh", "sql"]
        }
    }

    /// Группа расширения; `nil` — расширение не из списка поддерживаемых
    /// (своё, вписанное руками).
    public static func of(_ fileExtension: String) -> ExtensionGroup? {
        allCases.first { $0.extensions.contains(fileExtension) }
    }
}
