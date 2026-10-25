import Foundation

/// What the user can do about a file that did not produce text.
///
/// The *suggested* action, not the only one: the diagnostics screen always
/// offers «повторить» and «исключить», because a file can fail for a reason the
/// app classified wrongly. This says which action is worth trying first, and it
/// is derived from the error rather than guessed in the view.
public enum FileRemedy: String, Codable, Sendable, CaseIterable {
    /// A scan. Turning recognition on for the source is the fix.
    case enableOCR
    /// Locked. A password, kept in the Keychain, is the fix.
    case password
    /// Something that may well work next time: a timeout, an application that
    /// was busy. Nothing to change first.
    case retry
    /// Nothing to try. DRM, an unsupported format, a file with no text in it —
    /// the honest offer is to stop asking about it.
    case exclude
    /// Правило источника не ведёт файл ни в одну коллекцию: файл
    /// прочитать можно, но класть его некуда. Чинится правилом, а не файлом.
    case fixRule
    /// Лист таблицы, которому не подошёл ни один профиль, — при выключенном
    /// «записывать текстом». Раньше значился «сбоем чтения» с
    /// советом повторить, а повтор не меняет ничего: нужен профиль или текст.
    case chooseProfile

    public var title: String {
        switch self {
        case .enableOCR: return String(localized: "Включить распознавание")
        case .password: return String(localized: "Ввести пароль")
        case .retry: return String(localized: "Повторить")
        case .exclude: return String(localized: "Исключить из источника")
        case .fixRule: return String(localized: "Поправить правило источника")
        case .chooseProfile: return String(localized: "Записывать такие листы текстом")
        }
    }

    /// Название **разряда находок**, а не действия над ними.
    ///
    /// На вкладке диагностики по нему выбирают разом всё одного рода:
    /// «выбрать все сканы» — это про то, чем файлы похожи, а «Включить
    /// распознавание» — про то, что с ними делать, и одним словом эти две
    /// вещи называть нельзя.
    public var groupTitle: String {
        switch self {
        case .enableOCR: return String(localized: "Сканы без текста")
        case .password: return String(localized: "Под паролем")
        case .retry: return String(localized: "Сбой чтения")
        case .exclude: return String(localized: "Читать нечем")
        case .fixRule: return String(localized: "Не размещены")
        case .chooseProfile: return String(localized: "Листы без профиля")
        }
    }
}

/// One file that needs a decision, with the reason it needs one.
///
/// Persisted in the manifest so the diagnostics screen shows the state after the
/// last run instead of re-reading a folder of documents to find out what already
/// failed once.
public struct FileProblem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    /// The wording the run put in the report — the same string, so the screen
    /// and the log cannot disagree.
    public var reason: String
    public var remedy: FileRemedy
    public var noticedAt: Date

    public init(relativePath: String, reason: String, remedy: FileRemedy, noticedAt: Date = Date()) {
        self.relativePath = relativePath
        self.reason = reason
        self.remedy = remedy
        self.noticedAt = noticedAt
    }

    /// Which action to suggest for an error.
    ///
    /// `wrongPassword` maps to `.password` as well: the fix is still a password,
    /// just not the one already stored, and the reason text says so.
    public static func remedy(for error: Error) -> FileRemedy {
        guard let extraction = error as? ExtractionError else { return .retry }
        switch extraction {
        case .noTextLayer(let looksLikeScan):
            // A PDF with no text and no sign of being a scan has nothing to
            // recognise — offering OCR there would waste minutes per file.
            return looksLikeScan ? .enableOCR : .exclude
        case .passwordProtected, .wrongPassword:
            return .password
        case .timedOut, .applicationUnavailable:
            return .retry
        case .drmProtected, .unsupportedFormat, .corrupted, .empty, .tooLarge:
            return .exclude
        }
    }
}

/// Файлы папки, не взятые в источник по расширению.
///
/// Обход папки берёт только расширения из списка источника, и всё прочее
/// раньше отбрасывалось молча: архив приложений, презентация `.ppt`, сканы
/// в `.jpg` не появлялись ни в плане, ни в итоге, ни в журнале. Человек
/// видел «новых 2, пропущено 6» и не знал о двух десятках файлов, которых
/// в базе нет. Теперь они сосчитаны по расширениям — поштучно не нужны:
/// у папки со сканами их сотни, и решение по ним одно на расширение.
///
/// Скрытые файлы, служебные `~$…` и ссылки сюда не входят: это не файлы
/// человека, и сообщать о них — шум.
public struct IgnoredFiles: Hashable, Sendable {
    /// Расширение без точки, в нижнем регистре (`""` — без расширения) →
    /// число файлов.
    public var byExtension: [String: Int]

    public init(byExtension: [String: Int] = [:]) {
        self.byExtension = byExtension
    }

    public var isEmpty: Bool { byExtension.isEmpty }
    public var total: Int { byExtension.values.reduce(0, +) }

    /// Формат, который сборка не читает вовсе: добавить его в список
    /// источника не поможет.
    public static func isUnsupported(_ fileExtension: String) -> Bool {
        !TextExtractor.supportedExtensions.contains(fileExtension)
    }

    /// Не читается вовсе — по убыванию числа файлов.
    public var unsupported: [(fileExtension: String, count: Int)] {
        sorted.filter { Self.isUnsupported($0.fileExtension) }
    }

    /// Читается, но в списке источника не выбрано.
    public var notSelected: [(fileExtension: String, count: Int)] {
        sorted.filter { !Self.isUnsupported($0.fileExtension) }
    }

    private var sorted: [(fileExtension: String, count: Int)] {
        byExtension.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// «.ppt» или «без расширения».
    public static func title(_ fileExtension: String) -> String {
        fileExtension.isEmpty ? String(localized: "без расширения") : ".\(fileExtension)"
    }

    /// Причина одним словом — для строки в таблице.
    public static func reason(_ fileExtension: String) -> String {
        isUnsupported(fileExtension)
            ? String(localized: "формат не поддерживается")
            : String(localized: "расширение не выбрано в источнике")
    }

    /// «не взяты по расширению 19 файлов: формат не поддерживается — .jpg 14,
    /// .ppt 3; не выбрано в источнике — .md 2». Расширений в строке не больше
    /// шести на группу: остальное — в окне итога.
    public var line: String? {
        guard !isEmpty else { return nil }
        func list(_ items: [(fileExtension: String, count: Int)]) -> String {
            let shown = items.prefix(6).map { "\(Self.title($0.fileExtension)) \($0.count.plainDigits)" }
            let rest = items.count - shown.count
            return (shown + (rest > 0 ? [String(localized: "ещё \(rest.plainDigits)")] : [])).joined(separator: ", ")
        }
        var groups: [String] = []
        if !unsupported.isEmpty {
            groups.append(String(localized: "формат не поддерживается — \(list(unsupported))"))
        }
        if !notSelected.isEmpty {
            groups.append(String(localized: "не выбрано в источнике — \(list(notSelected))"))
        }
        let files = RussianCount.phrase(total, "файл", "файла", "файлов")
        return String(localized: "не взяты по расширению \(files): \(groups.joined(separator: "; "))")
    }
}
