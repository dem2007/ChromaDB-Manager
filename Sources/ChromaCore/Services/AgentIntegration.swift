import AppKit
import Foundation

/// Настройка агентских приложений одним нажатием.
///
/// Руками это делается так: найти конфигурацию агента, не перепутать её с
/// соседней, вписать путь к помощнику внутри бандла, не потеряв пробел в
/// «ChromaDB Manager.app», вписать ключ и не сбить отступы у чужих серверов.
/// Каждый шаг — место, где всё молча перестаёт работать: агент не скажет
/// «ты ошибся отступом», он просто не покажет инструментов.
///
/// Форматы взяты **с живых установок на этой машине**, а не из головы
/// (правило ТЗ): у Hermes это `~/.hermes/config.yaml` с деревом
/// `mcp_servers`, у Bionic — `~/.lmstudio/mcp.json` с объектом `mcpServers`.
public enum AgentKind: String, CaseIterable, Sendable, Hashable {
    case hermes
    case bionic

    public var title: String {
        switch self {
        case .hermes: return "Hermes"
        case .bionic: return "Bionic"
        }
    }

    /// Папка агента. По ней же решается, установлен ли он: конфигурации
    /// может ещё не быть, а папка есть с первого запуска.
    public var home: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .hermes: return base.appendingPathComponent(".hermes")
        case .bionic: return base.appendingPathComponent(".lmstudio")
        }
    }

    public var configuration: URL {
        switch self {
        case .hermes: return home.appendingPathComponent("config.yaml")
        case .bionic: return home.appendingPathComponent("mcp.json")
        }
    }

    /// Куда кладётся `SKILL.md`.
    ///
    /// У Bionic путь описан его же встроенным скиллом `skill-management`:
    /// «if there is a global skill called `example-skills`, its `SKILL.md`
    /// will be located at `~/.lmstudio/skills/example-skills/SKILL.md`», и имя
    /// папки обязано совпадать с `name` из шапки. У Hermes скиллы разложены
    /// по разделам, и наш живёт в `research` — там, где он уже лежит.
    public func skillFolder(
        named name: String, fileManager: FileManager = .default
    ) -> URL {
        switch self {
        case .bionic:
            return home.appendingPathComponent("skills/\(name)")
        case .hermes:
            return AgentIntegration.hermesSkillFolder(
                in: home.appendingPathComponent("skills"),
                named: name, fileManager: fileManager
            )
        }
    }

    /// Куда кладутся снимки прежнего скилла — **за пределами** папки скиллов.
    ///
    /// Это не вкусовщина, а условие работы. Hermes обходит дерево скиллов
    /// через `os.walk`, и точка в начале имени папки его не останавливает:
    /// пропускаются только те, что перечислены поимённо в
    /// `EXCLUDED_SKILL_DIRS` (`agent/skill_utils.py`), — среди них `.git`,
    /// `.hub` и **своя** папка копий `.curator_backups`, но чужих там нет
    /// и быть не может. Снимок, положенный внутрь `skills/`, становится
    /// вторым скиллом с тем же именем, и `_locate_skill` отвечает
    /// «Ambiguous skill name … Refusing to guess», отказываясь грузить оба.
    /// То есть копия, сделанная ради безопасности, ломает то, что берегла.
    ///
    /// Имя папки при этом обычное, без точки: прятать нечего, а найти
    /// снимок человек должен без подсказки.
    public var skillBackups: URL {
        home.appendingPathComponent("skills-backups/\(AgentIntegration.skillName)")
    }

    /// Куда снимки клали сборки до — **внутрь** дерева скиллов.
    ///
    /// Переезд папки снимков не убирает уже положенных туда: каждый из них
    /// остаётся вторым скиллом с тем же именем, и агент по-прежнему
    /// отказывается грузить оба. Поэтому старое место помнится — чтобы
    /// перенести оттуда то, что там уже лежит.
    var legacySkillBackups: URL {
        home.appendingPathComponent("skills/.chromadb-manager-backups")
    }

    /// Приложение, по которому агент опознаётся. Папки мало: `~/.lmstudio`
    /// заводит и сам LM Studio, и кнопка с надписью «Bionic» появилась бы
    /// у того, у кого Bionic нет вовсе.
    ///
    /// Опознаётся **идентификатором бандла**, а не путём: `/Applications`
    /// — не единственное место, куда ставят программы, и приложение,
    /// лежащее в `~/Applications` или на другом томе, для проверки по пути
    /// не существует.
    var applicationIdentifier: String? {
        switch self {
        case .hermes: return nil
        case .bionic: return "ai.elementlabs.bionic"
        }
    }

    public var isInstalled: Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: home.path, isDirectory: &directory)
        guard exists, directory.boolValue else { return false }
        guard let applicationIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: applicationIdentifier
        ) != nil
    }
}

/// Содержимое файла, если он есть.
///
/// «Файла нет» и «файл есть, а прочитать нечем» — разные вещи, и путать их
/// нельзя: второе уходило по ветке «нет файла», то есть **без снимка** и
/// поверх. Конфигурация в другой кодировке или с одним негодным байтом
/// стиралась вместе со всеми ключами человека.
func existingContents(
    of url: URL, fileManager: FileManager = .default
) throws -> String? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw AgentIntegrationError.unreadableFile(url.path)
    }
    return text
}

/// Что сделала кнопка — словами, которые можно показать человеку.
public struct AgentInstallOutcome: Sendable, Hashable {
    public let path: String
    /// Куда лёг снимок прежнего файла. `nil` — файла ещё не было.
    public let backup: String?
    /// Была ли уже такая запись: «добавлено» и «обновлено» — разные новости.
    public let replacedExisting: Bool
    /// Файл уже был ровно таким: ничего не записано и снимка нет.
    public let changedNothing: Bool
    /// Сколько файлов записано. `nil` — ставился один файл, а не папка.
    public let filesWritten: Int?
    /// Прежняя запись переписана по образцу, а не дополнена.
    ///
    /// У YAML разобрать чужие подключи нечем, и блок собирается заново: если
    /// человек что-то в нём правил, это надо **сказать**, а не оставить его
    /// выяснять пропажу самому.
    public let rewroteFromTemplate: Bool

    public init(
        path: String, backup: String?, replacedExisting: Bool,
        rewroteFromTemplate: Bool = false, changedNothing: Bool = false,
        filesWritten: Int? = nil
    ) {
        self.filesWritten = filesWritten
        self.path = path
        self.backup = backup
        self.replacedExisting = replacedExisting
        self.rewroteFromTemplate = rewroteFromTemplate
        self.changedNothing = changedNothing
    }
}

public enum AgentIntegrationError: LocalizedError {
    case notInstalled(AgentKind)
    case unreadableConfiguration(String)
    case unreadableFile(String)
    case handEditedConfiguration(String)
    case skillMissing
    /// Выбранная папка скиллом не является: в ней нет `SKILL.md`.
    case notASkillFolder(String)
    /// Имя скилла не годится в имя папки: путь, а не имя.
    case badSkillName(String)
    /// Настройка записана, но ограничить права на неё не вышло: путь,
    /// снимок прежнего файла и причина.
    case writtenButUnprotected(String, String?, String)
    /// Копирование скилла оборвалось на середине: папка, снимок прежней
    /// версии (если был) и причина.
    case skillHalfUpdated(String, String?, String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let kind):
            return String(localized: "\(kind.title) на этой машине не найден: нет папки \(kind.home.path).")
        case .unreadableConfiguration(let reason):
            return String(localized: "Конфигурацию агента не удалось разобрать: \(reason). Файл не тронут.")
        case .unreadableFile(let path):
            return String(localized: "Файл \(path) есть, но прочитать его не удалось — возможно, он в другой кодировке. Он не тронут: переписать нечитаемое значило бы стереть его без снимка.")
        case .handEditedConfiguration(let line):
            return String(localized: "Строку «\(line)» приложение разбирать не берётся — это может быть запись серверов в строку, якорь или ссылка. Файл не тронут: дописать туда, ничего не потеряв, нечем. Переведите запись в обычное дерево или добавьте сервер руками.")
        case .skillMissing:
            return String(localized: "В приложении нет файла скилла — сборка неполная.")
        case .notASkillFolder(let path):
            return String(localized: "В папке \(path) нет файла SKILL.md — скилла там нет. Выберите папку самого скилла, а не хранилище, в котором он лежит.")
        case .badSkillName(let name):
            return String(localized: "Имя скилла «\(name)» в шапке SKILL.md — это путь, а не имя: положить такую папку значит записать мимо папки скиллов. Исправьте строку name в шапке.")
        case .skillHalfUpdated(let path, let backup, let reason):
            var text = String(localized: "Скилл в \(path) обновлён не до конца: \(reason). В папке смесь новых и прежних файлов.")
            text += " " + (backup.map { String(localized: "Прежняя версия целиком — в \($0): верните её оттуда или нажмите ещё раз.") }
                ?? String(localized: "Нажмите ещё раз, когда причина устранена."))
            return text
        case .writtenButUnprotected(let path, let backup, let reason):
            var text = String(localized: "Настройка записана в \(path), но закрыть её от чужих учётных записей не удалось: \(reason). В файле лежит ключ — закройте его сами: chmod 600.")
            if let backup {
                text += " " + String(localized: "Прежний файл сохранён: \(backup).")
            }
            return text
        }
    }
}

public enum AgentIntegration {
    /// Имя сервера в конфигурации агента. Одно на оба: агент зовёт инструменты
    /// по нему, и разные имена у разных агентов означали бы разные скиллы.
    public static let serverName = "chromadb-manager"
    /// Имя скилла — оно же имя папки, этого требует Bionic.
    public static let skillName = "chromadb-manager"

    // MARK: - Конфигурация сервера

    public static func installServer(
        _ kind: AgentKind, key: String, helperPath: String,
        fileManager: FileManager = .default
    ) throws -> AgentInstallOutcome {
        guard kind.isInstalled else { throw AgentIntegrationError.notInstalled(kind) }
        return try writeConfiguration(
            kind, to: kind.configuration, key: key, helperPath: helperPath,
            fileManager: fileManager
        )
    }

    /// Всё, что происходит после того, как путь известен.
    ///
    /// Отдельно от `installServer` затем, что обещание «файл не тронут»
    /// держится **порядком** этих строк — сначала слияние, потом снимок,
    /// потом запись, — а проверить порядок можно, только пройдя его целиком
    /// на настоящем файле. Домашнюю папку агента подменить нечем, путь —
    /// можно.
    static func writeConfiguration(
        _ kind: AgentKind, to url: URL, key: String, helperPath: String,
        fileManager: FileManager = .default
    ) throws -> AgentInstallOutcome {
        let existing = try existingContents(of: url, fileManager: fileManager)
        let merged: (text: String, replaced: Bool)
        switch kind {
        case .hermes:
            merged = try hermesConfiguration(
                merging: existing ?? "", helperPath: helperPath, key: key
            )
        case .bionic:
            merged = try bionicConfiguration(
                merging: existing ?? "", helperPath: helperPath, key: key
            )
        }
        // Ответ, совпадающий с тем, что уже лежит, писать незачем: третье
        // нажатие подряд оставляло бы третий одинаковый снимок рядом с
        // файлом, который не менялся.
        if let existing, existing == merged.text {
            // Но права стянуть всё равно: содержимое совпало — не значит,
            // что файл защищён. LM Studio перезаписывает свой `mcp.json`
            // сам и оставляет 0644; следующее нажатие видело тот же текст,
            // отвечало «файл не тронут» и оставляло ключ читаемым всем.
            try restrictToOwner(url, fileManager: fileManager)
            return AgentInstallOutcome(
                path: url.path, backup: nil, replacedExisting: merged.replaced,
                rewroteFromTemplate: false, changedNothing: true
            )
        }
        let backup = existing == nil ? nil : try backUp(url, contents: existing ?? "", fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Пишем по **настоящему** пути, а не по ссылке на него.
        //
        // `write(atomically: true)` кладёт временный файл рядом и переименовывает
        // его на место назначения — символическая ссылка при этом заменяется
        // обычным файлом, а тот, на который она указывала, остаётся со старым
        // содержимым. Конфигурацию часто держат в отдельной папке под версиями
        // и ссылаются на неё из `~`: после кнопки связь молча рвётся, и все
        // дальнейшие правки в своей папке перестают доходить до агента.
        let target = resolvingLink(url, fileManager: fileManager)
        if fileManager.fileExists(atPath: target.path) {
            try merged.text.write(to: target, atomically: true, encoding: .utf8)
        } else {
            // Нового файла ещё нет — он и рождается закрытым. Запись с
            // `atomically` создаёт его с правами по umask (0644), и до
            // `restrictToOwner` ниже ключ был открыт на чтение всем.
            guard fileManager.createFile(
                atPath: target.path, contents: Data(merged.text.utf8),
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        }
        // В файл ушёл ключ — значит читать его посторонним нельзя, и
        // неважно, кто файл завёл.
        //
        // Прежде 0600 ставились только новому файлу: «прав, которые надо
        // сохранить, не было». Но у **чужого** файла права тоже бывают не
        // те: `~/.lmstudio/mcp.json` заводит сам LM Studio и оставляет 0644,
        // а перезапись с `atomically: true` их сохраняет. Ключ ложился в
        // файл, доступный на чтение любой другой учётной записи машины.
        // Условие было не на том: важно не «мы ли завели файл», а «лежит
        // ли в нём теперь ключ» — а он лежит всегда.
        // Права стягиваются после записи — значит их неудача приходит
        // тогда, когда файл уже на месте. Молчать нельзя (ключ открыт),
        // но и «не получилось» одно, без второй половины, — неправда:
        // человек пойдёт нажимать снова, не зная, что настройка записана,
        // а снимок прежней лежит рядом.
        do {
            try restrictToOwner(target, fileManager: fileManager)
        } catch {
            throw AgentIntegrationError.writtenButUnprotected(
                target.path, backup, error.localizedDescription
            )
        }
        return AgentInstallOutcome(
            path: url.path, backup: backup, replacedExisting: merged.replaced,
            rewroteFromTemplate: kind == .hermes && merged.replaced
        )
    }

    /// Чем оказалась строка `mcp_servers:` в этом файле.
    ///
    /// Различать обязательно: под обычное дерево блок дописывается, пустую
    /// запись в строку можно развернуть в дерево, а **непустую** трогать
    /// нельзя вовсе — там лежат чужие серверы, и переписать строку значит их
    /// удалить. Первая попытка различала только «пусто или нет» и удаляла
    ///.
    enum HermesRoot {
        /// Обычное дерево. Комментарий после двоеточия ему не мешает.
        case block(Int)
        /// `mcp_servers: {}` или `null` — разворачивается в дерево.
        case emptyInline(Int)
        /// Всё прочее: серверы записаны в строку, якорь, ссылка. Разобрать
        /// это нечем, и трогать нельзя — там чужое.
        case unmergeable(Int, String)
    }

    /// Строка объявляет наш сервер — в любой из записей, какие даёт YAML.
    ///
    /// Ключ можно писать в кавычках, и `"chromadb-manager":` — тот же ключ,
    /// что `chromadb-manager:`. Сравнение по голому имени его не узнавало:
    /// свой блок объявлялся отсутствующим, рядом с чужим появлялся второй,
    /// и работал из них прежний — с путём к старому помощнику, — пока
    /// человеку говорилось «сервер добавлен».
    ///
    /// `chromadb-manager-old:` не наш: двоеточие сразу за именем и отделяет.
    static func namesOurServer(_ trimmed: String) -> Bool {
        for spelling in [serverName, "\"\(serverName)\"", "'\(serverName)'"]
        where trimmed.hasPrefix(spelling) {
            let after = trimmed.dropFirst(spelling.count).drop { $0 == " " || $0 == "\t" }
            if after.first == ":" { return true }
        }
        return false
    }

    /// Первым содержательным потомком идёт элемент списка, а не ключ.
    static func firstChildIsSequence(in lines: [String], after index: Int) -> Bool {
        var cursor = index + 1
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { cursor += 1; continue }
            // Черта списка ищется **до** всякого счёта отступов: элемент
            // последовательности YAML разрешает писать на том же отступе,
            // что и ключ над ним, и `- name: other` в первом столбце —
            // обычная запись, какую по умолчанию печатает PyYAML. Прежде
            // отступ ноль считался «вышли из отображения», список не
            // узнавался, и в него вписывался ключ — то есть ровно то,
            // ради чего эта проверка и заведена.
            return trimmed == "-" || trimmed.hasPrefix("- ")
        }
        return false
    }

    /// Хвост строки после корневого ключа — или `nil`, если это не он.
    ///
    /// Пробел перед двоеточием YAML разрешает: `mcp_servers :` — тот же самый
    /// ключ. Сравнение по `hasPrefix("mcp_servers:")` его не узнавало, разбор
    /// возвращал «корня нет», и блок дописывался **вторым** таким же ключом
    /// в конец файла. Два одинаковых ключа в одном отображении — жёсткая
    /// ошибка у go-yaml (Hermes перестаёт читать конфигурацию целиком) и
    /// «выигрывает последний» у PyYAML: чужие серверы исчезали молча,
    /// а человеку говорилось «сервер добавлен».
    static func rootRemainder(of line: String) -> String? {
        // Ключ можно писать в кавычках — это тот же ключ. Узнавали только
        // голый, и файл с `"mcp_servers":` получал **второй** такой же ключ
        // в конец: та же беда, что была с именем сервера.
        for spelling in ["mcp_servers", "\"mcp_servers\"", "'mcp_servers'"]
        where line.hasPrefix(spelling) {
            let after = line.dropFirst(spelling.count).drop { $0 == " " || $0 == "\t" }
            if after.first == ":" { return String(after.dropFirst()) }
        }
        return nil
    }

    static func hermesRoot(in lines: [String]) -> HermesRoot? {
        for (index, line) in lines.enumerated() {
            guard let remainder = rootRemainder(of: line) else { continue }
            var rest = remainder.trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") {
                // Дерево ли это на самом деле. Под ключом бывает и **список**
                // (`- name: other`), а вписать в список ключ отображения
                // значит получить YAML, который не читается ни одним
                // разбором: падает вся конфигурация, а не только наш блок.
                if firstChildIsSequence(in: lines, after: index) {
                    return .unmergeable(index, line.trimmingCharacters(in: .whitespaces))
                }
                return .block(index)
            }
            // Комментарий в хвосте отбрасывается только у записи, которая
            // начинается со скобки: внутри кавычек решётка — обычный знак,
            // и резать по ней вслепую нельзя.
            if rest.hasPrefix("{"), let hash = rest.range(of: "#"),
               rest[..<hash.lowerBound].contains("}") {
                rest = String(rest[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let empty = rest.replacingOccurrences(of: " ", with: "")
            if empty == "{}" || rest == "null" || rest == "~" { return .emptyInline(index) }
            return .unmergeable(index, line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Правка YAML **точечная**, а не пересборка файла.
    ///
    /// Конфигурация Hermes — живой документ человека: там его модели, ключи
    /// других сервисов и сотни строк комментариев. Разобрать её и записать
    /// заново значило бы потерять и порядок, и комментарии. Поэтому меняется
    /// ровно один блок, а прежний файл кладётся рядом снимком.
    public static func hermesConfiguration(
        merging text: String, helperPath: String, key: String
    ) throws -> (text: String, replaced: Bool) {
        /// Блок с тем отступом, каким пользуется этот файл.
        ///
        /// Два пробела — наше умолчание, но не требование YAML: соседи одного
        /// отображения обязаны стоять на **одном** отступе, и блок, вписанный
        /// двумя пробелами в файл с четырьмя, ломает разбор всего дерева —
        /// вместе с чужими серверами, которых мы не трогали.
        func block(indent: Int) -> [String] {
            let pad = String(repeating: " ", count: indent)
            let step = String(repeating: " ", count: max(1, indent))
            return [
                "\(pad)\(serverName):",
                "\(pad)\(step)command: \(yamlScalar(helperPath))",
                "\(pad)\(step)env:",
                "\(pad)\(step)\(step)CHROMADB_MCP_KEY: \(yamlScalar(key))",
                "\(pad)\(step)supports_parallel_tool_calls: true",
                "\(pad)\(step)tools:",
                "\(pad)\(step)\(step)resources: false",
                "\(pad)\(step)\(step)prompts: false",
            ]
        }
        // Концы строк приводятся к одному виду на время разбора и
        // возвращаются как были при сборке.
        //
        // `\r` не входит в `CharacterSet.whitespaces`, и у файла с концами
        // CRLF строка «mcp_servers:\r» после обрезки оставалась непустой —
        // разбор объявлял её нечитаемой («серверы записаны в строку, якорь
        // или ссылка») и отказывался работать вовсе. А файл без корневого
        // ключа получал наш блок с концами LF вперемешку со своими CRLF.
        let usesCRLF = text.contains("\r\n")
        var lines = text.isEmpty
            ? []
            : text.components(separatedBy: "\n").map {
                $0.hasSuffix("\r") ? String($0.dropLast()) : $0
            }
        let newline = usesCRLF ? "\r\n" : "\n"

        // Корневой ключ ищется по началу строки: `mcp_servers:` с отступом —
        // это чужое поле внутри другого дерева, и трогать его нельзя.
        //
        // И только в блочной записи: `mcp_servers: {}` — отображение, уже
        // закрытое на своей строке, и дети под ним — не YAML вовсе. Такую
        // запись мы не дополняем, а заводим дерево заново на её месте.
        let rootIndex: Int
        switch hermesRoot(in: lines) {
        case .block(let index):
            rootIndex = index
        case .emptyInline(let index):
            // Пустую запись разворачиваем в дерево. Комментарий при ней —
            // не «ничего»: классификатор его нарочно обошёл, чтобы узнать
            // запись, и выбросить его здесь значило бы потерять заметку
            // человека в файле, который он ведёт руками.
            var head = "mcp_servers:"
            if let hash = lines[index].range(of: "#") {
                head += "  " + lines[index][hash.lowerBound...]
            }
            lines.replaceSubrange(index...index, with: [head] + block(indent: 2))
            return (lines.joined(separator: newline), false)
        case .unmergeable(_, let line):
            // Разобрать поток YAML нечем, а переписать строку значит удалить
            // чужие серверы. Отказ честнее: файл не тронут, и сказано почему.
            throw AgentIntegrationError.handEditedConfiguration(line)
        case nil:
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("mcp_servers:")
            lines += block(indent: 2)
            lines.append("")
            return (lines.joined(separator: newline), false)
        }

        // Наш сервер среди чужих: ищется по имени на любом отступе внутри
        // дерева, а конец блока — первая строка с отступом не больше его.
        var childIndex: Int?
        var childIndent = 0
        // Отступ соседей: по нему встаёт и наш блок, если его ещё нет.
        var siblingIndent: Int?
        var cursor = rootIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.isEmpty || trimmed.hasPrefix("#") { cursor += 1; continue }
            if indent == 0 { break }
            if siblingIndent == nil { siblingIndent = indent }
            if indent == siblingIndent, namesOurServer(trimmed) {
                // Якорь на нашем блоке (`chromadb-manager: &chroma`) может быть
                // упомянут ссылкой в другом месте файла. Заменить блок значит
                // оставить ссылку без якоря — а это не «наш блок пропал»,
                // а «конфигурация не читается целиком».
                if trimmed.contains("&") {
                    throw AgentIntegrationError.handEditedConfiguration(trimmed)
                }
                childIndex = cursor
                childIndent = indent
                break
            }
            cursor += 1
        }

        guard let start = childIndex else {
            lines.insert(contentsOf: block(indent: siblingIndent ?? 2), at: rootIndex + 1)
            return (lines.joined(separator: newline), false)
        }
        // Конец блока — **последняя его содержательная строка**, а не первая
        // строка после него. Пустые строки и комментарии, стоящие следом,
        // принадлежат тому, что идёт дальше: первый же прогон на живой
        // конфигурации Hermes показал, как в замену уезжает целый
        // комментарий «── Security ──» вместе с разделом под ним.
        var end = start + 1
        var lastContent = start
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { end += 1; continue }
            if line.prefix(while: { $0 == " " }).count <= childIndent { break }
            lastContent = end
            end += 1
        }
        lines.replaceSubrange(start...lastContent, with: block(indent: childIndent))
        return (lines.joined(separator: newline), true)
    }

    /// JSON разбирается и собирается заново: чужие серверы сохраняются, а
    /// комментариев в JSON не бывает — терять нечего.
    public static func bionicConfiguration(
        merging text: String, helperPath: String, key: String
    ) throws -> (text: String, replaced: Bool) {
        var root: [String: Any] = [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw AgentIntegrationError.unreadableConfiguration(
                    String(localized: "это не объект JSON")
                )
            }
            root = parsed
        }
        // Чужое, чего мы не понимаем, не трогаем — то же правило, что
        // у неразбираемой записи YAML. `mcpServers`, оказавшийся
        // не объектом — списком, строкой, числом, — это не «пусто»: там могут
        // лежать серверы человека в форме, которой мы не знаем, и подстановка
        // своего объекта стёрла бы их молча, отчитавшись «сервер добавлен».
        // `null` — это «пусто», а не «непонятное»: YAML-ветка разворачивает
        // такую запись в дерево, и здесь правило то же.
        if let existing = root["mcpServers"], !(existing is NSNull), !(existing is [String: Any]) {
            throw AgentIntegrationError.unreadableConfiguration(
                String(localized: "«mcpServers» в этом файле — не объект")
            )
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let replaced = servers[serverName] != nil
        // Своя запись **дополняется**, а не переписывается: человек мог
        // добавить в неё своё — `disabled`, таймаут, — и молча выбросить
        // это значит отнять настройку, о которой мы ничего не знаем.
        // Меняются ровно те два поля, ради которых кнопка и нажата.
        // …но «дополняется» держится только пока запись — объект. Прежде
        // `as? [String: Any] ?? [:]` молча подставлял пустоту: запись,
        // оказавшаяся строкой, и `env`, записанный списком `["A=1"]`,
        // выбрасывались целиком — вместе с чужими переменными, — и ответ
        // всё равно был «сервер добавлен». Обещание сохранить чужое либо
        // держится, либо о нём говорят вслух.
        var entry: [String: Any] = [:]
        if let existing = servers[serverName] {
            guard let object = existing as? [String: Any] else {
                throw AgentIntegrationError.unreadableConfiguration(
                    String(localized: "запись «\(serverName)» в этом файле — не объект")
                )
            }
            entry = object
        }
        entry["command"] = helperPath
        var environment: [String: Any] = [:]
        if let existing = entry["env"] {
            guard let object = existing as? [String: Any] else {
                throw AgentIntegrationError.unreadableConfiguration(
                    String(localized: "«env» у записи «\(serverName)» — не объект")
                )
            }
            environment = object
        }
        environment["CHROMADB_MCP_KEY"] = key
        entry["env"] = environment
        servers[serverName] = entry
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return (String(decoding: data, as: UTF8.self) + "\n", replaced)
    }

    // MARK: - Скилл

    /// Положить скилл агенту: одним файлом или папкой целиком.
    ///
    /// Папкой — потому что скилл редко один файл. У живого скилла рядом с
    /// `SKILL.md` лежат `references/` и `scripts/`, и половина его правил
    /// живёт там; копия без них — это скилл, который агент прочитает и не
    /// сможет исполнить. Своё имя папка называет сама — в шапке `SKILL.md`,
    /// потому что по нему скилл опознаёт агент.
    public static func installSkill(
        _ kind: AgentKind, from source: URL, fileManager: FileManager = .default
    ) throws -> AgentInstallOutcome {
        guard kind.isInstalled else { throw AgentIntegrationError.notInstalled(kind) }
        moveSnapshots(from: kind.legacySkillBackups, to: kind.skillBackups, fileManager: fileManager)
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw AgentIntegrationError.skillMissing
        }
        if isFolder.boolValue {
            return try installSkillFolder(kind, from: source, fileManager: fileManager)
        }
        let folder = kind.skillFolder(named: skillName, fileManager: fileManager)
        let target = folder.appendingPathComponent("SKILL.md")
        let existing = try existingContents(of: target, fileManager: fileManager)
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            // Файл есть, а прочитать нечем — это та же неполная сборка, для
            // которой и написана эта фраза. Код ошибки Cocoa человеку здесь
            // не говорит ничего.
            throw AgentIntegrationError.skillMissing
        }
        if let existing, existing == text {
            return AgentInstallOutcome(
                path: target.path, backup: nil, replacedExisting: true, changedNothing: true
            )
        }
        // Снимок — **за пределами** папки скиллов и папкой целиком.
        //
        // Прежде здесь звался `backUp`, а он кладёт копию рядом с оригиналом:
        // в папке скилла оседали `SKILL.md.bak-…`, по одному на нажатие. Имя
        // не `SKILL.md`, поэтому вторым скиллом такая копия не становится —
        // но она остаётся **внутри пакета скилла** и уезжает агенту вместе
        // с ним. А снимать надо не один файл: рядом с `SKILL.md` лежат
        // `references/`, `scripts/` и прочее, и вернуть прежнее состояние
        // по копии одного файла нельзя.
        let backup = existing == nil
            ? nil
            : try snapshotFolder(
                folder, named: skillName, in: kind.skillBackups, fileManager: fileManager
            )
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        return AgentInstallOutcome(
            path: target.path, backup: backup, replacedExisting: existing != nil
        )
    }

    /// Папка скилла целиком — со вложенными папками и без служебного сора.
    private static func installSkillFolder(
        _ kind: AgentKind, from source: URL, fileManager: FileManager
    ) throws -> AgentInstallOutcome {
        let manifest = source.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw AgentIntegrationError.notASkillFolder(source.path)
        }
        // Имя берётся из шапки, а не из имени папки: по нему скилл опознаёт
        // агент, и папка, названная иначе, даёт скилл, которого он не видит.
        guard let name = skillName(forFolderAt: source) else {
            throw AgentIntegrationError.badSkillName(
                declaredSkillName(in: manifest) ?? source.lastPathComponent
            )
        }
        return try copySkill(
            from: source,
            to: kind.skillFolder(named: name, fileManager: fileManager),
            named: name,
            backupsIn: kind.skillBackups,
            fileManager: fileManager
        )
    }

    /// Копия папки скилла: что изменилось — то и пишется.
    ///
    /// Пути параметрами, чтобы проверка шла через **этот** код, а не через
    /// его копию в тесте: настоящие пути ведут в домашнюю папку того, кто
    /// запустил, и трогать её тестом нельзя.
    static func copySkill(
        from source: URL, to folder: URL, named name: String,
        backupsIn backupRoot: URL, fileManager: FileManager = .default
    ) throws -> AgentInstallOutcome {
        let files = skillFiles(in: source, fileManager: fileManager)
        guard !files.isEmpty else { throw AgentIntegrationError.notASkillFolder(source.path) }

        // Сначала считается, что изменится, и только потом пишется: нажатие,
        // которое ничего не меняет, не должно оставлять ни снимка, ни правки
        // (то же правило, что у одиночного файла).
        let changed = files.filter { relative in
            !sameFile(
                source.appendingPathComponent(relative).resolvingSymlinksInPath(),
                folder.appendingPathComponent(relative),
                fileManager: fileManager
            )
        }
        let existed = fileManager.fileExists(atPath: folder.path)
        // Файлы, которых в новой версии скилла нет. Без этого справочник,
        // убранный из скилла, оставался у агента навсегда — и агент читал
        // правила, которых больше нет. Скрытые (`.…`) не трогаются: их
        // заводит не скилл. Убранное остаётся в снимке ниже.
        let installed = Set(files)
        let removed = existed
            ? skillFiles(in: folder, fileManager: fileManager)
                .filter { !installed.contains($0) && !($0.split(separator: "/").last ?? "").hasPrefix(".") }
            : []
        guard !changed.isEmpty || !removed.isEmpty else {
            return AgentInstallOutcome(
                path: folder.path, backup: nil, replacedExisting: existed,
                changedNothing: true, filesWritten: 0
            )
        }
        let backup = existed
            ? try snapshotFolder(folder, named: name, in: backupRoot, fileManager: fileManager)
            : nil
        do {
            for relative in changed {
                let target = folder.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                // Содержимое, а не ссылка: `copyItem` переносит символическую
                // ссылку как есть, и агент получал ссылку в чужой репозиторий —
                // она ломалась, стоило тому переехать, и тянула за собой
                // правки, которых человек агенту не ставил.
                let origin = source.appendingPathComponent(relative).resolvingSymlinksInPath()
                try fileManager.copyItem(at: origin, to: target)
            }
            for relative in removed {
                try fileManager.removeItem(at: folder.appendingPathComponent(relative))
            }
        } catch {
            // Копирование оборвалось на середине: в папке агента уже смесь
            // новых и старых файлов. Молча это не оставляется — ошибка
            // называет снимок, из которого вернуть прежний скилл.
            throw AgentIntegrationError.skillHalfUpdated(folder.path, backup, error.localizedDescription)
        }
        return AgentInstallOutcome(
            path: folder.path, backup: backup, replacedExisting: existed,
            filesWritten: changed.count
        )
    }

    /// Имя скилла из шапки `SKILL.md`.
    ///
    /// Читается **только шапка** — от первой черты до второй. Ниже начинается
    /// текст скилла, и строка «name:» в нём — это пример из чьих-то правил,
    /// а не имя папки, в которую мы собираемся писать.
    public static func declaredSkillName(in manifest: URL) -> String? {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        // Концы строк снимаются вместе с пробелами: `\r` не входит
        // в `CharacterSet.whitespaces`, и у файла, правленного в Windows,
        // первая строка шапки читалась как «---\r» — не «---». Имя не
        // находилось, и скилл ставился под именем папки, которого агент
        // по шапке не узнаёт.
        var lines = text.components(separatedBy: "\n")
            .drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })[...]
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        lines = lines.dropFirst()
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { return nil }
            guard line.hasPrefix("name:") else { continue }
            let name = line.dropFirst("name:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Под каким именем ставится скилл из этой папки.
    ///
    /// Правило одно на приложение и на службу: экран спрашивает его, чтобы
    /// показать в вопросе настоящий путь, служба — чтобы по нему писать.
    /// Разойдись они, человек согласился бы на одно, а получил другое.
    ///
    /// `nil` — имя не годится: см. `safeSkillName`.
    public static func skillName(forFolderAt folder: URL) -> String? {
        let declared = declaredSkillName(in: folder.appendingPathComponent("SKILL.md"))
        return safeSkillName(declared ?? folder.lastPathComponent)
    }

    /// Имя, годное в имя папки, — и ничего сверх того.
    ///
    /// Имя приезжает из чужого файла и превращается в путь. «../../evil»
    /// или «expertise/it-doc» — это уже не имя: первое пишет мимо папки
    /// скиллов вовсе, второе прячет скилл на этаж глубже, где агент его
    /// не найдёт. Одна составляющая пути, и никаких особенных.
    static func safeSkillName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains("\\"),
              !trimmed.contains("\0")
        else { return nil }
        return trimmed
    }

    /// Что из папки едет к агенту — относительными путями, по порядку.
    ///
    /// Не едет служебное: история хранилища, метки Finder и снимки прошлых
    /// нажатий. `.git` — это десятки тысяч файлов, которые агенту не нужны
    /// ни одним.
    static func skillFiles(in source: URL, fileManager: FileManager = .default) -> [String] {
        // Корень разыменовывается заранее: обход отдаёт пути **разрешённые**
        // («/private/var/…»), а спрошенный путь может быть ссылкой
        // («/var/…»), и вычитание строк тогда срезает не начало, а девять
        // случайных знаков — путь получается похожим на правду и неверным.
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = root.pathComponents
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".git" || name == "__pycache__" {
                walker.skipDescendants()
                continue
            }
            // Снимок прошлого нажатия узнаётся по своему же имени —
            // «…bak-20260906-120000», — а не по одной подстроке: файл,
            // названный «выгрузка.bak-старая.md», к агенту ехать обязан.
            if name == ".DS_Store" || isSnapshotName(name) { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory == true { continue }
            var parts = url.standardizedFileURL.pathComponents
            if !parts.starts(with: rootParts) {
                parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            }
            guard parts.count > rootParts.count, parts.starts(with: rootParts) else { continue }
            found.append(parts.dropFirst(rootParts.count).joined(separator: "/"))
        }
        return found.sorted()
    }

    /// Имя вида «что-угодно.bak-20260906-120000» — снимок прошлого нажатия.
    static func isSnapshotName(_ name: String) -> Bool {
        guard let mark = name.range(of: ".bak-", options: .backwards) else { return false }
        let tail = name[mark.upperBound...]
        guard tail.count == "20260906-120000".count else { return false }
        return tail.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Файлы одинаковы — значит копировать нечего.
    /// Сначала размер, потом содержимое: у скилла с большими справочниками
    /// каждое нажатие иначе читает оба дерева целиком, чтобы узнать то,
    /// что видно по одному числу.
    static func sameFile(_ left: URL, _ right: URL, fileManager: FileManager = .default) -> Bool {
        guard let leftSize = fileSize(of: left, fileManager: fileManager),
              let rightSize = fileSize(of: right, fileManager: fileManager),
              leftSize == rightSize
        else { return false }
        return fileManager.contentsEqual(atPath: left.path, andPath: right.path)
    }

    /// Размер файла; `nil` — файла нет или он недоступен.
    private static func fileSize(of url: URL, fileManager: FileManager) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue
    }

    /// Снимок прежней папки — **вне** разделов, по которым агент ищет скиллы.
    ///
    /// Рядом с самим скиллом снимок класть нельзя: папка со своим `SKILL.md`
    /// внутри раздела — это второй скилл с тем же именем, и агент увидит оба.
    static func snapshotFolder(
        _ folder: URL, named name: String, in root: URL, fileManager: FileManager
    ) throws -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var target = root.appendingPathComponent("\(name)-\(stamp.string(from: Date()))")
        var attempt = 2
        while fileManager.fileExists(atPath: target.path) {
            target = root.appendingPathComponent("\(name)-\(stamp.string(from: Date()))-\(attempt)")
            attempt += 1
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.copyItem(at: folder, to: target)
        return target.path
    }

    /// Переносит снимки со старого места на новое и убирает
    /// опустевшую старую папку.
    ///
    /// Молча и без отказа: неудавшийся перенос не повод не ставить скилл,
    /// а снимок, который не удалось перенести, остаётся где был — ничего
    /// не удаляется, кроме пустой папки. Имя, уже занятое на новом месте,
    /// получает номер: снимок нельзя затереть другим снимком.
    static func moveSnapshots(from legacy: URL, to root: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: legacy.path),
              !entries.isEmpty
        else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for entry in entries {
            var target = root.appendingPathComponent(entry)
            var attempt = 2
            while fileManager.fileExists(atPath: target.path) {
                target = root.appendingPathComponent("\(entry)-\(attempt)")
                attempt += 1
            }
            try? fileManager.moveItem(at: legacy.appendingPathComponent(entry), to: target)
        }
        if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? fileManager.removeItem(at: legacy)
        }
    }

    // MARK: - Общее

    /// Снимок прежнего файла рядом с ним же.
    ///
    /// Не «на всякий случай»: правится документ, который человек вёл руками,
    /// и вернуть его он должен уметь без нас. Имя со временем — чтобы второе
    /// нажатие не затёрло первый снимок.
    static func backUp(
        _ url: URL, contents: String, fileManager: FileManager = .default
    ) throws -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".bak-" + stamp.string(from: Date())
        // Второе нажатие в ту же секунду не должно затирать первый снимок:
        // на нём и держится возврат к тому, что было **до** кнопки.
        var backup = base.appendingPathComponent(prefix)
        var attempt = 2
        while fileManager.fileExists(atPath: backup.path), attempt < 100 {
            backup = base.appendingPathComponent("\(prefix)-\(attempt)")
            attempt += 1
        }
        try contents.write(to: backup, atomically: true, encoding: .utf8)
        // Права — как у оригинала. Замерено: перезапись существующего файла
        // их сохраняет, а **новый** получает 0644 по umask — и снимок
        // конфигурации Hermes, где лежат ключи человека к другим сервисам,
        // ложился бы доступным на чтение всем в системе. Свои снимки Hermes
        // держит в 0600.
        try matchPermissions(of: url, to: backup, fileManager: fileManager)
        // Права снимка — как у оригинала, но не шире владельца: в прежней
        // настройке уже мог лежать наш ключ с прошлого нажатия, а оригинал
        // мог достаться нам с 0644 от того, кто завёл файл.
        try restrictToOwner(backup, fileManager: fileManager)
        return backup.path
    }

    /// Где у Hermes лежит скилл с этим именем.
    ///
    /// Скилл, который уже есть, обновляется **на своём месте**. Hermes
    /// опознаёт скилл по имени в шапке, а разложены они по разделам:
    /// положить копию в «research», когда своя лежит в «devops», — это два
    /// скилла с одним именем, и агент увидит оба.
    ///
    /// Корень параметром, чтобы проверка шла через **этот** код, а не через
    /// его копию в тесте.
    static func hermesSkillFolder(
        in root: URL, named name: String, fileManager: FileManager = .default
    ) -> URL {
        let categories = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        for category in categories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let candidate = category.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("SKILL.md").path) {
                return candidate
            }
        }
        return root.appendingPathComponent("research/\(name)")
    }

    /// Настоящий путь файла, если по этому пути лежит символическая ссылка.
    static func resolvingLink(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
        else { return url }
        return url.resolvingSymlinksInPath()
    }

    /// Файл закрыт для всех, кроме владельца.
    ///
    /// Зовётся везде, где на диск уходит ключ: и сама настройка, и её снимок
    /// несут `CHROMADB_MCP_KEY` открытым текстом.
    ///
    /// Права **сужаются**, а не назначаются. Назначать 0600 напрямую было
    /// неверно дважды: файл на 0400 становился шире, чем был, а
    /// `matchPermissions` у снимка превращался в работу впустую — его
    /// результат тут же затирался. Проверено удалением вызова: ни один тест
    /// не падал, то есть строка не значила ничего.
    static func restrictToOwner(_ url: URL, fileManager: FileManager = .default) throws {
        let current = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions])
            as? NSNumber
        // Читать владелец обязан в любом случае: файл, закрытый и от него
        // тоже, — это не защита, а потерянная настройка.
        let owner = ((current?.intValue ?? 0o600) & 0o700) | 0o600
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: owner)], ofItemAtPath: url.path
        )
    }

    /// Права нового файла — как у того, с которого он снят.
    ///
    /// Если оригинала нет вовсе (конфигурации ещё не было), берётся 0600:
    /// в этот файл кладётся ключ, и «читают все» для него — не умолчание,
    /// а ошибка.
    static func matchPermissions(
        of source: URL, to target: URL, fileManager: FileManager = .default
    ) throws {
        let mode = (try? fileManager.attributesOfItem(atPath: source.path)[.posixPermissions])
            as? NSNumber ?? NSNumber(value: 0o600)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }

    /// Скаляр YAML в кавычках: в пути к помощнику есть пробел
    /// («ChromaDB Manager.app»), а ключ начинается с букв, но зарекаться
    /// не за что.
    static func yamlScalar(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                // Прочие управляющие знаки — тоже не сами по себе: сырой
                // перевод строки внутри кавычек рвёт построчную сборку блока,
                // а путь в macOS может содержать что угодно, кроме «/» и нуля.
                if let scalar = character.unicodeScalars.first,
                   character.unicodeScalars.count == 1, scalar.value < 0x20 {
                    escaped += String(format: "\\x%02x", scalar.value)
                } else {
                    escaped.append(character)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
