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

    private var groupBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { node.logic ?? .and },
                    set: { node.logic = $0 }
                )) {
                    ForEach(FilterLogic.allCases) { logic in
                        Text(logic.title).tag(logic)
                    }
                }
                .labelsHidden()
                .frame(width: 190)

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
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
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
        .padding(depth == 0 ? 0 : 8)
        .background(
            depth == 0
                ? Color.clear
                : Color(nsColor: .textBackgroundColor).opacity(0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var conditionRow: some View {
        let condition = Binding(
            get: { node.condition ?? MetadataCondition() },
            set: { node.condition = $0 }
        )
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if knownFields.isEmpty {
                    TextField(String(localized: "поле"), text: condition.field)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                } else {
                    // The known keys as a menu, with a free-text field kept for
                    // everything the current page did not happen to show.
                    HStack(spacing: 2) {
                        TextField(String(localized: "поле"), text: condition.field)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 122)
                        Menu {
                            ForEach(knownFields, id: \.self) { key in
                                Button(key) { condition.wrappedValue.field = key }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                }

                Picker("", selection: condition.op) {
                    ForEach(FilterOperator.allCases) { op in
                        Text(op.title).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                TextField(
                    condition.wrappedValue.op.wantsList
                        ? String(localized: "значения через запятую")
                        : String(localized: "значение"),
                    text: condition.value
                )
                .textFieldStyle(.roundedBorder)

                if let onRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            // Said here, next to the field, and before the request is sent.
            if let problem = condition.wrappedValue.problem {
                Text(problem)
                    .font(Theme.Font.micro).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(String(localized: "Текст документа")).font(Theme.Font.caption).bold()
                if conditions.count > 1 {
                    Picker("", selection: $logic) {
                        ForEach(FilterLogic.allCases) { item in
                            Text(item.shortTitle).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 110)
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
                HStack(spacing: 8) {
                    Picker("", selection: $condition.op) {
                        ForEach(DocumentTextOperator.allCases) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    TextField(String(localized: "подстрока"), text: $condition.text)
                        .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        conditions.removeAll { $0.id == condition.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !conditions.isEmpty {
                Text(String(localized: "Поиск по подстроке различает регистр: «Груша» и «груша» — разные условия."))
                    .font(Theme.Font.micro).foregroundStyle(.secondary)
            }
        }
    }
}
