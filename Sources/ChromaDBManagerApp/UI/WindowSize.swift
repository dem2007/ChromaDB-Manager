import SwiftUI

/// Размеры главного окна и колонок навигации (v3–). Экраны своих
/// ширин не задают: их делит окно, а пределы колонок — здесь.
enum MainWindowSize {
    /// Первое открытие окна. Потом macOS восстанавливает размер, у которого
    /// окно оставили. 1100, а не шире: форма `.grouped` сама не бывает шире
    /// ~700 pt и встаёт по центру (поведение системы, проверено пробой) —
    /// в более широком окне по бокам формы оставалась пустота.
    static let initial = CGSize(width: 1100, height: 720)
    /// Окно просмотра исходного документа.
    static let viewer = CGSize(width: 900, height: 760)
}

extension View {
    /// Минимум всего окна, вместе с сайдбаром: при 900 pt помещаются сайдбар,
    /// список раздела и деталь.
    func mainWindowMinimumSize() -> some View {
        frame(minWidth: 900, minHeight: 560)
    }

    /// Колонка сайдбара.
    func sidebarColumnWidth() -> some View {
        navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }
}
