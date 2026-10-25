import SwiftUI

/// Длинное значение в инспекторе (v3): подпись сверху, значение под ней,
/// по левому краю.
///
/// Путь, настройки нарезки, текст ошибки справа от подписи переносились
/// рваным правым краем в узкой колонке. Короткое значение (дата, число,
/// статус) — по-прежнему `LabeledContent` в одну строку.
struct InspectorField: View {
    let title: String
    let value: String
    var monospaced = false

    init(_ title: String, _ value: String, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .copyable(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // VoiceOver читает подпись и значение одной строкой.
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    Form {
        Section {
            LabeledContent("Вид" as String, value: "Папка → одна коллекция")
            InspectorField("Путь" as String, "/Users/USER/Downloads/ru_rag_test_dataset-main/files_2", monospaced: true)
        }
    }
    .formStyle(.grouped)
    .frame(width: 300)
}
