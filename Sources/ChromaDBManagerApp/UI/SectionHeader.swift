import SwiftUI

/// Заголовок секции формы — с «?» справа, если есть что объяснить.
///
/// Шрифт заголовка задаёт `Form`/`List`; здесь он не трогается.
struct SectionHeader: View {
    let title: String
    var help: String?

    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let help {
                InfoButton(help)
            }
        }
    }
}

#Preview {
    Form {
        Section {
            Toggle("Использовать кэш", isOn: .constant(true))
        } header: {
            SectionHeader("Кэш эмбеддингов", help: "Вектор уже посчитанного текста берётся из кэша.")
        } footer: {
            Text(verbatim: "После очистки векторы придётся считать заново — коллекции не меняются.")
        }
    }
    .formStyle(.grouped)
}
