import SwiftUI
import ChromaCore

/// what the file holds, what a row will become, and the mapping that
/// decides it.
///
/// Лист-форма секциями. Две сетки — предпросмотр строк и список колонок —
/// свои: они ленивые, и их геометрия задана числами в `Grid` ниже.
/// Это исключение из «числа только в `UI/`», и оно под сторожем тестов:
/// ячейки и номера строк совпадают только по общей мерке.
struct TableMappingSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: TableMappingViewModel
    let source: DataSource
    var onClose: () -> Void

    /// Показывать ли предпросмотр целиком. Сбрасывается при смене
    /// листа: решение «покажи все двести» принимается про конкретный лист.
    @State private var showsAllColumns = false
    /// Спрашивать ли подтверждение переиндексации: операция удаляет
    /// строки из коллекции, и правило 3 приложения 5 требует сначала сказать,
    /// сколько именно.
    @State private var confirmsReindex = false
    /// Профиль сопоставления, который просят удалить, — ждёт подтверждения
    ///: назначенные ему файлы вернутся к подбору по колонкам.
    @State private var profilePendingRemoval: TableProfile?

    var body: some View {
        SheetFrame(width: .wide, height: .tall) {
            messages
            filesSection
            if model.sheets.isEmpty {
                Section {
                    Text(model.isBusy
                         ? String(localized: "Читаем файл…")
                         : String(localized: "Выберите таблицу выше — или откройте `.xlsx`, `.ods`, `.csv` или `.numbers` со стороны."))
                        .foregroundStyle(.secondary)
                }
            } else {
                sheetsSection
                if let preview = model.preview { rowsSection(preview) }
                if let preview = model.preview { columnsSection(preview) }
                documentSection
                reindexSection
                profileSection
            }
        } actions: {
            Button(String(localized: "Открыть файл…")) { model.chooseFile(app, source: source) }
                .disabled(model.isBusy)
            Spacer()
            Button(String(localized: "Закрыть")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .task { model.scanSourceFiles(app, source: source) }
    }

    @ViewBuilder
    private var messages: some View {
        if model.errorMessage != nil || model.infoMessage != nil {
            Section {
                if let error = model.errorMessage {
                    HStack {
                        Notice(.warning, error)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
                if let message = model.infoMessage {
                    HStack {
                        Notice(.info, message)
                        Spacer()
                        Button(String(localized: "Скрыть")) { model.infoMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// The source's own table files.
    ///
    /// The source knows which files its next run will send to the table
    /// pipeline; making the user find one of them in a file panel was asking
    /// them to repeat work the app had already done. Nothing opens by itself:
    /// a `.numbers` file is read by asking Numbers to export it, and that is not
    /// something a screen starts on its own.
    private var filesSection: some View {
        Section {
            if model.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Ищем таблицы в папке источника…").foregroundStyle(.secondary)
                }
            } else if model.sourceFiles.isEmpty {
                Text("В папке источника нет файлов табличных форматов среди тех расширений, которые он индексирует. Открыть можно любой другой файл кнопкой «Открыть файл…».")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sourceFiles) { file in
                HStack {
                    Label {
                        Text(file.relativePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.relativePath)
                    } icon: {
                        Image(systemName: model.openedPath == file.relativePath ? "tablecells.fill" : "tablecells")
                            .foregroundStyle(model.openedPath == file.relativePath ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                    Spacer()

                    // Профиль этого файла. «Подбирать по колонкам» —
                    // прежнее поведение и по-прежнему умолчание: назначение
                    // нужно там, где подбору ответить нечем.
                    Picker(String(localized: "Профиль"), selection: Binding(
                        get: { model.assignments[file.relativePath]?.uuidString ?? "" },
                        set: { (value: String) in
                            model.assign(
                                profileID: UUID(uuidString: value),
                                to: file.relativePath, app: app, source: source
                            )
                        }
                    )) {
                        Text("подбирать по колонкам").tag("")
                        ForEach(model.allProfiles) { profile in
                            Text(model.isShared(profile)
                                 ? String(localized: "\(profile.name) · общий")
                                 : profile.name)
                                .tag(profile.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.allProfiles.isEmpty)
                    .help(model.allProfiles.isEmpty
                          ? String(localized: "Профилей ещё нет: откройте файл, разметьте колонки и сохраните профиль — он появится в этом списке")
                          : String(localized: "Каким профилем читать этот файл. «Подбирать по колонкам» — как раньше, по совпадению набора заголовков"))

                    Button(model.openedPath == file.relativePath
                           ? String(localized: "Открыт")
                           : String(localized: "Открыть")) {
                        model.open(file.url, app: app, source: source)
                    }
                    .disabled(model.isBusy || model.openedPath == file.relativePath)
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Таблица: сопоставление колонок"),
                help: String(localized: "Таблица индексируется не как текст: строка становится отдельным документом, а значения колонок — метаданными, по которым работает фильтр. От того, какие колонки попадут в текст документа, прямо зависит качество поиска.")
            )
        } footer: {
            Text("Таблицы этого источника. Ничего не индексируется и не записывается — это предпросмотр до запуска.")
        }
    }

    // MARK: - Sheets

    private var sheetsSection: some View {
        Section {
            Picker(String(localized: "Лист"), selection: $model.selectedSheet) {
                ForEach(model.sheets) { preview in
                    Text(preview.sheet.isHidden
                         ? String(localized: "\(preview.sheet.name) · скрытый")
                         : preview.sheet.name)
                        .tag(Optional(preview.sheet.name))
                }
            }
            ForEach(model.sheets) { preview in
                LabeledContent {
                    Picker(String(localized: "Режим"), selection: model.binding(for: preview.sheet.name).mode) {
                        ForEach(SheetMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(preview.sheet.name)
                    Text(preview.shape.reason)
                }
            }
        } header: {
            Text(model.fileName.map { String(localized: "Листы · \($0)") } ?? String(localized: "Листы"))
        } footer: {
            VStack(alignment: .leading) {
                if let mode = model.draft?.mode {
                    Text(mode.explanation)
                }
                if let note = model.matchNote {
                    Notice(.info, note)
                }
            }
        }
    }

    /// The first rows, coloured by what each column is for —'s «с
    /// подсветкой ролей колонок».
    private func rowsSection(_ preview: TableMappingViewModel.SheetPreview) -> some View {
        let mapping = model.draft ?? TableMapping(sheetName: preview.sheet.name)
        let width = max(mapping.columns.count, (preview.rows.map { $0.lastColumn + 1 }.max() ?? 0))
        // Роли и свои названия — по разу на колонку, а не по разу на ячейку.
        // На листе в 210 колонок это 4 400 обращений к словарям при каждой
        // перерисовке — то есть при каждом нажатии клавиши в поле «Своё
        // название».
        let titles = (0..<width).map { $0 < mapping.columns.count ? mapping.columns[$0] : "" }
        let roles = titles.map { mapping.role(of: $0) }
        let shown = showsAllColumns ? width : min(width, Grid.columnsShownAtOnce)
        // Строки считаются один раз на сетку, а не в каждой колонке.
        let previewRows = preview.previewRows

        return Section {
            // на листе бывают одни данные — без шапки или с шапкой,
            // которую не прочитать. Тогда колонки называются буквами, как в
            // самой таблице, а имена человек задаёт полем «Своё название».
            HStack {
                Button(String(localized: "Заголовков нет — назвать колонки самому")) {
                    model.useColumnLetters(startingAfter: 0, for: preview.sheet.name)
                }
                if let row = mapping.headerRow, row > 0 {
                    Button(String(localized: "В строке \(row.plainDigits) заголовков нет")) {
                        model.useColumnLetters(startingAfter: row, for: preview.sheet.name)
                    }
                    .help(String(localized: "Считать эту строку служебной: колонки назвать буквами, данные читать со следующей"))
                }
                Spacer()
            }

            // Сетка собирается **колонками**, а не строками: колонка
            // целиком — один элемент ленивого стека, и строится только то,
            // что видно. Замер на рабочей книге: ядро отдаёт все 14 листов
            // за 0,04 с, а построчная сетка не отвечала минуту.
            HStack(alignment: .top, spacing: 0) {
                // Номера строк — вне прокрутки: по ним назначают строку
                // заголовков, а уезжали они вместе с содержимым.
                VStack(alignment: .leading, spacing: Grid.rowSpacing) {
                    Color.clear.frame(width: Grid.numberGutter, height: Grid.rowHeight)
                    ForEach(previewRows, id: \.number) { row in
                        numberCell(
                            row.number,
                            isHeader: row.number == mapping.headerRow,
                            sheet: preview.sheet.name
                        )
                    }
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(0..<shown, id: \.self) { column in
                            VStack(alignment: .leading, spacing: Grid.rowSpacing) {
                                // Буквы колонок — как в самой таблице:
                                // единственное имя колонки, не зависящее ни
                                // от строки заголовков, ни от переименований.
                                Text(XLSXReader.columnName(column))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: Grid.cellWidth + Grid.cellPadding * 2, height: Grid.rowHeight)
                                ForEach(previewRows, id: \.number) { row in
                                    let isHeader = row.number == mapping.headerRow
                                    let isAbove = mapping.headerRow.map { row.number < $0 } ?? false
                                    // В строке заголовков — выбранное человеком
                                    // имя: переименование видно там же, где на
                                    // него смотрят.
                                    let text = isHeader && !titles[column].isEmpty
                                        ? mapping.title(of: titles[column])
                                        : row.value(at: column).displayText
                                    cell(text, role: roles[column], isHeader: isHeader, isAbove: isAbove)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: model.selectedSheet) { _, _ in showsAllColumns = false }

            if width > shown {
                HStack {
                    Text("Показаны первые \(shown.plainDigits) колонок из \(width.plainDigits).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Показать все")) { showsAllColumns = true }
                        .buttonStyle(.link)
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Первые строки"),
                help: String(localized: "Как их прочитало приложение: текст, число, дата или пусто. Цвет ячейки — роль колонки: текст, метаданные или пропуск.")
            )
        } footer: {
            // строку заголовка называет человек. Автоопределение берёт
            // первую непустую, и на файле с шапкой отчёта над таблицей
            // «заголовками» становится название отчёта.
            Text(mapping.headerRow.map {
                String(localized: "Заголовки читаются из строки \($0). Нажмите на номер другой строки, чтобы читать их с неё: всё, что выше заголовка, в индекс не попадёт.")
            } ?? String(localized: "Строка заголовков не найдена. Нажмите на номер строки, чтобы прочитать заголовки с неё."))
        }
    }

    /// Геометрия двух сеток листа. Номера строк стоят вне прокрутки и
    /// совпадают с ячейками только по общей мерке — поэтому числа, а не
    /// содержимое.
    private enum Grid {
        static let rowHeight: CGFloat = 22
        static let rowSpacing: CGFloat = 2
        static let cellWidth: CGFloat = 130
        static let cellPadding: CGFloat = 6
        static let numberWidth: CGFloat = 30
        static let numberPadding: CGFloat = 4
        static var numberGutter: CGFloat { numberWidth + numberPadding * 2 }
        /// Столько колонок показывается сразу. Лист в тысячу колонок бывает
        /// (сводная выгрузка по дням), и строить его целиком незачем.
        static let columnsShownAtOnce = 60
        /// Колонки списка «Колонки»: буква, имя в файле, своё название, роль.
        static let letterWidth: CGFloat = 28
        static let fileNameWidth: CGFloat = 160
        static let titleWidth: CGFloat = 170
        static let roleWidth: CGFloat = 140
    }

    /// Номер строки — он же кнопка «читать заголовки отсюда».
    private func numberCell(_ number: Int, isHeader: Bool, sheet: String) -> some View {
        Button {
            model.useHeaderRow(number, for: sheet)
        } label: {
            Text("\(number)")
                .font(.caption)
                .foregroundStyle(isHeader ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: Grid.numberWidth, height: Grid.rowHeight, alignment: .trailing)
                .padding(.horizontal, Grid.numberPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isHeader)
        .help(isHeader
              ? String(localized: "Заголовки читаются отсюда")
              : String(localized: "Читать заголовки с этой строки"))
    }

    private func cell(_ text: String, role: ColumnRole, isHeader: Bool, isAbove: Bool = false) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(isHeader ? .caption.bold() : .caption)
            .lineLimit(1).truncationMode(.tail)
            // Строки выше заголовка приглушены: по ним и выбирают строку
            // заголовка, но записями они не станут.
            .foregroundStyle(isAbove ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(width: Grid.cellWidth, height: Grid.rowHeight, alignment: .leading)
            .padding(.horizontal, Grid.cellPadding)
            .background(isAbove ? Color.clear : colour(for: role).opacity(isHeader ? 0.28 : 0.12))
            // `border`, а не `overlay` с фигурой: представлений на ячейку
            // вдвое меньше — на сетке в две тысячи ячеек это заметно.
            .border(Color(nsColor: .separatorColor), width: 0.5)
    }

    private func colour(for role: ColumnRole) -> Color {
        switch role {
        case .text: return .accentColor
        case .metadata: return .green
        case .ignore: return .gray
        }
    }

    // MARK: - Roles

    private func columnsSection(_ preview: TableMappingViewModel.SheetPreview) -> some View {
        let binding = model.binding(for: preview.sheet.name)
        // Ключи метаданных считаются **один раз на список**, а не на строку:
        // `keyMap` строится по всем колонкам сразу, и обращение к нему в
        // каждой строке превращало 210 колонок в 44 000 нормализаций.
        let keyMap = binding.wrappedValue.keyMap
        return Section {
            // Заголовки из файла — в поля «Своё название».
            HStack {
                Spacer()
                Button(String(localized: "Заполнить названия из файла")) {
                    model.fillTitlesFromFile(for: preview.sheet.name)
                }
                .help(String(localized: "Перенести заголовки из файла в поля «Своё название», чтобы их править. Уже заданные названия не трогаются."))
            }

            HStack {
                Text("Колонка в файле")
                    .frame(width: Grid.letterWidth + Grid.fileNameWidth, alignment: .leading)
                Text("Своё название").frame(width: Grid.titleWidth, alignment: .leading)
                Text("Что с ней делать").frame(width: Grid.roleWidth, alignment: .leading)
                Text("Ключ в метаданных")
                Spacer()
            }
            .foregroundStyle(.secondary)

            // По порядковому номеру, а не по имени: заголовки в файле
            // повторяются («Итого» над каждым кварталом), а `id: \.self` на
            // повторе склеивает строки в одну. `LazyVStack` — потому
            // что в каждой строке поле и два списка, а колонок бывает 210.
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(binding.wrappedValue.columns.enumerated()), id: \.offset) { index, column in
                    HStack {
                        Circle().fill(colour(for: binding.wrappedValue.role(of: column)))
                            .frame(width: Grid.cellPadding, height: Grid.cellPadding)
                        // Буква колонки — рядом с её именем: размечают, глядя
                        // в таблицу выше и в свой файл, а там колонка
                        // называется буквой.
                        Text(XLSXReader.columnName(index))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: Grid.letterWidth, alignment: .trailing)
                        Text(column)
                            .frame(width: Grid.fileNameWidth, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                            .help(column)

                        // 5,: заголовки бывают служебными, длинными
                        // или отсутствуют — а по ним строятся ключи метаданных.
                        // Пусто — значит «как в файле».
                        TextField(column, text: Binding(
                            get: { binding.wrappedValue.titles[column] ?? "" },
                            set: { binding.wrappedValue.titles[column] = $0 }
                        ))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Grid.titleWidth)

                        Picker(String(localized: "Роль"), selection: Binding(
                            get: { binding.wrappedValue.role(of: column) },
                            set: { binding.wrappedValue.roles[column] = $0 }
                        )) {
                            ForEach(ColumnRole.allCases) { role in Text(role.title).tag(role) }
                        }
                        .labelsHidden()
                        .frame(width: Grid.roleWidth)

                        if let key = keyMap.key(for: binding.wrappedValue.title(of: column)) {
                            Text(key).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
            }

            Picker(String(localized: "Ключевая колонка"), selection: Binding(
                get: { binding.wrappedValue.keyColumn ?? "" },
                set: { binding.wrappedValue.keyColumn = $0.isEmpty ? nil : $0 }
            )) {
                Text("нет").tag("")
                // С буквой: в списке из «Итого», «Итого», «Итого» выбрать
                // нужную иначе нельзя.
                ForEach(Array(binding.wrappedValue.columns.enumerated()), id: \.offset) { index, column in
                    Text("\(XLSXReader.columnName(index)) · \(column)").tag(column)
                }
            }
        } header: {
            Text("Колонки")
        } footer: {
            VStack(alignment: .leading) {
                if let warning = model.keyColumnWarning {
                    Notice(.warning, warning)
                }
                // Повтор значения ключа — не стиль разметки, а строки,
                // которые не попадут в базу. Говорится там, где ключ выбирают.
                if let duplicates = model.keyColumnDuplicates {
                    Notice(.warning, duplicates)
                }
                // a rename the user never sees is the same as losing
                // the column — so every one of them is listed.
                ForEach(model.keyCollisions) { collision in
                    Notice(.warning, collision.explanation)
                }
                Text("Текст уходит в документ и участвует в поиске по смыслу; метаданные — в фильтры. Артикул в тексте это шум в векторе.")
            }
        }
    }

    // MARK: - What one row becomes

    /// переиндексация листа отдельной операцией: смена разметки —
    /// это другой рецепт для **каждой** строки листа.
    @ViewBuilder
    private var reindexSection: some View {
        // Лист уже очищен и ждёт записи: состояние «строк в базе нет,
        // и это мы их убрали» обязано быть видно.
        if model.selectedSheetAwaitsWrite {
            Section {
                StatusLabel(.warning, model.selectedSheet.map { String(localized: "Лист «\($0)» ждёт записи") }
                    ?? String(localized: "Лист ждёт записи"))
            } header: {
                Text("Лист ждёт записи")
            } footer: {
                Text("Лист очищен под переиндексацию: его строк в коллекции сейчас нет, и поиск по ним ничего не находит. Запишет их обычная синхронизация источника — по нынешней разметке.")
            }
        } else if let state = model.reindexState() {
            Section {
                LabeledContent(String(localized: "Строк листа в коллекции"), value: state.rows.plainDigits)
                HStack {
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button(String(localized: "Переиндексировать лист…")) { confirmsReindex = true }
                        .disabled(model.isBusy)
                        .confirmationDialog(
                            model.selectedSheet.map { String(localized: "Переиндексировать лист «\($0)»?") }
                                ?? String(localized: "Переиндексировать лист?"),
                            isPresented: $confirmsReindex,
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "Очистить лист и забыть его"), role: .destructive) {
                                Task { await model.reindexSheet(app, source: source) }
                            }
                            Button(String(localized: "Отменить"), role: .cancel) {}
                        } message: {
                            Text(app.settings.configuration.trashEnabled
                                ? String(localized: "Будет удалено строк: \(state.rows.plainDigits). Копии лягут в корзину, и оттуда их можно вернуть. Заново лист запишется при следующей синхронизации источника — за это придётся заплатить эмбеддингами.")
                                : String(localized: "Будет удалено строк: \(state.rows.plainDigits). Корзина выключена — копий не останется. Заново лист запишется при следующей синхронизации источника — за это придётся заплатить эмбеддингами."))
                        }
                }
            } header: {
                Text("Переиндексация листа")
            } footer: {
                VStack(alignment: .leading) {
                    if state.changed {
                        Notice(.warning, String(localized: "Разметка изменилась с той, которой лист записан. Пока лист не переиндексирован, в коллекции лежат строки, собранные прежним рецептом."))
                    } else {
                        Text("Лист записан нынешней разметкой. Переиндексация нужна только после её изменения.")
                    }
                    Text(app.settings.configuration.trashEnabled
                        ? String(localized: "Строки уйдут в корзину, потом будут удалены из коллекции, а лист забыт в манифесте. Запишутся они заново обычной синхронизацией источника — до неё лист в коллекции пуст.")
                        : String(localized: "Корзина выключена: строки будут удалены из коллекции без копии. Запишутся они заново обычной синхронизацией источника — до неё лист в коллекции пуст."))
                }
            }
        }
    }

    private var documentSection: some View {
        Section {
            if let binding = model.preview.map({ model.binding(for: $0.sheet.name) }),
               binding.wrappedValue.mode == .dataTable {
                TextField(String(localized: "Шаблон"), text: binding.textTemplate, prompt: Text("например {Название}. {Описание}"))
                    .help(String(localized: "Пусто — «Колонка: значение» по колонкам, помеченным как текст."))
                ForEach(model.templateProblems, id: \.self) { name in
                    Notice(.warning, String(localized: "В шаблоне есть {\(name)}, но такой колонки нет — документ выйдет без этого куска."))
                }
            }

            if let document = model.documentPreview {
                LabeledContent(String(localized: "Текст документа")) {
                    Text(document.text)
                        .copyable(document.text)
                        .copyable(document.text)
                }
                ForEach(document.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent {
                        Text(describe(value))
                    } label: {
                        Text(key)
                            .font(.body.monospaced())
                            .foregroundStyle(MetadataSchema.isTechnicalKey(key) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    }
                }
            } else if let rendered = model.renderedDocument {
                Text(rendered.text.prefix(1200))
                    .font(.body.monospaced())
                    .copyable(rendered.text)
                if rendered.header != nil {
                    Notice(.info, String(localized: "Строка заголовков повторится в каждом чанке — без неё второй чанк был бы сеткой значений без названий колонок."))
                }
            } else {
                Text("Для этого листа предпросмотр документа не показывается: режим «не индексировать».")
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(
                String(localized: "Что получится из строки"),
                help: String(localized: "Из этого текста считается вектор — от него прямо зависит поиск. Поэтому он показан до запуска, а не подбирается переиндексациями.")
            )
        }
    }

    private func describe(_ value: MetadataValue) -> String {
        switch value {
        case .string(let value): return "\"\(value)\""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .list(let values): return "[" + values.map(describe).joined(separator: ", ") + "]"
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            TextField(String(localized: "Название профиля"), text: $model.profileName)

            // Где хранить профиль. Выбор человека, а не умолчание
            // приложения: одинаковые книги приходят в разные папки.
            Picker(String(localized: "Хранить профиль"), selection: $model.scope) {
                ForEach(TableProfileScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .help(model.scope.explanation)

            // Что именно сохранится: по варианту на лист.
            ForEach(model.sheets) { entry in
                let mapping = model.drafts[entry.sheet.name] ?? TableMapping(sheetName: entry.sheet.name)
                if mapping.mode == .skip {
                    // «Не индексировать» тоже сохраняется: лист без варианта
                    // подхватывал бы чужой разбор.
                    LabeledContent(entry.sheet.name, value: String(localized: "не индексировать — так и записано в профиле"))
                } else {
                    Picker(selection: Binding(
                        get: {
                            switch model.sheetSelection(for: entry.sheet.name) {
                            case .named: return 0
                            case .anyMatching: return 1
                            case .first: return 2
                            }
                        },
                        set: { (choice: Int) in
                            switch choice {
                            case 1: model.sheetSelections[entry.sheet.name] = .anyMatching
                            case 2: model.sheetSelections[entry.sheet.name] = .first
                            default: model.sheetSelections[entry.sheet.name] = .named([entry.sheet.name])
                            }
                        }
                    )) {
                        Text("листу с этим именем").tag(0)
                        Text("любому подходящему листу").tag(1)
                        Text("только первому листу").tag(2)
                    } label: {
                        Text(entry.sheet.name)
                        Text("\(mapping.columns.count) колонок")
                    }
                }
            }

            HStack {
                Button(String(localized: "Экспорт профилей…")) { model.exportProfiles(app, source: source) }
                    .disabled(model.allProfiles.isEmpty)
                Button(String(localized: "Импорт профилей…")) { model.importProfiles(app, source: source) }
                Button(String(localized: "Разметить заново")) { model.startOver(app, source: source) }
                    .help(String(localized: "Забыть подставленный профиль и собрать разметку этого файла с нуля"))
                    .disabled(model.sheets.isEmpty)
                Spacer()
                Button(String(localized: "Сохранить профиль")) { model.save(app, source: source) }
                    .primaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
            }

            let listed = model.listedProfiles
            if !listed.isEmpty {
                ForEach(listed) { profile in
                    LabeledContent {
                        Button(String(localized: "Удалить…"), role: .destructive) {
                            profilePendingRemoval = profile
                        }
                        // У кнопки своей строки, а не у секции: диалог на
                        // секции формы не открывается.
                        .confirmationDialog(
                            String(localized: "Удалить профиль «\(profile.name)»?"),
                            isPresented: Binding(
                                get: { profilePendingRemoval?.id == profile.id },
                                set: { if !$0 { profilePendingRemoval = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "Удалить"), role: .destructive) {
                                model.removeProfile(named: profile.name, app: app, source: source)
                            }
                            Button(String(localized: "Отменить"), role: .cancel) {}
                        } message: {
                            Text(model.isShared(profile)
                                 ? String(localized: "Профиль общий: он исчезнет у всех источников, и их файлы вернутся к подбору по колонкам")
                                 : String(localized: "Профиль исчезнет у этого источника; назначенные ему файлы вернутся к подбору по колонкам"))
                        }
                        .help(model.isShared(profile)
                              ? String(localized: "Профиль общий: он исчезнет у всех источников, и их файлы вернутся к подбору по колонкам")
                              : String(localized: "Профиль исчезнет у этого источника; назначенные ему файлы вернутся к подбору по колонкам"))
                    } label: {
                        Text(profile.name)
                        // Общий — виден всем источникам; перекрытый — виден,
                        // но в подборе не участвует: у источника есть свой
                        // с тем же именем.
                        Text(model.isOverridden(profile)
                             ? String(localized: "общий, перекрыт своим · \(profile.summary)")
                             : (model.isShared(profile)
                                ? String(localized: "общий · \(profile.summary)")
                                : profile.summary))
                    }
                }
            }
        } header: {
            SectionHeader(
                String(localized: "Профиль сопоставления"),
                help: String(localized: "Применяется к файлам с тем же набором колонок. Файл с другим набором не индексируется наполовину — он попадёт в «требуют решения».")
            )
        } footer: {
            Text(model.scope.explanation)
        }
    }
}
