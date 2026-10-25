import SwiftUI

/// Раздел со своим списком: «Коллекции», «Клиенты → Ключи». Список
/// слева, выбранное справа, между ними — перетаскиваемый разделитель.
///
/// Голый `HSplitView` на macOS 26 не помещался в окно минимальной ширины:
/// сайдбар там плавает над деталью, и `HSplitView` (AppKit) растягивал
/// первую панель под него, а SwiftUI вдобавок ставил весь `HSplitView` в
/// безопасную зону правее сайдбара. Полоса под сайдбаром считалась дважды,
/// и деталь уезжала за правый край на 62 pt. Здесь `HSplitView` сам
/// становится правее сайдбара явным отступом; на 14–15 отступ нулевой.
struct SectionSplit<List: View, Detail: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        GeometryReader { proxy in
            HSplitView {
                list
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                // Деталь забирает всё, что осталось; минимум — только чтобы
                // разделитель не схлопнул её в ноль.
                detail
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .padding(.leading, proxy.safeAreaInsets.leading)
        }
        .ignoresSafeArea(.container, edges: .leading)
    }
}
