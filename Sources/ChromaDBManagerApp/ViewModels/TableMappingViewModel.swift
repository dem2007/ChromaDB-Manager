import Foundation
import SwiftUI
import ChromaCore

/// The screen of: what a table file holds, what a row will become, and the
/// mapping that decides it.
@MainActor
final class TableMappingViewModel: ObservableObject {
    /// One sheet as the preview knows it.
    struct SheetPreview: Identifiable {
        var id: String { sheet.name }
        let sheet: SheetInfo
        let shape: SheetShape
        /// The first rows, as read — twenty is what asks to show.
        let rows: [SheetRow]

        /// Строки для предпросмотра — **подряд по номерам**, включая пустые.
        ///
        /// XLSX не хранит строки без единой ячейки: их просто нет в файле,
        /// а значит не было и в списке. Выглядело это так, что по строке 7
        /// нельзя щёлкнуть, — при том что именно её человек и хотел назначить
        /// заголовком, глядя в свой файл в Excel, где эта строка есть.
        var previewRows: [SheetRow] {
            let byNumber = Dictionary(rows.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
            let last = min(rows.map(\.number).max() ?? 0, TableMappingViewModel.previewRowCount + 1)
            guard last > 0 else { return [] }
            return (1...last).map { byNumber[$0] ?? SheetRow(number: $0, cells: [:]) }
        }
    }

    /// A table file the source itself indexes.
    struct SourceFile: Identifiable, Hashable {
        var id: String { relativePath }
        let url: URL
        let relativePath: String
        let size: Int64
    }

    @Published var fileName: String?
    /// The source's own table files, offered instead of «найдите файл сами».
    ///
    /// The source knows them: they are the files its next run will hand to the
    /// table pipeline, found by the same scan that run uses. Asking the user to
    /// locate one of them in a file panel was asking them to repeat work the app
    /// had already done.
    @Published var sourceFiles: [SourceFile] = []
    @Published var isScanning = false
    /// Which of them is open, so the list says where you are.
    @Published var openedPath: String?
    @Published var sheets: [SheetPreview] = []
    @Published var selectedSheet: String?
    /// The mapping being edited, per sheet.
    @Published var drafts: [String: TableMapping] = [:]
    @Published var profileName = ""
    /// Выбор листов — на каждый лист свой.
    ///
    /// Профиль описывает книгу целиком, и «Товары и услуги» может быть привязан
    /// к своему имени, а соседний лист — к любому подходящему. Одно значение на
    /// весь экран заставляло бы выбирать одно и то же для всех листов сразу.
    @Published var sheetSelections: [String: SheetSelection] = [:]
    /// Профили источника — здесь, а не в переданном `DataSource`: экран их
    /// правит, и читать при этом слепок, снятый при открытии, значит показывать
    /// вчерашний список.
    @Published var profiles: [TableProfile] = []
    /// Профили, общие для всех источников.
    @Published var sharedProfiles: [TableProfile] = []
    /// Куда сохранять следующий профиль — выбор человека, а не умолчание
    /// приложения. При открытии файла подставляется область того
    /// профиля, которым файл узнан: повторное сохранение не должно молча
    /// раздваивать разметку на общую и свою.
    @Published var scope: TableProfileScope = .source
    /// Какой профиль назначен файлу: путь → id профиля.
    @Published var assignments: [String: UUID] = [:]
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Which saved profile the open sheet matched, if any.
    @Published var matchNote: String?

    /// 8 asks for the first twenty rows.
    /// `nonisolated`: к ней обращается вложенный `SheetPreview`, который
    /// главному потоку не принадлежит. Число это постоянная, а не состояние.
    nonisolated static let previewRowCount = 20

    /// Все профили, которыми читается этот источник: свои плюс общие.
    ///
    /// Ровно тот же список и в том же порядке, что увидит прогон: экран,
    /// показывающий не то, чем файл будет прочитан, хуже отсутствия экрана.
    var allProfiles: [TableProfile] {
        TableProfile.resolved(own: profiles, shared: sharedProfiles)
    }

    /// Список для экрана: свои, затем общие, без повторов по `id`.
    var listedProfiles: [TableProfile] {
        var seen: Set<UUID> = []
        return (profiles + sharedProfiles).filter { seen.insert($0.id).inserted }
    }

    /// Профиль общий — то есть виден всем источникам.
    func isShared(_ profile: TableProfile) -> Bool {
        sharedProfiles.contains { $0.id == profile.id }
    }

    /// Одноимённый общий профиль перекрыт своим и в подборе не участвует.
    func isOverridden(_ profile: TableProfile) -> Bool {
        isShared(profile) && !allProfiles.contains { $0.id == profile.id }
    }

    var preview: SheetPreview? {
        sheets.first { $0.sheet.name == selectedSheet } ?? sheets.first
    }

    var draft: TableMapping? {
        guard let name = preview?.sheet.name else { return nil }
        return drafts[name]
    }

    func binding(for sheetName: String) -> Binding<TableMapping> {
        Binding(
            get: { self.drafts[sheetName] ?? TableMapping(sheetName: sheetName) },
            set: { self.drafts[sheetName] = $0 }
        )
    }

    /// Выбор листов для этого листа. По умолчанию — «лист с этим именем»:
    /// профиль книги описывает именно эти листы, и разные листы книги как раз
    /// и различаются именами.
    func sheetSelection(for sheetName: String) -> SheetSelection {
        sheetSelections[sheetName] ?? .named([sheetName])
    }

    /// Варианты, которые сохранятся в профиле: по одному на лист.
    ///
    /// **«Не индексировать» сохраняется наравне с остальными**, и это
    /// исправление. Считалось, что «не читать» — это отсутствие варианта;
    /// на деле отсутствие означало «про этот лист ничего не сказано», и при
    /// следующем открытии режим определялся заново. Хуже того: лист без
    /// варианта подхватывал чужой разбор и попадал в индекс — ровно то,
    /// от чего его пометили.
    ///
    /// Не сохраняются только пустышки: разбор «таблица данных» без единой
    /// колонки не описывает ничего, а его пустая подпись совпадает с любым
    /// листом, у которого не нашлось заголовка.
    var variantsToSave: [TableProfile.Variant] {
        sheets.compactMap { entry in
            guard let mapping = drafts[entry.sheet.name] else { return nil }
            if mapping.mode == .dataTable && mapping.columns.isEmpty { return nil }
            return TableProfile.Variant(
                sheets: sheetSelection(for: entry.sheet.name),
                mapping: mapping
            )
        }
    }

    /// Листы открытой книги — по ним решается, какие варианты профиля
    /// эта книга описывает, а какие остались от других файлов.
    private var openSheetNames: [(name: String, index: Int)] {
        sheets.enumerated().map { ($0.element.sheet.name, $0.offset) }
    }

    /// Варианты сохраняемого профиля: разбор открытой книги плюс всё, что
    /// профиль знал про **другие** файлы.
    ///
    /// Раньше сохранение заменяло варианты целиком тем, что видно в открытой
    /// книге. Профиль, описывавший две книги, после правки одной из них терял
    /// половину — молча, без единого слова. В журнале это выглядело как
    /// «вариантов 14» → «вариантов 9».
    func mergedVariants(with existing: TableProfile?) -> [TableProfile.Variant] {
        let fresh = variantsToSave
        guard let existing else { return fresh }
        let kept = existing.variants.filter { variant in
            !openSheetNames.contains { variant.sheets.admits(sheetName: $0.name, index: $0.index) }
        }
        return kept + fresh
    }

    // MARK: - Opening

    /// The table files of this source, by the same scan its sync uses.
    ///
    /// Read-only and cheap: names, sizes and nothing else. Nothing is opened by
    /// itself — a `.numbers` file is read by asking Numbers to export it, and
    /// that is not something a screen may start on its own (rule 4).
    func scanSourceFiles(_ app: AppEnvironment, source: DataSource) {
        // Профили и назначения читаются один раз при открытии экрана и дальше
        // живут здесь: правит их этот же экран.
        profiles = source.tableProfiles
        sharedProfiles = app.settings.configuration.sharedTableProfiles
        assignments = source.tableProfileAssignments
        isScanning = true
        Task {
            defer { isScanning = false }
            // The scan itself lives on the sync service's actor, so the walk of
            // a folder of thousands of files does not happen on the main one.
            let urls = (try? await app.syncService.scanFiles(source: source)) ?? []
            let excluded = Set(source.excludedPaths)
            let root = source.url
            sourceFiles = await Task.detached(priority: .userInitiated) {
                urls.compactMap { url -> SourceFile? in
                    guard TabularFormat.of(url) != nil else { return nil }
                    let relative = SourceSyncService.relative(url, to: root)
                    guard !excluded.contains(relative) else { return nil }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    return SourceFile(url: url, relativePath: relative, size: size)
                }
            }.value
        }
    }

    func chooseFile(_ app: AppEnvironment, source: DataSource) {
        guard let url = ConnectionViewModel.chooseFile(
            title: "Файл таблицы для предпросмотра",
            message: "Файл только читается: ничего не индексируется и не записывается."
        ) else { return }
        open(url, app: app, source: source)
    }

    func open(_ url: URL, app: AppEnvironment, source: DataSource) {
        isBusy = true
        errorMessage = nil
        infoMessage = nil
        fileName = url.lastPathComponent
        // Empty for a file opened from outside the source — the list marks its
        // own files, and a stranger is not one of them.
        openedPath = sourceFiles.first { $0.url == url }?.relativePath

        Task {
            defer { isBusy = false }
            do {
                // Only the first rows are read: judging a workbook must not cost
                // a full parse of a fifty-thousand-row sheet.
                let read = try await TableSyncService.read(
                    url: url,
                    allowApplicationExport: source.numbersExportEnabled,
                    limits: XLSXReader.Limits(maxRows: Self.previewRowCount + 1)
                )
                defer { read.temporary.map { try? FileManager.default.removeItem(at: $0) } }

                sheets = read.sheets.map { entry in
                    SheetPreview(
                        sheet: entry.sheet,
                        shape: SheetModeDetector.suggest(rows: entry.rows, isHidden: entry.sheet.isHidden),
                        rows: entry.rows
                    )
                }
                selectedSheet = sheets.first { $0.shape.mode != .skip }?.sheet.name ?? sheets.first?.sheet.name

                drafts = [:]
                sheetSelections = [:]
                // Назначенный этому файлу профиль — впереди подбора:
                // человек уже ответил на вопрос, который подбор угадывает.
                let visible = allProfiles
                let assigned = openedPath.flatMap { assignments[$0] }
                    .flatMap { id in visible.first { $0.id == id } }

                for (index, entry) in sheets.enumerated() {
                    let suggestion = TableMapping.suggested(sheetName: entry.sheet.name, shape: entry.shape)
                    if let assigned,
                       let variant = assigned.variants.first(where: {
                           $0.sheets.admits(sheetName: entry.sheet.name, index: index)
                       }) {
                        drafts[entry.sheet.name] = apply(variant, to: index)
                        sheetSelections[entry.sheet.name] = variant.sheets
                        if entry.sheet.name == selectedSheet {
                            matchNote = isShared(assigned)
                                ? String(localized: "общий профиль «\(assigned.name)» назначен этому файлу вручную")
                                : String(localized: "профиль «\(assigned.name)» назначен этому файлу вручную")
                            profileName = assigned.name
                            scope = isShared(assigned) ? .application : .source
                        }
                        continue
                    }

                    let match = TableProfileMatcher.match(
                        profiles: visible,
                        sheetName: entry.sheet.name,
                        sheetIndex: index,
                        columns: entry.shape.columns
                    )
                    switch match {
                    case .matched(let profile, let variant):
                        drafts[entry.sheet.name] = apply(variant, to: index)
                        sheetSelections[entry.sheet.name] = variant.sheets
                        if entry.sheet.name == selectedSheet {
                            matchNote = isShared(profile)
                                ? String(localized: "лист узнан общим профилем «\(profile.name)»")
                                : String(localized: "лист узнан профилем «\(profile.name)»")
                            profileName = profile.name
                            scope = isShared(profile) ? .application : .source
                        }
                    case .needsDecision(let reason, _, _, _):
                        drafts[entry.sheet.name] = suggestion
                        if entry.sheet.name == selectedSheet { matchNote = reason }
                    case .ambiguous(let candidates):
                        drafts[entry.sheet.name] = suggestion
                        if entry.sheet.name == selectedSheet {
                            matchNote = String(localized: "подходит несколько профилей: \(candidates.map(\.name).joined(separator: ", "))")
                        }
                    }
                }
                if profileName.isEmpty { profileName = url.deletingPathExtension().lastPathComponent }
            } catch {
                sheets = []
                errorMessage = "\(url.lastPathComponent): \(SourceSyncService.reason(for: error))"
            }
        }
    }

    /// Разметка варианта, пересчитанная на колонки открытого файла.
    ///
    /// Заголовок читается со строки, записанной в варианте: у книги, где та же
    /// таблица начинается ниже, иначе прочиталась бы не та строка. Побочно
    /// обновляется и форма листа — от неё зависит подсветка в предпросмотре.
    private func apply(_ variant: TableProfile.Variant, to index: Int) -> TableMapping {
        let entry = sheets[index]
        guard variant.mapping.mode == .dataTable else { return variant.mapping }
        let shape = variant.mapping.headerRow
            .flatMap { SheetModeDetector.shape(rows: entry.rows, headerRow: $0) } ?? entry.shape
        sheets[index] = SheetPreview(sheet: entry.sheet, shape: shape, rows: entry.rows)
        return variant.mapping.rebased(on: shape)
    }

    // MARK: - The preview of one document

    /// What a row will actually become — text and metadata — **before** anything
    /// is indexed.
    ///
    /// The point of showing it: the template is what the vector is computed
    /// from, and tuning it blind means a full re-index per attempt.
    var documentPreview: TableRowDocument? {
        guard let preview, let mapping = draft, mapping.mode == .dataTable else { return nil }
        // Строки выше заголовка — шапка отчёта, а не записи: показывать «что
        // получится из строки» на названии отчёта значит показывать документ,
        // которого не будет.
        let first = mapping.headerRow.map { $0 + 1 } ?? Int.min
        let dataRows = preview.rows.filter { $0.number >= first && !$0.isEmpty }
        guard let row = dataRows.first else { return nil }
        return RowMapper.document(
            for: row,
            mapping: mapping,
            layout: SheetLayout(mapping: mapping),
            sourceID: UUID(),
            sourceFile: fileName ?? ""
        )
    }

    /// What the document mode would produce instead: the sheet as text, with the
    /// header that every chunk will repeat.
    var renderedDocument: SheetRenderer.Rendered? {
        guard let preview, let mapping = draft, mapping.mode == .document else { return nil }
        return SheetRenderer.render(rows: preview.rows, headerRow: mapping.headerRow)
    }

    /// Placeholders in the template that name no column — a typo would otherwise
    /// quietly produce empty documents.
    var templateProblems: [String] {
        guard let mapping = draft, !mapping.textTemplate.isEmpty else { return [] }
        // У сопоставления, а не у списка колонок: в шаблоне работают оба имени,
        // и проверка по одним заголовкам из файла объявила бы `{Группа ПО}`
        // опечаткой — а опечатка запрещает сохранение профиля.
        return RowMapper.unknownPlaceholders(in: mapping.textTemplate, mapping: mapping)
    }

    /// Renames forced on column names, so they are seen rather than discovered
    ///.
    var keyCollisions: [ColumnKeyCollision] {
        draft?.keyMap.collisions ?? []
    }

    var keyColumnWarning: String? {
        guard let mapping = draft, mapping.mode == .dataTable, mapping.keyColumn == nil else { return nil }
        return String(localized: "Без ключевой колонки строка узнаётся по содержимому: вставка и перестановка строк ничего не стоят, но правка создаёт новый документ, а прежний попадает в «Требуют решения» — его нужно будет разобрать. Выберите колонку с артикулом, кодом или адресом почты, если такая есть.")
    }

    /// Ключевая колонка, в которой значения повторяются.
    ///
    /// Смотрит только показанные строки — их двадцать, и большего экрану
    /// не нужно: колонка вроде «Категория», выбранная ключом по ошибке,
    /// повторяется в первом же десятке. Отсутствие повтора здесь ничего
    /// не обещает — настоящая проверка идёт в прогоне и попадает в отчёт.
    var keyColumnDuplicates: String? {
        guard let mapping = draft, mapping.mode == .dataTable,
              let key = mapping.keyColumn, let preview
        else { return nil }
        let layout = SheetLayout(shape: preview.shape)
        guard let index = layout.index(of: key) else { return nil }
        let firstDataRow = (layout.headerRow ?? 0) + 1

        var rowsByValue: [String: [Int]] = [:]
        for row in preview.rows where row.number >= firstDataRow {
            let value = row.value(at: index).displayText
            guard !value.isEmpty else { continue }
            rowsByValue[value, default: []].append(row.number)
        }
        let repeats = rowsByValue.filter { $0.value.count > 1 }.sorted { ($0.value.first ?? 0) < ($1.value.first ?? 0) }
        guard !repeats.isEmpty else { return nil }

        let examples = repeats.prefix(3)
            .map { "«\($0.key)» — строки \($0.value.map(\.plainDigits).joined(separator: ", "))" }
            .joined(separator: "; ")
        let tail = repeats.count > 3 ? String(localized: " и ещё \(repeats.count - 3)") : ""
        return String(localized: "В колонке «\(mapping.title(of: key))» значения повторяются уже в показанных строках: \(examples)\(tail). Ключ определяет документ, поэтому из каждой такой группы запишется только первая строка. Выберите колонку, где значение своё у каждой строки.")
    }

    // MARK: - Строка заголовка

    /// Читать заголовки с указанной строки.
    ///
    /// Автоопределение берёт первую непустую строку, и на файле с шапкой отчёта
    /// над таблицей «заголовками» становится название отчёта. Угадать тут
    /// нечего — строку называет человек, а колонки пересчитываются от неё.
    ///
    /// Роли, свои названия и ключевая колонка переносятся по именам, которые
    /// уцелели; новые колонки получают роль по первому предположению. Если
    /// заголовков в строке нет, не меняется ничего и об этом говорится: молча
    /// оставить прежний разбор значило бы показывать сопоставление, которого
    /// человек не просил.
    func useHeaderRow(_ number: Int, for sheetName: String) {
        guard let index = sheets.firstIndex(where: { $0.sheet.name == sheetName }) else { return }
        let entry = sheets[index]

        guard let shape = SheetModeDetector.shape(rows: entry.rows, headerRow: number) else {
            if case .needsDecision(let reason) = TableProfileMatcher.headers(in: entry.rows, headerRow: number) {
                errorMessage = String(localized: "Заголовки со строки \(number) прочитать нечем: \(reason).")
            } else {
                errorMessage = String(localized: "Заголовки со строки \(number) прочитать нечем.")
            }
            return
        }

        errorMessage = nil
        sheets[index] = SheetPreview(sheet: entry.sheet, shape: shape, rows: entry.rows)

        var mapping = drafts[sheetName] ?? TableMapping(sheetName: sheetName)
        let suggested = TableMapping.suggested(sheetName: sheetName, shape: shape)
        var roles: [String: ColumnRole] = [:]
        var titles: [String: String] = [:]
        for column in shape.columns {
            roles[column] = mapping.roles[column] ?? suggested.role(of: column)
            if let own = mapping.titles[column] { titles[column] = own }
        }
        mapping.headerRow = number
        mapping.columns = shape.columns
        mapping.roles = roles
        mapping.titles = titles
        if let key = mapping.keyColumn, !shape.columns.contains(key) {
            mapping.keyColumn = suggested.keyColumn
        }

        // Режим меняется только вверх и только по находке: лист, который
        // автоопределение объявило документом, потому что не нашло заголовков,
        // теперь оказался таблицей — и стоять «документом» ему незачем.
        // Обратно — никогда: «документ» человек мог выбрать сам.
        var note = String(localized: "Заголовки прочитаны из строки \(number): \(shape.columns.joined(separator: ", ")).")
        // Повторы в шапке — обычное дело у таблиц в два этажа: «Стоимость»
        // стоит под каждым годом. Имена им дописаны, и сказать об этом надо
        // сразу: в базу они уйдут именно такими.
        // Спрашивается у самой шапки, а не у вида полученных имён: заголовок
        // «Стоимость (руб.)» из файла оканчивается скобкой и без всякого
        // переименования, и проверка «на вид похоже на номер» врала бы.
        if let row = entry.rows.first(where: { $0.number == number }) {
            let width = entry.rows.map { $0.lastColumn + 1 }.max() ?? 0
            let original = SheetModeDetector.headerTitles(row, width: width)
            let duplicated = Set(Dictionary(grouping: original, by: { $0 }).filter { $0.value.count > 1 }.keys)
            if !duplicated.isEmpty {
                note += " " + String(localized: "Названия повторялись — к ним дописаны номера: \(duplicated.sorted().joined(separator: ", ")). Своё название колонке можно задать ниже.")
            }
        }
        if mapping.mode == .document, shape.mode == .dataTable {
            mapping.mode = .dataTable
            note += " " + String(localized: "Под ними однородные строки — режим переключён на «Таблица данных».")
        }
        drafts[sheetName] = mapping
        infoMessage = note
    }

    /// Переписывает заголовки из файла в поля «Своё название».
    ///
    /// Пустое поле и так значит «как в файле», и до сих пор это считалось
    /// достаточным. Но править имя приходится ровно тогда, когда оно
    /// **почти** годится: «Продолжи-тельность (мес)» с переносом посреди
    /// слова, «Столбец 3», заголовок на полстроки. Переписывать его руками
    /// в поле — это набирать заново то, что уже написано рядом.
    ///
    /// Заполняются только пустые поля: у тех, что человек уже правил,
    /// значение важнее нашего удобства. Заголовок, равный букве колонки,
    /// пропускается — «A» в качестве имени не лучше пустого поля.
    func fillTitlesFromFile(for sheetName: String) {
        guard var mapping = drafts[sheetName] else { return }
        var filled = 0
        for (index, column) in mapping.columns.enumerated() {
            let own = (mapping.titles[column] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard own.isEmpty, column != XLSXReader.columnName(index) else { continue }
            mapping.titles[column] = column
            filled += 1
        }
        guard filled > 0 else {
            infoMessage = String(localized: "Заполнять нечего: у всех колонок уже есть свои названия или заголовков в файле нет.")
            return
        }
        drafts[sheetName] = mapping
        infoMessage = String(localized: "Названия перенесены из файла: \(filled.plainDigits). Теперь их можно править — в базу уйдут они.")
    }

    /// Размечать по буквам колонок: заголовков на листе нет.
    ///
    /// `row == 0` — заголовка нет вовсе, данные с первой строки. Иначе строка
    /// считается служебной: она есть, но названий колонок в ней не прочитать
    /// — объединённые ячейки, номера столбцов, пустая строка. Названия человек
    /// задаёт полем «Своё название»: буква — это адрес колонки, а не смысл.
    func useColumnLetters(startingAfter row: Int, for sheetName: String) {
        guard let index = sheets.firstIndex(where: { $0.sheet.name == sheetName }) else { return }
        let entry = sheets[index]
        let shape = SheetModeDetector.lettered(rows: entry.rows, headerRow: row)
        guard !shape.columns.isEmpty else {
            errorMessage = String(localized: "В листе «\(sheetName)» нет ни одной колонки с данными.")
            return
        }
        errorMessage = nil
        sheets[index] = SheetPreview(sheet: entry.sheet, shape: shape, rows: entry.rows)
        let previous = drafts[sheetName] ?? TableMapping(sheetName: sheetName)
        drafts[sheetName] = previous.rebased(on: shape)
        infoMessage = row == 0
            ? String(localized: "Колонки названы буквами, данные читаются с первой строки. Задайте названия в поле «Своё название» — они уйдут в ключи метаданных.")
            : String(localized: "Колонки названы буквами, данные читаются со строки \(row + 1). Задайте названия в поле «Своё название».")
    }

    /// Забыть подставленный профиль и разметить книгу заново.
    ///
    /// Открытие файла подставляет профиль, которым он читается, — иначе
    /// правка существующей разметки была бы невозможна. Но и обратное верно:
    /// пока подстановка происходит всегда, на основе однажды распознанного
    /// файла нельзя собрать **другую** разметку. Эта команда снимает
    /// назначение и возвращает первое предположение по файлу.
    func startOver(_ app: AppEnvironment, source: DataSource) {
        for entry in sheets {
            drafts[entry.sheet.name] = TableMapping.suggested(sheetName: entry.sheet.name, shape: entry.shape)
            sheetSelections[entry.sheet.name] = .named([entry.sheet.name])
        }
        matchNote = nil
        if let path = openedPath, assignments[path] != nil {
            assign(profileID: nil, to: path, app: app, source: source)
        }
        profileName = fileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? profileName
        infoMessage = String(localized: "Разметка сброшена к предположению по файлу, назначение профиля снято. Сохранение создаст новый профиль — под другим именем.")
    }

    // MARK: - Saving

    /// Сохраняет разбор **всей книги** одним профилем.
    ///
    /// Не одного листа: в рабочей книге «Товары и услуги» и «ФЭО» — разные
    /// таблицы с разными колонками и разным ключом, и описывать их порознь
    /// значит заводить два профиля, каждый из которых потом претендует на
    /// чужой лист. Внутри профиля они становятся вариантами.
    func save(_ app: AppEnvironment, source: DataSource) {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = String(localized: "У профиля должно быть имя — по нему он называется в отчётах и по нему его выбирают в списке файлов.")
            return
        }
        guard templateProblems.isEmpty else {
            errorMessage = String(localized: "В шаблоне есть поля, которых нет среди колонок: \(templateProblems.joined(separator: ", ")).")
            return
        }
        // Одноимённый профиль ищется в **обеих** областях: сохранение под тем
        // же именем — это правка того же профиля, где бы он ни лежал, а не
        // второй такой же рядом.
        let existing = allProfiles.first { $0.name == name } ?? sharedProfiles.first { $0.name == name }
        let variants = mergedVariants(with: existing)
        guard !variants.isEmpty else {
            errorMessage = String(localized: "Сохранять нечего: ни один лист книги не размечен.")
            return
        }

        let profile = TableProfile(
            // `id` переживает смену области: за ним закреплены назначения
            // файлов, и новый идентификатор молча снял бы их все.
            id: existing?.id ?? UUID(),
            name: name,
            variants: variants
        )
        let movedFrom: TableProfileScope? = existing.map { isShared($0) ? .application : .source }
            .flatMap { $0 == scope ? nil : $0 }

        // Профиль лежит ровно в одной области. Оставить его в прежней значило
        // бы получить два профиля на один лист — то есть `.ambiguous`, при
        // котором лист не индексируется вовсе.
        var own = profiles.filter { $0.id != profile.id && $0.name != name }
        var shared = sharedProfiles.filter { $0.id != profile.id && $0.name != name }
        switch scope {
        case .source: own.append(profile)
        case .application: shared.append(profile)
        }

        var updated = source
        updated.tableProfiles = own
        // Открытый файл сразу закрепляется за этим профилем: человек только что
        // разметил именно его, и заставлять его после этого выбирать профиль
        // в списке значило бы спрашивать о том, что уже сказано.
        if let path = openedPath { updated.tableProfileAssignments[path] = profile.id }

        persist(updated, shared: shared, app: app)
        app.log.record(
            .info, "Таблицы",
            "Источник «\(source.name)»: сохранён профиль «\(name)» (\(scope.title)) — вариантов \(variants.count.plainDigits) "
            + "(\(variants.map { "\($0.title): \($0.mapping.columns.count) колонок" }.joined(separator: "; ")))"
        )
        var note = variants.count == 1
            ? String(localized: "Профиль «\(name)» сохранён \(scope.title). Он применится к файлам с тем же набором колонок; файл с другим набором попадёт в «требуют решения».")
            : String(localized: "Профиль «\(name)» сохранён \(scope.title): вариантов \(variants.count), по одному на лист. Каждый лист читается своим — тот же файл целиком.")
        if let movedFrom {
            note += " " + String(localized: "Из области «\(movedFrom.title)» он убран: профиль живёт в одной области, иначе на лист претендовали бы два одинаковых.")
        }
        infoMessage = note
    }

    /// Удаляет профиль из той области, где он лежит — из обеих, если
    /// одноимённые есть и там и там.
    func removeProfile(named name: String, app: AppEnvironment, source: DataSource) {
        var updated = source
        let removed = (profiles + sharedProfiles).filter { $0.name == name }.map(\.id)
        updated.tableProfiles = profiles.filter { $0.name != name }
        let shared = sharedProfiles.filter { $0.name != name }
        // Назначения на удалённый профиль снимаются здесь же: оставленные,
        // они молча превратились бы в «подбором, как раньше», и человек узнал
        // бы об этом по результату следующего прогона.
        //
        // Только у этого источника: у чужих источников назначения на общий
        // профиль тоже перестанут работать, но снять их отсюда — значит
        // править чужие настройки вслепую. Прогон скажет об этом словами:
        // «профиль не найден — подбором по колонкам».
        updated.tableProfileAssignments = assignments.filter { !removed.contains($0.value) }
        persist(updated, shared: shared, app: app)
        app.log.record(.warning, "Таблицы", "Источник «\(source.name)»: профиль «\(name)» удалён")
    }

    // MARK: - Назначение профиля файлу

    /// Закрепляет профиль за файлом. `nil` — вернуть подбор по колонкам.
    func assign(profileID: UUID?, to relativePath: String, app: AppEnvironment, source: DataSource) {
        var updated = source
        updated.tableProfiles = profiles
        updated.tableProfileAssignments = assignments
        if let profileID {
            updated.tableProfileAssignments[relativePath] = profileID
        } else {
            updated.tableProfileAssignments.removeValue(forKey: relativePath)
        }
        persist(updated, app: app)

        let name = profileID.flatMap { id in allProfiles.first { $0.id == id }?.name }
        app.log.record(
            .info, "Таблицы",
            name.map { "Источник «\(source.name)»: файлу \(relativePath) назначен профиль «\($0)»" }
                ?? "Источник «\(source.name)»: с файла \(relativePath) снято назначение профиля — снова подбор по колонкам"
        )
    }

    /// Что показывать в списке файлов рядом с выбором профиля.
    func assignmentTitle(for relativePath: String) -> String? {
        assignments[relativePath].flatMap { id in allProfiles.first { $0.id == id }?.name }
    }

    /// Записывает правку и в источник, и — когда она была — в общий список.
    ///
    /// `shared == nil` означает «общие не трогаем»: назначение файла профилю
    /// или импорт в источник к ним отношения не имеют.
    private func persist(_ source: DataSource, shared: [TableProfile]? = nil, app: AppEnvironment) {
        profiles = source.tableProfiles
        assignments = source.tableProfileAssignments
        if let shared {
            sharedProfiles = shared
            app.settings.configuration.sharedTableProfiles = shared
        }
        app.settings.upsert(source: source)
    }

    // MARK: - Перенос профилей

    /// Выгружает в файл профили, которыми читается этот источник.
    ///
    /// Свои и общие вместе: на экране они одним списком, и файл, в котором
    /// половины из увиденного нет, — это ловушка. Область хранения при этом
    /// не переносится: на другой машине всё уляжется у источника, а сделать
    /// общим — отдельное решение, которое там принимают заново.
    func exportProfiles(_ app: AppEnvironment, source: DataSource) {
        let profiles = allProfiles
        guard !profiles.isEmpty else {
            errorMessage = String(localized: "Профилей нет ни у источника, ни у приложения — выгружать нечего.")
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "Экспорт профилей сопоставления")
        panel.nameFieldStringValue = "table-profiles.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let package = TableProfilePackage(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            sourceName: source.name,
            profiles: profiles
        )
        do {
            try TableProfileTransfer.encode(package).write(to: url, options: .atomic)
            infoMessage = String(localized: "Профилей выгружено: \(profiles.count) → \(url.lastPathComponent).")
            app.log.record(
                .success, "Таблицы",
                "Источник «\(source.name)»: экспорт профилей — \(profiles.count.plainDigits) в \(url.lastPathComponent)"
            )
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Таблицы")
        }
    }

    /// Читает файл профилей и сливает его с тем, что есть.
    ///
    /// Одноимённые заменяются, остальные добавляются, и об этом говорится
    /// поимённо: «импортировано 4» не отвечает на вопрос, что стало с тем,
    /// что было размечено вчера.
    func importProfiles(_ app: AppEnvironment, source: DataSource) {
        guard let url = ConnectionViewModel.chooseFile(
            title: String(localized: "Импорт профилей сопоставления"),
            message: String(localized: "Одноимённые профили будут заменены, остальные добавлены. Ничего не индексируется.")
        ) else { return }

        do {
            let package = try TableProfileTransfer.decode(try Data(contentsOf: url))
            let merged = TableProfileTransfer.merge(package.profiles, into: profiles)
            var updated = source
            updated.tableProfiles = merged.profiles
            updated.tableProfileAssignments = assignments
            persist(updated, app: app)

            var parts: [String] = []
            if !merged.added.isEmpty {
                parts.append(String(localized: "добавлены: \(merged.added.joined(separator: ", "))"))
            }
            if !merged.replaced.isEmpty {
                parts.append(String(localized: "заменены: \(merged.replaced.joined(separator: ", "))"))
            }
            infoMessage = parts.isEmpty
                ? String(localized: "В файле не оказалось профилей с именами — ничего не изменилось.")
                : String(localized: "Профили из \(url.lastPathComponent) — \(parts.joined(separator: "; ")).")
            app.log.record(
                .success, "Таблицы",
                "Источник «\(source.name)»: импорт профилей из \(url.lastPathComponent) — "
                + "добавлено \(merged.added.count.plainDigits), заменено \(merged.replaced.count.plainDigits)"
            )
        } catch {
            errorMessage = app.describe(error)
            app.report(error, category: "Таблицы")
        }
    }
}
