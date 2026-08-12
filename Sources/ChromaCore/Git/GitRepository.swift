import Foundation

/// Что случилось с файлом между двумя коммитами.
public struct GitChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case added
        case modified
        /// Переименование — **не** «удалён и создан»: векторы у файла те же,
        /// и пересчитывать их не за что.
        case renamed(from: String)
        case deleted
        /// Тип файла сменился (обычный файл ↔ ссылка) — читаем заново.
        case typeChanged
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// Кто и когда трогал файл последним.
public struct GitFileInfo: Sendable, Hashable {
    public var lastCommitDate: String
    public var lastCommitAuthor: String

    public init(lastCommitDate: String, lastCommitAuthor: String) {
        self.lastCommitDate = lastCommitDate
        self.lastCommitAuthor = lastCommitAuthor
    }
}

/// Разговор с `git` о рабочей копии.
///
/// Репозиторий формально индексируется как папка, но плохо: обход заходит
/// в `.git` и в `node_modules`, хэширует десятки тысяч файлов, из которых
/// изменились единицы, а после переключения ветки переиндексирует всё. Git
/// знает ответы на эти вопросы дешевле, чем их можно вычислить обходом, — надо
/// только спросить.
public struct GitRepository: Sendable {
    public enum GitError: LocalizedError, Equatable {
        case notInstalled
        case notARepository(String)
        case failed(command: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return String(localized: "Git не установлен. Поставьте Command Line Tools (`xcode-select --install`) — до тех пор репозиторий индексируется как обычная папка.")
            case .notARepository(let path):
                return String(localized: "В папке \(path) нет git-репозитория.")
            case .failed(let command, let reason):
                return String(localized: "Команда \(command) не отработала: \(reason)")
            }
        }
    }

    public let root: URL
    private let executable: String
    private let runner: ShellRunner

    /// `nil`, если git не установлен: источник тогда деградирует до обычной
    /// папки с предупреждением, а не отказывается работать.
    public init?(root: URL, runner: ShellRunner = .shared, locator: ToolLocator = .shared) {
        // Абсолютный путь, никакого голого имени команды — то же правило, что
        // для `chroma` и `python3` (2.6).
        guard let executable = locator.locate("git") else { return nil }
        self.root = root
        self.executable = executable
        self.runner = runner
    }

    public static func isInstalled(locator: ToolLocator = .shared) -> Bool {
        locator.locate("git") != nil
    }

    /// Рабочая копия ли это. `git rev-parse` отвечает и для подкаталога
    /// репозитория — а нам важно, что индексируем именно репозиторий.
    public func isRepository() async -> Bool {
        guard let output = try? await git(["rev-parse", "--is-inside-work-tree"]) else { return false }
        return output.trimmed == "true"
    }

    /// Хэш текущего коммита. `nil` — репозиторий без единого коммита: это
    /// нормальное состояние, а не поломка.
    public func headCommit() async throws -> String? {
        guard let output = try? await git(["rev-parse", "HEAD"]) else { return nil }
        let value = output.trimmed
        return value.isEmpty ? nil : value
    }

    /// Имя ветки. На отсоединённой голове git отвечает `HEAD` — так и говорим.
    public func currentBranch() async throws -> String {
        let output = try await git(["rev-parse", "--abbrev-ref", "HEAD"])
        return output.trimmed
    }

    /// Файлы под контролем версий.
    ///
    /// `git ls-files` вместо обхода файловой системы: он сам учитывает
    /// `.gitignore`, не заходит в `.git` и не видит неотслеживаемый мусор.
    ///
    /// - Parameter includeUntracked: незакоммиченное новое — по настройке
    /// источника.
    public func listFiles(includeUntracked: Bool) async throws -> [String] {
        var arguments = ["ls-files", "-z", "--cached"]
        if includeUntracked {
            // `--exclude-standard` — это и есть уважение к `.gitignore`:
            // без него в списке окажутся сборочные артефакты.
            arguments += ["--others", "--exclude-standard"]
        }
        // Подмодули по умолчанию не обходятся: их файлы принадлежат
        // другому репозиторию, со своей историей и своими правилами.
        let output = try await git(arguments)
        return output.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    /// Что изменилось между коммитом и текущим состоянием.
    ///
    /// Один вызов вместо десятков тысяч чтений и хэширований. Правило
    /// `file_hash`/`content_hash` остаётся вторым уровнем проверки — git
    /// говорит, **что** трогали, а не **изменился ли текст**.
    public func changes(since commit: String, includeWorkingCopy: Bool) async throws -> [GitChange] {
        var arguments = ["diff", "--name-status", "-z", "--find-renames", commit]
        if !includeWorkingCopy { arguments.append("HEAD") }
        let output = try await git(arguments)
        return Self.parseNameStatus(output)
    }

    /// Разбор `--name-status -z`.
    ///
    /// Формат недобрый: обычная запись — это два поля («M», путь), а
    /// переименование — **три** («R100», старый путь, новый путь). Читать
    /// его построчно нельзя, только по полям.
    static func parseNameStatus(_ output: String) -> [GitChange] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last?.isEmpty == true { fields.removeLast() }

        var changes: [GitChange] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            guard let letter = status.first else { index += 1; continue }
            index += 1
            guard index < fields.count else { break }

            switch letter {
            case "R", "C":
                let from = fields[index]
                index += 1
                guard index < fields.count else { break }
                let to = fields[index]
                index += 1
                // Копия (`C`) — это новый файл, у которого есть предок; для нас
                // это просто новый файл, а вот переименование стоит векторов.
                changes.append(GitChange(path: to, kind: letter == "R" ? .renamed(from: from) : .added))
            case "A":
                changes.append(GitChange(path: fields[index], kind: .added))
                index += 1
            case "D":
                changes.append(GitChange(path: fields[index], kind: .deleted))
                index += 1
            case "T":
                changes.append(GitChange(path: fields[index], kind: .typeChanged))
                index += 1
            default:
                changes.append(GitChange(path: fields[index], kind: .modified))
                index += 1
            }
        }
        return changes
    }

    /// Кто и когда трогал файл последним.
    ///
    /// Отдельный вызов **на каждый файл**, и на большом репозитории это
    /// заметно — поэтому включается настройкой, а не всегда.
    public func fileInfo(path: String) async throws -> GitFileInfo? {
        let output = try? await git(["log", "-1", "--format=%aI%x00%an", "--", path])
        let parts = (output ?? "").trimmed.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return GitFileInfo(lastCommitDate: String(parts[0]), lastCommitAuthor: String(parts[1]))
    }

    // MARK: - Запуск

    @discardableResult
    func git(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(
            executable,
            arguments: arguments,
            // Ни личных настроек, ни чужих хуков: индексация не должна зависеть
            // от того, что человек написал в своём `~/.gitconfig`.
            environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"],
            currentDirectory: root,
            timeout: 120
        )
        guard result.isSuccess else {
            throw GitError.failed(
                command: "git " + arguments.prefix(2).joined(separator: " "),
                reason: result.standardError.trimmed.isEmpty ? "код \(result.exitCode)" : result.standardError.trimmed
            )
        }
        return result.standardOutput
    }
}
