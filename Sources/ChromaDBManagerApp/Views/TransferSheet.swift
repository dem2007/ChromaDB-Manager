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
        SheetShell(
            title: mode == .export
                ? String(localized: "Экспорт коллекции")
                : String(localized: "Импорт коллекции"),
            subtitle: mode == .export
                ? String(localized: "Коллекция уходит в пакет .chromaexport — папку с описанием и документами.")
                : String(localized: "Пакет .chromaexport разворачивается в коллекцию этой базы."),
            help: String(localized: "Пакет `.chromaexport` — это папка: `manifest.json` с описанием коллекции и `documents.jsonl`, по строке на документ. Так пакет на миллион документов не собирается в память ни при записи, ни при чтении. С векторами он в разы больше, зато импорт не тратит время локальной модели; без них — компактнее и годится для переноса на другую модель."),
            width: 620,
            height: 560
        ) {
            if let error = model.errorMessage {
                MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
            }
            if let message = model.statusMessage {
                MessageBanner(kind: .info, text: message) { model.statusMessage = nil }
            }
            if let stage = model.stage {
                ProgressView(value: model.progress ?? 0) { Text(stage).font(Theme.Font.caption) }
            }
            if mode == .export { exportBody } else { importBody }
        } actions: {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button(String(localized: "Отменить")) { model.cancel() }
                    .buttonStyle(.chromaNormal)
            }
            Button(String(localized: "Закрыть")) { onClose() }
                .buttonStyle(.chromaNormal)
            if mode == .export {
                Button(String(localized: "Экспортировать…")) {
                    guard let collection else { return }
                    model.export(collection: collection, filter: currentFilter, app: app)
                }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning || collection == nil || !app.connection.isConnected)
            } else {
                Button(String(localized: "Импортировать")) { model.runImport(target: collection, app: app) }
                    .buttonStyle(.chromaPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning || model.packageManifest == nil || model.packageProblem != nil)
            }
        }
    }

    // MARK: - Экспорт

    @ViewBuilder
    private var exportBody: some View {
        SectionCard(
            title: String(localized: "Что уйдёт в пакет"),
            subtitle: exportSizeLine,
            help: String(localized: "Свободное место проверяется до старта: упасть на середине хуже, чем не начаться. Оценка считает компоненту вектора как текст, а не как восемь двоичных байт, — заниженная оценка опаснее завышенной.")
        ) {
            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(String(localized: "Включить векторы"), isOn: $model.includesEmbeddings)
                        .font(Theme.Font.control)
                    Text("С векторами пакет в разы больше, зато импорт не тратит время локальной модели.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                }

                if let filter = currentFilter, !filter.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(String(localized: "Только то, что сейчас отфильтровано"), isOn: $model.usesCurrentFilter)
                            .font(Theme.Font.control)
                        Text("Фильтр запишется в манифест словами — чтобы потом было видно, почему в пакете не вся коллекция.")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 18)
                    }
                }
            }
        }

        if let manifest = model.lastExport { manifestCard(manifest) }
    }

    /// Ожидаемый размер пакета — подписью карточки, а не строкой в её теле.
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
        SectionCard(
            title: String(localized: "Пакет"),
            subtitle: model.packageURL.map { $0.lastPathComponent }
                ?? String(localized: "Папка .chromaexport, снятая с этой или другой машины.")
        ) {
            HStack(spacing: 10) {
                Button(String(localized: "Выбрать пакет…")) { model.choosePackage(target: collection, app: app) }
                    .buttonStyle(.chromaNormal)
                Spacer(minLength: 0)
            }
        }

        if let problem = model.packageProblem {
            MessageBanner(kind: .error, text: problem)
        }

        if let manifest = model.packageManifest {
            manifestCard(manifest)

            SectionCard(
                title: String(localized: "Куда импортировать"),
                subtitle: model.importsIntoNewCollection
                    ? String(localized: "Метрика, размерность и модель возьмутся из манифеста — коллекция получится такой же, как была.")
                    : collection.map { String(localized: "Цель: «\($0.name)».") }
                        ?? String(localized: "Коллекция не выбрана.")
            ) {
                VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                    Picker("", selection: $model.importsIntoNewCollection) {
                        Text("В новую коллекцию").tag(true)
                        Text("В выбранную коллекцию").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .font(Theme.Font.control)
                    .onChange(of: model.importsIntoNewCollection) {
                        model.revalidate(target: collection, app: app)
                    }

                    if model.importsIntoNewCollection {
                        TextField(String(localized: "Имя коллекции"), text: $model.newCollectionName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 10) {
                        Text("Если документ уже есть").font(Theme.Font.control)
                        Picker("", selection: $model.conflictPolicy) {
                            ForEach(ImportConflictPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }

                    ForEach(model.packageWarnings, id: \.self) { warning in
                        MessageBanner(kind: .warning, text: warning)
                    }

                    if !manifest.includesEmbeddings {
                        MessageBanner(
                            kind: .warning,
                            text: String(localized: "В пакете нет векторов — они будут посчитаны заново моделью по умолчанию. Это время локальной модели, и его стоит оценить заранее.")
                        )
                    }

                    if let checkpoint = model.resumeOffer {
                        MessageBanner(
                            kind: .info,
                            text: String(localized: "Прошлый импорт этого пакета остановился на строке \(checkpoint.processedLines.plainDigits) (\(checkpoint.updatedAt.formatted(date: .abbreviated, time: .shortened))). Запуск продолжит с этого места.")
                        )
                    }
                }
            }
        }

        if let report = model.lastImport {
            SectionCard(title: "Отчёт импорта", subtitle: report.line) {
                VStack(alignment: .leading, spacing: 4) {
                    if !report.brokenLines.isEmpty {
                        Text("Строки, которые не разобрались: \(report.brokenLines.prefix(20).map(\.description).joined(separator: ", "))")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Они пропущены — один битый документ не должен ронять перенос целиком.")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                    if let clash = report.stoppedAtConflict {
                        Text("Остановлено на документе \(clash): так велит выбранная политика конфликтов.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.Palette.attention)
                    }
                }
            }
        }
    }

    private func manifestCard(_ manifest: CollectionExportManifest) -> some View {
        SectionCard(title: "Пакет", subtitle: manifest.collectionName) {
            VStack(alignment: .leading, spacing: 3) {
                row("Документов", manifest.documentCount.plainDigits)
                row("Векторы", manifest.includesEmbeddings ? String(localized: "включены") : String(localized: "не включены"))
                if let dimension = manifest.dimension { row("Размерность", dimension.plainDigits) }
                if let metric = manifest.metric { row("Метрика", metric) }
                if let model = manifest.model { row("Модель", model) }
                row("Сервер-источник", "\(manifest.serverVersion), \(manifest.tenant)/\(manifest.database)")
                row("Создан", manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))
                if let filter = manifest.filterDescription { row("Фильтр", filter) }
                row("Размер данных", ByteCountFormatter.string(fromByteCount: Int64(manifest.dataBytes), countStyle: .file))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .frame(width: 140, alignment: .leading)
            Text(value).font(Theme.Font.caption)
                .textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        }
    }
}
