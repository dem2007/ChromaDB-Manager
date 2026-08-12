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
        SheetShell(
            title: String(localized: "Перетащенное"),
            subtitle: String(localized: "Перетащено: \(items.summary). Приложение ничего не делает с этим само."),
            help: String(localized: "Папка становится источником: приложение следит за ней и переиндексирует изменившиеся файлы. Отдельные файлы добавляются разово — следить за ними приложение не будет, и, если они изменятся на диске, в базе останется прежний текст."),
            width: 560,
            height: nil,
            scrolls: false
        ) {
            if !items.folders.isEmpty {
                SectionCard(
                    title: String(localized: "Папки"),
                    subtitle: String(localized: "Станут источниками — с отслеживанием изменений.")
                ) {
                    VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                        ForEach(items.folders, id: \.self) { url in
                            Text(url.path).font(Theme.Font.mono).foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        HStack {
                            Button(String(localized: "Зарегистрировать источником")) { registerSources(items.folders) }
                                .buttonStyle(.chromaNormal)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if !items.files.isEmpty {
                SectionCard(
                    title: String(localized: "Файлы"),
                    subtitle: String(localized: "Разовое добавление: следить за этими файлами приложение не будет.")
                ) {
                    VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                        ForEach(items.files.prefix(8), id: \.self) { url in
                            Text(url.lastPathComponent).font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if items.files.count > 8 {
                            Text("…и ещё \(RussianCount.grouped(items.files.count - 8, "файл", "файла", "файлов"))")
                                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                        }
                        HStack(spacing: 10) {
                            Text("В коллекцию").font(Theme.Font.control)
                            Picker("", selection: $collection) {
                                Text("выберите").tag("")
                                ForEach(collections, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            Spacer(minLength: 0)
                        }
                        // Пустой список — это тупик, и объяснить его надо
                        // здесь: иначе кнопка просто не нажимается, и почему —
                        // непонятно.
                        if let problem = collectionsProblem {
                            Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button(String(localized: "Добавить документами")) { addDocuments(items.files, collection) }
                                .buttonStyle(.chromaNormal)
                                .disabled(collection.isEmpty)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if !items.unsupported.isEmpty {
                Text("Приложение не читает: \(items.unsupported.map(\.lastPathComponent).joined(separator: ", "))")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(String(localized: "Отмена"), action: cancel)
                .buttonStyle(.chromaNormal)
                .keyboardShortcut(.cancelAction)
        }
        .task { await loadCollections() }
    }
}
