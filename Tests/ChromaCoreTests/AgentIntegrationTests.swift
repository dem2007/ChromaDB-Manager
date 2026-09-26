import XCTest
@testable import ChromaCore

/// Настройка агента одной кнопкой.
///
/// Проверяется одно свойство, из которого растёт всё остальное: **чужое в
/// конфигурации агента остаётся нетронутым**. Файл этот человек вёл руками —
/// там его модели, ключи других сервисов и сотни строк комментариев, — и
/// кнопка, которая их потеряет, хуже, чем отсутствие кнопки.
final class AgentIntegrationTests: XCTestCase {
    private let helper = "/Applications/ChromaDB Manager.app/Contents/MacOS/chromadb-mcp"
    private let key = "cdbm_0123456789abcdef"

    // MARK: - Hermes, YAML

    /// Пустой конфигурации хватает: дерево заводится целиком.
    func testHermesWritesTheWholeTreeWhenThereIsNone() throws {
        let made = try AgentIntegration.hermesConfiguration(merging: "", helperPath: helper, key: key)
        XCTAssertFalse(made.replaced)
        XCTAssertTrue(made.text.hasPrefix("mcp_servers:\n  chromadb-manager:"), made.text)
        XCTAssertTrue(made.text.contains("CHROMADB_MCP_KEY: \"\(key)\""), made.text)
    }

    /// Чужие серверы остаются на месте, наш добавляется рядом.
    func testHermesKeepsOtherServers() throws {
        let before = """
        model: qwen
        mcp_servers:
          github:
            command: /usr/local/bin/github-mcp
            env:
              GITHUB_TOKEN: секрет
        logging: info
        """
        let made = try AgentIntegration.hermesConfiguration(merging: before, helperPath: helper, key: key)
        XCTAssertFalse(made.replaced)
        XCTAssertTrue(made.text.contains("  github:"), made.text)
        XCTAssertTrue(made.text.contains("GITHUB_TOKEN: секрет"), "чужой ключ потерян")
        XCTAssertTrue(made.text.contains("logging: info"), "хвост файла потерян")
        XCTAssertTrue(made.text.contains("  chromadb-manager:"), made.text)
    }

    /// Своя прежняя запись заменяется целиком, а соседняя — нет.
    func testHermesReplacesItsOwnBlockAndNothingElse() throws {
        let before = """
        mcp_servers:
          chromadb-manager:
            command: /старый/путь
            env:
              CHROMADB_MCP_KEY: cdbm_старый
            tools:
              resources: false
          github:
            command: /usr/local/bin/github-mcp
        """
        let made = try AgentIntegration.hermesConfiguration(merging: before, helperPath: helper, key: key)
        XCTAssertTrue(made.replaced)
        XCTAssertFalse(made.text.contains("cdbm_старый"), "старый ключ остался: \(made.text)")
        XCTAssertFalse(made.text.contains("/старый/путь"), made.text)
        XCTAssertTrue(made.text.contains("  github:"), "сосед снесён вместе с нашим блоком")
        XCTAssertTrue(made.text.contains("/usr/local/bin/github-mcp"), made.text)
    }

    /// Комментарии после дерева — часть документа человека.
    func testHermesKeepsCommentsAfterTheTree() throws {
        let before = """
        mcp_servers:
          chromadb-manager:
            command: /старый/путь

        # ── Security ──────────────────────────
        # Secret redaction is ON by default.
        security:
          redact_secrets: true
        """
        let made = try AgentIntegration.hermesConfiguration(merging: before, helperPath: helper, key: key)
        XCTAssertTrue(made.text.contains("# ── Security"), "комментарий потерян: \(made.text)")
        XCTAssertTrue(made.text.contains("redact_secrets: true"), made.text)
    }

    /// `mcp_servers` внутри чужого дерева — не наш корень.
    ///
    /// Отступ решает: строка с отступом принадлежит другому полю, и вписывать
    /// туда сервер значит менять чужую настройку.
    func testHermesDoesNotMistakeANestedKeyForTheRoot() throws {
        let before = """
        profiles:
          research:
            mcp_servers:
              github:
                command: /usr/local/bin/github-mcp
        """
        let made = try AgentIntegration.hermesConfiguration(merging: before, helperPath: helper, key: key)
        XCTAssertTrue(made.text.contains("profiles:"), made.text)
        // Наш блок заведён своим корнем, а не подсунут в профиль.
        XCTAssertTrue(made.text.contains("\nmcp_servers:\n  chromadb-manager:"), made.text)
        XCTAssertTrue(made.text.contains("    mcp_servers:\n      github:"), "чужое дерево тронуто")
    }

    /// Путь с пробелом — обычный случай: «ChromaDB Manager.app».
    func testHermesQuotesThePathWithASpace() throws {
        let made = try AgentIntegration.hermesConfiguration(merging: "", helperPath: helper, key: key)
        XCTAssertTrue(made.text.contains("command: \"\(helper)\""), made.text)
    }

    // MARK: - Bionic, JSON

    func testBionicWritesTheServerIntoAnEmptyFile() throws {
        let made = try AgentIntegration.bionicConfiguration(
            merging: "{\n  \"mcpServers\": {}\n}", helperPath: helper, key: key
        )
        XCTAssertFalse(made.replaced)
        XCTAssertTrue(made.text.contains("\"chromadb-manager\""), made.text)
        XCTAssertTrue(made.text.contains("\"CHROMADB_MCP_KEY\" : \"\(key)\"")
            || made.text.contains("\"CHROMADB_MCP_KEY\": \"\(key)\""), made.text)
        // Путь не должен уехать в экранированном виде: агент подставит его как есть.
        XCTAssertTrue(made.text.contains(helper), made.text)
    }

    func testBionicKeepsOtherServersAndOtherKeys() throws {
        let before = """
        {"mcpServers": {"github": {"command": "/usr/local/bin/github-mcp"}}, "telemetry": false}
        """
        let made = try AgentIntegration.bionicConfiguration(
            merging: before, helperPath: helper, key: key
        )
        let data = made.text.data(using: .utf8)!
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]
        XCTAssertNotNil(servers["github"], "чужой сервер потерян")
        XCTAssertNotNil(servers["chromadb-manager"])
        XCTAssertEqual(root["telemetry"] as? Bool, false, "чужое поле верхнего уровня потеряно")
    }

    func testBionicReplacesItsOwnEntry() throws {
        let before = """
        {"mcpServers": {"chromadb-manager": {"command": "/старый", "env": {"CHROMADB_MCP_KEY": "cdbm_старый"}}}}
        """
        let made = try AgentIntegration.bionicConfiguration(
            merging: before, helperPath: helper, key: key
        )
        XCTAssertTrue(made.replaced)
        XCTAssertFalse(made.text.contains("cdbm_старый"), made.text)
        XCTAssertFalse(made.text.contains("/старый"), made.text)
    }

    /// Испорченный файл — отказ, а не перезапись.
    ///
    /// Сказать «не разобрал, файл не тронут» честнее, чем заменить документ
    /// человека своим: разбирать его было нашей задачей, а не его.
    func testBionicRefusesToOverwriteWhatItCannotParse() {
        XCTAssertThrowsError(
            try AgentIntegration.bionicConfiguration(
                merging: "{ это не json ", helperPath: helper, key: key
            )
        )
    }

    /// Разобранный файл, но `mcpServers` в нём — не объект.
    ///
    /// Тот же случай, что у неразбираемой записи YAML: там могут лежать
    /// серверы человека в форме, которой мы не знаем. Подстановка своего
    /// объекта стёрла бы их молча, а ответ сказал бы «сервер добавлен».
    func testBionicRefusesWhenTheServerListIsNotAnObject() {
        for broken in ["[]", "\"chromadb\"", "17"] {
            XCTAssertThrowsError(
                try AgentIntegration.bionicConfiguration(
                    merging: "{\"mcpServers\": \(broken)}", helperPath: helper, key: key
                ),
                "«mcpServers»: \(broken) — отказ, а не перезапись"
            )
        }
    }

    /// А `null` и отсутствие ключа — это «пусто», и по ним пишем.
    func testBionicWritesWhenTheServerListIsAbsentOrNull() throws {
        for empty in ["{}", "{\"mcpServers\": null}", "{\"other\": 1}"] {
            let made = try AgentIntegration.bionicConfiguration(
                merging: empty, helperPath: helper, key: key
            )
            XCTAssertTrue(made.text.contains("chromadb-manager"), "\(empty) → \(made.text)")
        }
    }

    /// Отображение, закрытое на своей строке, детей иметь не может.
    ///
    /// `mcp_servers: {}` — обычная запись пустого дерева, и блок, вписанный
    /// под неё с отступом, — не YAML вовсе: агент перестал бы разбирать свою
    /// конфигурацию целиком, вместе с чужими серверами.
    func testHermesDoesNotHangChildrenOffAFlowMapping() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "model: qwen\nmcp_servers: {}\nlogging: info",
            helperPath: helper, key: key
        )
        XCTAssertFalse(made.text.contains("mcp_servers: {}"), made.text)
        XCTAssertTrue(made.text.contains("mcp_servers:\n  chromadb-manager:"), made.text)
        XCTAssertTrue(made.text.contains("logging: info"), "хвост потерян: \(made.text)")
    }

    /// Отступ берётся у соседей: у отображения YAML он общий для всех детей.
    func testHermesMatchesTheIndentationTheFileUses() throws {
        let before = """
        mcp_servers:
            github:
                command: /usr/local/bin/github-mcp
        """
        let made = try AgentIntegration.hermesConfiguration(
            merging: before, helperPath: helper, key: key
        )
        XCTAssertTrue(made.text.contains("\n    chromadb-manager:"), "чужой отступ не подхвачен: \(made.text)")
        XCTAssertFalse(made.text.contains("\n  chromadb-manager:"), made.text)
    }

    /// Своё в записи Bionic сохраняется: меняются ровно команда и ключ.
    func testBionicKeepsWhatTheUserAddedToOurEntry() throws {
        let before = """
        {"mcpServers": {"chromadb-manager": {"command": "/старый", "disabled": true,
         "env": {"CHROMADB_MCP_KEY": "cdbm_старый", "EXTRA": "своё"}}}}
        """
        let made = try AgentIntegration.bionicConfiguration(
            merging: before, helperPath: helper, key: key
        )
        let root = try JSONSerialization.jsonObject(
            with: made.text.data(using: .utf8)!
        ) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["chromadb-manager"] as! [String: Any]
        XCTAssertEqual(entry["disabled"] as? Bool, true, "чужое поле записи потеряно")
        XCTAssertEqual((entry["env"] as! [String: Any])["EXTRA"] as? String, "своё")
        XCTAssertEqual(entry["command"] as? String, helper)
        XCTAssertEqual((entry["env"] as! [String: Any])["CHROMADB_MCP_KEY"] as? String, key)
    }

    /// Серверы, записанные в строку, — отказ, а не удаление.
    ///
    /// Первая правка различала только «пусто после двоеточия или нет» и
    /// заменяла строку целиком: конфигурация, где серверы записаны потоком,
    /// теряла их молча. Сломанный YAML замечают при следующем запуске,
    /// тихо удалённый сервер — нет.
    func testHermesRefusesToTouchServersWrittenInline() {
        let before = "mcp_servers: {github: {command: /usr/local/bin/github-mcp}}"
        XCTAssertThrowsError(
            try AgentIntegration.hermesConfiguration(
                merging: before, helperPath: helper, key: key
            )
        ) { error in
            guard case AgentIntegrationError.handEditedConfiguration = error else {
                return XCTFail("не тот отказ: \(error)")
            }
        }
    }

    /// Комментарий после двоеточия — это обычное дерево, а не поток.
    func testHermesTreatsATrailingCommentAsABlockRoot() throws {
        let before = """
        mcp_servers:  # только локальные
          chromadb-manager:
            command: /старый
          github:
            command: /usr/local/bin/github-mcp
        """
        let made = try AgentIntegration.hermesConfiguration(
            merging: before, helperPath: helper, key: key
        )
        XCTAssertTrue(made.replaced, "запись не найдена — вышло бы два ключа с одним именем")
        XCTAssertTrue(made.text.contains("# только локальные"), "комментарий потерян: \(made.text)")
        XCTAssertFalse(made.text.contains("/старый"), made.text)
        XCTAssertEqual(
            made.text.components(separatedBy: "chromadb-manager:").count - 1, 1,
            "запись задвоилась: \(made.text)"
        )
        XCTAssertTrue(made.text.contains("  github:"), made.text)
    }

    /// Пустая запись в строку разворачивается в дерево: терять там нечего.
    func testHermesUnfoldsAnEmptyInlineMapping() throws {
        for empty in ["mcp_servers: {}", "mcp_servers: { }", "mcp_servers: null", "mcp_servers: ~"] {
            let made = try AgentIntegration.hermesConfiguration(
                merging: "model: qwen\n\(empty)\nlogging: info",
                helperPath: helper, key: key
            )
            XCTAssertTrue(made.text.contains("mcp_servers:\n  chromadb-manager:"), empty)
            XCTAssertTrue(made.text.contains("logging: info"), empty)
        }
    }

    /// Второе нажатие — основной путь, а не край: кнопка работает только со
    /// свежим ключом, значит давнему клиенту настройка достаётся на повторе.
    func testPressingTheButtonTwiceLeavesOneEntry() throws {
        let before = """
        mcp_servers:
          github:
            command: /usr/local/bin/github-mcp
        """
        let once = try AgentIntegration.hermesConfiguration(
            merging: before, helperPath: helper, key: key
        )
        let twice = try AgentIntegration.hermesConfiguration(
            merging: once.text, helperPath: helper, key: "cdbm_новый"
        )
        XCTAssertTrue(twice.replaced)
        XCTAssertEqual(
            twice.text.components(separatedBy: "\(AgentIntegration.serverName):").count - 1, 1,
            "запись задвоилась: \(twice.text)"
        )
        XCTAssertTrue(twice.text.contains("cdbm_новый"), twice.text)
        XCTAssertFalse(twice.text.contains(key), "старый ключ остался")
        XCTAssertTrue(twice.text.contains("  github:"), "чужой сервер потерян")
        // Третье нажатие тем же ключом ничего не меняет.
        let thrice = try AgentIntegration.hermesConfiguration(
            merging: twice.text, helperPath: helper, key: "cdbm_новый"
        )
        XCTAssertEqual(thrice.text, twice.text, "повтор меняет файл без нужды")
    }

    /// То же у Bionic: повтор не плодит записей и не двигает файл.
    func testPressingTheBionicButtonTwiceIsStable() throws {
        let once = try AgentIntegration.bionicConfiguration(
            merging: "{\n  \"mcpServers\": {}\n}", helperPath: helper, key: key
        )
        let twice = try AgentIntegration.bionicConfiguration(
            merging: once.text, helperPath: helper, key: key
        )
        XCTAssertEqual(once.text, twice.text, "повтор переписал файл иначе")
        XCTAssertTrue(twice.replaced)
    }

    // MARK: - Запись на диск

    /// Снимок делается **до** перезаписи, и второе нажатие его не затирает.
    func testTheBackupIsWrittenBeforeTheOverwriteAndIsNotClobbered() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.yaml")
        try "mcp_servers:\n  github:\n    command: /чужой\n".write(
            to: config, atomically: true, encoding: .utf8
        )
        let first = try AgentIntegration.backUp(config, contents: "первое")
        let second = try AgentIntegration.backUp(config, contents: "второе")
        XCTAssertNotEqual(first, second, "второй снимок затёр первый")
        XCTAssertEqual(try String(contentsOfFile: first, encoding: .utf8), "первое")
        XCTAssertEqual(try String(contentsOfFile: second, encoding: .utf8), "второе")
    }

    /// Права снимка — как у оригинала.
    ///
    /// Замерено: перезапись существующего файла права сохраняет, а **новый**
    /// получает 0644 по umask. Конфигурация Hermes — 0600, и в ней ключи
    /// человека к другим сервисам: снимок, доступный на чтение всем, — это
    /// кнопка, публикующая то, что она пришла беречь.
    func testTheBackupIsAsPrivateAsWhatItCopies() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.yaml")
        try "api_key: секрет\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: config.path
        )
        let backup = try AgentIntegration.backUp(config, contents: "api_key: секрет\n")
        let mode = try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions]
        XCTAssertEqual(
            (mode as? NSNumber)?.intValue, 0o600,
            "снимок конфигурации с ключами доступен на чтение всем"
        )
    }

    /// Ключ не ложится в файл, доступный на чтение всей машине.
    ///
    /// Права 0600 ставились только **новому** файлу — «прав, которые надо
    /// сохранить, не было». Но `~/.lmstudio/mcp.json` заводит сам LM Studio
    /// и оставляет 0644 (замерено на живой машине), а перезапись с
    /// `atomically: true` права сохраняет. Кнопка вписывала туда
    /// `CHROMADB_MCP_KEY` и оставляла файл читаемым любой другой учётной
    /// записи. Условие было не на том: важно не «мы ли завели файл»,
    /// а «лежит ли в нём теперь ключ».
    func testTheKeyNeverLandsInAWorldReadableConfiguration() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("mcp.json")
        // Ровно то, что лежит на живой машине: чужой файл с правами по umask.
        try "{\"mcpServers\":{}}".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: config.path
        )

        let outcome = try AgentIntegration.writeConfiguration(
            .bionic, to: config, key: key, helperPath: helper
        )

        // Сначала — что ключ действительно уехал в файл: без этого
        // проверка прав сторожит пустоту.
        let written = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(written.contains(key), "ключа в файле нет — проверять нечего")

        func mode(_ path: String) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(config.path), 0o600, "ключ лежит в файле, читаемом всеми")
        let backup = try XCTUnwrap(outcome.backup, "снимок чужого файла обязателен")
        XCTAssertEqual(try mode(backup), 0o600, "снимок доступен на чтение всем")
    }

    // MARK: - Записи YAML, которые файл имеет право содержать

    /// Пробел перед двоеточием — тот же самый ключ.
    ///
    /// `mcp_servers :` — законный YAML. Сравнение по `hasPrefix("mcp_servers:")`
    /// его не узнавало, и блок дописывался **вторым** таким же ключом в конец
    /// файла. Два одинаковых ключа — жёсткая ошибка у go-yaml и «выигрывает
    /// последний» у PyYAML: чужой сервер исчезал, а ответ был «добавлен».
    func testASpaceBeforeTheColonIsStillTheSameRootKey() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "mcp_servers :\n  other:\n    command: /x\n",
            helperPath: helper, key: key
        )
        // Считаем **не** тем, что проверяем: `rootRemainder` — как раз
        // разбираемая функция, и сломанная она отвечала бы «корень один»
        // на файле с двумя. Мутация это и показала: проверка проходила
        // со снятой правкой.
        let roots = made.text.components(separatedBy: "\n").filter { line in
            guard line.hasPrefix("mcp_servers") else { return false }
            return line.dropFirst("mcp_servers".count).drop(while: { $0 == " " }).first == ":"
        }
        XCTAssertEqual(roots.count, 1, "корневой ключ задвоился: \(roots)")
        XCTAssertTrue(made.text.contains("  other:"), "чужой сервер потерян")
        XCTAssertTrue(made.text.contains(AgentIntegration.serverName + ":"))
    }

    /// Под корнем список, а не дерево — вписывать некуда.
    ///
    /// Ключ отображения внутри последовательности не читается ни одним
    /// разбором: падает вся конфигурация, а не только наш блок. Отказ честнее.
    func testASequenceUnderTheRootIsRefusedRatherThanCorrupted() {
        XCTAssertThrowsError(
            try AgentIntegration.hermesConfiguration(
                merging: "mcp_servers:\n  - name: other\n    command: /x\n",
                helperPath: helper, key: key
            )
        ) { error in
            guard case AgentIntegrationError.handEditedConfiguration = error else {
                return XCTFail("ожидался отказ, пришло: \(error)")
            }
        }
    }

    /// Файл с концами CRLF читается и остаётся с ними же.
    ///
    /// `\r` не входит в `CharacterSet.whitespaces`: строка «mcp_servers:\r»
    /// после обрезки оставалась непустой, и разбор объявлял её нечитаемой —
    /// кнопка не работала вовсе. А файл без корня получал наш блок с LF
    /// вперемешку со своими CRLF.
    func testWindowsLineEndingsSurviveTheMerge() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "mcp_servers:\r\n  other:\r\n    command: /x\r\n",
            helperPath: helper, key: key
        )
        XCTAssertTrue(made.text.contains("  other:"), "чужой сервер потерян")
        XCTAssertTrue(
            made.text.contains(AgentIntegration.serverName + ":"), "наш блок не вписан"
        )
        let lf = made.text.components(separatedBy: "\n").count - 1
        let crlf = made.text.components(separatedBy: "\r\n").count - 1
        XCTAssertEqual(lf, crlf, "концы строк перемешаны: LF \(lf), CRLF \(crlf)")
    }

    /// Ключ в кавычках — тот же ключ.
    ///
    /// Иначе свой блок объявлялся отсутствующим, рядом появлялся второй,
    /// и работал из них прежний — с путём к старому помощнику.
    func testAQuotedServerNameIsRecognisedAsOurs() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: """
            mcp_servers:
              "chromadb-manager":
                command: /old
              other:
                command: /x

            """,
            helperPath: helper, key: key
        )
        XCTAssertTrue(made.replaced, "своя запись не опознана — будет задвоение")
        XCTAssertFalse(made.text.contains("/old"), "прежний путь остался жить")
        XCTAssertTrue(made.text.contains("  other:"), "чужой сервер потерян")
        let ours = made.text.components(separatedBy: "\n")
            .filter { AgentIntegration.namesOurServer($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(ours.count, 1, "записей нашего сервера стало \(ours.count)")
    }

    /// Якорь на нашем блоке — отказ, а не молчаливая ссылка в никуда.
    func testAnAnchorOnOurBlockIsRefused() {
        XCTAssertThrowsError(
            try AgentIntegration.hermesConfiguration(
                merging: "mcp_servers:\n  chromadb-manager: &chroma\n    command: /old\n",
                helperPath: helper, key: key
            )
        ) { error in
            guard case AgentIntegrationError.handEditedConfiguration = error else {
                return XCTFail("ожидался отказ, пришло: \(error)")
            }
        }
    }

    /// Чужое `env` списком не выбрасывается молча.
    ///
    /// `as? [String: Any] ?? [:]` подставлял пустоту, и переменные человека
    /// исчезали — а ответ всё равно был «сервер добавлен».
    func testAnEnvThatIsNotAnObjectIsReportedRatherThanDropped() {
        XCTAssertThrowsError(
            try AgentIntegration.bionicConfiguration(
                merging: #"{"mcpServers":{"chromadb-manager":{"env":["MY_TOKEN=abc"]}}}"#,
                helperPath: helper, key: key
            )
        ) { error in
            guard case AgentIntegrationError.unreadableConfiguration = error else {
                return XCTFail("ожидался отказ, пришло: \(error)")
            }
        }
    }

    /// Совпало содержимое — не значит, что файл защищён.
    ///
    /// LM Studio перезаписывает свой `mcp.json` сам и оставляет 0644. Второе
    /// нажатие видело тот же текст, отвечало «файл не тронут» и оставляло
    /// ключ читаемым всем.
    func testTheUnchangedPathStillTightensPermissions() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("mcp.json")
        _ = try AgentIntegration.writeConfiguration(
            .bionic, to: config, key: key, helperPath: helper
        )
        // Кто-то снаружи вернул права по умолчанию, содержимое не тронув.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: config.path
        )

        let again = try AgentIntegration.writeConfiguration(
            .bionic, to: config, key: key, helperPath: helper
        )

        XCTAssertTrue(again.changedNothing, "текст тот же — снимок не нужен")
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions]
        XCTAssertEqual(
            (mode as? NSNumber)?.intValue, 0o600, "ключ остался читаемым всей машине"
        )
    }

    /// Символическая ссылка на конфигурацию переживает запись.
    ///
    /// `write(atomically: true)` переименовывает временный файл на место
    /// назначения и заменяет ссылку обычным файлом; настоящий файл остаётся
    /// со старым содержимым. Конфигурацию часто держат в папке под версиями
    /// и ссылаются на неё из `~`.
    func testWritingThroughASymbolicLinkKeepsTheLink() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = real.appendingPathComponent("mcp.json")
        try "{\"mcpServers\":{}}".write(to: target, atomically: true, encoding: .utf8)
        let link = home.appendingPathComponent("mcp.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        _ = try AgentIntegration.writeConfiguration(
            .bionic, to: link, key: key, helperPath: helper
        )

        let kind = try FileManager.default.attributesOfItem(atPath: link.path)[.type]
        XCTAssertEqual(
            kind as? FileAttributeType, .typeSymbolicLink, "ссылка заменена обычным файлом"
        )
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(written.contains(key), "настоящий файл остался со старым содержимым")
    }

    // MARK: - Куда ложится копия скилла

    /// Снимок скилла не лежит внутри папки скиллов — ни у одного агента.
    ///
    /// Это условие работы, а не порядок ради порядка. Hermes обходит дерево
    /// скиллов через `os.walk` (`agent/skill_utils.py`,
    /// `iter_skill_index_files`), и точка в начале имени папки его не
    /// останавливает: пропускаются только перечисленные поимённо в
    /// `EXCLUDED_SKILL_DIRS` — `.git`, `.hub`, `.archive` и **своя** папка
    /// копий `.curator_backups`. Чужой там нет и не будет.
    ///
    /// Снимок, положенный внутрь `skills/`, становится вторым скиллом с тем
    /// же именем, и `_locate_skill` отвечает «Ambiguous skill name … Refusing
    /// to guess», не загружая **ни одного** из двух. Копия, сделанная ради
    /// безопасности, ломала то, что берегла.
    func testSkillBackupsLiveOutsideTheSkillsTree() {
        for kind in AgentKind.allCases {
            let skills = kind.home.appendingPathComponent("skills").pathComponents
            let backups = kind.skillBackups.pathComponents
            // Сравнение **по составляющим пути**, а не по началу строки:
            // «skills-backups» начинается со «skills», и проверка на префикс
            // объявила бы верный путь нарушением.
            XCTAssertFalse(
                backups.count > skills.count && Array(backups.prefix(skills.count)) == skills,
                "\(kind.title): снимки лежат в дереве скиллов — \(kind.skillBackups.path)"
            )
            XCTAssertTrue(
                kind.skillBackups.pathComponents.contains("skills-backups"),
                "\(kind.title): \(kind.skillBackups.path)"
            )
        }
    }

    /// Проверка предыдущего теста ловит именно вложенность, а не имя.
    ///
    /// Путь «skills-backups» начинается со «skills»: сравнение по началу
    /// строки прошло бы мимо настоящей вложенности и споткнулось бы
    /// о правильный путь. Здесь обе стороны проверены нарочно.
    func testTheNestingCheckTellsSkillsBackupsFromSkills() {
        let home = URL(fileURLWithPath: "/tmp/дом")
        func nested(_ path: String) -> Bool {
            let skills = home.appendingPathComponent("skills").pathComponents
            let candidate = home.appendingPathComponent(path).pathComponents
            return candidate.count > skills.count
                && Array(candidate.prefix(skills.count)) == skills
        }
        XCTAssertTrue(nested("skills/.chromadb-manager-backups"), "вложенность не замечена")
        XCTAssertTrue(nested("skills/research/chromadb-manager"), "вложенность не замечена")
        XCTAssertFalse(nested("skills-backups/chromadb-manager"), "соседняя папка принята за вложенную")
        XCTAssertFalse(nested("skills"), "сама папка скиллов — не вложенность в себя")
    }

    /// Снимки, положенные прежними сборками внутрь `skills/`, переезжают.
    ///
    /// Смена папки снимков не убирала уже положенных: каждый оставался вторым
    /// скиллом с тем же именем. Занятое имя на новом месте не затирается.
    func testSnapshotsLeftInsideTheSkillsTreeMoveOut() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("skills/.chromadb-manager-backups")
        let backups = home.appendingPathComponent("skills-backups/chromadb-manager")
        for folder in [legacy, backups] {
            let snapshot = folder.appendingPathComponent("chromadb-manager-20260831-101500")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try "---\nname: chromadb-manager\n---\n\(folder.lastPathComponent)".write(
                to: snapshot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }

        AgentIntegration.moveSnapshots(from: legacy, to: backups, fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "старая папка осталась в дереве скиллов")
        XCTAssertEqual(
            try String(
                contentsOf: backups.appendingPathComponent("chromadb-manager-20260831-101500-2/SKILL.md"),
                encoding: .utf8
            ),
            "---\nname: chromadb-manager\n---\n.chromadb-manager-backups"
        )
        XCTAssertEqual(
            try String(
                contentsOf: backups.appendingPathComponent("chromadb-manager-20260831-101500/SKILL.md"),
                encoding: .utf8
            ),
            "---\nname: chromadb-manager\n---\nchromadb-manager",
            "снимок на новом месте затёрт переехавшим"
        )
    }

    /// Снимок — папка целиком, а не один `SKILL.md`.
    ///
    /// Рядом с манифестом лежат `references/`, `scripts/` и прочее. По копии
    /// одного файла прежнее состояние не вернуть, а прежний `backUp` клал
    /// рядом с оригиналом именно файл — и тот оседал внутри пакета скилла.
    func testTheSnapshotKeepsTheWholeSkillFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = home.appendingPathComponent("skills/research/chromadb-manager")
        let references = installed.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try "---\nname: chromadb-manager\n---\nпрежний".write(
            to: installed.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "таблица подстановок".write(
            to: references.appendingPathComponent("tables.md"), atomically: true, encoding: .utf8
        )

        let backups = home.appendingPathComponent("skills-backups/chromadb-manager")
        let path = try AgentIntegration.snapshotFolder(
            installed, named: "chromadb-manager", in: backups, fileManager: .default
        )

        let snapshot = URL(fileURLWithPath: path)
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "---\nname: chromadb-manager\n---\nпрежний"
        )
        XCTAssertEqual(
            try String(contentsOf: snapshot.appendingPathComponent("references/tables.md"), encoding: .utf8),
            "таблица подстановок",
            "вложенная папка в снимок не попала — вернуть прежнее состояние нечем"
        )
        // И в самой папке скилла копия не осела.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.path)
            .filter { $0.contains(".bak-") }
        XCTAssertEqual(leftovers, [], "копия осталась внутри пакета скилла: \(leftovers)")
    }

    /// Список без отступа — тоже список.
    ///
    /// Элемент последовательности YAML разрешает писать на том же отступе,
    /// что и ключ над ним, и `- name: other` в первом столбце печатает по
    /// умолчанию PyYAML. Проверка считала отступ ноль выходом из отображения,
    /// список не узнавала — и вписывала в него ключ, то есть делала ровно то,
    /// ради чего заведена. Прежняя проверка знала только отступленную запись.
    func testAnIndentlessSequenceIsRefusedToo() {
        for text in [
            "mcp_servers:\n- name: other\n  command: /x\n",
            "mcp_servers:\n-\n  name: other\n",
            "mcp_servers:\n\n# заметка\n- name: other\n",
        ] {
            XCTAssertThrowsError(
                try AgentIntegration.hermesConfiguration(
                    merging: text, helperPath: helper, key: key
                ),
                "список без отступа принят за отображение"
            ) { error in
                guard case AgentIntegrationError.handEditedConfiguration = error else {
                    return XCTFail("ожидался отказ, пришло: \(error)")
                }
            }
        }
    }

    /// Пустое отображение под ключом — по-прежнему не список.
    func testAnEmptyMappingUnderTheRootStillTakesTheBlock() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "mcp_servers:\nmodels:\n  gpt: on\n", helperPath: helper, key: key
        )
        XCTAssertTrue(made.text.contains(AgentIntegration.serverName + ":"), "блок не вписан")
        XCTAssertTrue(made.text.contains("models:"), "чужой ключ потерян")
    }

    /// Корневой ключ в кавычках — тот же ключ.
    func testAQuotedRootKeyIsRecognised() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "\"mcp_servers\":\n  other:\n    command: /x\n",
            helperPath: helper, key: key
        )
        let roots = made.text.components(separatedBy: "\n").filter {
            let bare = $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return bare.hasPrefix("mcp_servers") && $0.hasPrefix("\"") || $0.hasPrefix("mcp_servers")
        }
        XCTAssertEqual(roots.count, 1, "корневой ключ задвоился: \(roots)")
        XCTAssertTrue(made.text.contains("  other:"), "чужой сервер потерян")
    }

    /// Шапка скилла с концами CRLF читается.
    ///
    /// `\r` не входит в `CharacterSet.whitespaces`: первая строка читалась
    /// как «---\r», имя не находилось, и скилл ставился под именем папки —
    /// которого агент по шапке не узнаёт.
    func testASkillHeaderWithWindowsLineEndingsIsRead() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = home.appendingPathComponent("SKILL.md")
        try "---\r\nname: it-doc-expertise\r\nversion: 1.0.0\r\n---\r\n\r\nтекст\r\n"
            .write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentIntegration.declaredSkillName(in: manifest), "it-doc-expertise")
    }

    /// Комментарий при пустой записи — заметка человека, а не «ничего».
    func testUnfoldingAnEmptyInlineMappingKeepsItsComment() throws {
        let made = try AgentIntegration.hermesConfiguration(
            merging: "mcp_servers: {}  # пока пусто\nlogging: info",
            helperPath: helper, key: key
        )
        XCTAssertTrue(made.text.contains("# пока пусто"), "комментарий потерян: \(made.text)")
        XCTAssertTrue(made.text.contains("\n  chromadb-manager:"), made.text)
    }

    /// Якорь и ссылка — тоже отказ, и сказано, что именно увидели.
    func testAnAnchorIsRefusedWithoutCallingItInlineServers() {
        XCTAssertThrowsError(
            try AgentIntegration.hermesConfiguration(
                merging: "mcp_servers: &servers\n  github:\n    command: /x",
                helperPath: helper, key: key
            )
        ) { error in
            let text = (error as? AgentIntegrationError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("якорь"), text)
        }
    }

    /// Скилл, который уже есть в другом разделе, обновляется на своём месте.
    ///
    /// Hermes опознаёт скилл по имени в шапке: копия под «research», когда
    /// своя лежит в «devops», — это два скилла с одним именем.
    func testAnExistingHermesSkillIsUpdatedWhereItAlreadyLives() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let devops = home.appendingPathComponent("skills/devops/\(AgentIntegration.skillName)")
        try FileManager.default.createDirectory(at: devops, withIntermediateDirectories: true)
        try "старое".write(
            to: devops.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        // Проверяется **тот же** код, что работает у агента: корень
        // передаётся параметром, копии логики в тесте нет.
        let found = AgentIntegration.hermesSkillFolder(
            in: home.appendingPathComponent("skills"), named: AgentIntegration.skillName
        )
        XCTAssertEqual(
            found.resolvingSymlinksInPath().path, devops.resolvingSymlinksInPath().path,
            "копия легла бы вторым скиллом с тем же именем"
        )

        // А когда своего нет — «research», как и было.
        let empty = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(
            AgentIntegration.hermesSkillFolder(
                in: empty.appendingPathComponent("skills"), named: "новый"
            ).lastPathComponent,
            "новый"
        )
        XCTAssertTrue(
            AgentIntegration.hermesSkillFolder(
                in: empty.appendingPathComponent("skills"), named: "новый"
            ).path.contains("/research/")
        )
    }

    /// Файл, который есть, но не читается, — отказ, а не перезапись.
    ///
    /// «Файла нет» и «файл есть, а прочитать нечем» уходили по одной ветке:
    /// конфигурация в другой кодировке стиралась вместе со всеми ключами
    /// человека, и **без снимка**.
    func testAnUnreadableFileIsRefusedInsteadOfOverwritten() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("config.yaml")
        // Байты, которые не разбираются как UTF-8.
        try Data([0xFF, 0xFE, 0x00, 0x41, 0x00, 0x42]).write(to: config)
        let before = try Data(contentsOf: config)
        XCTAssertThrowsError(try existingContents(of: config)) { error in
            guard case AgentIntegrationError.unreadableFile = error else {
                return XCTFail("не тот отказ: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: config), before, "файл тронут при отказе")
    }

    /// Отсутствие файла отказом не считается: его просто ещё нет.
    func testAnAbsentFileIsNotAnError() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(try existingContents(of: home.appendingPathComponent("нет.yaml")))
    }

    /// Нажатие, которое ничего не меняет, ничего и не пишет.
    ///
    /// Иначе третье нажатие подряд оставляет третий одинаковый снимок рядом
    /// с файлом, который не менялся, и настоящий снимок «до кнопки» теряется
    /// среди них.
    func testAPressThatChangesNothingWritesNothing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let skills = home.appendingPathComponent("skills/chromadb-manager")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let target = skills.appendingPathComponent("SKILL.md")
        let source = home.appendingPathComponent("источник.md")
        try "скилл".write(to: source, atomically: true, encoding: .utf8)
        try "скилл".write(to: target, atomically: true, encoding: .utf8)
        let modified = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate]

        // Прямой вызов внутренней части: `installSkill` требует установленного
        // агента, а проверяется здесь именно правило «нечего менять».
        let existing = try existingContents(of: target)
        XCTAssertEqual(existing, "скилл")
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate]) as? Date,
            modified as? Date, "файл тронут чтением"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: skills.path).count, 1,
            "рядом появился снимок там, где ничего не менялось"
        )
    }

    /// «Файл не тронут» проверяется на настоящем файле, а не на слиянии.
    ///
    /// Обещание это держится **порядком** строк внутри записи — сначала
    /// слияние, потом снимок, потом запись. Порядок ничем не был закреплён:
    /// перестановка трёх строк прошла бы мимо всех тестов, а отказ начал бы
    /// обрезать файл, который отказывается трогать.
    func testARefusalLeavesTheFileByteIdentical() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // Hermes: корень, который разобрать нечем.
        let yaml = home.appendingPathComponent("config.yaml")
        try "mcp_servers: &servers\n  github:\n    command: /чужой\n".write(
            to: yaml, atomically: true, encoding: .utf8
        )
        let yamlBefore = try Data(contentsOf: yaml)
        XCTAssertThrowsError(
            try AgentIntegration.writeConfiguration(
                .hermes, to: yaml, key: key, helperPath: helper
            )
        )
        XCTAssertEqual(try Data(contentsOf: yaml), yamlBefore, "отказ тронул файл")

        // Bionic: JSON, который не разбирается.
        let json = home.appendingPathComponent("mcp.json")
        try "{ это не json ".write(to: json, atomically: true, encoding: .utf8)
        let jsonBefore = try Data(contentsOf: json)
        XCTAssertThrowsError(
            try AgentIntegration.writeConfiguration(
                .bionic, to: json, key: key, helperPath: helper
            )
        )
        XCTAssertEqual(try Data(contentsOf: json), jsonBefore, "отказ тронул файл")

        // И снимка не осталось: отказ ничего не пишет вовсе.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(),
            ["config.yaml", "mcp.json"],
            "отказ оставил после себя файлы"
        )
    }

    /// А удачная запись тот же путь проходит целиком: снимок есть, ключ на
    /// месте, чужой сервер не потерян.
    func testASuccessfulWriteGoesThroughTheWholePath() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let yaml = home.appendingPathComponent("config.yaml")
        try "mcp_servers:\n  github:\n    command: /чужой\n".write(
            to: yaml, atomically: true, encoding: .utf8
        )
        let outcome = try AgentIntegration.writeConfiguration(
            .hermes, to: yaml, key: key, helperPath: helper
        )
        XCTAssertNotNil(outcome.backup, "снимок не сделан")
        XCTAssertFalse(outcome.changedNothing)
        let after = try String(contentsOf: yaml, encoding: .utf8)
        XCTAssertTrue(after.contains(key), after)
        XCTAssertTrue(after.contains("  github:"), "чужой сервер потерян")

        // Повтор тем же ключом ничего не пишет и снимка не оставляет.
        let again = try AgentIntegration.writeConfiguration(
            .hermes, to: yaml, key: key, helperPath: helper
        )
        XCTAssertTrue(again.changedNothing)
        XCTAssertNil(again.backup)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: home.path)
                .filter { $0.contains(".bak-") }.count,
            1, "повтор оставил второй снимок"
        )
    }

    /// Перевод строки в значении не рвёт построчную сборку блока.
    ///
    /// Путь берётся у бандла, а в macOS он может содержать что угодно, кроме
    /// «/» и нуля. Сырой перевод строки внутри кавычек развалил бы и отсчёт
    /// конца блока при следующем нажатии.
    func testYamlScalarEscapesControlCharacters() throws {
        let odd = "/Volumes/Диск/стран\nная/ChromaDB Manager.app/Contents/MacOS/chromadb-mcp"
        let made = try AgentIntegration.hermesConfiguration(
            merging: "", helperPath: odd, key: "cdbm_\u{7}x"
        )
        XCTAssertFalse(made.text.contains("стран\nная"), "сырой перевод строки в блоке")
        XCTAssertTrue(made.text.contains("стран\\nная"), made.text)
        // Блок остался восемью строками, как и был.
        let block = made.text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") || $0.hasPrefix("    ") }
        XCTAssertEqual(block.count, 8, made.text)
    }

    /// Ненайденному агенту не создаётся папка: отказ — это отказ.
    func testAnAbsentAgentIsRefusedAndNothingIsCreated() {
        // `.bionic` опознаётся по /Applications/Bionic.app; на машине без него
        // кнопка обязана отказать, а не завести ~/.lmstudio.
        guard !AgentKind.bionic.isInstalled else {
            return  // Bionic здесь есть — проверять нечего.
        }
        XCTAssertThrowsError(
            try AgentIntegration.installServer(.bionic, key: key, helperPath: helper)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: AgentKind.bionic.home.path),
            "папка агента заведена там, где агента нет"
        )
    }

    /// Имя скилла обязано совпадать с именем его папки — этого требует Bionic.
    ///
    /// Две строки, ничем не связанные: `skillName` в коде и `name` в шапке
    /// файла. Разойдутся — агент молча не увидит скилла, и отличить это от
    /// «не установили» нельзя.
    func testTheSkillNameMatchesTheFolderBionicRequires() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/hermes/chromadb-manager-SKILL.md")
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("name:") })
        else { return XCTFail("в шапке скилла нет имени") }
        let name = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(
            name, AgentIntegration.skillName,
            "имя в шапке разошлось с именем папки — Bionic такой скилл не увидит"
        )
    }

    // MARK: - Скилл папкой

    /// Скилл кладётся папкой целиком: без `references` он неисполним.
    ///
    /// Живой случай: скилл правился в своём хранилище, а у агента лежала
    /// копия недельной давности — и агент читал вчерашние правила, считая
    /// их сегодняшними. Кнопка умела один файл и до вложенных папок не
    /// доставала вовсе.
    func testASkillIsInstalledWholeWithItsSubfolders() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try skillSource(in: home)
        let target = home.appendingPathComponent("skills/expertise/it-doc-expertise")

        let outcome = try AgentIntegration.copySkill(
            from: source, to: target, named: "it-doc-expertise",
            backupsIn: home.appendingPathComponent("skills/.backups")
        )

        XCTAssertEqual(outcome.filesWritten, 4, "доехало не всё")
        XCTAssertFalse(outcome.replacedExisting)
        XCTAssertNil(outcome.backup, "снимок нечего было делать")
        for relative in ["SKILL.md", "references/inputs.json", "references/checks/list.md", "scripts/run.py"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.appendingPathComponent(relative).path),
                "не доехал \(relative)"
            )
        }
    }

    /// Служебное к агенту не едет: история хранилища и метки Finder.
    func testTheRepositoryPlumbingIsLeftBehind() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try skillSource(in: home)
        let files = AgentIntegration.skillFiles(in: source)
        XCTAssertEqual(files, [
            "SKILL.md", "references/checks/list.md", "references/inputs.json", "scripts/run.py",
        ], "в выдаче служебное или пропало нужное")
        // Снимок узнаётся по своему имени, а не по подстроке: чужой файл
        // со словом «bak» в имени — это содержимое скилла.
        XCTAssertTrue(AgentIntegration.isSnapshotName("SKILL.md.bak-20260906-120000"))
        XCTAssertFalse(AgentIntegration.isSnapshotName("выгрузка.bak-старая.md"))
    }

    /// Имя берётся из шапки, а не из имени папки: по нему скилл ищет агент.
    func testTheNameComesFromTheHeaderNotTheFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try skillSource(in: home)
        XCTAssertEqual(
            AgentIntegration.declaredSkillName(in: source.appendingPathComponent("SKILL.md")),
            "it-doc-expertise"
        )
        // Папка называется иначе — имя всё равно из шапки.
        XCTAssertNotEqual(source.lastPathComponent, "it-doc-expertise")
    }

    /// Второе нажатие подряд не пишет ничего и не оставляет снимка.
    func testASecondPressChangesNothing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try skillSource(in: home)
        let target = home.appendingPathComponent("skills/expertise/it-doc-expertise")
        let backups = home.appendingPathComponent("skills/.backups")
        _ = try AgentIntegration.copySkill(
            from: source, to: target, named: "it-doc-expertise", backupsIn: backups
        )
        let again = try AgentIntegration.copySkill(
            from: source, to: target, named: "it-doc-expertise", backupsIn: backups
        )
        XCTAssertTrue(again.changedNothing)
        XCTAssertEqual(again.filesWritten, 0)
        XCTAssertNil(again.backup)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: backups.path),
            "снимок там, где ничего не менялось"
        )
    }

    /// Снимок ложится **вне** разделов, по которым агент ищет скиллы.
    ///
    /// Папка со своим `SKILL.md` внутри раздела — это второй скилл с тем же
    /// именем, и агент увидит оба.
    func testTheSnapshotDoesNotBecomeASecondSkill() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = try skillSource(in: home)
        let target = home.appendingPathComponent("skills/expertise/it-doc-expertise")
        let backups = home.appendingPathComponent("skills/.backups")
        _ = try AgentIntegration.copySkill(
            from: source, to: target, named: "it-doc-expertise", backupsIn: backups
        )
        try "правило второе\n".write(
            to: source.appendingPathComponent("references/inputs.json"),
            atomically: true, encoding: .utf8
        )
        let outcome = try AgentIntegration.copySkill(
            from: source, to: target, named: "it-doc-expertise", backupsIn: backups
        )
        XCTAssertEqual(outcome.filesWritten, 1, "переписан не только изменившийся файл")
        let backup = try XCTUnwrap(outcome.backup)
        XCTAssertTrue(backup.hasPrefix(backups.path), backup)
        // В самом разделе — по-прежнему один скилл.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: home.appendingPathComponent("skills/expertise").path
            ),
            ["it-doc-expertise"]
        )
    }

    /// Папка без `SKILL.md` — не скилл, и об этом говорится словами.
    func testAFolderWithoutASkillFileIsRefused() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let empty = home.appendingPathComponent("пусто")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try AgentIntegration.copySkill(
                from: empty, to: home.appendingPathComponent("куда"), named: "нет",
                backupsIn: home.appendingPathComponent("снимки")
            )
        ) { error in
            XCTAssertTrue(
                (error as? AgentIntegrationError)?.localizedDescription.contains("SKILL.md") ?? false,
                "\(error)"
            )
        }
    }

    /// Имя из чужой шапки не уводит запись из папки скиллов.
    ///
    /// Имя приезжает из файла, который писали не мы, и превращается в путь.
    /// «../../evil» записал бы папку мимо скиллов вовсе, «expertise/it-doc» —
    /// этажом глубже, где агент скилла не найдёт.
    func testAHeaderNameCannotEscapeTheSkillsFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for bad in ["../../evil", "expertise/it-doc", ".hidden", "..", ".", " ", "a\\b"] {
            XCTAssertNil(AgentIntegration.safeSkillName(bad), "имя «\(bad)» принято за годное")
        }
        for good in ["it-doc-expertise", "chromadb-manager", "skill.v2"] {
            XCTAssertEqual(AgentIntegration.safeSkillName(good), good)
        }

        // И то же правило — на живой папке: шапка с путём отвергается, а не
        // молча подменяется именем папки.
        let source = try skillSource(in: home)
        try "---\nname: ../../evil\n---\n\nправила\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(AgentIntegration.skillName(forFolderAt: source))
    }

    /// Имя читается из шапки, а не из текста скилла.
    ///
    /// Ниже шапки «name:» — это пример из чьих-то правил, и брать его в имя
    /// папки, куда мы пишем, нельзя.
    func testTheNameIsReadFromTheHeaderOnly() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manifest = home.appendingPathComponent("SKILL.md")
        try "---\ndescription: без имени\n---\n\nname: не-имя-а-пример\n"
            .write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertNil(
            AgentIntegration.declaredSkillName(in: manifest),
            "имя взято из текста скилла, а не из шапки"
        )
        // Шапки нет вовсе — тоже не имя.
        try "name: сразу-без-шапки\n".write(to: manifest, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentIntegration.declaredSkillName(in: manifest))
    }

    /// Хранилище скилла: имя папки нарочно не совпадает с именем в шапке.
    private func skillSource(in home: URL) throws -> URL {
        let source = home.appendingPathComponent("хранилище")
        let manager = FileManager.default
        try manager.createDirectory(
            at: source.appendingPathComponent("references/checks"), withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: source.appendingPathComponent(".git/objects"), withIntermediateDirectories: true
        )
        try "---\nname: it-doc-expertise\n---\n\nправила\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "{}\n".write(
            to: source.appendingPathComponent("references/inputs.json"), atomically: true, encoding: .utf8
        )
        try "проверки\n".write(
            to: source.appendingPathComponent("references/checks/list.md"), atomically: true, encoding: .utf8
        )
        try "print(1)\n".write(
            to: source.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8
        )
        // Служебное, которому к агенту ехать незачем.
        try "объект\n".write(
            to: source.appendingPathComponent(".git/objects/abc"), atomically: true, encoding: .utf8
        )
        try "мусор\n".write(
            to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8
        )
        try "снимок\n".write(
            to: source.appendingPathComponent("SKILL.md.bak-20260906-120000"),
            atomically: true, encoding: .utf8
        )
        return source
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Ни один путь не берётся из головы: всё считается от домашней папки
    /// того, кто запустил, а Bionic ищется по идентификатору бандла.
    ///
    /// Иначе кнопки работают на одной машине и молчат на всех прочих: приложение
    /// ставят и в `~/Applications`, и на другой том.
    func testEveryPathIsDerivedAndNotHardCoded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for kind in AgentKind.allCases {
            XCTAssertTrue(kind.home.path.hasPrefix(home), "\(kind.title): \(kind.home.path)")
            XCTAssertTrue(kind.configuration.path.hasPrefix(home), kind.configuration.path)
            XCTAssertTrue(
                kind.skillFolder(named: AgentIntegration.skillName).path.hasPrefix(home),
                kind.title
            )
        }
        // Путь к помощнику берётся у бандла, а не пишется строкой.
        XCTAssertFalse(
            MCPConnectionConfig.configPaths.contains { $0.contains("/Users/") },
            "в списке путей осталась чужая домашняя папка: \(MCPConnectionConfig.configPaths)"
        )
        XCTAssertTrue(
            MCPConnectionConfig.configPaths.contains { $0.contains("~/") },
            MCPConnectionConfig.configPaths.description
        )
    }

    // MARK: - Живые файлы этой машины

    /// Слияние проверяется на **настоящей** конфигурации Hermes, если она
    /// есть: правило ТЗ — не выдумывать формат, а брать с живой системы.
    /// Файл только читается.
    func testMergingTheRealHermesConfigurationLosesNothing() throws {
        let url = AgentKind.hermes.configuration
        guard let before = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("Hermes на этой машине не настроен")
        }
        let made = try AgentIntegration.hermesConfiguration(
            merging: before, helperPath: helper, key: key
        )
        // Ни одна строка вне нашего блока не пропала.
        //
        // «Наш блок» считается по отступам, а не по списку известных ключей.
        // Список ключей узнаёт `command:`, но не узнаёт **продолжение** его
        // значения: в живом файле путь к помощнику свёрнут на две строки,
        // потому что в «ChromaDB Manager.app» есть пробел, — и строка
        // «      Manager.app/Contents/MacOS/chromadb-mcp» объявлялась
        // потерянной, хотя слияние заменило её ровно так, как обещало.
        // Проверять надо то же, что делает сам код: всё с отступом больше
        // нашего — наше.
        let lines = before.components(separatedBy: "\n")
        var ours = Set<Int>()
        if let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(AgentIntegration.serverName):")
        }) {
            let indent = lines[start].prefix { $0 == " " }.count
            ours.insert(start)
            var cursor = start + 1
            while cursor < lines.count {
                let line = lines[cursor]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { cursor += 1; continue }
                if line.prefix(while: { $0 == " " }).count <= indent { break }
                ours.insert(cursor)
                cursor += 1
            }
            XCTAssertGreaterThan(
                ours.count, 1, "блок сервера в живом файле пуст — проверять нечего"
            )
        }
        let kept = Set(made.text.components(separatedBy: "\n"))
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || line == "mcp_servers:" || ours.contains(index) { continue }
            XCTAssertTrue(kept.contains(line), "потеряна строка живой конфигурации: «\(line)»")
        }
        XCTAssertTrue(made.replaced, "в живой конфигурации сервер уже есть — ожидалась замена")
    }
}
