import SwiftUI

/// Встроенное предупреждение — в `footer` секции.
///
/// Заменяет цветные плашки и карточки: предупреждение — это строка со
/// значком, а не фон. Цветной у предупреждения — только значок.
struct Notice: View {
    enum Kind {
        case info
        case warning
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        // Цвет — у значка; текст предупреждения обычного цвета (v3):
        // абзац оранжевого текста читается хуже, а тревогу несёт значок.
        Label {
            Text(text)
                .foregroundStyle(kind == .warning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        } icon: {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(kind == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

#Preview {
    Form {
        Section {
            LabeledContent("Прокси", value: "Остановлен")
        } footer: {
            Notice(.info, "Прокси не запущен — по HTTP ключи не работают.")
        }
        Section {
            LabeledContent("Данные приложения", value: "1,24 ГБ")
        } footer: {
            Notice(.warning, "Удаление необратимо: вернуть данные будет нельзя.")
        }
    }
    .formStyle(.grouped)
}
