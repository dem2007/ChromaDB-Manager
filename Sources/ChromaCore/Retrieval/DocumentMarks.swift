import Foundation

/// Ручная пометка на документе.
///
/// Три состояния, и они **взаимоисключающие**: документ либо закреплён, либо
/// понижен, либо помечен устаревшим, либо не помечен вовсе. Тремя отдельными
/// флажками это было бы четыре бессмысленных сочетания — «закреплён и понижен»
/// не значит ничего, а показать его на экране пришлось бы.
public enum DocumentMark: String, Codable, Sendable, CaseIterable, Identifiable {
    public var id: String { rawValue }

    /// Человек ручается за этот фрагмент: он должен быть в выдаче.
    case pinned
    /// Формально подходит, а по делу мешает.
    case demoted
    /// Устарел: данные из него больше не верны.
    case stale

    public var title: String {
        switch self {
        case .pinned: return String(localized: "закреплён")
        case .demoted: return String(localized: "понижен")
        case .stale: return String(localized: "устарел")
        }
    }

    /// Что делает действие — глаголом, для кнопки.
    public var actionTitle: String {
        switch self {
        case .pinned: return String(localized: "Закрепить")
        case .demoted: return String(localized: "Понизить")
        case .stale: return String(localized: "Пометить устаревшим")
        }
    }

    /// Куда пометка двигает результат: меньше — выше.
    ///
    /// Устаревшее стоит ниже пониженного: «мешает» и «неверно» — разные беды,
    /// и вторая хуже.
    var rankGroup: Int {
        switch self {
        case .pinned: return 0
        case .demoted: return 2
        case .stale: return 3
        }
    }
}

/// Пометки, теги и заметка одного документа — как они лежат в его метаданных.
///
/// **Хранятся в базе, а не рядом с приложением.** Это решение человека, и оно
/// про то, что пометка обязана быть видна всем, кто работает с этой базой:
/// агенту через MCP, обычному фильтру по метаданным, другой машине, куда базу
/// перевезли. Копия в приложении расходилась бы с базой ровно в тот день,
/// когда о ней забыли.
///
/// Ключи — со служебным префиксом `_cdbm_`: редактор метаданных показывает
/// такие поля только для чтения, и переписать пометку руками, минуя действия
/// экрана, нельзя.
public struct DocumentMarks: Sendable, Hashable, Codable {
    public static let markKey = "_cdbm_mark"
    public static let tagsKey = "_cdbm_tags"
    public static let noteKey = "_cdbm_note"
    /// Все поля пометок разом — их сохраняет синхронизация при перезаписи
    /// чанка и пропускает диагностика.
    public static let keys: Set<String> = [markKey, tagsKey, noteKey]

    public var mark: DocumentMark?
    /// Произвольные пользовательские теги. В метаданных живут одной строкой
    /// через запятую: ChromaDB хранит числа, строки и логические значения —
    /// массивов у неё нет.
    public var tags: [String]
    public var note: String?

    public init(mark: DocumentMark? = nil, tags: [String] = [], note: String? = nil) {
        self.mark = mark
        self.tags = tags
        self.note = note
    }

    public init(metadata: ChromaMetadata?) {
        guard let metadata else {
            self.init()
            return
        }
        var mark: DocumentMark?
        if case .string(let raw)? = metadata[Self.markKey] {
            mark = DocumentMark(rawValue: raw)
        }
        var tags: [String] = []
        if case .string(let raw)? = metadata[Self.tagsKey] {
            tags = Self.parse(tags: raw)
        }
        var note: String?
        if case .string(let raw)? = metadata[Self.noteKey], !raw.isEmpty {
            note = raw
        }
        self.init(mark: mark, tags: tags, note: note)
    }

    public var isEmpty: Bool { mark == nil && tags.isEmpty && (note ?? "").isEmpty }

    /// Теги как одна строка — вид, в котором они лежат в метаданных.
    public var tagsLine: String { tags.joined(separator: ", ") }

    /// Одной строкой: что стоит на документе — для сводки и журнала.
    public var summaryLine: String {
        var parts: [String] = []
        if let mark { parts.append(mark.title) }
        if !tags.isEmpty { parts.append(String(localized: "теги: \(tagsLine)")) }
        if let note, !note.isEmpty { parts.append(String(localized: "заметка есть")) }
        return parts.isEmpty ? String(localized: "пометок нет") : parts.joined(separator: " · ")
    }

    /// Разбор строки тегов: пробелы по краям снимаются, пустые отбрасываются,
    /// повторы схлопываются — иначе «важное, важное» станет двумя разными
    /// тегами, отличающимися ничем.
    public static func parse(tags raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Метаданные документа с этими пометками: пустое поле **удаляется**, а не
    /// пишется пустой строкой. Снятая пометка обязана исчезнуть из документа,
    /// иначе фильтр «есть пометка» находил бы снятые.
    public func applied(to metadata: ChromaMetadata?) -> ChromaMetadata {
        var result = metadata ?? [:]
        if let mark {
            result[Self.markKey] = .string(mark.rawValue)
        } else {
            result[Self.markKey] = nil
        }
        if tags.isEmpty {
            result[Self.tagsKey] = nil
        } else {
            result[Self.tagsKey] = .string(tagsLine)
        }
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result[Self.noteKey] = .string(note)
        } else {
            result[Self.noteKey] = nil
        }
        return result
    }

    /// Переносит пометки из старой записи документа в новую.
    ///
    /// Синхронизация перезаписывает чанк целиком: без этого переноса пометка
    /// исчезала бы при первом же изменении файла — то есть ровно тогда, когда
    /// человек о ней не думает.
    public static func carriedOver(
        from previous: ChromaMetadata?, to fresh: ChromaMetadata
    ) -> ChromaMetadata {
        let marks = DocumentMarks(metadata: previous)
        guard !marks.isEmpty else { return fresh }
        return marks.applied(to: fresh)
    }
}
