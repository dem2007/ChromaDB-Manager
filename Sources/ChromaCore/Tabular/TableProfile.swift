import Foundation

/// Which sheets of a file a variant speaks for.
public enum SheetSelection: Codable, Hashable, Sendable {
    /// Every sheet whose headers match — the usual case for a folder of files
    /// that all look alike.
    case anyMatching
    /// Only sheets with these names.
    case named([String])
    /// Only the first sheet, whatever it is called. Export tools name the sheet
    /// after the report, so the name changes while the shape does not.
    case first

    public func admits(sheetName: String, index: Int) -> Bool {
        switch self {
        case .anyMatching: return true
        case .named(let names): return names.contains(sheetName)
        case .first: return index == 0
        }
    }

    public var title: String {
        switch self {
        case .anyMatching: return String(localized: "любой подходящий лист")
        case .named(let names): return String(localized: "листы: \(names.joined(separator: ", "))")
        case .first: return String(localized: "первый лист")
        }
    }
}

/// Где живёт профиль сопоставления.
///
/// Профили начинались как принадлежность источника, и для папки, которую
/// индексируют по расписанию, это правильно: разметка — часть её настройки.
/// Но одинаковые книги приходят в разные папки, и разметив «отчёт ФЭО» в одном
/// источнике, человек не находит его в другом — список там пуст, и разметку
/// приходится повторять слово в слово.
///
/// Поэтому выбор делается при сохранении, а не решается за человека: у
/// источника — как было, у приложения — видно всем источникам.
public enum TableProfileScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Профиль виден только файлам этого источника.
    case source
    /// Профиль виден всем источникам приложения.
    case application

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return String(localized: "у этого источника")
        case .application: return String(localized: "у всего приложения")
        }
    }

    public var explanation: String {
        switch self {
        case .source:
            return String(localized: "Профиль виден только файлам этого источника — как было раньше.")
        case .application:
            return String(localized: "Профиль виден всем источникам: та же книга в другой папке разметится сама. Свой профиль источника с таким же именем всё равно главнее.")
        }
    }
}

/// A saved mapping, attached to a source.
///
/// A folder that indexes itself on a timer cannot stop to ask which column is
/// the key, so the answer has to be recorded once and recognised again.
///
/// **Профиль описывает книгу целиком, а не один лист.** В рабочей
/// книге листы разные: «Товары и услуги» — это перечень с артикулами,
/// «ФЭО» рядом с ним — совсем другая таблица с другими колонками и другим
/// ключом. Пока профиль хранил одно сопоставление, такую книгу нельзя было
/// описать вовсе: сохранение второго листа либо затирало первый, либо
/// заводило второй профиль, который потом сам претендовал на первый лист.
/// Поэтому внутри профиля — варианты, у каждого свой выбор листов и своё
/// сопоставление.
public struct TableProfile: Codable, Hashable, Sendable, Identifiable {
    /// Один разбор: какие листы и как.
    public struct Variant: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var sheets: SheetSelection
        public var mapping: TableMapping

        public init(id: UUID = UUID(), sheets: SheetSelection = .anyMatching, mapping: TableMapping) {
            self.id = id
            self.sheets = sheets
            self.mapping = mapping
        }

        /// The set of headers this variant was built for — its identity.
        public var headerSignature: Set<String> { TableProfile.signature(of: mapping.columns) }

        /// Колонки, без которых разбор не имеет смысла: текст документа
        /// и ключ строки.
        ///
        /// Всё остальное — метаданные, и их отсутствие меняет не смысл записи,
        /// а состав фильтров по ней.
        public var requiredColumns: [String] {
            var required = mapping.textColumns
            if let key = mapping.keyColumn, !required.contains(key) { required.append(key) }
            return required
        }

        /// Берётся ли этот вариант за лист с такими колонками.
        ///
        /// **Не точное совпадение набора, и это исправление, а не послабление.**
        /// Точное равенство означало, что файл, где колонка называется годом
        /// («2025», «2026»), не совпадёт ни с одним профилем: у отчёта за
        /// 2026–2027 годы другие, хотя таблица та же самая. Такие файлы уходили
        /// в «требуют решения» целиком — при том что от недостающей колонки
        /// с суммой за 2030 год теряется один фильтр, а не смысл строки.
        ///
        /// Поэтому обязательны только текст и ключ: без них запись не о чем.
        /// Недостающие метаданные называются в отчёте, лишние колонки файла
        /// не мешают — они просто не размечены.
        /// - Parameter strict: требовать полного совпадения набора колонок.
        ///   **Подбор строг, назначение — нет**, и это не мелочь: подбор
        ///   угадывает, чем читать лист, и ошибка в догадке пишет в базу
        ///   документы с чужой разметкой. Назначение — ответ человека, и
        ///   спорить с ним из-за колонки со сроком «2030» незачем.
        public func accepts(columns: [String], strict: Bool = true) -> Acceptance {
            // Режимы «документ» и «не индексировать» колонок не разбирают:
            // первому нужен лист целиком, второму — ничего.
            guard mapping.mode == .dataTable else {
                return Acceptance(matches: true, missing: [], extra: [], exact: true)
            }
            let present = TableProfile.signature(of: columns)
            let missingRequired = requiredColumns.filter { !present.contains(TableProfile.normalised($0)) }
            let missing = mapping.columns.filter { !present.contains(TableProfile.normalised($0)) }
            let extra = columns.filter { !headerSignature.contains(TableProfile.normalised($0)) }
            let exact = missing.isEmpty && extra.isEmpty
            return Acceptance(
                matches: strict ? exact : (missingRequired.isEmpty && !columns.isEmpty),
                missing: missing,
                extra: extra,
                exact: exact
            )
        }

        /// Чем кончилась примерка варианта к листу.
        public struct Acceptance: Hashable, Sendable {
            public var matches: Bool
            /// Колонки профиля, которых в файле нет. При `matches` — только
            /// метаданные: без текста и ключа вариант не берётся вовсе.
            public var missing: [String]
            /// Колонки файла, которых нет в профиле: они останутся неразмеченными.
            public var extra: [String]
            /// Набор совпал полностью — такой вариант предпочитается неточному.
            public var exact: Bool
        }

        /// Чем этот вариант назвать в списке: именем листа, если он назван,
        /// иначе — по выбору листов.
        public var title: String {
            if case .named(let names) = sheets, let first = names.first, !first.isEmpty {
                return first
            }
            return sheets.title
        }
    }

    public var id: UUID
    public var name: String
    public var variants: [Variant]

    public init(id: UUID = UUID(), name: String, variants: [Variant]) {
        self.id = id
        self.name = name
        self.variants = variants
    }

    /// Профиль из одного варианта — тот же вызов, что был до.
    public init(
        id: UUID = UUID(),
        name: String,
        sheets: SheetSelection = .anyMatching,
        mapping: TableMapping
    ) {
        self.init(id: id, name: name, variants: [Variant(sheets: sheets, mapping: mapping)])
    }

    // MARK: - Чтение

    /// Вариант, который берётся за этот лист, — или `nil`, если ни один
    /// не про него.
    ///
    /// Совпадение по набору колонок **и** по выбору листов: вариант «листы:
    /// ФЭО» не должен разбирать «Товары и услуги», даже если колонки сошлись.
    public func variant(forSheet sheetName: String, index: Int, columns: [String]) -> Variant? {
        variants(claiming: sheetName, index: index, columns: columns).first
    }

    /// Все варианты, готовые взять этот лист. Больше одного — профиль собран
    /// так, что сам себе противоречит, и выбирать за человека нельзя.
    ///
    /// Точное совпадение набора колонок идёт первым: когда в книге есть и
    /// точный вариант, и подходящий с оговорками, брать надо точный.
    public func variants(claiming sheetName: String, index: Int, columns: [String], strict: Bool = true) -> [Variant] {
        let admitting = variants.filter { $0.sheets.admits(sheetName: sheetName, index: index) }
        let accepted = admitting.compactMap { variant -> (Variant, Variant.Acceptance)? in
            let acceptance = variant.accepts(columns: columns, strict: strict)
            return acceptance.matches ? (variant, acceptance) : nil
        }
        // Точные вперёд неточных — но **все** точные: два одинаково точных
        // варианта на один лист это спор профиля с самим собой, и решать его
        // за человека нельзя.
        let exact = accepted.filter(\.1.exact)
        return (exact.isEmpty ? accepted : exact).map(\.0)
    }

    /// Строка для списка: сколько вариантов и про какие листы.
    public var summary: String {
        if variants.count == 1, let only = variants.first {
            return String(localized: "\(only.mapping.columns.count) колонок · \(only.sheets.title)")
        }
        return String(localized: "вариантов: \(variants.count) — \(variants.map(\.title).joined(separator: ", "))")
    }

    /// Строки заголовков, встречающиеся в профиле, — по ним подбор пробует
    /// прочитать шапку не с первой строки.
    public var headerRows: [Int] { variants.compactMap(\.mapping.headerRow) }

    /// Case and spacing are not a different table; order is not either, because
    /// columns are resolved by title rather than by position.
    public static func signature(of columns: [String]) -> Set<String> {
        Set(columns.map(normalised))
    }

    static func normalised(_ column: String) -> String {
        column.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Профили, которыми читается источник: его собственные плюс общие.
    ///
    /// **Свой профиль главнее общего.** Одноимённый общий отбрасывается, а не
    /// добавляется вторым: два профиля на один лист — это `.ambiguous`, то есть
    /// лист не индексируется вовсе. Правка общего профиля не должна ломать
    /// источник, у которого есть своя версия той же разметки.
    ///
    /// По имени **и** по `id`: общий профиль мог быть сделан из профиля
    /// источника (при смене области хранения `id` сохраняется, чтобы уцелели
    /// назначения файлов), и тогда одинаковы оба.
    public static func resolved(own: [TableProfile], shared: [TableProfile]) -> [TableProfile] {
        let takenIDs = Set(own.map(\.id))
        let takenNames = Set(own.map { normalised($0.name) })
        return own + shared.filter { !takenIDs.contains($0.id) && !takenNames.contains(normalised($0.name)) }
    }
}

/// What matching a file's sheet against the saved profiles produced.
public enum TableProfileMatch: Hashable, Sendable {
    case matched(profile: TableProfile, variant: TableProfile.Variant)
    /// No profile fits. Carries what is closest and how it differs — «требуют
    /// решения» is only useful with the difference spelled out.
    case needsDecision(reason: String, closest: TableProfile?, missing: [String], extra: [String])
    /// More than one profile claims this sheet. Guessing between them would be
    /// arbitrary, so the user picks.
    case ambiguous([TableProfile])

    public var profile: TableProfile? {
        if case .matched(let profile, _) = self { return profile }
        return nil
    }

    /// Сопоставление, которое из этого следует.
    public var mapping: TableMapping? {
        if case .matched(_, let variant) = self { return variant.mapping }
        return nil
    }
}

/// What reading the header row produced.
public enum HeaderReadout: Hashable, Sendable {
    case headers([String])
    /// The row the user pointed at is not a header row, and guessing another
    /// would be worse than asking.
    case needsDecision(String)

    public var headers: [String]? {
        if case .headers(let titles) = self { return titles }
        return nil
    }
}

/// Matches a sheet's headers against a source's saved profiles.
///
/// The rule the section rests on: a file with a different set of columns is
/// **not** processed «как получится». Half-mapping it produces documents whose
/// metadata is silently missing the column somebody filters by — a failure that
/// only shows up as an empty search result weeks later.
public enum TableProfileMatcher {
    public static func match(
        profiles: [TableProfile],
        sheetName: String,
        sheetIndex: Int,
        columns: [String]
    ) -> TableProfileMatch {
        let signature = TableProfile.signature(of: columns)

        // Пара «профиль и его вариант»: претендует не профиль целиком, а
        // конкретный разбор внутри него.
        var claims: [(profile: TableProfile, variant: TableProfile.Variant)] = []
        for profile in profiles {
            for variant in profile.variants(claiming: sheetName, index: sheetIndex, columns: columns) {
                claims.append((profile, variant))
            }
        }
        if claims.count == 1 { return .matched(profile: claims[0].profile, variant: claims[0].variant) }
        if claims.count > 1 {
            // Одно и то же имя дважды означает профиль, спорящий сам с собой;
            // разные имена — два профиля на один лист. Человеку и то и другое
            // выглядит одинаково: выбирать должен он.
            return .ambiguous(claims.map(\.profile))
        }

        guard !profiles.isEmpty else {
            return .needsDecision(
                reason: String(localized: "для этого источника ещё нет профиля сопоставления"),
                closest: nil, missing: [], extra: []
            )
        }

        let admitting = profiles.filter { profile in
            profile.variants.contains { $0.sheets.admits(sheetName: sheetName, index: sheetIndex) }
        }

        // The closest by shared columns, so the offer can name the difference
        // instead of saying «не подошло».
        func overlap(_ profile: TableProfile) -> Int {
            profile.variants.map { $0.headerSignature.intersection(signature).count }.max() ?? 0
        }
        let pool = admitting.isEmpty ? profiles : admitting
        guard let closest = pool.max(by: { overlap($0) < overlap($1) }),
              let closestVariant = closest.variants.max(by: {
                  $0.headerSignature.intersection(signature).count < $1.headerSignature.intersection(signature).count
              })
        else {
            return .needsDecision(
                reason: String(localized: "ни один профиль не подошёл"),
                closest: nil, missing: [], extra: []
            )
        }

        let wanted = closestVariant.headerSignature
        let missing = closestVariant.mapping.columns.filter { !signature.contains(normalised($0)) }
        let extra = columns.filter { !wanted.contains(normalised($0)) }

        if missing.isEmpty, extra.isEmpty, !admitting.contains(where: { $0.id == closest.id }) {
            return .needsDecision(
                reason: String(localized: "профиль «\(closest.name)» подходит по колонкам, но не по выбору листов (\(closestVariant.sheets.title))"),
                closest: closest, missing: [], extra: []
            )
        }

        var parts: [String] = []
        if !missing.isEmpty { parts.append(String(localized: "нет колонок: \(missing.joined(separator: ", "))")) }
        if !extra.isEmpty { parts.append(String(localized: "лишние колонки: \(extra.joined(separator: ", "))")) }
        return .needsDecision(
            reason: String(localized: "набор колонок не совпадает с профилем «\(closest.name)» — \(parts.joined(separator: "; "))"),
            closest: closest, missing: missing, extra: extra
        )
    }

    static func normalised(_ column: String) -> String {
        column.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Headers read from the row the user pointed at.
    ///
    /// Multi-row and merged headers are **not** worked out automatically: the
    /// row number is given by hand, and a row that does not yield usable titles
    /// sends the sheet to «требуют решения» rather than producing columns named
    /// after whatever happened to be in it.
    public static func headers(in rows: [SheetRow], headerRow: Int) -> HeaderReadout {
        guard let row = rows.first(where: { $0.number == headerRow }) else {
            return .needsDecision(String(localized: "строки \(headerRow) в листе нет"))
        }
        let width = rows.map { $0.lastColumn + 1 }.max() ?? 0
        guard width > 0, !row.isEmpty else {
            return .needsDecision(String(localized: "строка \(headerRow) пуста — на строку заголовков не похоже"))
        }
        let titles = SheetModeDetector.headerTitles(row, width: width)
        // Titles that are all spreadsheet letters mean the row held no text at
        // all: columns called «A», «B», «C» are not a mapping anybody can use.
        let named = zip(titles, 0..<width).filter { $0.0 != XLSXReader.columnName($0.1) }
        guard !named.isEmpty else {
            return .needsDecision(String(localized: "в строке \(headerRow) нет названий колонок"))
        }
        // Повтор названий — не отказ, а различимые имена.
        //
        // Строку заголовков называет человек, и он смотрит в свой файл: там
        // шапка в два этажа, и «Стоимость» стоит под каждым годом. Отказ
        // означал, что выбрать такую строку нельзя вовсе — при том что
        // ниже по конвейеру коллизии имён и так разрешаются, просто
        // на входе стоял запрет.
        return .headers(uniqued(titles))
    }

    /// Повторяющиеся названия — с номерами: «Стоимость», «Стоимость (2)».
    ///
    /// Номер дописывается ко **второму** и дальше: первая колонка сохраняет
    /// имя, которое человек видит в файле, и переименовывать её незачем.
    /// Если имя с номером тоже занято — номер растёт, пока не найдётся
    /// свободное: в шапке бывает и «Стоимость», и «Стоимость (2)» сразу.
    public static func uniqued(_ titles: [String]) -> [String] {
        var seen: Set<String> = []
        return titles.map { title in
            guard !seen.insert(title).inserted else { return title }
            var number = 2
            while !seen.insert("\(title) (\(number))").inserted { number += 1 }
            return "\(title) (\(number))"
        }
    }
}
