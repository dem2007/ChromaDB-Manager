import SwiftUI
import UniformTypeIdentifiers
import ChromaCore

/// Что делать с перетащенным.
///
/// Спрашивается всегда: приложение, которое само решило зарегистрировать
/// папку источником и запустить по ней индексацию, — это приложение,
/// которому потом не доверяют перетаскивать ничего.
struct DropSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    let items: DroppedItems
    /// Зарегистрировать папки источниками — переход на экран источников
    /// с уже заполненным путём.
    let registerSources: ([URL]) -> Void
    /// Добавить файлы документами в выбранную коллекцию.
    let addDocuments: ([URL], String) -> Void
    let cancel: () -> Void

    @State private var collection: String = ""
    @State private var collections: [String] = []
    @State private var collectionsProblem: String?

    /// Список коллекций для выбора.
    ///
    /// Ошибка и «коллекций нет» — разные вещи, и обе называются вслух:
    /// молча неактивная кнопка «Добавить документами» не объясняет ничего.
    private func loadCollections() async {
        guard let client = app.client else {
            collectionsProblem = String(localized: "Нет подключения к базе — подключитесь на экране «Подключение».")
            return
        }
        do {
            collections = try await client.listCollections().map(\.name)
            collectionsProblem = collections.isEmpty
                ? String(localized: "В базе нет ни одной коллекции — создайте её на экране «Коллекции».")
                : nil
            if collections.count == 1 { collection = collections[0] }
        } catch {
            collectionsProblem = app.describe(error)
            app.report(error, category: "Перетаскивание")
        }
    }

    var body: some View {
        SheetFrame {
            Section {
                LabeledContent(String(localized: "Перетащено"), value: items.summary)
            } header: {
                SectionHeader(
                    String(localized: "Перетащенное"),
                    help: String(localized: "Папка становится источником: приложение следит за ней и переиндексирует изменившиеся файлы. Отдельные файлы добавляются разово — следить за ними приложение не будет, и, если они изменятся на диске, в базе останется прежний текст.")
                )
            } footer: {
                VStack(alignment: .leading) {
                    Text("Приложение ничего не делает с этим само — выберите, что сделать.")
                    if !items.unsupported.isEmpty {
                        Notice(.warning, String(localized: "Приложение не читает: \(items.unsupported.map(\.lastPathComponent).joined(separator: ", "))"))
                    }
                }
            }

            if !items.folders.isEmpty {
                Section {
                    ForEach(items.folders, id: \.self) { url in
                        Label(url.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    }
                    Button(String(localized: "Зарегистрировать источником")) { registerSources(items.folders) }
                } header: {
                    Text("Папки")
                } footer: {
                    Text("Станут источниками — с отслеживанием изменений.")
                }
            }

            if !items.files.isEmpty {
                Section {
                    ForEach(items.files.prefix(8), id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if items.files.count > 8 {
                        Text("…и ещё \(RussianCount.grouped(items.files.count - 8, "файл", "файла", "файлов"))")
                            .foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "В коллекцию"), selection: $collection) {
                        Text("выберите").tag("")
                        ForEach(collections, id: \.self) { Text($0).tag($0) }
                    }
                    Button(String(localized: "Добавить документами")) { addDocuments(items.files, collection) }
                        .disabled(collection.isEmpty)
                } header: {
                    Text("Файлы")
                } footer: {
                    // Пустой список — это тупик, и объяснить его надо
                    // здесь: иначе кнопка просто не нажимается, и почему —
                    // непонятно.
                    if let problem = collectionsProblem {
                        Notice(.warning, problem)
                    } else {
                        Text("Разовое добавление: следить за этими файлами приложение не будет.")
                    }
                }
            }
        } actions: {
            Spacer()
            Button(String(localized: "Отменить"), action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .task { await loadCollections() }
    }
}
