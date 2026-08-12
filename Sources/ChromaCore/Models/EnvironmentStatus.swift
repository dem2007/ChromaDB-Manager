import Foundation

public struct PythonInterpreter: Identifiable, Hashable, Codable {
    public var path: String
    public var version: String
    public var isManagedVenv: Bool
    public var isExternallyManaged: Bool

    public var id: String { path }

    public init(path: String, version: String, isManagedVenv: Bool = false, isExternallyManaged: Bool = false) {
        self.path = path
        self.version = version
        self.isManagedVenv = isManagedVenv
        self.isExternallyManaged = isExternallyManaged
    }

    public var displayName: String {
        if isManagedVenv { return String(localized: "venv приложения — Python \(version)") }
        return "\(path) — Python \(version)"
    }
}

/// Rendered as a uniform coloured dot in the UI (see `StatusDot`).
public enum CheckState: String, Codable {
    case ok, warning, missing, unknown, checking
}

public struct CheckItem: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var state: CheckState
    public var detail: String
    public var hint: String?

    public init(id: String, title: String, state: CheckState, detail: String, hint: String? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
        self.hint = hint
    }
}

/// Which flavour of the engine was found.
public enum EngineFlavor: String {
    case standalone
    case venv
    case unknown

    public var title: String {
        switch self {
        case .standalone: return String(localized: "автономный CLI")
        case .venv: return String(localized: "venv приложения")
        case .unknown: return String(localized: "внешняя установка")
        }
    }
}

/// Snapshot of everything the «Статус окружения» screen shows.
///
/// The engine, not Python, is the requirement: with the standalone CLI there is
/// no Python involved at all, so Python/pip are reported as information for
/// install path B only.
public struct EnvironmentStatus {
    public var chromaCLIPath: String?
    public var chromaCLIVersion: String?
    public var engineFlavor: EngineFlavor = .unknown
    public var latestCLIVersion: String?

    public var interpreters: [PythonInterpreter] = []
    public var activeInterpreter: PythonInterpreter?
    public var pipVersion: String?
    public var chromadbPackageVersion: String?
    public var latestPyPIVersion: String?

    public var homebrewPath: String?
    public var checkedAt: Date?
    public var updateChecked = false

    public init() {}

    public var isEngineInstalled: Bool { chromaCLIPath != nil }
    /// The CLI is what starts servers, so it gates local databases and profiles.
    public var canRunServer: Bool { chromaCLIPath != nil }

    public var installedVersion: String? {
        chromaCLIVersion.map { Self.numericVersion(from: $0) } ?? chromadbPackageVersion
    }

    public var latestVersion: String? {
        engineFlavor == .venv ? latestPyPIVersion : latestCLIVersion
    }

    public var updateAvailable: Bool {
        guard let installed = installedVersion.flatMap(SemanticVersion.init),
              let latest = latestVersion.flatMap(SemanticVersion.init) else { return false }
        return installed < latest
    }

    /// "chroma 1.4.4" → "1.4.4". Takes the first dotted number in the string,
    /// so stray text around it cannot poison the version comparison.
    public static func numericVersion(from raw: String) -> String {
        if let range = raw.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) {
            return String(raw[range])
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing has been measured yet: the screen must not claim anything is
    /// missing, and must not change its row count once the probe finishes.
    public var hasBeenProbed: Bool { checkedAt != nil }

    /// The rows are fixed — same ids, same order, always five — so the screen
    /// does not reflow when a probe completes.
    private static let rows: [(id: String, title: String)] = [
        ("engine", String(localized: "Движок ChromaDB")),
        ("updates", String(localized: "Проверка обновлений")),
        ("python", String(localized: "Python 3")),
        ("pip", String(localized: "pip")),
        ("package", String(localized: "Пакет chromadb")),
    ]

    /// Проверки, которые относятся к выбранному способу установки.
    ///
    /// Python, pip и пакет `chromadb` нужны только тому, кто ставит движок
    /// Python-пакетом. Автономному CLI они не нужны вовсе — и «Python 3 не
    /// найден» оранжевой строкой посреди проверок означало у него ровно
    /// ничего, кроме тревоги. Поэтому приписок «(путь B)» в названиях больше
    /// нет: строка либо относится к делу, либо её на экране нет.
    public func items(for path: EngineInstallPath) -> [CheckItem] {
        switch path {
        case .standalone:
            let shown: Set<String> = ["engine", "updates"]
            return items.filter { shown.contains($0.id) }
        case .managedVenv:
            return items
        }
    }

    /// Static text, shown in both states so the row does not change height
    /// when the probe finishes.
    private static let updatesHint = String(localized: "Проверка обращается к GitHub Releases или PyPI и выполняется только по вашей команде.")

    public var items: [CheckItem] {
        guard hasBeenProbed else {
            return Self.rows.map { row in
                CheckItem(
                    id: row.id,
                    title: row.title,
                    state: .checking,
                    detail: String(localized: "Проверяется…"),
                    hint: row.id == "updates" ? Self.updatesHint : nil
                )
            }
        }

        var result: [CheckItem] = []

        if let cli = chromaCLIPath {
            let state: CheckState = updateAvailable ? .warning : .ok
            var detail = "\(chromaCLIVersion ?? "версия неизвестна") · \(engineFlavor.title)\n\(cli)"
            if updateAvailable, let latest = latestVersion {
                detail += "\n" + String(localized: "Доступна версия \(latest)")
            }
            result.append(CheckItem(id: "engine", title: Self.rows[0].title, state: state, detail: detail))
        } else {
            result.append(CheckItem(
                id: "engine",
                title: Self.rows[0].title,
                state: .missing,
                detail: String(localized: "Chroma CLI не найден"),
                hint: String(localized: "Выберите способ установки ниже. Автономный CLI не требует Python.")
            ))
        }

        result.append(CheckItem(
            id: "updates",
            title: Self.rows[1].title,
            state: updateChecked ? (updateAvailable ? .warning : .ok) : .unknown,
            detail: updateChecked
                ? (latestVersion.map { String(localized: "Последняя доступная: \($0)") } ?? String(localized: "Не удалось определить"))
                : String(localized: "Не проверялась"),
            hint: updateChecked ? nil : Self.updatesHint
        ))

        if let python = activeInterpreter {
            result.append(CheckItem(
                id: "python",
                title: Self.rows[2].title,
                state: .ok,
                detail: python.displayName
            ))
        } else {
            result.append(CheckItem(
                id: "python",
                title: Self.rows[2].title,
                state: .warning,
                detail: String(localized: "Не найден"),
                hint: String(localized: "Нужен выбранному способу установки: venv создаётся его средствами. Поставить Python можно на вкладке «Установка».")
            ))
        }

        // pip and the package rows stay in place even when they do not apply —
        // a row that appears later would reflow the whole card.
        if activeInterpreter == nil {
            result.append(CheckItem(
                id: "pip",
                title: Self.rows[3].title,
                state: .unknown,
                detail: String(localized: "Нет интерпретатора для проверки")
            ))
        } else {
            result.append(CheckItem(
                id: "pip",
                title: Self.rows[3].title,
                state: pipVersion == nil ? .warning : .ok,
                detail: pipVersion ?? String(localized: "недоступен для выбранного интерпретатора"),
                hint: pipVersion == nil ? String(localized: "Обычно чинится командой python3 -m ensurepip --upgrade.") : nil
            ))
        }

        if let package = chromadbPackageVersion {
            result.append(CheckItem(
                id: "package",
                title: Self.rows[4].title,
                state: .ok,
                detail: String(localized: "\(package) — в venv приложения")
            ))
        } else {
            result.append(CheckItem(
                id: "package",
                title: Self.rows[4].title,
                state: .unknown,
                detail: engineFlavor == .standalone
                    ? String(localized: "Не используется: движок стоит автономным бинарником")
                    : String(localized: "Не установлен в venv приложения")
            ))
        }

        return result
    }
}
