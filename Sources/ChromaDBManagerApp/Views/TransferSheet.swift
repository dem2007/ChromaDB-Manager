import SwiftUI
import ChromaCore

/// Экспорт и импорт коллекции пакетом `.chromaexport`.
struct TransferSheet: View {
    enum Mode { case export, importing }

    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: TransferViewModel
    let mode: Mode
    let collection: ChromaCollection?
    let currentFilter: DocumentFilter?
    var onClose: () -> Void

    var body: some View {
        SheetFrame(width: .wide) {
            Section {
                if mode == .export {
                    LabeledContent(String(localized: "Коллекция"), value: collection?.name ?? "—")
                } else {
                    LabeledContent(String(localized: "Пакет")) {
                        Text(model.packageURL?.lastPathComponent ?? String(localized: "не выбран"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button(String(localized: "Выбрать пакет…")) { model.choosePackage(target: collection, app: app) }
                }
                if let stage = model.stage {
                    ProgressView(value: model.progress ?? 0) { Text(stage) }
                }
            } header: {
                SectionHeader(
                    mode == .export
                        ? String(localized: "Экспорт коллекции")
                        : String(localized: "Импорт коллекции"),
                    help: String(localized: "Пакет `.chromaexport` — это папка: `manifest.json` с описанием коллекции и `documents.jsonl`, по строке на документ. Так пакет на миллион документов не собирается в память ни при записи, ни при чтении. С векторами он в разы больше, зато импорт не тратит время локальной модели; без них — компактнее и годится для переноса на другую модель.")
                )
            } footer: {
                VStack(alignment: .leading) {
                    if let error = model.errorMessage {
                        Notice(.warning, error)
                    }
                    if let message = model.statusMessage {
                        Notice(.info, message)
                    }
                    if mode == .importing, let problem = model.packageProblem {
                        Notice(.warning, problem)
                    }
                    if model.errorMessage == nil, model.statusMessage == nil, model.packageProblem == nil || mode == .export {
                        Text(mode == .export
                             ? String(localized: "Коллекция уходит в пакет .chromaexport — папку с описанием и документами.")
                             : String(localized: "Пакет .chromaexport разворачивается в коллекцию этой базы."))
                    }
                }
            }
            if mode == .export { exportBody } else { importBody }
        } actions: {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button(String(localized: "Остановить")) { model.cancel() }
            }
            Spacer()
            Button(String(localized: "Закрыть")) { onClose() }
                .keyboardShortcut(.cancelAction)
            if mode == .export {
                Button(String(localized: "Экспортировать…")) {
                    guard let collection else { return }
                    model.export(collection: collection, filter: currentFilter, app: app)
                }
                .primaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || collection == nil || !app.connection.isConnected)
            } else {
                Button(String(localized: "Импортировать")) { model.runImport(target: collection, app: app) }
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning || model.packageManifest == nil || model.packageProblem != nil)
            }
        }
    }

    // MARK: - Экспорт

    @ViewBuilder
    private var exportBody: some View {
        Section {
            Toggle(String(localized: "Включить векторы"), isOn: $model.includesEmbeddings)
                .help(String(localized: "С векторами пакет в разы больше, зато импорт не тратит время локальной модели."))
            if let filter = currentFilter, !filter.isEmpty {
                Toggle(String(localized: "Только то, что сейчас отфильтровано"), isOn: $model.usesCurrentFilter)
                    .help(String(localized: "Фильтр запишется в манифест словами — чтобы потом было видно, почему в пакете не вся коллекция."))
            }
        } header: {
            SectionHeader(
                String(localized: "Что уйдёт в пакет"),
                help: String(localized: "Свободное место проверяется до старта: упасть на середине хуже, чем не начаться. Оценка считает компоненту вектора как текст, а не как восемь двоичных байт, — заниженная оценка опаснее завышенной.")
            )
        } footer: {
            Text(exportSizeLine)
        }

        if let manifest = model.lastExport { manifestSection(manifest) }
    }

    /// Ожидаемый размер пакета — подписью секции.
    private var exportSizeLine: String {
        guard let collection, let count = collection.documentCount else {
            return String(localized: "Пакет собирается из описания коллекции и её документов.")
        }
        let estimate = CollectionExporter.estimatedBytes(
            documents: count,
            dimension: model.includesEmbeddings ? collection.effectiveDimension : 0
        )
        return String(localized: "Примерно \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) при \(count.plainDigits) документах.")
    }

    // MARK: - Импорт

    @ViewBuilder
    private var importBody: some View {
        if let manifest = model.packageManifest {
            manifestSection(manifest)

            Section {
                Picker(String(localized: "Куда"), selection: $model.importsIntoNewCollection) {
                    Text("В новую коллекцию").tag(true)
                    Text("В выбранную коллекцию").tag(false)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: model.importsIntoNewCollection) {
                    model.revalidate(target: collection, app: app)
                }
                if model.importsIntoNewCollection {
                    TextField(String(localized: "Имя коллекции"), text: $model.newCollectionName)
                }
                Picker(String(localized: "Если документ уже есть"), selection: $model.conflictPolicy) {
                    ForEach(ImportConflictPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
            } header: {
                Text("Куда импортировать")
            } footer: {
                VStack(alignment: .leading) {
                    Text(model.importsIntoNewCollection
                         ? String(localized: "Метрика, размерность и модель возьмутся из манифеста — коллекция получится такой же, как была.")
                         : collection.map { String(localized: "Цель: «\($0.name)».") }
                            ?? String(localized: "Коллекция не выбрана."))
                    ForEach(model.packageWarnings, id: \.self) { warning in
                        Notice(.warning, warning)
                    }
                    if !manifest.includesEmbeddings {
                        Notice(.warning, String(localized: "В пакете нет векторов — они будут посчитаны заново моделью по умолчанию. Это время локальной модели, и его стоит оценить заранее."))
                    }
                    if let checkpoint = model.resumeOffer {
                        Notice(.info, String(localized: "Прошлый импорт этого пакета остановился на строке \(checkpoint.processedLines.plainDigits) (\(checkpoint.updatedAt.formatted(date: .abbreviated, time: .shortened))). Запуск продолжит с этого места."))
                    }
                }
            }
        }

        if let report = model.lastImport {
            Section {
                StatusLabel(
                    report.brokenLines.isEmpty && report.stoppedAtConflict == nil ? .ok : .warning,
                    report.line
                )
                if !report.brokenLines.isEmpty {
                    LabeledContent(
                        String(localized: "Не разобрались строки"),
                        value: report.brokenLines.prefix(20).map(\.description).joined(separator: ", ")
                    )
                }
                if let clash = report.stoppedAtConflict {
                    LabeledContent(String(localized: "Остановлено на документе"), value: clash)
                }
            } header: {
                Text("Отчёт импорта")
            } footer: {
                if !report.brokenLines.isEmpty {
                    Text("Битые строки пропущены — один битый документ не должен ронять перенос целиком.")
                } else if report.stoppedAtConflict != nil {
                    Text("Так велит выбранная политика конфликтов.")
                }
            }
        }
    }

    private func manifestSection(_ manifest: CollectionExportManifest) -> some View {
        Section {
            row(String(localized: "Коллекция"), manifest.collectionName)
            row(String(localized: "Документов"), manifest.documentCount.plainDigits)
            row(String(localized: "Векторы"), manifest.includesEmbeddings ? String(localized: "включены") : String(localized: "не включены"))
            if let dimension = manifest.dimension { row(String(localized: "Размерность"), dimension.plainDigits) }
            if let metric = manifest.metric { row(String(localized: "Метрика"), metric) }
            if let model = manifest.model { row(String(localized: "Модель"), model) }
            row(String(localized: "Сервер-источник"), "\(manifest.serverVersion), \(manifest.tenant)/\(manifest.database)")
            row(String(localized: "Создан"), manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))
            if let filter = manifest.filterDescription { row(String(localized: "Фильтр"), filter) }
            row(String(localized: "Размер данных"), ByteCountFormatter.string(fromByteCount: Int64(manifest.dataBytes), countStyle: .file))
        } header: {
            Text("Пакет")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .copyable(value)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
