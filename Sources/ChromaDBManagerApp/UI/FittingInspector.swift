import SwiftUI

/// Инспектор справа (тип Б) одной ширины на всех экранах, который сам
/// уходит, когда рядом с ним не остаётся места для таблицы (v3).
///
/// При узком окне открытый инспектор оставлял таблице полоску в сотню
/// точек. Теперь он прячется, пока экран уже `roomyWidth`, и возвращается,
/// когда окно снова шире; выбор человека (`isPresented`) при этом не
/// меняется.
private struct FittingInspector<Inspector: View>: ViewModifier {
    @Binding var isPresented: Bool
    let inspector: () -> Inspector
    @State private var hasRoom = true

    /// Минимум инспектора и таблица, в которой ещё можно что-то прочесть.
    private static var roomyWidth: CGFloat { 640 }

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: Binding(
                get: { isPresented && hasRoom },
                set: { isPresented = $0 }
            )) {
                inspector()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.roomyWidth } action: { hasRoom = $0 }
    }
}

extension View {
    func fittingInspector<Inspector: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Inspector
    ) -> some View {
        modifier(FittingInspector(isPresented: isPresented, inspector: content))
    }
}
