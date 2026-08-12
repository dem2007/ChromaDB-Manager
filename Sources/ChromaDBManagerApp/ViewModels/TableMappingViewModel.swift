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
    /// Какой профиль назначен файлу: путь → id профиля.
    @Published var assignments: [String: UUID] = [:]
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// Which saved profile the open sheet matched, if any.
    @Published var matchNote: String?

    /// 8 asks for the first twenty rows.
    static let previewRowCount = 20

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

    /// Варианты, которые сохранятся в профиле: по одному на лист, который
    /// человек размечал как таблицу или как документ.
    ///
    /// Листы в режиме «пропустить» вариантами не становятся: вариант — это
    /// указание, как читать, а «не читать» — это его отсутствие.
    var variantsToSave: [TableProfile.Variant] {
        sheets.compactMap { entry in
            guard let mapping = drafts[entry.sheet.name], mapping.mode != .skip else { return nil }
            return TableProfile.Variant(
                sheets: sheetSelection(for: entry.sheet.name),
                mapping: mapping
            )
        }
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
                let assigned = openedPath.flatMap { assignments[$0] }
                    .flatMap { id in profiles.first { $0.id == id } }

                for (index, entry) in sheets.enumerated() {
                    let suggestion = TableMapping.suggested(sheetName: entry.sheet.name, shape: entry.shape)
                    if let assigned,
                       let variant = assigned.variants.first(where: {
                           $0.sheets.admits(sheetName: entry.sheet.name, index: index)
                       }) {
                        drafts[entry.sheet.name] = variant.mapping
                        sheetSelections[entry.sheet.name] = variant.sheets
                        if entry.sheet.name == selectedSheet {
                            matchNote = String(localized: "профиль «\(assigned.name)» назначен этому файлу вручную")
                            profileName = assigned.name
                        }
                        continue
                    }

                    let match = TableProfileMatcher.match(
                        profiles: profiles,
                        sheetName: entry.sheet.name,
                        sheetIndex: index,
                        columns: entry.shape.columns
                    )
                    switch match {
                    case .matched(let profile, let variant):
                        drafts[entry.sheet.name] = variant.mapping
                        sheetSelections[entry.sheet.name] = variant.sheets
                        if entry.sheet.name == selectedSheet {
                            matchNote = String(localized: "лист узнан профилем «\(profile.name)»")
                            profileName = profile.name
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
        return String(localized: "Без ключевой колонки идентификатор строки считается от её содержимого: вставка строк безопасна, но любая правка создаёт новый документ, а старый придётся удалить вручную. Выберите колонку с артикулом, кодом или адресом почты, если такая есть.")
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
        if mapping.mode == .document, shape.mode == .dataTable {
            mapping.mode = .dataTable
            note += " " + String(localized: "Под ними однородные строки — режим переключён на «Таблица данных».")
        }
        drafts[sheetName] = mapping
        infoMessage = note
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
        let variants = variantsToSave
        guard !variants.isEmpty else {
            errorMessage = String(localized: "Сохранять нечего: все листы книги стоят «пропустить».")
            return
        }

        var updated = source
        updated.tableProfiles = profiles
        let profile = TableProfile(
            id: profiles.first { $0.name == name }?.id ?? UUID(),
            name: name,
            variants: variants
        )
        if let index = updated.tableProfiles.firstIndex(where: { $0.id == profile.id }) {
            updated.tableProfiles[index] = profile
        } else {
            updated.tableProfiles.append(profile)
        }
        // Открытый файл сразу закрепляется за этим профилем: человек только что
        // разметил именно его, и заставлять его после этого выбирать профиль
        // в списке значило бы спрашивать о том, что уже сказано.
        if let path = openedPath { updated.tableProfileAssignments[path] = profile.id }

        persist(updated, app: app)
        app.log.record(
            .info, "Таблицы",
            "Источник «\(source.name)»: сохранён профиль «\(name)» — вариантов \(variants.count.plainDigits) "
            + "(\(variants.map { "\($0.title): \($0.mapping.columns.count) колонок" }.joined(separator: "; ")))"
        )
        infoMessage = variants.count == 1
            ? String(localized: "Профиль «\(name)» сохранён. Он применится к файлам с тем же набором колонок; файл с другим набором попадёт в «требуют решения».")
            : String(localized: "Профиль «\(name)» сохранён: вариантов \(variants.count), по одному на лист. Каждый лист читается своим — тот же файл целиком.")
    }

    func removeProfile(named name: String, app: AppEnvironment, source: DataSource) {
        var updated = source
        let removed = profiles.filter { $0.name == name }.map(\.id)
        updated.tableProfiles = profiles.filter { $0.name != name }
        // Назначения на удалённый профиль снимаются здесь же: оставленные,
        // они молча превратились бы в «подбором, как раньше», и человек узнал
        // бы об этом по результату следующего прогона.
        updated.tableProfileAssignments = assignments.filter { !removed.contains($0.value) }
        persist(updated, app: app)
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

        let name = profileID.flatMap { id in profiles.first { $0.id == id }?.name }
        app.log.record(
            .info, "Таблицы",
            name.map { "Источник «\(source.name)»: файлу \(relativePath) назначен профиль «\($0)»" }
                ?? "Источник «\(source.name)»: с файла \(relativePath) снято назначение профиля — снова подбор по колонкам"
        )
    }

    /// Что показывать в списке файлов рядом с выбором профиля.
    func assignmentTitle(for relativePath: String) -> String? {
        assignments[relativePath].flatMap { id in profiles.first { $0.id == id }?.name }
    }

    private func persist(_ source: DataSource, app: AppEnvironment) {
        profiles = source.tableProfiles
        assignments = source.tableProfileAssignments
        app.settings.upsert(source: source)
    }

    // MARK: - Перенос профилей

    /// Выгружает профили источника в файл.
    func exportProfiles(_ app: AppEnvironment, source: DataSource) {
        guard !profiles.isEmpty else {
            errorMessage = String(localized: "У источника нет ни одного профиля — выгружать нечего.")
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
