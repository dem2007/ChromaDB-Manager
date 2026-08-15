import Foundation

/// Что нашлось на странице релизов приложения.
public struct AppRelease: Equatable, Sendable {
    /// Версия из метки: `v0.1.5` → `0.1.5`.
    public var version: String
    /// Название релиза — то, что человек увидит заголовком.
    public var title: String
    /// Описание изменений как есть, в Markdown, как его написали в релизе.
    public var notes: String
    /// Страница релиза. Открывается в браузере — скачивать и ставить
    /// приложение само не будет никогда.
    public var pageURL: URL
    public var publishedAt: Date?

    public init(version: String, title: String, notes: String, pageURL: URL, publishedAt: Date? = nil) {
        self.version = version
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }
}

/// Итог проверки. Отдельным типом, а не «версия или nil»: «обновления нет»
/// и «проверить не удалось» — разные новости, и путать их нельзя.
public enum AppUpdateOutcome: Equatable, Sendable {
    case upToDate(current: String)
    case available(AppRelease, current: String)
    /// Версия приложения неизвестна: так бывает вне бандла, при запуске
    /// из `swift run`. Сравнивать не с чем, и врать об этом не надо.
    case unknownCurrentVersion(latest: AppRelease?)

    public var release: AppRelease? {
        switch self {
        case .available(let release, _): return release
        case .unknownCurrentVersion(let release): return release
        case .upToDate: return nil
        }
    }
}

/// Проверка обновлений **приложения** — не движка: у того свой источник
/// и свой экран.
///
/// Правило то же, что у движка: **не молча при старте**. Проверка идёт либо
/// по нажатию, либо когда галочка включена явно; по умолчанию она выключена.
/// Причина не в трафике, а в доверии: программа, которая при каждом запуске
/// сама куда-то ходит, обязана об этом спрашивать.
///
/// **Встроенного автообновления не будет никогда.** Проверка показывает, что
/// вышло, и открывает страницу релиза; скачивает и ставит человек.
public struct AppUpdateChecker: Sendable {
    /// Репозиторий, куда публикуются версии.
    public static let repository = "dem2007/ChromaDB-Manager"

    /// Откуда берётся список релизов. Репозиторий уже замкнут здесь, отдельным
    /// полем не хранится: поле, которое никто не читает, обещает связь,
    /// которой нет.
    private let releases: @Sendable () async throws -> [GitHubReleaseClient.Release]

    public init(repository: String = AppUpdateChecker.repository) {
        let client = GitHubReleaseClient(repository: repository)
        self.releases = { try await client.releases() }
    }

    /// Для тестов: список релизов подставляется, сеть не трогается.
    public init(releases: @escaping @Sendable () async throws -> [GitHubReleaseClient.Release]) {
        self.releases = releases
    }

    /// Версия работающего приложения. Вне бандла её нет — и это честный `nil`,
    /// а не «0.0.0».
    public static func currentVersion(bundle: Bundle = .main) -> String? {
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return nil }
        return version
    }

    public func check(currentVersion: String? = AppUpdateChecker.currentVersion()) async throws -> AppUpdateOutcome {
        let newest = Self.newest(in: try await releases())
        guard let currentVersion else {
            return .unknownCurrentVersion(latest: newest)
        }
        guard let newest else {
            return .upToDate(current: currentVersion)
        }
        return Self.isNewer(newest.version, than: currentVersion)
            ? .available(newest, current: currentVersion)
            : .upToDate(current: currentVersion)
    }

    /// Самый свежий выпущенный релиз. Черновики и предрелизы пропускаются:
    /// предложить человеку то, что автор ещё не считает готовым, — плохая
    /// услуга.
    public static func newest(in releases: [GitHubReleaseClient.Release]) -> AppRelease? {
        releases
            .filter { !($0.draft ?? false) && !($0.prerelease ?? false) }
            .compactMap(makeRelease)
            .max { left, right in
                guard let a = SemanticVersion(left.version), let b = SemanticVersion(right.version) else {
                    return left.version < right.version
                }
                return a < b
            }
    }

    static func makeRelease(_ release: GitHubReleaseClient.Release) -> AppRelease? {
        guard let page = release.html_url, let url = URL(string: page) else { return nil }
        let version = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppRelease(
            version: version,
            title: (title?.isEmpty == false ? title! : release.tag_name),
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: url,
            publishedAt: release.published_at.flatMap(ISO8601DateFormatter().date(from:))
        )
    }

    /// Строгое «новее». Равные версии и версии старше текущей обновлением
    /// не считаются: локальная сборка обычно опережает опубликованную,
    /// и предлагать «обновиться» назад нельзя.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = SemanticVersion(candidate), let old = SemanticVersion(current) else {
            return candidate != current
        }
        return old < new
    }
}
