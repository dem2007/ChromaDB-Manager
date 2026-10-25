import SwiftUI

/// Инспектор, когда ничего не выбрано (v4 B): одна строка по центру,
/// вторичным цветом.
///
/// `ContentUnavailableView` в узкой колонке инспектора рисовал заголовок
/// размером с пол-экрана — для подсказки «выберите строку» это слишком
/// громко.
struct InspectorPlaceholder: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    InspectorPlaceholder("Выберите строку в таблице." as String)
        .frame(width: 280, height: 400)
}
