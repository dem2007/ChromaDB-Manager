import SwiftUI

/// Состояние — цветной точкой и словами.
///
/// Цвет не единственный носитель смысла: текст говорит то же самое, и при
/// дальтонизме или «Увеличить контраст» различие не пропадает.
struct StatusLabel: View {
    enum State {
        /// Работает.
        case ok
        /// Требует решения.
        case warning
        /// Ошибка.
        case error
        /// Остановлено, выключено.
        case off

        var color: Color {
            switch self {
            case .ok: return .green
            case .warning: return .orange
            case .error: return .red
            case .off: return .secondary
            }
        }
    }

    let state: State
    let text: String

    init(_ state: State, _ text: String) {
        self.state = state
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "circle.fill")
                // Единственное место в приложении с размером шрифта числом:
                // точка — знак, а не текст, и расти с ним не должна.
                .font(.system(size: 8))
                .foregroundStyle(state.color)
                .accessibilityHidden(true)
        }
    }
}

extension StatusLabel {
    /// Только точка — для строки списка, где одно и то же слово стояло бы у
    /// каждой строки (v4 B). Слова — в подсказке и для VoiceOver; на экране
    /// их показывает инспектор выбранного.
    func dotOnly() -> some View {
        labelStyle(.iconOnly)
            .help(text)
            .accessibilityLabel(text)
    }
}

#Preview {
    VStack(alignment: .leading) {
        StatusLabel(.ok, "Работает")
        StatusLabel(.warning, "Требует решения")
        StatusLabel(.error, "Ошибка")
        StatusLabel(.off, "Остановлен")
    }
    .padding()
}
