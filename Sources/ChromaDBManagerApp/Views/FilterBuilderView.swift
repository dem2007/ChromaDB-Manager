import SwiftUI
import ChromaCore

/// The condition tree, drawn recursively.
///
/// A group holds a logic and children; a child is either another group or a
/// single condition. Nesting is the point: `$and` and `$or` mixed at two levels
/// is what makes «этот автор ИЛИ тот, но только за 2024» expressible, and the
/// server handles it.
struct FilterNodeEditor: View {
    @Binding var node: FilterNode
    /// Fields offered in the picker — from the collection's schema, or from
    /// the keys actually seen on the page.
    let knownFields: [String]
    let depth: Int
    let onRemove: (() -> Void)?

    var body: some View {
        if node.isGroup {
            groupBody
        } else if node.condition != nil {
            conditionRow
        }
    }

    @ViewBuilder
    private var groupBody: some View {
        let controls = VStack(alignment: .leading) {
            HStack {
                Picker(String(localized: "Логика"), selection: Binding(
                    get: { node.logic ?? .and },
                    set: { node.logic = $0 }
                )) {
                    ForEach(FilterLogic.allCases) { logic in
                        Text(logic.title).tag(logic)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Button {
                    node.children.append(.leaf(MetadataCondition()))
                } label: {
                    Label(String(localized: "Условие"), systemImage: "plus")
                }
                .buttonStyle(.borderless)

                // Two levels is what the interface can show without turning
                // into a maze; deeper trees go through the JSON editor.
                if depth < 2 {
                    Button {
                        node.children.append(.group(.or, [.leaf(MetadataCondition())]))
                    } label: {
                        Label(String(localized: "Группа"), systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                if let onRemove {
                    removeButton(onRemove)
                }
            }

            ForEach($node.children) { $child in
                FilterNodeEditor(
                    node: $child,
                    knownFields: knownFields,
                    depth: depth + 1,
                    onRemove: { node.children.removeAll { $0.id == child.id } }
                )
            }
        }
        // Вложенная группа — с отступом и чертой слева: видно, какие
        // условия связаны её логикой. `GroupBox` внутри формы рамки не
        // рисует.
        if depth == 0 {
            controls
        } else {
            HStack(alignment: .top) {
                Divider()
                controls
            }
            .padding(.leading)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(String(localized: "Убрать"), systemImage: "minus.circle")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Убрать"))
    }

    @ViewBuilder
    private var conditionRow: some View {
        let condition = Binding(
            get: { node.condition ?? MetadataCondition() },
            set: { node.condition = $0 }
        )
        VStack(alignment: .leading) {
            HStack {
                // Поля в строке условия — с рамкой: без неё подсказки «поле»
                // и «значение» читаются как подписи.
                TextField(String(localized: "Поле"), text: condition.field, prompt: Text("поле"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if !knownFields.isEmpty {
                    // The known keys as a menu, with a free-text field kept for
                    // everything the current page did not happen to show.
                    Menu {
                        ForEach(knownFields, id: \.self) { key in
                            Button(key) { condition.wrappedValue.field = key }
                        }
                    } label: {
                        Label(String(localized: "Известные поля"), systemImage: "list.bullet")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Известные поля"))
                }

                Picker(String(localized: "Оператор"), selection: condition.op) {
                    ForEach(FilterOperator.allCases) { op in
                        Text(op.title).tag(op)
                    }
                }
                .labelsHidden()
                .fixedSize()

                TextField(
                    String(localized: "Значение"),
                    text: condition.value,
                    prompt: Text(condition.wrappedValue.op.wantsList
                        ? String(localized: "значения через запятую")
                        : String(localized: "значение"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)

                // «2025» и «true» иначе уходят числом и логическим значением,
                // а в поле могут лежать строки — тогда равенство не найдёт
                // ничего.
                if condition.wrappedValue.valueLooksTyped || condition.wrappedValue.valueIsText {
                    Toggle(String(localized: "как текст"), isOn: condition.valueIsText)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(String(localized: "Отправить значение строкой, даже если оно похоже на число или true/false."))
                }

                if let onRemove {
                    removeButton(onRemove)
                }
            }
            // Said here, next to the field, and before the request is sent.
            if let problem = condition.wrappedValue.problem {
                Notice(.warning, problem)
            }
        }
    }
}

/// `where_document`: a flat list of contains / not-contains, joined by one
/// logic. Deeper shapes are possible on the server and available through the
/// JSON editor, but they are not worth a second tree in the interface.
struct DocumentTextConditionsEditor: View {
    @Binding var conditions: [DocumentTextCondition]
    @Binding var logic: FilterLogic

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if conditions.count > 1 {
                    Picker(String(localized: "Логика"), selection: $logic) {
                        ForEach(FilterLogic.allCases) { item in
                            Text(item.shortTitle).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Button {
                    conditions.append(DocumentTextCondition())
                } label: {
                    Label(String(localized: "Условие"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }

            ForEach($conditions) { $condition in
                HStack {
                    Picker(String(localized: "Оператор"), selection: $condition.op) {
                        ForEach(DocumentTextOperator.allCases) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    TextField(String(localized: "Подстрока"), text: $condition.text, prompt: Text("подстрока"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        conditions.removeAll { $0.id == condition.id }
                    } label: {
                        Label(String(localized: "Убрать"), systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Убрать"))
                }
            }

            if !conditions.isEmpty {
                Text(String(localized: "Поиск по подстроке различает регистр: «Груша» и «груша» — разные условия."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
