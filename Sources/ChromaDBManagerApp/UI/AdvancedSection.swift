import SwiftUI

/// «Для опытных» — то, что настраивают редко и осознанно.
///
/// Параметры индекса, JSON-фильтр, таймауты, лимиты не исчезают — они
/// перестают быть первым, что видно на экране. Свёрнуто по умолчанию;
/// состояние помнится на экран (`@AppStorage`), а не на всё приложение.
struct AdvancedSection<Content: View>: View {
    let content: Content
    let title: String
    /// Одна расшифровка на весь блок — знаком «?» в заголовке (
    /// «Клиенты → Ключи»): полей в блоке много, а «?» у каждого — это шум.
    let help: String?
    /// Подпись под карточкой, как у обычной секции (v5). У раскрывающейся
    /// секции своего подвала нет — подпись встаёт подвалом пустой секции
    /// сразу под ней, а не последней строкой внутри.
    let footer: String?
    @AppStorage private var expanded: Bool

    init(
        screen: String,
        title: String = String(localized: "Для опытных"),
        help: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.title = title
        self.help = help
        self.footer = footer
        _expanded = AppStorage(wrappedValue: false, "advanced.\(screen)")
    }

    @ViewBuilder
    var body: some View {
        // Штатная раскрывающаяся секция (v3), а не `DisclosureGroup`
        // внутри секции: у строк — обычные разделители и высота формы.
        // Подвала у такой секции нет — пояснение ставят последней строкой.
        Section(isExpanded: $expanded) {
            content
        } header: {
            HStack {
                // Заголовок нажимается целиком, а не одной стрелкой.
                Text(title)
                    .togglesDisclosure($expanded)
                if let help {
                    InfoButton(help)
                }
            }
        }
        if expanded, let footer {
            Section {
            } footer: {
                Text(footer)
            }
        }
    }
}

#Preview {
    Form {
        Section {
            LabeledContent("Записей в одном запросе" as String, value: "5 461")
        }
        AdvancedSection(screen: "preview") {
            LabeledContent("Таймаут чтения, с" as String, value: "30")
            LabeledContent("Таймаут записи, с" as String, value: "120")
        }
    }
    .formStyle(.grouped)
}
