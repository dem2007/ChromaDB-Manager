import SwiftUI

/// «Как это работает» — третий уровень текста: устройство раздела.
///
/// Читают один раз, поэтому свёрнуто. Ставится в **последнюю** секцию формы.
/// Раскрытие помнит окно (`@SceneStorage`), и помнит его на экран, а не на
/// всё приложение: раскрытый блок на «Источниках» ничего не говорит о том,
/// нужен ли он на «Логах».
struct HowItWorks: View {
    let text: String
    @SceneStorage private var expanded: Bool

    init(screen: String, _ text: String) {
        self.text = text
        _expanded = SceneStorage(wrappedValue: false, "howItWorks.\(screen)")
    }

    var body: some View {
        // Заголовок нажимается целиком, а не одной стрелкой.
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Как это работает")
                .togglesDisclosure($expanded)
        }
    }
}

#Preview {
    Form {
        Section {
            HowItWorks(screen: "preview", "Кэш хранит вектор каждого посчитанного текста. Совпал текст и модель — вектор берётся отсюда.")
        }
    }
    .formStyle(.grouped)
}
