import SwiftUI
import AppKit
import ChromaCore

/// «Файлы» на вкладке «Обзор» коллекции: какие файлы в ней лежат, по имени
/// и пути, и их ID — тот, что принимает `get_file`.
///
/// Для задач, где данные отдельного куска не нужны: скопировать ID для
/// агента, найти файл, открыть его целиком, перейти к его кускам.
struct CollectionFilesSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: CollectionFilesViewModel
    let collection: ChromaCollection
    var openFile: (CollectionFile) -> Void
    var showChunks: (CollectionFile) -> Void
    var searchInFile: (CollectionFile) -> Void

    var body: some View {
        Section {
            if let error = model.errorMessage {
                LabeledContent {
                    Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                } label: {
                    Notice(.warning, error)
                }
            }
            if let list = model.list {
                listRows(list)
            }
            actionRow
        } header: {
            SectionHeader(
                String(localized: "Файлы"),
                help: String(localized: "Список собирается чтением метаданных всех кусков коллекции — не выборки, — поэтому видны все файлы. ID файла — то, что принимает инструмент get_file у агента; без него файл узнаётся по пути.")
            )
        } footer: {
            if model.list == nil {
                Text("Какие файлы лежат в коллекции, по имени и пути, и их ID для get_file.")
            }
        }
        .task(id: collection.id) { model.prepare(for: collection) }
    }

    // MARK: - Список

    @ViewBuilder
    private func listRows(_ list: CollectionFileList) -> some View {
        LabeledContent(String(localized: "Собрано"), value: summary(list))
        if model.isStale(collection) {
            StatusLabel(.warning, String(localized: "С тех пор в коллекции стало другое число записей — обновите список"))
        }
        HStack {
            TextField(String(localized: "Найти"), text: $model.query, prompt: Text("Имя или путь"))
                .textFieldStyle(.roundedBorder)
            Picker(String(localized: "Порядок"), selection: $model.sort) {
                ForEach(CollectionFilesViewModel.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button(String(localized: "Выгрузить CSV…")) { model.exportCSV(collection: collection) }
                .help(String(localized: "Весь список, без учёта поиска: имя, путь, ID, источник, куски, размер, дата"))
        }
        let matching = model.matching
        ForEach(matching.prefix(CollectionFilesViewModel.shownLimit)) { file in
            fileRow(file)
        }
        if matching.isEmpty, !model.query.isEmpty {
            Text("Ни один файл не подходит под «\(model.query)».")
                .foregroundStyle(.secondary)
        }
        if matching.count > CollectionFilesViewModel.shownLimit {
            Text("…и ещё \((matching.count - CollectionFilesViewModel.shownLimit).plainDigits) — уточните поиск или выгрузите список в CSV.")
                .foregroundStyle(.secondary)
        }
        if list.recordsWithoutFile > 0 {
            LabeledContent(
                String(localized: "Без файла"),
                value: RussianCount.grouped(list.recordsWithoutFile, "запись", "записи", "записей")
            )
            .help(String(localized: "Добавлены агентом, импортом или вручную — исходного файла у них нет."))
        }
    }

    private func summary(_ list: CollectionFileList) -> String {
        var parts = [
            String(localized: "файлов \(list.files.count.plainDigits)"),
            String(localized: "записей \(list.records.plainDigits)"),
        ]
        if list.filesWithoutID > 0 {
            parts.append(String(localized: "без ID \(list.filesWithoutID.plainDigits)"))
        }
        parts.append(list.builtAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// Строка — одной линией при любой длине имени: имя сокращается
    /// посередине, а числа и кнопка стоят справа на своём месте. В строке
    /// формы (`LabeledContent`) длинное имя переносило числа под себя,
    /// и соседние строки прыгали.
    private func fileRow(_ file: CollectionFile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.folder.isEmpty ? (file.sourceName ?? "—") : file.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(file.path)
            Spacer(minLength: 12)
            Text(details(file))
                .foregroundStyle(file.isIncomplete ? Color.orange : Color.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            copyButton(file)
                .fixedSize()
        }
        .contextMenu { menu(file) }
    }

    private func details(_ file: CollectionFile) -> String {
        var parts = [RussianCount.grouped(file.chunks, "кусок", "куска", "кусков")]
        if file.isIncomplete, let expected = file.expectedChunks {
            parts[0] = String(localized: "\(file.chunks.plainDigits) из \(expected.plainDigits) кусков — запись неполная")
        }
        if let bytes = file.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let date = file.modifiedDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    /// Кнопка копирования — постоянной ширины: надпись не меняется, отметка
    /// «скопировано» — сменой значка. Прежде надпись становилась длиннее,
    /// строке переставало хватать места, и она перестраивалась у человека
    /// под рукой.
    private func copyButton(_ file: CollectionFile) -> some View {
        let copied = model.copiedID == file.id
        let value = file.fileID ?? file.path
        return Button {
            model.copy(value, marking: file)
        } label: {
            Label {
                Text(file.fileID == nil ? String(localized: "Путь") : String(localized: "ID"))
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.primary)
                    .frame(width: 16)
            }
        }
        .help(file.fileID.map { String(localized: "Скопировать ID файла \($0) — для get_file") }
              ?? String(localized: "ID нет — файл записан ранней сборкой; get_file примет путь"))
        .accessibilityValue(copied ? String(localized: "Скопировано") : "")
    }

    @ViewBuilder
    private func menu(_ file: CollectionFile) -> some View {
        Button(String(localized: "Скопировать ID файла")) {
            if let fileID = file.fileID { model.copy(fileID, marking: file) }
        }
        .disabled(file.fileID == nil)
        Button(String(localized: "Скопировать путь")) { model.copy(file.path, marking: file) }
            .disabled(file.path.isEmpty)
        Divider()
        Button(String(localized: "Открыть")) { openFile(file) }
        Button(String(localized: "Показать в Finder")) { model.revealInFinder(file, app: app) }
        Divider()
        Button(String(localized: "Куски этого файла")) { showChunks(file) }
        Button(String(localized: "Искать в этом файле")) { searchInFile(file) }
    }

    // MARK: - Сбор

    @ViewBuilder
    private var actionRow: some View {
        if model.isLoading(collection) {
            LabeledContent {
                Button(String(localized: "Остановить")) { model.cancel() }
            } label: {
                if let progress = model.progress {
                    ProgressView(value: progress) { Text(model.progressText ?? "") }
                } else {
                    ProgressView { Text("Чтение метаданных") }
                }
            }
        } else {
            LabeledContent {
                Button(model.list == nil ? String(localized: "Показать файлы") : String(localized: "Обновить список")) {
                    model.load(collection: collection, app: app)
                }
                // Сбор один на окно: пока идёт чужой, свой подождёт.
                .disabled(model.isRunning)
            } label: {
                if model.isRunning {
                    Text("Собирается список другой коллекции — дождитесь его или остановите там")
                } else {
                    Text(model.list == nil
                         ? String(localized: "Список ещё не собран")
                         : String(localized: "Собирается заново целиком"))
                }
            }
        }
    }
}
