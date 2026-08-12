import SwiftUI
import ChromaCore

/// «Экран диагностики»: files the last run could not read, files it read
/// with something to say about them, and what can be done about each.
///
/// Everything here comes out of the manifests, not out of a fresh scan: opening
/// diagnostics must not re-read a folder of documents, and the point is to see
/// what the last run actually found.
struct DiagnosticsSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: SourcesViewModel
    /// Диагностика живёт в двух местах: вкладкой экрана «Источники» и
    /// отдельным листом, который открывают из карточки с находками. Разница
    /// ровно в оправе — своя шапка и фиксированный размер нужны только листу
    ///.
    var embedded = false

    /// Сколько строк показывать сразу и на сколько прибавлять по кнопке.
    ///
    /// Экран показывал **все** находки всех источников: на машине, где это
    /// поймали, — 2720 «требуют решения» и 1503 файла с предупреждениями.
    /// В строке «требуют решения» четыре текста, точка и до четырёх кнопок,
    /// то есть в листе оказывались десятки тысяч элементов разметки, каждый
    /// со своим измерением текста. Главный поток уходил в раскладку на
    /// секунды, интерфейс замирал, появлялись графические артефакты.
    ///
    /// Прочитать три тысячи строк всё равно нельзя; но и решать за человека,
    /// что ему хватит первых пятидесяти, приложение не вправе — поэтому
    /// сколько скрыто, сказано, и кнопка рядом.
    static let pageSize = 50
    @State private var problemLimit = pageSize
    @State private var warningLimit = pageSize

    var body: some View {
        Group {
            if embedded { embeddedBody } else { sheetBody }
        }
        .sheet(isPresented: Binding(
            get: { model.passwordFor != nil },
            set: { if !$0 { model.passwordFor = nil } }
        )) {
            passwordSheet
        }
    }

    /// Лист поверх экрана источников — со своей шапкой и подвалом.
    private var sheetBody: some View {
        SheetShell(
            title: String(localized: "Диагностика извлечения"),
            subtitle: String(localized: "Состояние после последнего запуска. Приложение ничего не перечитывает, открывая этот лист."),
            help: String(localized: "Файл с текстовым слоем читается напрямую; PDF-картинка требует распознавания, а .pages и .numbers — экспорта средствами самих программ. Пока разрешение на автоматизацию не выдано, такие файлы попадают сюда."),
            width: 720,
            height: 560
        ) {
            cards
        } actions: {
            Button(String(localized: "Закрыть")) { model.showingDiagnostics = false }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Та же диагностика вкладкой экрана: ни оправы, ни прокрутки, ни полей —
    /// всё это уже есть у экрана, который её показывает.
    ///
    /// Своя прокрутка внутри чужой и вторые поля поверх первых — из-за них
    /// карточки на вкладке были уже колонки и вставали по её середине
    ///. Прокрутка на экране одна — правило 5а.
    private var embeddedBody: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            cards
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var cards: some View {
        if model.problemCount == 0 && model.warnedFileCount == 0 {
            SectionCard(
                title: String(localized: "Замечаний нет"),
                subtitle: String(localized: "Последний запуск прочитал все файлы без оговорок."),
                help: String(localized: "Файл с текстовым слоем читается напрямую; PDF-картинка требует распознавания, а .pages и .numbers — экспорта средствами самих программ. Пока разрешение на автоматизацию не выдано, такие файлы попадают сюда.")
            ) {
                Text("Здесь появятся файлы, которые не удалось прочитать, и те, что прочитаны с оговорками. Приложение ничего не перечитывает, открывая эту вкладку, — показано состояние после последнего запуска.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        problemsCard
        warningsCard
    }

    private var sourcesWithProblems: [DataSource] {
        settings.configuration.dataSources.filter { !(model.problems[$0.id] ?? []).isEmpty }
    }

    private var sourcesWithWarnings: [DataSource] {
        settings.configuration.dataSources.filter { !(model.warnedFiles[$0.id] ?? []).isEmpty }
    }

    // MARK: - Files that need a decision

    /// Одна карточка на весь экран, а не по карточке на источник.
    ///
    /// Источников дюжина, и заголовок с подписью повторялись у каждого — три
    /// одинаковых абзаца подряд читаются как разные, пока не вчитаешься.
    /// Имя источника осталось рубрикой над его файлами.
    @ViewBuilder
    private var problemsCard: some View {
        if !sourcesWithProblems.isEmpty {
            SectionCard(
                title: String(localized: "Требуют решения: \(model.problemCount.plainDigits)"),
                subtitle: String(localized: "Эти файлы не прочитаны, и в базу из них ничего не попало."),
                help: String(localized: "Файл с текстовым слоем читается напрямую; PDF-картинка требует распознавания, а .pages и .numbers — экспорта средствами самих программ. Пока разрешение на автоматизацию не выдано, такие файлы попадают сюда.")
            ) {
                LazyVStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                    ForEach(sourcesWithProblems, id: \.id) { source in
                        let all = model.problems[source.id] ?? []
                        VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                            Text(source.name)
                                .font(Theme.Font.control).fontWeight(.medium)
                            ForEach(all.prefix(problemLimit)) { problem in
                                problemRow(problem, source: source)
                            }
                            more(shown: problemLimit, of: all.count) { problemLimit += Self.pageSize }
                        }
                    }
                }
            }
        }
    }

    /// «Показаны первые N из M» с кнопкой рядом.
    ///
    /// Строка нужна и тогда, когда всё поместилось: молча показать пятьдесят
    /// строк из тысячи — то же самое, что потерять девятьсот пятьдесят.
    @ViewBuilder
    private func more(shown: Int, of total: Int, onMore: @escaping () -> Void) -> some View {
        if total > shown {
            HStack(spacing: 8) {
                Text("показаны первые \(shown.plainDigits) из \(total.plainDigits)")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                Button(String(localized: "Показать ещё \(Self.pageSize)"), action: onMore)
                    .buttonStyle(.chromaSecondary)
                Spacer()
            }
        }
    }

    private func problemRow(_ problem: FileProblem, source: DataSource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(problem.relativePath).font(Theme.Font.body)
                .lineLimit(1).truncationMode(.middle)
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Theme.Palette.attention)
                    .frame(width: Theme.Size.statusDot, height: Theme.Size.statusDot)
                    .padding(.top, 5)
                Text(problem.reason).font(Theme.Font.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("замечено \(problem.noticedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            actions(for: problem, source: source)
        }
        .padding(Theme.Padding.rowHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    /// The suggested action first, the rest after it. Every file can be retried
    /// and every file can be excluded — the classification says what is worth
    /// trying, not what is allowed.
    @ViewBuilder
    private func actions(for problem: FileProblem, source: DataSource) -> some View {
        HStack(spacing: 8) {
            switch problem.remedy {
            case .enableOCR:
                Button(FileRemedy.enableOCR.title) { model.enableOCR(for: source, app: app) }
                    .buttonStyle(.chromaPrimary)
                    .disabled(source.ocrEnabled)
                if source.ocrEnabled {
                    Text("уже включено").font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            case .password:
                Button(FileRemedy.password.title) { model.promptForPassword(problem, source: source) }
                    .buttonStyle(.chromaPrimary)
                // Only the fact, never a verdict: whether the stored password
                // worked is what the reason line above says, and it is the run
                // that knows it. Found live — a password saved a second ago was
                // being labelled «не подошёл» before anything had tried it.
                if app.documentPasswords.has(sourceID: source.id, relativePath: problem.relativePath) {
                    Text("пароль сохранён").font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            case .retry, .exclude:
                EmptyView()
            }

            Button(FileRemedy.retry.title) { model.retry(source, app: app) }
                .buttonStyle(.chromaNormal)
                .disabled(model.isBusy(source.id) || !app.connection.isConnected)
            Button(FileRemedy.exclude.title) {
                model.exclude(problem.relativePath, in: source, app: app)
            }
            .buttonStyle(.chromaSecondary)
            Spacer()
        }
    }

    // MARK: - Files read with warnings

    @ViewBuilder
    private var warningsCard: some View {
        if !sourcesWithWarnings.isEmpty {
            SectionCard(
                title: String(localized: "Прочитаны с предупреждениями: \(model.warnedFileCount.plainDigits)"),
                subtitle: String(localized: "Эти файлы проиндексированы. Предупреждение — не ошибка: оно говорит, насколько доверять тексту и структуре.")
            ) {
                LazyVStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                    ForEach(sourcesWithWarnings, id: \.id) { source in
                        let all = model.warnedFiles[source.id] ?? []
                        VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                            Text(source.name)
                                .font(Theme.Font.control).fontWeight(.medium)
                            ForEach(all.prefix(warningLimit), id: \.relativePath) { entry in
                                warningRow(entry)
                            }
                            more(shown: warningLimit, of: all.count) { warningLimit += Self.pageSize }
                        }
                    }
                }
            }
        }
    }

    private func warningRow(_ entry: ManifestEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.relativePath).font(Theme.Font.body)
                    .lineLimit(1).truncationMode(.middle)
                if !entry.extractorID.isEmpty {
                    Text("\(entry.extractorID) v\(entry.extractorVersion)")
                        .font(Theme.Font.micro)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.Palette.accent.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                }
            }
            // Предупреждения не красятся: делать с ними нечего, а цвет в этом
            // приложении означает «есть действие рядом».
            ForEach(Array(entry.warnings.enumerated()), id: \.offset) { _, warning in
                Text("• " + warning).font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Padding.rowHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
    }

    // MARK: - Password

    private var passwordSheet: some View {
        SheetShell(
            title: String(localized: "Пароль к документу"),
            subtitle: model.passwordFor?.relativePath
                ?? String(localized: "Документ защищён паролем — без него текст не прочитать."),
            help: String(localized: "Пароль хранится в Keychain и только там: ни в config.json, ни в манифесте, ни в логах. Перенос настроек его не увозит."),
            width: 460,
            height: nil,
            scrolls: false
        ) {
            SecureField(String(localized: "Пароль"), text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
        } actions: {
            Button(String(localized: "Отмена")) { model.passwordFor = nil; model.passwordInput = "" }
                .buttonStyle(.chromaNormal)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Сохранить")) { model.savePassword(app) }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.passwordInput.isEmpty)
        }
    }
}
