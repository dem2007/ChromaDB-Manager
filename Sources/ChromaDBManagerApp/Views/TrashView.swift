import SwiftUI
import ChromaCore

/// «Корзина»: what was deleted from the UI, from where, when — and the
/// way back, without a re-embed.
///
/// Тип Б: таблица удалённого или `ContentUnavailableView`. Поиск —
/// в тулбаре, фильтр по коллекции и действия — там же; «Восстановить» —
/// двойной щелчок и контекстное меню. Настройки корзины — в окне
/// «Настройки» → «Хранение».
struct TrashView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var trash: TrashService
    @ObservedObject var model: TrashViewModel
    /// Порядок, ширины и видимость колонок — помнит окно (v3).
    @SceneStorage("table.trash.v3") private var columns: TableColumnCustomization<TrashEntry>

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var entries: [TrashEntry] { model.entries(app) }

    var body: some View {
        VStack(spacing: 0) {
            messages
            if trash.isLoading && trash.entries.isEmpty {
                ProgressView(String(localized: "Корзина читается…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if trash.entries.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Корзина пуста"), systemImage: "trash")
                } description: {
                    Text(settings.configuration.trashEnabled
                         ? String(localized: "Удалённые вручную документы и коллекции появятся здесь — и вернутся отсюда без повторного эмбеддинга.")
                         : String(localized: "Корзина выключена: удаление документа необратимо."))
                } actions: {
                    if !settings.configuration.trashEnabled {
                        SettingsLink { Text("Изменить в Настройках…") }
                    }
                }
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
            if !trash.entries.isEmpty { footer }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Поиск"))
        .toolbar { toolbarContent }
        .confirmationDialog(
            String(localized: "Очистить корзину безвозвратно?"),
            isPresented: $model.showEmptyConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) { model.emptyTrash(app) }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text(String(localized: "Записей: \(trash.entries.count.plainDigits). Восстановить их после этого будет нельзя."))
        }
        .confirmationDialog(
            String(localized: "Восстановить выбранное: \(model.selectedIDs.count.plainDigits)?"),
            isPresented: $model.confirmingRestore,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Восстановить")) { Task { await model.restoreSelected(app) } }
            Button(String(localized: "Отменить"), role: .cancel) {}
        } message: {
            Text(model.restoreWarning(app) ?? String(localized: "Записи вернутся в свои коллекции из сохранённых векторов, без эмбеддинга."))
        }
    }

    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.statusMessage != nil {
            VStack(alignment: .leading) {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let status = model.statusMessage {
                    HStack {
                        Notice(.info, status)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.statusMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    // MARK: - Таблица

    private var table: some View {
        // Строки однострочные (v3): идентификатор — своей колонкой.
        Table(entries, selection: $model.selectedIDs, columnCustomization: $columns) {
            TableColumn(String(localized: "Документ")) { entry in
                Text(preview(entry.document))
                    .lineLimit(1)
                    .help(entry.document ?? "")
            }
            .customizationID("document")
            TableColumn(String(localized: "ID")) { entry in
                Text(entry.documentID)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.documentID)
            }
            .width(min: 90, ideal: 130, max: 180)
            .customizationID("id")
            TableColumn(String(localized: "Коллекция")) { entry in
                Text(entry.collectionName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.collectionName)
            }
            .width(min: 100, ideal: 160, max: 220)
            .customizationID("collection")
            TableColumn(String(localized: "Удалено")) { entry in
                Text(entry.reason == .collection
                     ? String(localized: "вся коллекция")
                     : String(localized: "документ"))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110, max: 150)
            .customizationID("reason")
            TableColumn(String(localized: "Когда")) { entry in
                Text(entry.deletedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 110, ideal: 140, max: 200)
            .customizationID("date")
            TableColumn(String(localized: "Вектор")) { entry in
                if !entry.hasEmbedding {
                    StatusLabel(.warning, String(localized: "нет"))
                        .help(String(localized: "Без вектора — восстановление недоступно"))
                } else {
                    Text("есть").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 70, max: 100)
            .customizationID("vector")
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button(String(localized: "Восстановить")) {
                model.requestRestore(ids, app: app, alwaysAsk: false)
            }
            .disabled(ids.isEmpty || model.isRestoring)
            if ids.count == 1, let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                Divider()
                Button(String(localized: "Скопировать ID")) { copy(entry.documentID) }
                // В памяти — только начало текста; целиком — из файла.
                Button(String(localized: "Скопировать текст")) {
                    guard entry.isDocumentTruncated else { return copy(entry.document ?? "") }
                    Task {
                        let full = await trash.fullEntries(withIDs: [entry.id]).first?.document
                        copy(full ?? entry.document ?? "")
                    }
                }
                    .disabled((entry.document ?? "").isEmpty)
            }
        } primaryAction: { ids in
            model.requestRestore(ids, app: app, alwaysAsk: true)
        }
    }

    private var footer: some View {
        TableFooter(
            footerLine,
            help: String(localized: "Приложение не удаляет ничего само. В корзину попадает только то, что удалено руками из интерфейса: документ, выбранные находки инспектора или коллекция целиком. Автоматически удалённые при переиндексации чанки сюда не попадают. Запись хранит и текст, и вектор — поэтому восстановление ничего не считает заново. Записи старше срока хранения и всё, что не помещается в предел размера, вытесняются: сначала самые старые.")
        ) {
            if model.isRestoring { ProgressView().controlSize(.small) }
        }
    }

    private var footerLine: String {
        let count = String(localized: "В корзине \(RussianCount.grouped(trash.entries.count, "запись", "записи", "записей"))")
        let size = trash.totalBytes > 0
            ? String(localized: " · занято \(Self.sizeFormatter.string(fromByteCount: Int64(trash.totalBytes)))")
            : ""
        let chosen = model.selectedIDs.isEmpty
            ? ""
            : String(localized: " · выбрано \(model.selectedIDs.count.plainDigits)")
        return count + size + chosen
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !trash.collectionNames.isEmpty {
                Picker(String(localized: "Коллекция"), selection: $model.collectionFilter) {
                    Text(String(localized: "Все коллекции")).tag(String?.none)
                    ForEach(trash.collectionNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .help(String(localized: "Показать удалённое из одной коллекции"))
            }
            Menu {
                Button(String(localized: "Восстановить всё")) {
                    Task { await model.restoreAll(app) }
                }
                .disabled(entries.isEmpty || model.isRestoring)
                Divider()
                SettingsLink { Text("Настройки корзины…") }
                Divider()
                Button(String(localized: "Очистить корзину…"), role: .destructive) {
                    model.showEmptyConfirmation = true
                }
                .disabled(trash.entries.isEmpty)
            } label: {
                Label(String(localized: "Ещё"), systemImage: "ellipsis.circle")
            }
            if !trash.entries.isEmpty {
                Button {
                    model.requestRestore(model.selectedIDs, app: app, alwaysAsk: false)
                } label: {
                    Label(String(localized: "Восстановить"), systemImage: "arrow.uturn.backward")
                }
                .help(String(localized: "Вернуть выбранное в коллекцию — из сохранённого вектора, без эмбеддинга"))
                .disabled(model.selectedIDs.isEmpty || model.isRestoring)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func preview(_ document: String?) -> String {
        guard let document, !document.isEmpty else { return String(localized: "— пустой документ —") }
        let flat = document.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}
