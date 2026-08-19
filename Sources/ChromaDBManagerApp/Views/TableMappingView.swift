import SwiftUI
import ChromaCore

/// what the file holds, what a row will become, and the mapping that
/// decides it.
struct TableMappingSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @ObservedObject var model: TableMappingViewModel
    let source: DataSource
    var onClose: () -> Void

    /// Показывать ли предпросмотр целиком. Сбрасывается при смене
    /// листа: решение «покажи все двести» принимается про конкретный лист.
    @State private var showsAllColumns = false

    var body: some View {
        SheetShell(
            title: String(localized: "Таблица: сопоставление колонок"),
            subtitle: String(localized: "Ничего не индексируется и не записывается — это предпросмотр до запуска."),
            help: String(localized: "Таблица индексируется не как текст: строка становится отдельным документом, а значения колонок — метаданными, по которым работает фильтр. От того, какие колонки попадут в текст документа, прямо зависит качество поиска."),
            width: 860,
            height: 640
        ) {
            if let error = model.errorMessage {
                MessageBanner(kind: .error, text: error) { model.errorMessage = nil }
            }
            if let message = model.infoMessage {
                MessageBanner(kind: .info, text: message) { model.infoMessage = nil }
            }
            filesCard
            if model.sheets.isEmpty {
                empty
            } else {
                sheetPicker
                if let preview = model.preview { sheetCard(preview) }
                if let preview = model.preview { rolesCard(preview) }
                documentCard
                profileCard
            }
        } actions: {
            Button(String(localized: "Открыть файл…")) { model.chooseFile(app, source: source) }
                .buttonStyle(.chromaNormal)
                .disabled(model.isBusy)
            Button(String(localized: "Закрыть")) { onClose() }
                .buttonStyle(.chromaPrimary)
                .keyboardShortcut(.cancelAction)
        }
        .task { model.scanSourceFiles(app, source: source) }
    }

    /// The source's own table files.
    ///
    /// The source knows which files its next run will send to the table
    /// pipeline; making the user find one of them in a file panel was asking
    /// them to repeat work the app had already done. Nothing opens by itself:
    /// a `.numbers` file is read by asking Numbers to export it, and that is not
    /// something a screen starts on its own.
    @ViewBuilder
    private var filesCard: some View {
        SectionCard(
            title: "Таблицы источника",
            subtitle: model.isScanning
                ? String(localized: "Ищем таблицы в папке источника…")
                : String(localized: "Файлы, которые этот источник отдаст табличному конвейеру. Выберите любой — он только читается.")
        ) {
            if model.sourceFiles.isEmpty && !model.isScanning {
                Text("В папке источника нет файлов табличных форматов среди тех расширений, которые он индексирует. Открыть можно любой другой файл кнопкой «Открыть файл…».")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sourceFiles) { file in
                        HStack(spacing: 8) {
                            Image(systemName: model.openedPath == file.relativePath
                                  ? "largecircle.fill.circle" : "tablecells")
                                .foregroundStyle(model.openedPath == file.relativePath ? Color.accentColor : .secondary)
                            Text(file.relativePath)
                                .font(Theme.Font.body)
                                .lineLimit(1).truncationMode(.middle)
                                .help(file.relativePath)
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            Spacer()

                            // Профиль этого файла. «Подбирать по
                            // колонкам» — прежнее поведение и по-прежнему
                            // умолчание: назначение нужно там, где подбору
                            // ответить нечем, а не вместо него.
                            Picker("", selection: Binding(
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
                            .frame(width: 200)
                            .disabled(model.allProfiles.isEmpty)
                            .help(model.allProfiles.isEmpty
                                  ? String(localized: "Профилей ещё нет: откройте файл, разметьте колонки и сохраните профиль — он появится в этом списке")
                                  : String(localized: "Каким профилем читать этот файл. «Подбирать по колонкам» — как раньше, по совпадению набора заголовков"))

                            Button(model.openedPath == file.relativePath ? "Открыт" : "Открыть") {
                                model.open(file.url, app: app, source: source)
                            }
                            .disabled(model.isBusy || model.openedPath == file.relativePath)
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        Text(model.isBusy
             ? String(localized: "Читаем файл…")
             : String(localized: "Выберите таблицу выше — или откройте `.xlsx`, `.ods`, `.csv` или `.numbers` со стороны."))
            .font(Theme.Font.body).foregroundStyle(Theme.Palette.captionText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sheets

    private var sheetPicker: some View {
        SectionCard(title: "Листы", subtitle: model.fileName ?? "") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.sheets) { preview in
                    HStack(spacing: 8) {
                        Button {
                            model.selectedSheet = preview.sheet.name
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: model.selectedSheet == preview.sheet.name ? "largecircle.fill.circle" : "circle")
                                Text(preview.sheet.name).font(Theme.Font.body)
                                if preview.sheet.isHidden {
                                    Text("скрытый").font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Picker("", selection: model.binding(for: preview.sheet.name).mode) {
                            ForEach(SheetMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .labelsHidden()
                        .frame(width: 180)

                        Text(preview.shape.reason)
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                    }
                }
                if let mode = model.draft?.mode {
                    Text(mode.explanation)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = model.matchNote {
                    Label(note, systemImage: "info.circle")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The first rows, coloured by what each column is for —'s «с
    /// подсветкой ролей колонок».
    private func sheetCard(_ preview: TableMappingViewModel.SheetPreview) -> some View {
        SectionCard(title: "Первые строки", subtitle: "Как их прочитало приложение: текст, число, дата или пусто.") {
            let mapping = model.draft ?? TableMapping(sheetName: preview.sheet.name)
            let width = max(mapping.columns.count, (preview.rows.map { $0.lastColumn + 1 }.max() ?? 0))
            VStack(alignment: .leading, spacing: 6) {
                // строку заголовка называет человек. Автоопределение
                // берёт первую непустую, и на файле с шапкой отчёта над
                // таблицей «заголовками» становится название отчёта.
                Label(
                    mapping.headerRow.map {
                        String(localized: "Заголовки читаются из строки \($0). Нажмите на номер другой строки, чтобы читать их с неё: всё, что выше заголовка, в индекс не попадёт.")
                    } ?? String(localized: "Строка заголовков не найдена. Нажмите на номер строки, чтобы прочитать заголовки с неё."),
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                .fixedSize(horizontal: false, vertical: true)

                // на листе бывают одни данные — без шапки или с шапкой,
                // которую не прочитать. Тогда колонки называются буквами, как
                // в самой таблице, а имена человек задаёт полем «Своё
                // название»: буква — адрес колонки, а не её смысл.
                HStack(spacing: 8) {
                    Button(String(localized: "Заголовков нет — назвать колонки самому")) {
                        model.useColumnLetters(startingAfter: 0, for: preview.sheet.name)
                    }
                    .buttonStyle(.chromaNormal)
                    if let row = mapping.headerRow, row > 0 {
                        Button(String(localized: "В строке \(row.plainDigits) заголовков нет")) {
                            model.useColumnLetters(startingAfter: row, for: preview.sheet.name)
                        }
                        .buttonStyle(.chromaNormal)
                        .help(String(localized: "Считать эту строку служебной: колонки назвать буквами, данные читать со следующей"))
                    }
                    Spacer()
                }

                // Horizontal only, and no height cap. A vertically capped ScrollView
                // nested inside the sheet's own ScrollView laid out its twenty rows
                // over the heading above it — the sheet already scrolls, so the card
                // is simply allowed to be as tall as its rows.
                // Роли и свои названия — по разу на колонку, а не по разу
                // на ячейку. На листе в 210 колонок это 4 400 обращений
                // к словарям при каждой перерисовке — то есть при каждом
                // нажатии клавиши в поле «Своё название».
                let titles = (0..<width).map { $0 < mapping.columns.count ? mapping.columns[$0] : "" }
                let roles = titles.map { mapping.role(of: $0) }

                // Сетка собирается **колонками**, а не строками.
                //
                // Так ленивость наконец работает. Раньше ленивый стек лежал
                // внутри вертикального: тому нужен полный размер каждой
                // строки, и стек был обязан построить все свои ячейки —
                // на листе в 114 колонок это 2 400 текстов с фоном и рамкой,
                // и собирались они заново при каждом нажатии на номер строки
                // и каждом знаке в поле «Своё название». Замер на рабочей
                // книге: ядро отдаёт все 14 листов за 0,04 с, а экран не
                // отвечал минуту.
                //
                // Колонка целиком — один элемент ленивого стека, и строится
                // только то, что видно: двадцать одна ячейка вместо всех.
                let shown = showsAllColumns ? width : min(width, Self.columnsShownAtOnce)
                // Строки считаются один раз на сетку, а не в каждой колонке:
                // `previewRows` строит словарь и массив, и в ленивом стеке
                // из ста колонок это сто одинаковых построений на каждую
                // перерисовку — то есть на каждый знак в поле «Своё название».
                let previewRows = preview.previewRows
                HStack(alignment: .top, spacing: 0) {
                    // Номера строк — вне прокрутки: по ним назначают строку
                    // заголовков, а уезжали они вместе с содержимым, и на
                    // широком листе целиться становилось не во что.
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        Color.clear.frame(width: numberGutterWidth, height: Self.rowHeight)
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
                                VStack(alignment: .leading, spacing: rowSpacing) {
                                    // Буквы колонок — как в самой таблице.
                                    //
                                    // Они не строка файла, а его разметка, и потому
                                    // стоят отдельно и всегда: строка заголовков
                                    // может быть десятой, всё что выше приглушено,
                                    // и опереться при разметке становится не на что.
                                    // «Колонка E» — то, чем человек называет колонку,
                                    // глядя в свой же файл рядом, и это единственное
                                    // имя, которое не зависит ни от выбранной строки
                                    // заголовков, ни от переименований.
                                    Text(XLSXReader.columnName(column))
                                        .font(Theme.Font.micro)
                                        .foregroundStyle(Theme.Palette.captionText)
                                        .frame(width: 130 + 12, height: Self.rowHeight)
                                    ForEach(previewRows, id: \.number) { row in
                                        let isHeader = row.number == mapping.headerRow
                                        let isAbove = mapping.headerRow.map { row.number < $0 } ?? false
                                        // В строке заголовков показывается выбранное
                                        // человеком имя: переименование должно быть
                                        // видно там же, где на него смотрят.
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

                if width > shown {
                    HStack(spacing: 8) {
                        Text("Показаны первые \(shown.plainDigits) колонок из \(width.plainDigits).")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        Button(String(localized: "Показать все")) { showsAllColumns = true }
                            .font(Theme.Font.micro).buttonStyle(.link)
                        Spacer()
                    }
                }
            }
            // Решение «показать все» принимается про конкретный лист: на
            // соседнем оно значит другое число колонок и другую задержку.
            .onChange(of: model.selectedSheet) { _, _ in showsAllColumns = false }
        }
    }

    /// Ширина колонки с номерами строк — она же отступ под буквами колонок,
    /// чтобы буква стояла над своей колонкой, а не съезжала на соседнюю.
    private var numberGutterWidth: CGFloat { 30 + 4 * 2 }
    /// Высота строки задана числом, а не содержимым: номера строк стоят вне
    /// прокрутки, и совпасть с ячейками они могут только по общей мерке.
    private static let rowHeight: CGFloat = 22
    private var rowSpacing: CGFloat { 2 }
    /// Столько колонок показывается сразу. Лист в тысячу колонок бывает
    /// (сводная выгрузка по дням), и строить его целиком незачем: разметку
    /// делают по первым, а «показать все» — рядом, одной кнопкой.
    private static let columnsShownAtOnce = 60

    /// Номер строки — он же кнопка «читать заголовки отсюда».
    private func numberCell(_ number: Int, isHeader: Bool, sheet: String) -> some View {
        Button {
            model.useHeaderRow(number, for: sheet)
        } label: {
            Text("\(number)")
                .font(Theme.Font.micro)
                .foregroundStyle(isHeader ? Color.accentColor : Theme.Palette.captionText)
                .frame(width: 30, height: Self.rowHeight, alignment: .trailing)
                .padding(.horizontal, 4)
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
            .font(isHeader ? Theme.Font.tableHeader : Theme.Font.micro)
            .lineLimit(1).truncationMode(.tail)
            // Строки выше заголовка приглушены: они остаются на виду, потому
            // что по ним и выбирают строку заголовка, но записями не станут.
            .foregroundStyle(isAbove ? Theme.Palette.captionText : .primary)
            .frame(width: 130, height: Self.rowHeight, alignment: .leading)
            .padding(.horizontal, 6)
            .background(isAbove ? Color.clear : colour(for: role).opacity(isHeader ? 0.28 : 0.12))
            // `border`, а не `overlay` с фигурой: рамка та же, а представлений
            // на ячейку вдвое меньше — на сетке в две тысячи ячеек это заметно.
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

    private func rolesCard(_ preview: TableMappingViewModel.SheetPreview) -> some View {
        SectionCard(
            title: "Колонки",
            subtitle: "Текст уходит в документ и участвует в поиске по смыслу; метаданные — в фильтры. Артикул в тексте это шум в векторе."
        ) {
            let binding = model.binding(for: preview.sheet.name)
            VStack(alignment: .leading, spacing: 6) {
                // Заголовки из файла — в поля «Своё название».
                // Править имя приходится ровно тогда, когда оно почти годится,
                // и набирать его заново ради одной правки — работа на ровном
                // месте: оно уже написано в соседней колонке.
                HStack(spacing: 8) {
                    Button(String(localized: "Заполнить названия из файла")) {
                        model.fillTitlesFromFile(for: preview.sheet.name)
                    }
                    .buttonStyle(.chromaNormal)
                    .help(String(localized: "Перенести заголовки из файла в поля «Своё название», чтобы их править. Уже заданные названия не трогаются."))
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Колонка в файле").frame(width: 190, alignment: .leading)
                    Text("Своё название").frame(width: 170, alignment: .leading)
                    Text("Что с ней делать").frame(width: 140, alignment: .leading)
                    Text("Ключ в метаданных")
                    Spacer()
                }
                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)

                // По порядковому номеру, а не по имени: заголовки в файле
                // повторяются («Итого» над каждым кварталом), а `id: \.self`
                // на повторе склеивает строки в одну. Номер он же
                // даёт букву колонки.
                //
                // `LazyVStack` — по той же причине, что и в предпросмотре, но
                // тяжелее: в каждой строке поле ввода и два выпадающих списка,
                // и на листе в 210 колонок обычный стек строит их все разом.
                //
                // Ключи метаданных считаются **один раз на список**, а не
                // на строку: `keyMap` строится по всем колонкам сразу, и
                // обращение к нему в каждой строке превращало 210 колонок
                // в 44 000 нормализаций на каждую перерисовку.
                let keyMap = binding.wrappedValue.keyMap
                LazyVStack(alignment: .leading, spacing: 6) {
                  ForEach(Array(binding.wrappedValue.columns.enumerated()), id: \.offset) { index, column in
                    HStack(spacing: 8) {
                        Circle().fill(colour(for: binding.wrappedValue.role(of: column))).frame(width: 8, height: 8)
                        // Буква колонки — рядом с её именем: размечают, глядя
                        // в таблицу выше и в свой файл в Excel, а там колонка
                        // называется буквой.
                        // Ширины хватает на две буквы: у листа в 210 колонок
                        // они начинаются с двадцать седьмой, и в 22 точки
                        // «HB» переносилось на вторую строку, растягивая
                        // строку списка вдвое.
                        Text(XLSXReader.columnName(index))
                            .font(Theme.Font.micro.monospaced())
                            .foregroundStyle(Theme.Palette.captionText)
                            .lineLimit(1)
                            .frame(width: 28, alignment: .trailing)
                        Text(column).font(Theme.Font.body).frame(width: 160, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                            .help(column)

                        // 5,: заголовки в рабочих таблицах бывают
                        // служебными («Столбец 3»), длинными на полстроки или
                        // отсутствуют вовсе — а именно по ним строятся ключи
                        // метаданных, то есть имя из файла уезжает в базу
                        // навсегда. Переименование здесь, а не правкой файла:
                        // файл чужой. Пусто — значит «как в файле».
                        TextField(column, text: Binding(
                            get: { binding.wrappedValue.titles[column] ?? "" },
                            set: { binding.wrappedValue.titles[column] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.caption)
                        .frame(width: 170)

                        Picker("", selection: Binding(
                            get: { binding.wrappedValue.role(of: column) },
                            set: { binding.wrappedValue.roles[column] = $0 }
                        )) {
                            ForEach(ColumnRole.allCases) { role in Text(role.title).tag(role) }
                        }
                        .labelsHidden()
                        .frame(width: 140)

                        if let key = keyMap.key(for: binding.wrappedValue.title(of: column)) {
                            Text(key).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                  }
                }

                Divider()
                HStack {
                    Text("Ключевая колонка").font(Theme.Font.caption)
                    Picker("", selection: Binding(
                        get: { binding.wrappedValue.keyColumn ?? "" },
                        set: { binding.wrappedValue.keyColumn = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("нет").tag("")
                        // С буквой: в списке из «Итого», «Итого», «Итого»
                        // выбрать нужную иначе нельзя.
                        ForEach(Array(binding.wrappedValue.columns.enumerated()), id: \.offset) { index, column in
                            Text("\(XLSXReader.columnName(index)) · \(column)").tag(column)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                }
                if let warning = model.keyColumnWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Повтор значения ключа — не стиль разметки, а строки, которые
                // не попадут в базу. Говорится здесь же, где ключ выбирают.
                if let duplicates = model.keyColumnDuplicates {
                    Label(duplicates, systemImage: "doc.on.doc")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // a rename the user never sees is the same as losing the
                // column — so every one of them is listed.
                ForEach(model.keyCollisions) { collision in
                    Label(collision.explanation, systemImage: "arrow.triangle.branch")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - What one row becomes

    private var documentCard: some View {
        SectionCard(
            title: "Что получится из строки",
            subtitle: "Из этого текста считается вектор — от него прямо зависит поиск. Поэтому он показан до запуска, а не подбирается переиндексациями."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let binding = model.preview.map({ model.binding(for: $0.sheet.name) }),
                   binding.wrappedValue.mode == .dataTable {
                    TextField("Шаблон, например {Название}. {Описание}", text: binding.textTemplate)
                        .textFieldStyle(.roundedBorder)
                    Text("Пусто — «Колонка: значение» по колонкам, помеченным как текст.")
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                    ForEach(model.templateProblems, id: \.self) { name in
                        Label("В шаблоне есть {\(name)}, но такой колонки нет — документ выйдет без этого куска.",
                              systemImage: "exclamationmark.triangle")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let document = model.documentPreview {
                    Text("Текст документа").font(Theme.Font.caption).bold()
                    Text(document.text)
                        .font(Theme.Font.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .copyable(document.text)

                    Text("Метаданные").font(Theme.Font.caption).bold()
                    ForEach(document.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(spacing: 6) {
                            Text(key).font(Theme.Font.mono)
                                .foregroundStyle(MetadataSchema.isTechnicalKey(key) ? .secondary : .primary)
                            Text(describe(value)).font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                    }
                } else if let rendered = model.renderedDocument {
                    Text("Лист как текст").font(Theme.Font.caption).bold()
                    Text(rendered.text.prefix(1200))
                        .font(Theme.Font.mono)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if rendered.header != nil {
                        Label("Строка заголовков повторится в каждом чанке — без неё второй чанк был бы сеткой значений без названий колонок.",
                              systemImage: "info.circle")
                            .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Для этого листа предпросмотр документа не показывается: режим «не индексировать».")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.captionText)
                }
            }
        }
    }

    private func describe(_ value: MetadataValue) -> String {
        switch value {
        case .string(let value): return "\"\(value)\""
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    // MARK: - Profile

    private var profileCard: some View {
        SectionCard(
            title: "Профиль сопоставления",
            subtitle: "Применяется к файлам с тем же набором колонок. Файл с другим набором не индексируется наполовину — он попадёт в «требуют решения»."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Название профиля", text: $model.profileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                // Кнопки — строкой под полем, а не рядом с ним: вчетвером
                // в одном ряду с текстовым полем они не помещались, и надписи
                // обрезались до «Экспорт профи…». Кнопка, которую нельзя
                // прочитать, ничем не лучше кнопки без подписи.
                HStack(spacing: 8) {
                    Button("Экспорт профилей…") { model.exportProfiles(app, source: source) }
                        .disabled(model.allProfiles.isEmpty)
                    Button("Импорт профилей…") { model.importProfiles(app, source: source) }
                    Button("Разметить заново") { model.startOver(app, source: source) }
                        .help(String(localized: "Забыть подставленный профиль и собрать разметку этого файла с нуля"))
                        .disabled(model.sheets.isEmpty)
                    Button("Сохранить профиль") { model.save(app, source: source) }
                        .keyboardShortcut(.defaultAction)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)
                // Пустая строка после действий: дальше идут настройки профиля,
                // и без зазора кнопка «Сохранить профиль» читается как часть
                // строки «Хранить профиль».
                .padding(.bottom, 8)

                // Где хранить профиль. Выбор человека, а не умолчание
                // приложения: одинаковые книги приходят в разные папки, и
                // разметка «отчёт ФЭО» не должна повторяться в каждой из них
                // слово в слово. Умолчание при этом прежнее — у источника.
                HStack(spacing: 8) {
                    Text("Хранить профиль").font(Theme.Font.caption)
                    Picker("", selection: $model.scope) {
                        ForEach(TableProfileScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Text(model.scope.explanation)
                        .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                // Что именно сохранится: по варианту на лист, и к каким листам
                // каждый вариант применяется. Показано списком, а не
                // одним выбором на весь профиль: у листов книги ответы разные.
                Text("Сохранится вся книга — по варианту на лист:")
                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                ForEach(model.sheets) { entry in
                    let mapping = model.drafts[entry.sheet.name] ?? TableMapping(sheetName: entry.sheet.name)
                    HStack(spacing: 8) {
                        Text(entry.sheet.name).font(Theme.Font.caption)
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        if mapping.mode == .skip {
                            // «Не индексировать» тоже сохраняется, и это важно:
                            // лист без варианта означал бы «про него ничего
                            // не сказано» и подхватывал чужой разбор.
                            Text("не индексировать — так и записано в профиле")
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        } else {
                            Picker("", selection: Binding(
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
                            }
                            .labelsHidden()
                            .frame(width: 260)
                            Text("\(mapping.columns.count) колонок")
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                        }
                        Spacer()
                    }
                }

                let listed = model.listedProfiles
                if !listed.isEmpty {
                    Divider()
                    Text("Профили").font(Theme.Font.caption).bold()
                    ForEach(listed) { profile in
                        HStack(spacing: 8) {
                            Text(profile.name).font(Theme.Font.caption)
                            // Общий — виден всем источникам; перекрытый —
                            // виден, но в подборе не участвует, потому что
                            // у источника есть свой с тем же именем.
                            if model.isOverridden(profile) {
                                Text("общий, перекрыт своим")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.attention)
                            } else if model.isShared(profile) {
                                Text("общий")
                                    .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                            }
                            Text(profile.summary)
                                .font(Theme.Font.micro).foregroundStyle(Theme.Palette.captionText)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Button("Удалить", role: .destructive) {
                                model.removeProfile(named: profile.name, app: app, source: source)
                            }
                            .font(Theme.Font.micro).buttonStyle(.link)
                            .help(model.isShared(profile)
                                  ? String(localized: "Профиль общий: он исчезнет у всех источников, и их файлы вернутся к подбору по колонкам")
                                  : String(localized: "Профиль исчезнет у этого источника; назначенные ему файлы вернутся к подбору по колонкам"))
                        }
                    }
                }
            }
        }
    }
}
