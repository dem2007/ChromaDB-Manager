import SwiftUI
import ChromaCore

/// «Экран диагностики»: files the last run could not read, files it read
/// with something to say about them, and what can be done about each.
///
/// Everything here comes out of the manifests, not out of a fresh scan: opening
/// diagnostics must not re-read a folder of documents, and the point is to see
/// what the last run actually found.
struct DiagnosticsSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: SourcesViewModel

    /// Что отмечено для общего решения. Ключ — источник и путь:
    /// одинаковые пути в разных источниках — обычное дело.
    @State private var selected: Set<String> = []
    /// Показывать только выбранные находки.
    ///
    /// Пять находок «читать нечем» среди двух с лишним тысяч «сбоев чтения»
    /// прочитать иначе нельзя: их не видно ни в первых пятидесяти строках,
    /// ни в следующих пятидесяти. Кнопка разряда ставит отметки, но список
    /// от этого не меняется — а решать (исключить? включить распознавание?)
    /// можно только увидев, что именно выбрано.
    @State private var onlyChosen = false
    /// Свёрнутые источники: рубрика видна, список находок под ней скрыт.
    ///
    /// Источников дюжина, находок у каждого — сотни. Пока рубрика не
    /// сворачивается, дойти до третьего источника — значит прокрутить сто
    /// строк первых двух.
    @State private var collapsed: Set<UUID> = []
    /// Ждёт ли подтверждения красная кнопка «очистить все находки».
    @State private var confirmingClearAll = false

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

    /// Вкладка экрана «Источники»: ни оправы, ни своей прокрутки, ни полей —
    /// всё это уже есть у экрана, который её показывает.
    ///
    /// Своя прокрутка внутри чужой и вторые поля поверх первых — из-за них
    /// карточки на вкладке были уже колонки и вставали по её середине
    ///. Прокрутка на экране одна — правило 5а.
    ///
    /// Листом поверх «Источников» это же содержимое больше не открывается
    ///: кнопка «Открыть диагностику» ведёт сюда, а лист прятал
    /// массовые действия, ради которых на вкладку и заходят.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            cards
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(
            get: { model.passwordFor != nil },
            set: { if !$0 { model.passwordFor = nil } }
        )) {
            passwordSheet
        }
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
                let sources = sourcesWithProblems
                let all = allProblems(sources)
                // Выбранное считается один раз за отрисовку и раздаётся тем,
                // кому нужно: строке действий, фильтру, рубрикам.
                let picked = all.filter { selected.contains(key($0.source.id, $0.problem.relativePath)) }
                LazyVStack(alignment: .leading, spacing: Theme.Padding.cardContentSpacing) {
                    selectionBar(all, picked: picked)
                    kindBar(all)
                    if onlyChosen && picked.isEmpty {
                        emptyFilterNote
                    }
                    ForEach(sources, id: \.id) { source in
                        // Имя своё, а не `all`: тем же именем выше назван
                        // набор находок **всего экрана**, и одинаковые имена
                        // у двух разных наборов — заготовка для правки,
                        // которая посчитает одно вместо другого.
                        let ofSource = model.problems[source.id] ?? []
                        // При фильтре источник без выбранных находок исчезает
                        // целиком: рубрика с нулём — та же стена, от которой
                        // фильтр и спасает.
                        let visible = onlyChosen
                            ? ofSource.filter { selected.contains(key(source.id, $0.relativePath)) }
                            : ofSource
                        if !visible.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Padding.rowSpacing) {
                                sourceHeader(source, problems: ofSource, visible: visible.count)
                                if !collapsed.contains(source.id) {
                                    ForEach(visible.prefix(problemLimit)) { problem in
                                        problemRow(problem, source: source)
                                    }
                                    more(shown: problemLimit, of: visible.count) { problemLimit += Self.pageSize }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Массовый выбор и массовое решение

    /// Ключ строки: источник и путь. Пути в разных источниках совпадают.
    private func key(_ sourceID: UUID, _ path: String) -> String {
        "\(sourceID.uuidString)|\(path)"
    }

    /// Все находки экрана парами «источник — находка».
    ///
    /// Считается **один раз** за отрисовку и передаётся в строки действий
    ///. Вычисляемым свойством его звали и `selectionBar`, и `kindBar`,
    /// и `chosen` — на живой базе с 2285 находками это несколько полных
    /// обходов с построением массива кортежей на каждую перерисовку, ровно
    /// та работа на главном потоке, из-за которой урезал этот экран
    /// до пятидесяти строк.
    private func allProblems(_ sources: [DataSource]) -> [(source: DataSource, problem: FileProblem)] {
        sources.flatMap { source in
            (model.problems[source.id] ?? []).map { (source, $0) }
        }
    }

    /// Что выбрано и что с этим можно сделать разом.
    ///
    /// Действий два, и оба честные: «исключить» меняет источник — файл
    /// перестанет читаться; «убрать из списка» не меняет ничего, кроме самого
    /// списка, и следующий прогон скажет о файле снова. Третьего — «починить
    /// разом» — не бывает: пароль у каждого файла свой, а распознавание
    /// включается у источника целиком, и обе кнопки для этого стоят в строке.
    @ViewBuilder
    private func selectionBar(
        _ all: [(source: DataSource, problem: FileProblem)],
        picked: [(source: DataSource, problem: FileProblem)]
    ) -> some View {
        // «Всё выбрано» — это когда выбрано всё, а не когда выбрано хоть
        // что-то: после выбора разряда («Сканы без текста (14)») кнопка
        // предлагала снять выбор, и выбрать всё одним нажатием было нельзя.
        // Так же считает соседний экран источников.
        //
        // Сами ключи собираются **в действии кнопки**, а не при отрисовке:
        // на 2285 находках это массив склеенных строк, который иначе строился
        // бы заново на каждый щелчок по флажку и выбрасывался нетронутым.
        let allChosen = !all.isEmpty && picked.count == all.count
        HStack(spacing: 10) {
            Button(allChosen
                   ? String(localized: "Снять выбор")
                   : String(localized: "Выбрать все")) {
                if allChosen {
                    clearSelection()
                } else {
                    selected.formUnion(all.map { key($0.source.id, $0.problem.relativePath) })
                }
            }
            .buttonStyle(.link).font(Theme.Font.micro)

            if !picked.isEmpty {
                // «Из скольких» считается по тем же находкам, что и кнопки
                // разрядов, а не по общему счётчику модели: в счётчик
                // попадают и находки источника, которого больше нет в
                // настройках, а выбрать их на этом экране нельзя — и «выбрано
                // 2285 из 2290» читалось бы как промах выбора.
                Text("выбрано \(picked.count.plainDigits) из \(all.count.plainDigits)")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
            }

            // Фильтр — рядом со счётчиком, до кнопок решения: он про то,
            // чтобы **увидеть** выбранное, а решают уже увидев.
            // Кнопка остаётся и когда выбор опустел: иначе из фильтра,
            // показывающего пустой список, нечем было бы выйти.
            if !picked.isEmpty || onlyChosen {
                if onlyChosen {
                    Button(String(localized: "Показать все")) { onlyChosen = false }
                        .buttonStyle(.chromaNormal)
                        .help(String(localized: "Вернуть в список все находки"))
                } else {
                    Button(String(localized: "Только выбранные")) { onlyChosen = true }
                        .buttonStyle(.chromaSecondary)
                        .help(String(localized: "Оставить в списке только выбранные находки — так видно, что именно выбрано"))
                }
            }

            if !picked.isEmpty {
                Button(String(localized: "Исключить из индексации")) { excludeChosen(picked) }
                    .buttonStyle(.chromaSecondary)
                Button(String(localized: "Убрать из списка")) { forgetChosen(picked) }
                    .buttonStyle(.chromaNormal)
            }

            Spacer()

            // Красная и последняя в ряду: она снимает **все** находки разом,
            // и стоять рядом с «выбрать все» ей нельзя.
            Button(String(localized: "Очистить все находки")) { confirmingClearAll = true }
                .buttonStyle(.chromaDanger)
        }
        .confirmationDialog(
            String(localized: "Очистить все находки диагностики?"),
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Очистить"), role: .destructive) {
                model.forgetAllProblems(app)
                clearSelection()
            }
            Button(String(localized: "Отмена"), role: .cancel) { confirmingClearAll = false }
        } message: {
            Text(String(localized: "Список опустеет: находок — \(model.problemCount.plainDigits). Файлы останутся в источниках, ничего не исключается и из базы ничего не удаляется. Если файл снова не прочитается, следующий запуск скажет о нём опять."))
        }
    }

    /// Фильтр включён, а выбор опустел: список пуст не потому, что находок нет.
    ///
    /// Дойти сюда просто — снять последний флажок при включённом фильтре, — и
    /// без этой строки экран выглядел бы так, будто находки кончились.
    private var emptyFilterNote: some View {
        HStack(spacing: 8) {
            Text("Показаны только выбранные, а выбранных нет.")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
            Button(String(localized: "Показать все")) { onlyChosen = false }
                .buttonStyle(.chromaSecondary)
            Spacer()
        }
    }

    /// Выбор по разряду находки: «все сканы», «все под паролем».
    ///
    /// Тип — это то, чем файлы похожи, и решение о них обычно одно на весь
    /// разряд: полтора десятка сканов исключают вместе или включают
    /// распознавание источника, а не разбирают по одному.
    ///
    /// Нажатие **показывает** выбранный разряд: список тут же сжимается до
    /// него одного. Отдельная кнопка «Только выбранные» рядом остаётся
    /// для выбора, собранного руками или по источникам.
    ///
    /// Кнопка **переключает** разряд, а не только добавляет его.
    /// Живой случай: выбрано 1542 из 2285, среди них уже все восемь сканов —
    /// и нажатие «Сканы без текста (8)» не меняло ровно ничего. Со стороны
    /// это выглядит сломанной кнопкой, и первым делом жмут её ещё раз.
    /// Теперь состояние видно по самой кнопке: «✓» и заливка означают, что
    /// разряд выбран целиком, а нажатие его снимает.
    @ViewBuilder
    private func kindBar(_ all: [(source: DataSource, problem: FileProblem)]) -> some View {
        let byKind = Dictionary(grouping: all, by: { $0.problem.remedy })
        if byKind.count > 1 {
            HStack(spacing: 8) {
                Text("выбрать разом:").font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.captionText)
                ForEach(FileRemedy.allCases, id: \.self) { remedy in
                    if let group = byKind[remedy] {
                        let keys = group.map { key($0.source.id, $0.problem.relativePath) }
                        let chosen = keys.allSatisfy { selected.contains($0) }
                        Button(chosen
                               ? "✓ \(remedy.groupTitle) (\(group.count.plainDigits))"
                               : "\(remedy.groupTitle) (\(group.count.plainDigits))") {
                            if chosen {
                                selected.subtract(keys)
                                // Разряд сняли и больше ничего не отмечено —
                                // показывать «только выбранные» не из чего.
                                if selected.isEmpty { onlyChosen = false }
                            } else {
                                selected.formUnion(keys)
                                // …и сразу показать выбранное.
                                // Выбор разрядом затем и делают, что пять
                                // находок «читать нечем» среди двух тысяч
                                // «сбоев чтения» иначе не найти; требовать
                                // ради этого второго нажатия по соседней
                                // кнопке — то же самое, что не показать.
                                onlyChosen = true
                            }
                        }
                        .buttonStyle(chosen ? .chromaNormal : .chromaSecondary)
                        .help(chosen
                              ? String(localized: "Весь разряд уже выбран — нажатие снимет выбор")
                              : String(localized: "Добавить к выбранному все находки этого разряда"))
                    }
                }
                Spacer()
            }
        }
    }

    /// Рубрика источника: имя, коллекция, выбор всего источника разом — и
    /// сворачивание списка под ней.
    ///
    /// Нажатие на саму рубрику сворачивает и раскрывает список; «выбрать все»
    /// стоит **рядом** с ней, а не внутри, — вложенная кнопка в кнопке
    /// оставляет ссылку на милость порядка обхода нажатий.
    ///
    /// `visible` — сколько строк источника видно сейчас; `problems` — сколько
    /// у него находок всего. Выбор всего источника считается по `problems`:
    /// «выбрать все» при включённом фильтре означает «все находки источника»,
    /// а не «все показанные», иначе кнопка выбирала бы уже выбранное.
    private func sourceHeader(
        _ source: DataSource, problems: [FileProblem], visible: Int
    ) -> some View {
        let keys = problems.map { key(source.id, $0.relativePath) }
        let allChosen = !keys.isEmpty && keys.allSatisfy { selected.contains($0) }
        let isCollapsed = collapsed.contains(source.id)
        return HStack(spacing: 8) {
            Button {
                if isCollapsed { collapsed.remove(source.id) } else { collapsed.insert(source.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.captionText)
                    Text(source.name).font(Theme.Font.control).fontWeight(.medium)
                    // Числа складываются в текст двумя надписями, а не
                    // тройкой в одной: у тройки оба исхода — обычные строки,
                    // и в каталог текстов такая надпись не попадает.
                    if onlyChosen {
                        Text("→ \(CollectionNaming.sanitize(source.collectionName)) · выбрано \(visible.plainDigits) из \(problems.count.plainDigits)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    } else {
                        Text("→ \(CollectionNaming.sanitize(source.collectionName)) · \(problems.count.plainDigits)")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isCollapsed
                  ? String(localized: "Раскрыть список находок источника")
                  : String(localized: "Свернуть список находок источника"))

            Button(allChosen
                   ? String(localized: "Снять выбор")
                   : String(localized: "Выбрать все")) {
                if allChosen {
                    selected.subtract(keys)
                } else {
                    selected.formUnion(keys)
                }
            }
            .buttonStyle(.link).font(Theme.Font.micro)
            Spacer()
        }
    }

    /// Исключение идёт источник за источником — одна запись настроек на каждый,
    /// а сообщение об итоге одно на всё выбранное.
    private func excludeChosen(_ picked: [(source: DataSource, problem: FileProblem)]) {
        var excluded = 0
        for group in Dictionary(grouping: picked, by: { $0.source.id }).values {
            guard let source = group.first?.source else { continue }
            excluded += model.exclude(group.map { $0.problem.relativePath }, in: source, app: app)
        }
        model.reportExcluded(excluded)
        clearSelection()
    }

    private func forgetChosen(_ picked: [(source: DataSource, problem: FileProblem)]) {
        for (sourceID, problems) in Dictionary(grouping: picked, by: { $0.source.id }) {
            model.forget(problems.map { $0.problem.relativePath }, in: sourceID, app: app)
        }
        model.reportForgotten(picked.count)
        clearSelection()
    }

    /// Выбор опустел — фильтр выключается вместе с ним.
    ///
    /// Иначе после «убрать из списка» человек остаётся перед пустым экраном:
    /// решение он принял, выбор снят, а фильтр всё ещё показывает только
    /// выбранное. Настоящие находки при этом никуда не делись.
    private func clearSelection() {
        selected.removeAll()
        onlyChosen = false
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
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { selected.contains(key(source.id, problem.relativePath)) },
                    set: { isOn in
                        let id = key(source.id, problem.relativePath)
                        if isOn { selected.insert(id) } else { selected.remove(id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                Text(problem.relativePath).font(Theme.Font.body)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
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
