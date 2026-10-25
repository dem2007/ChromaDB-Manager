import SwiftUI

/// Поле «через запятую», в которое можно **набрать** второй элемент.
///
/// Прежде текст таких полей каждый раз собирался заново из разобранного
/// списка, а `split(separator:)` отбрасывает пустой кусок после последней
/// запятой: «md,» становилось «md», запятая исчезала в момент нажатия,
/// и следующие буквы дописывались к первому элементу — «mdpdf». Второй
/// элемент можно было только вставить.
///
/// Здесь текст свой. Список обновляется на каждом нажатии, а текст
/// переписывается только когда список поменяли снаружи — так, что набранное
/// ему уже не соответствует.
struct CommaListField: View {
    let title: String
    let items: [String]
    /// Что значит пустое поле — подсказкой в нём самом.
    let prompt: String?
    /// Как привести один элемент к виду, в котором он хранится; пустой —
    /// выбрасывается.
    let clean: (String) -> String
    let commit: ([String]) -> Void

    @State private var text = ""

    init(
        _ title: String, items: [String], prompt: String? = nil,
        clean: @escaping (String) -> String = { $0.trimmingCharacters(in: .whitespaces) },
        commit: @escaping ([String]) -> Void
    ) {
        self.title = title
        self.items = items
        self.prompt = prompt
        self.clean = clean
        self.commit = commit
    }

    init(
        _ title: String, items: Binding<[String]>,
        clean: @escaping (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
    ) {
        self.init(title, items: items.wrappedValue, clean: clean, commit: { items.wrappedValue = $0 })
    }

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .onAppear { text = items.joined(separator: ", ") }
            .onChange(of: text) { _, typed in
                let parsed = parse(typed)
                if parsed != items { commit(parsed) }
            }
            .onChange(of: items) { _, current in
                if parse(text) != current { text = current.joined(separator: ", ") }
            }
    }

    private func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
    }
}
