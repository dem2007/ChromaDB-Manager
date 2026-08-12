import Foundation

/// Порядок и отбор в списке коллекций.
///
/// **Почему в ядре, а не во вьюхе.** Сортировка выглядит мелочью ровно до
/// первого `nil`: число записей известно не всегда — список отдаёт его
/// отдельным запросом, — и «неизвестно», поставленное в порядок как ноль,
/// показывает непосчитанную коллекцию пустой. Это то же смешение «нет данных»
/// и «ноль», которое уже трижды находилось в отчёте стенда, и держать его
/// стоит там, где есть тесты.
public enum CollectionListOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case nameAscending
    case nameDescending
    case documentsDescending
    case documentsAscending

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nameAscending: return String(localized: "По имени, А→Я")
        case .nameDescending: return String(localized: "По имени, Я→А")
        case .documentsDescending: return String(localized: "Записей: больше сверху")
        case .documentsAscending: return String(localized: "Записей: меньше сверху")
        }
    }

    /// Порядок по умолчанию — по имени. Сервер отдаёт коллекции в порядке,
    /// который ничего не значит для человека, и найти нужную в списке из
    /// одиннадцати уже трудно.
    public static let `default` = CollectionListOrder.nameAscending
}

public enum CollectionList {
    /// Отсортированный и отфильтрованный список.
    public static func arrange(
        _ collections: [ChromaCollection],
        order: CollectionListOrder,
        search: String = ""
    ) -> [ChromaCollection] {
        sorted(filtered(collections, search: search), order: order)
    }

    /// Отбор по имени.
    ///
    /// Регистр и диакритика не учитываются, потому что человек ищет «Files»
    /// и «files» одним и тем же движением. Совпадение — подстрокой в любом
    /// месте имени: коллекции называются `files_2_hierarchical`, и искать их
    /// приходится по середине слова.
    public static func filtered(_ collections: [ChromaCollection], search: String) -> [ChromaCollection] {
        let needle = normalised(search)
        guard !needle.isEmpty else { return collections }
        return collections.filter { normalised($0.name).contains(needle) }
    }

    static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    public static func sorted(
        _ collections: [ChromaCollection], order: CollectionListOrder
    ) -> [ChromaCollection] {
        switch order {
        case .nameAscending:
            return collections.sorted { byName($0, $1) }
        case .nameDescending:
            return collections.sorted { byName($1, $0) }
        case .documentsDescending:
            return byDocuments(collections, descending: true)
        case .documentsAscending:
            return byDocuments(collections, descending: false)
        }
    }

    /// Сравнение имён «как в Finder»: `files_2` идёт перед `files_10`, потому
    /// что числа сравниваются числами. Посимвольное сравнение поставило бы
    /// `files_10` вторым, и человек решил бы, что список не отсортирован.
    static func byName(_ left: ChromaCollection, _ right: ChromaCollection) -> Bool {
        left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    /// **Непосчитанные — всегда в конце, в обе стороны.**
    ///
    /// `documentCount` приходит отдельным запросом и до его ответа равен `nil`.
    /// Считать `nil` нулём значит показать непосчитанную коллекцию пустой —
    /// и поставить её первой при сортировке «меньше сверху», то есть ровно
    /// там, где на неё посмотрят. Между собой такие идут по имени, чтобы
    /// порядок не прыгал от обновления к обновлению.
    static func byDocuments(_ collections: [ChromaCollection], descending: Bool) -> [ChromaCollection] {
        let known = collections.filter { $0.documentCount != nil }
        let unknown = collections.filter { $0.documentCount == nil }
        let sortedKnown = known.sorted { left, right in
            let a = left.documentCount ?? 0
            let b = right.documentCount ?? 0
            if a == b { return byName(left, right) }
            return descending ? a > b : a < b
        }
        return sortedKnown + unknown.sorted { byName($0, $1) }
    }

    /// Строка над списком: сколько показано и сколько всего.
    ///
    /// При включённом отборе число обязано называть оба: «Коллекций: 3»
    /// в базе из одиннадцати — это не сведения, а недоразумение.
    public static func countLine(shown: Int, total: Int) -> String {
        guard shown != total else {
            return String(localized: "Коллекций: \(total)")
        }
        return String(localized: "Показано \(shown) из \(total)")
    }
}
