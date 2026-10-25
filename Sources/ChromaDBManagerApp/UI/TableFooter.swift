import SwiftUI

/// Строка статуса под таблицей или журналом (v3) — одна на всё
/// приложение: «Показано 5 из 5», «Записей: 1 975», «Строк: 12».
///
/// Раньше каждый экран собирал её сам, и у каждого был свой знак «?» рядом
/// с текстом. Пояснение теперь — подсказкой у самого текста; справа — только
/// то, что относится к списку целиком (индикатор, «Показать ещё»).
struct TableFooter<Trailing: View>: View {
    let text: String
    let help: String?
    let trailing: Trailing

    init(_ text: String, help: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.help = help
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(text)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(help ?? text)
                Spacer(minLength: 8)
                trailing
            }
            .font(.callout)
            .padding()
        }
    }
}

extension TableFooter where Trailing == EmptyView {
    init(_ text: String, help: String? = nil) {
        self.init(text, help: help) { EmptyView() }
    }
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        TableFooter("Записей: 1 975" as String, help: "Каждый запрос через прокси или MCP." as String)
    }
    .frame(width: 480, height: 120)
}
