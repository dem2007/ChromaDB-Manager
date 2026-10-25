import SwiftUI

/// Кружок «?» — второй уровень текста: почему так устроено, 2–4 предложения.
///
/// Один на секцию, не на каждое поле. На экране остаётся то, что меняет
/// решение прямо сейчас; причина — здесь. Необратимое, пересчёт векторов
/// и остановка сервера сюда не прячутся никогда: им место в `footer`.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(String(localized: "Подробнее"))
        .accessibilityLabel(String(localized: "Подробнее"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    InfoButton("Вектор уже посчитанного текста берётся из кэша, а не считается заново.")
        .padding()
}
