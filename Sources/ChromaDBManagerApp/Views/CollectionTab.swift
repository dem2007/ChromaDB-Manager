import SwiftUI
import ChromaCore

/// Стороны одной коллекции.
///
/// Раньше это были три разных места: вкладки в шапке экрана («Документы»,
/// «Поиск»), модальный лист инспектора с собственными вкладками («Проверки»,
/// «Обзор», «Темы») и ещё один лист под схему. Вопрос у всех один — «что
/// в этой коллекции и что с ней делать», — и человек не должен помнить, за
/// какой кнопкой лежит какая его половина.
///
/// Порядок — по тому, как часто открывают. «Документы» и «Поиск» — каждый
/// день; «Обзор» и «Темы» — когда разбираются, что вообще накопилось;
/// «Правила» — реже всего, но там же, а не за отдельной кнопкой.
enum CollectionTab: String, CaseIterable, Identifiable {
    case documents
    case search
    case overview
    case topics
    case rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: return String(localized: "Документы")
        case .search: return String(localized: "Поиск")
        case .overview: return String(localized: "Обзор")
        case .topics: return String(localized: "Темы")
        case .rules: return String(localized: "Правила")
        }
    }
}
