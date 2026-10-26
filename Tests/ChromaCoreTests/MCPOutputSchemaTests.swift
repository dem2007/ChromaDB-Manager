import XCTest
@testable import ChromaCore

/// Ответ соответствует схеме, которую инструмент сам и объявил.
///
/// «Объявляется не для красоты: объявив её, сервер **обязан** возвращать
/// `structuredContent` по ней» — так написано у `MCPToolDefinition`, и так
/// это понимает клиент. Hermes сверяет выдачу со схемой и при расхождении
/// выбрасывает **весь ответ**, отдавая агенту ошибку валидации.
///
/// Живой случай, ради которого сторож и написан: `get_file` с «outline»
/// отдаёт `sections` и не отдаёт `documents`, а схема требовала `documents`.
/// Карта файла на 1281 кусок до агента не дошла ни разу; он вычитал числа
/// из текста ошибки, счёл, что оглавление получено, и дальше угадывал
/// названия разделов. Ни один тест этого не видел: проверялось содержимое
/// ответа, но не его согласие с собственной схемой.
final class MCPOutputSchemaTests: XCTestCase {
    private let key = "ключ-схемы"

    /// Каждая ветка каждого инструмента — против его же объявленной схемы.
    ///
    /// Ветки перечислены поимённо, а не собраны одним удачным вызовом:
    /// расходится обычно та, о которой не подумали, — пустая выдача,
    /// промах по имени, смещение за концом.
    func testEveryAnswerSatisfiesTheSchemaItsToolDeclares() async throws {
        let service = await service(Backend())
        for (tool, arguments) in Self.cases {
            let named = "\(tool) \(JSONValue.object(arguments).jsonString ?? "")"
            let result = try await service.call(
                name: tool, arguments: .object(arguments), key: key
            ).get()
            guard let structured = result["structuredContent"] else {
                XCTFail("\(named): схема объявлена, а structuredContent нет")
                continue
            }
            let schema = try XCTUnwrap(Self.schema(of: tool), "\(named): у инструмента нет схемы")
            XCTAssertEqual(Self.violations(structured, against: schema), [], named)
        }
    }

    /// Ни один инструмент не остался без ветки в списке выше.
    ///
    /// Список написан руками, а каталог растёт: девятый инструмент иначе
    /// не проверялся бы вовсе, и сторож молчал бы именно там, где новее
    /// всего код.
    func testTheCaseListCoversEveryToolInTheCatalogue() {
        let covered = Set(Self.cases.map(\.tool))
        let missing = Set(MCPToolCatalogue.all.map(\.name)).subtracting(covered).sorted()
        XCTAssertEqual(missing, [], "инструмент без ветки в проверке")
    }

    /// Схема, по которой сверяют, сама обязана быть схемой.
    ///
    /// Без этого сторож проходит вхолостую: опечатка в слове «properties»
    /// или пустой «required» — и сверять становится не с чем, а тест
    /// по-прежнему зелёный.
    func testEveryDeclaredOutputSchemaIsWellFormed() {
        for tool in MCPToolCatalogue.all {
            guard let schema = tool.outputSchema else { continue }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
            XCTAssertFalse(
                schema["properties"]?.objectValue?.isEmpty ?? true,
                "\(tool.name): в схеме ответа нет properties"
            )
            XCTAssertFalse(
                schema["required"]?.arrayValue?.isEmpty ?? true,
                "\(tool.name): в схеме ответа нет required"
            )
        }
    }

    /// Ветки, по которым ходит сторож: у каждого инструмента — обычный ответ,
    /// а у чтения файла ещё и все его виды и промахи.
    private static let cases: [(tool: String, arguments: [String: JSONValue])] = [
            ("list_collections", [:]),
            ("describe_collection", ["collection": .string("заметки")]),
            ("search", ["collection": .string("заметки"), "query": .string("приёмка")]),
            ("search", [
                "collections": .array([.string("заметки"), .string("письма")]),
                "query": .string("приёмка"),
            ]),
            ("get_documents", ["collection": .string("заметки"), "limit": .int(3)]),
            ("get_documents", [
                "collection": .string("заметки"),
                "where": .object(["file_id": .object(["$eq": .string("нет-такого")])]),
            ]),
            // Чтение по порядку: страница, хвост, промах по пути и по отпечатку.
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "limit": .int(2)]),
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "offset": .int(99)]),
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/нет.md")]),
            ("get_file", ["collection": .string("заметки"), "file_id": .string("0000000000000000")]),
            // Карта файла — та самая ветка, что ломалась живьём.
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "outline": .bool(true)]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "outline": .bool(true), "outline_depth": .int(9),
                "heading": .string("Требования"),
            ]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "outline": .bool(true), "heading": .string("Нет такого раздела"),
            ]),
            // Чтение по разделу: страница, промах по названию, смещение за концом.
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "heading": .string("Требования")]),
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "heading": .string("Нет такого раздела")]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "heading": .string("Требования"), "offset": .int(99),
            ]),
            ("collect_mentions", ["collection": .string("заметки"), "contains": .string("приёмк")]),
            // Список файлов: страница, промах по имени, смещение за концом, узкий срез.
            ("list_files", ["collection": .string("заметки")]),
            ("list_files", ["collection": .string("заметки"), "name": .string("нет-такого")]),
            ("list_files", ["collection": .string("заметки"), "offset": .int(99)]),
            ("list_files", [
                "collection": .string("заметки"), "folder": .string("папка"),
                "sort": .string("chunks"), "limit": .int(1),
            ]),
            ("add_documents", [
                "collection": .string("заметки"),
                "documents": .array([.object(["text": .string("новый кусок")])]),
            ]),
            ("delete_documents", ["collection": .string("заметки"), "ids": .array([.string("c0")])]),
    ]

    /// Пустая коллекция — тоже ветка, и она отвечает по той же схеме.
    func testAnEmptyCollectionStillAnswersBySchema() async throws {
        let service = await service(Backend(chunks: []))
        for (tool, arguments): (String, [String: JSONValue]) in [
            ("search", ["collection": .string("заметки"), "query": .string("приёмка")]),
            ("get_documents", ["collection": .string("заметки")]),
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md")]),
            ("get_file", ["collection": .string("заметки"), "file": .string("папка/тз.md"), "outline": .bool(true)]),
            ("collect_mentions", ["collection": .string("заметки"), "contains": .string("приёмк")]),
            ("list_files", ["collection": .string("заметки")]),
        ] {
            let result = try await service.call(
                name: tool, arguments: .object(arguments), key: key
            ).get()
            let structured = try XCTUnwrap(result["structuredContent"], tool)
            let schema = try XCTUnwrap(Self.schema(of: tool))
            XCTAssertEqual(Self.violations(structured, against: schema), [], tool)
        }
    }

    /// Сторож ловит именно ту поломку, ради которой написан.
    ///
    /// Без этого он мог бы молчать по любой причине — например, разбирая
    /// схему не с той стороны, — и мы узнали бы об этом снова от агента.
    func testTheGuardCatchesAMissingRequiredKey() {
        let schema = JSONValue.object([
            "properties": .object(["documents": .object(["type": .string("array")])]),
            "required": .array([.string("collection"), .string("documents")]),
        ])
        let structured = JSONValue.object([
            "collection": .string("заметки"), "sections": .array([]),
        ])
        XCTAssertEqual(Self.violations(structured, against: schema), ["нет обязательного поля «documents»"])
        XCTAssertEqual(
            Self.violations(.object(["documents": .string("не массив")]), against: schema),
            ["нет обязательного поля «collection»", "поле «documents»: объявлено array"]
        )
    }

    func testZZunitsProbe() async throws {
        let service = await service(Backend(chunks: Backend.heavy))
        for (tool, arguments) in [
            ("search", ["collection": JSONValue.string("заметки"), "query": .string("приёмка"), "n_results": .int(50)]),
            ("get_documents", ["collection": JSONValue.string("заметки"), "limit": .int(50)]),
        ] {
            let result = try await service.call(name: tool, arguments: .object(arguments), key: key).get()
            let text = result["content"]?[0]?["text"]?.stringValue ?? ""
            let structured = result["structuredContent"] ?? .null
            let json = (try? JSONEncoder().encode(structured)) ?? Data()
            let asString = String(decoding: json, as: UTF8.self)
            print("ЕДИНИЦЫ \(tool): текст знаков \(text.count), байт \(text.utf8.count); зеркало знаков \(asString.count), байт \(json.count)")
            print("   всего знаков \(text.count + asString.count), всего байт \(text.utf8.count + json.count), потолок 24000")
        }
    }

    /// Ответ, который не влез даже одним документом, говорит об этом.
    ///
    /// Первый документ отдаётся всегда — иначе ответ был бы пустым, — но
    /// у ключа с малым потолком метаданные одного куска больше всего бюджета,
    /// и ответ выходит за объявленное. Сплошной текст про этот случай
    /// говорит с, список молчал: агент видел ответ вдвое больше
    /// обещанного и не знал, почему.
    func testAnAnswerBiggerThanTheCeilingSaysSo() async throws {
        let heavy = [
            MCPDocumentPayload(
                id: "один",
                text: String(repeating: "текст ", count: 200),
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    MCPFileChunks.orderKey: .int(0),
                    "extraction_warnings": .string(String(repeating: "таблица плоским текстом; ", count: 60)),
                ]
            ),
        ]
        let service = await service(Backend(chunks: heavy), responseCharacters: 1_200)
        let result = try await service.call(
            name: "get_documents",
            arguments: .object(["collection": .string("заметки"), "limit": .int(5)]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        XCTAssertTrue(
            text.contains("longer than the key's ceiling"),
            "ответ вышел за потолок и промолчал: \(text.prefix(300))"
        )
        // И документ всё-таки отдан: пустой ответ хуже урезанного.
        XCTAssertEqual(result["structuredContent"]?["documents"]?.arrayValue?.count, 1)
    }

    /// И не говорит этого там, где ответ в потолок уложился.
    ///
    /// Рабочий остаток меньше потолка на подушку конверта — тысячу знаков,
    /// которые чаще всего не тратятся. Документ, переваливший через остаток,
    /// сплошь и рядом укладывается в объявленное, и пометка «ответ больше
    /// потолка» была бы про него неправдой.
    func testAnAnswerThatFitsDoesNotClaimOtherwise() async throws {
        // Кусок под самый остаток: больше рабочего бюджета, меньше потолка.
        let big = [
            MCPDocumentPayload(
                id: "один",
                text: String(repeating: "текст ", count: 3_700),
                metadata: [
                    "source_file": .string("папка/тз.md"),
                    MCPFileChunks.orderKey: .int(0),
                ]
            ),
        ]
        let service = await service(Backend(chunks: big))
        let result = try await service.call(
            name: "get_documents",
            arguments: .object(["collection": .string("заметки"), "limit": .int(5)]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
        XCTAssertLessThanOrEqual(
            text.count + mirror, MCPOutputLimits.defaultResponseCharacters,
            "подложка выбрана так, чтобы ответ в потолок укладывался"
        )
        XCTAssertFalse(
            text.contains("longer than the key's ceiling"),
            "ответ уложился, а пометка говорит обратное: \(text.prefix(200))"
        )
    }

    /// Потолок ответа держится **у всех** инструментов и без допуска.
    ///
    /// Мерка одна и в знаках: столько же, сколько обещано ключу и написано
    /// агенту в схеме. Прежде текст считался знаками, а зеркало — байтами
    /// UTF-8, и сумма двух разных единиц не значила ничего: на кириллице она
    /// давала 24 906 там, где ответ на деле нёс 17 280 знаков из 24 000.
    ///
    /// Проверяются все пять: рендер у них общий, и дыра в нём — дыра сразу
    /// у всех. Допуска нет: обещание либо держится, либо нет.
    func testEveryToolStaysInsideTheAnswerCeiling() async throws {
        // Подложка обязана **упереться** в потолок, иначе проверка зелена
        // на любом счёте: сорок кусков по полторы тысячи знаков с настоящим
        // набором метаданных — это втрое больше, чем ответ вместит.
        let deep = "Ведомство А/ОРИС/2026/П1-00001вн/Документ/2. ТЗ_Платформа_2030-2031.docx"
        let crowd = (0..<40).map { index in
            MCPDocumentPayload(
                id: "\(deep)#\(index)",
                text: String(repeating: "требование к оказанию услуги приёмка. ", count: 40),
                metadata: [
                    "source_file": .string(deep),
                    "file_id": .string("abcdef0123456789"),
                    MCPFileChunks.orderKey: .int(index),
                    "heading_path": .string("Требования к оказанию общих услуг"),
                    "extraction_warnings": .string(String(repeating: "таблица пришла плоским текстом; ", count: 8)),
                    "doc_type": .string("ГК ПР10 001_24_01 от 01.01.2024"),
                    "file_size": .int(1_240_238),
                ]
            )
        }
        var largest = 0
        var tightest = 0
        let cases: [(tool: String, arguments: [String: JSONValue])] = [
            ("search", ["collection": .string("заметки"), "query": .string("приёмка"), "n_results": .int(100)]),
            ("get_documents", ["collection": .string("заметки"), "limit": .int(100)]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string(deep),
                "as": .string("chunks"), "limit": .int(100),
            ]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string(deep),
                "heading": .string("Требования к оказанию общих услуг"),
                "as": .string("chunks"), "limit": .int(100),
            ]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string(deep),
                "outline": .bool(true),
            ]),
            ("get_file", ["collection": .string("заметки"), "file": .string(deep)]),
            ("collect_mentions", ["collection": .string("заметки"), "contains": .string("приёмк"), "limit": .int(100)]),
            ("list_files", ["collection": .string("заметки"), "limit": .int(500)]),
        ]
        // Два потолка, и второй тесный нарочно: при 24 000 запас конверта —
        // четыре процента ответа и скрывает промах в счёте, при 4 000 он
        // четверть, и всякая неточность видна сразу.
        for ceiling in [MCPOutputLimits.defaultResponseCharacters, 4_000] {
            let service = await service(Backend(chunks: crowd), responseCharacters: ceiling)
            for (tool, arguments) in cases {
                let named = "\(tool) \(JSONValue.object(arguments).jsonString ?? "") при потолке \(ceiling)"
                let result = try await service.call(
                    name: tool, arguments: .object(arguments), key: key
                ).get()
                let text = result["content"]?[0]?["text"]?.stringValue ?? ""
                let mirror = result["structuredContent"].map { $0.deliveredSize } ?? 0
                XCTAssertLessThanOrEqual(
                    text.count + mirror, ceiling,
                    "\(named): текст \(text.count) + зеркало \(mirror)"
                )
                if ceiling == MCPOutputLimits.defaultResponseCharacters {
                    largest = max(largest, text.count + mirror)
                } else {
                    tightest = max(tightest, text.count + mirror)
                }
            }
        }
        // И проверка не вырождена: хоть один ответ подошёл к потолку вплотную.
        // Без этого она зеленела бы на подложке, которая в него и не упиралась
        // (урок: сторож проверяет ту форму данных, что ему подсунули).
        XCTAssertGreaterThan(
            largest, MCPOutputLimits.defaultResponseCharacters * 3 / 4,
            "подложка не упирается в потолок — проверять нечего"
        )
        XCTAssertGreaterThan(tightest, 4_000 * 3 / 4, "то же и у тесного потолка")
    }

    /// Пометка об урезании называет параметр, который у инструмента есть.
    ///
    /// Рендер один на пять инструментов, и совет «позови снова с меньшим
    /// n_results» уезжал во все пять. Параметр с таким именем есть только у
    /// `search`; остальные листаются «limit» и отвергли бы `n_results` как
    /// неизвестный — «additionalProperties»: false. Совет, который нельзя
    /// выполнить, хуже молчания.
    func testACutNoteNamesAParameterTheToolAccepts() async throws {
        let service = await service(Backend(chunks: Backend.heavy), responseCharacters: 2500)
        let cases: [(tool: String, arguments: [String: JSONValue])] = [
            ("search", ["collection": .string("заметки"), "query": .string("приёмка"), "n_results": .int(6)]),
            ("get_documents", ["collection": .string("заметки"), "limit": .int(6)]),
            // Пометка об урезании списка есть только там, где список есть:
            // ветку кусков `get_file` с нужно называть явно.
            ("get_file", [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "as": .string("chunks"), "limit": .int(6),
            ]),
            ("get_file", [
                "collection": .string("заметки"), "file": .string("папка/тз.md"),
                "heading": .string("Требования"), "as": .string("chunks"), "limit": .int(6),
            ]),
            ("collect_mentions", ["collection": .string("заметки"), "contains": .string("приёмк"), "limit": .int(6)]),
        ]
        for (tool, arguments) in cases {
            let named = "\(tool) \(JSONValue.object(arguments).jsonString ?? "")"
            let result = try await service.call(
                name: tool, arguments: .object(arguments), key: key
            ).get()
            let text = result["content"]?[0]?["text"]?.stringValue ?? ""
            guard let note = text.split(separator: "\n").first(where: {
                $0.contains("was cut by total answer size")
            }) else {
                XCTFail("\(named): выдача не урезалась — проверять нечего")
                continue
            }
            // Проверяются **все** имена в кавычках, а не последнее: совет
            // называет и параметр страницы, и проекцию полей, и ошибиться
            // можно в любом из них.
            let asked = Self.quoted(in: String(note))
            let accepted = MCPToolCatalogue.all
                .first { $0.name == tool }?
                .inputSchema["properties"]?.objectValue?.keys.sorted() ?? []
            XCTAssertFalse(asked.isEmpty, "\(named): в пометке не названо, что уменьшать: \(note)")
            for name in asked {
                XCTAssertTrue(
                    accepted.contains(name),
                    "\(named): совет зовёт «\(name)», а у инструмента есть только \(accepted)"
                )
            }
        }
    }

    /// Выборке по идентификаторам не советуют уменьшать «limit».
    ///
    /// Живой замер: двенадцать идентификаторов при `limit` 12, 3 и 1 дают
    /// побайтно один и тот же ответ — «limit» на этот путь не действует.
    /// Совет уменьшить его означал бы «сделай то же самое ещё раз».
    func testACallByIdentifiersIsNotToldToShrinkTheLimit() async throws {
        let service = await service(Backend(chunks: Backend.heavy), responseCharacters: 2500)
        let result = try await service.call(
            name: "get_documents",
            arguments: .object([
                "collection": .string("заметки"),
                "ids": .array(Backend.heavy.map { .string($0.id) }),
            ]),
            key: key
        ).get()
        let text = result["content"]?[0]?["text"]?.stringValue ?? ""
        let note = text.split(separator: "\n").first { $0.contains("was cut by total answer size") }
        let asked = Self.quoted(in: String(note ?? ""))
        XCTAssertTrue(asked.contains("ids"), "совет обязан звать «ids»: \(note ?? "пометки нет")")
        XCTAssertFalse(
            String(note ?? "").contains("smaller «limit»"),
            "уменьшать «limit» тут бесполезно: \(note ?? "")"
        )
    }

    /// Имена в кавычках-ёлочках — по порядку и без повторов.
    private static func quoted(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«"),
              let close = rest[rest.index(after: open)...].firstIndex(of: "»") {
            let name = String(rest[rest.index(after: open)..<close])
            if !name.isEmpty, !found.contains(name) { found.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    // MARK: - Сверка со схемой

    private static func schema(of tool: String) -> JSONValue? {
        MCPToolCatalogue.all.first { $0.name == tool }?.outputSchema
    }

    /// Чего не хватает и что не того типа — по одной строке на расхождение.
    ///
    /// Проверяются ровно два обещания схемы, те самые, по которым клиент
    /// отвергает ответ: обязательные поля на месте, а объявленные — того
    /// типа, что объявлен. Полей сверх объявленных схема не запрещает.
    private static func violations(_ structured: JSONValue, against schema: JSONValue) -> [String] {
        var found: [String] = []
        for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where structured[name] == nil {
            found.append("нет обязательного поля «\(name)»")
        }
        for (name, declared) in schema["properties"]?.objectValue ?? [:] {
            guard let value = structured[name], let type = declared["type"]?.stringValue else { continue }
            let matches: Bool
            switch type {
            case "string": matches = value.stringValue != nil
            case "integer": matches = value.intValue != nil
            case "number": matches = value.doubleValue != nil
            case "boolean": matches = value.boolValue != nil
            case "array": matches = value.arrayValue != nil
            case "object": matches = value.objectValue != nil
            default: matches = true
            }
            if !matches { found.append("поле «\(name)»: объявлено \(type)") }
        }
        return found.sorted()
    }

    // MARK: - Подложка

    /// Отдаёт один файл из четырёх кусков: два раздела и безымянный кусок
    /// внутри первого — этого хватает и карте, и чтению по разделу.
    private struct Backend: MCPToolBackend {
        var chunks: [MCPDocumentPayload] = [
            Backend.chunk(0, heading: "Требования"),
            Backend.chunk(1, heading: "Требования > Функциональные"),
            Backend.chunk(2, heading: nil),
            Backend.chunk(3, heading: "Приёмка"),
        ]

        static func chunk(
            _ index: Int, heading: String?, path: String = "папка/тз.md", length: Int = 0
        ) -> MCPDocumentPayload {
            var metadata: ChromaMetadata = [
                "source_file": .string(path),
                // Отпечаток выводится из пути, а не из hashValue: он в Swift
                // засеян случайно на каждый запуск, и опереться на него
                // в проверке значило бы получить разный ответ дважды подряд.
                "file_id": .string("f" + String(path.unicodeScalars.reduce(0) { $0 &* 31 &+ $1.value })),
                MCPFileChunks.orderKey: .int(index),
            ]
            if let heading { metadata["heading_path"] = .string(heading) }
            let text = "кусок \(index) про приёмку"
            return MCPDocumentPayload(
                id: "\(path)#\(index)",
                text: length > 0 ? String(repeating: "п", count: length) : text,
                metadata: metadata
            )
        }

        /// Три файла по два длинных куска: столько, чтобы потолок объёма
        /// ответа сработал у каждого инструмента, а у сбора упоминаний
        /// нашлось больше одного файла.
        static let heavy: [MCPDocumentPayload] = ["папка/тз.md", "папка/акт.md", "папка/смета.md"]
            .flatMap { path in
                (0..<2).map { chunk($0, heading: $0 == 0 ? "Требования" : nil, path: path, length: 1500) }
            }

        func collections(allowed: [String]) async throws -> [MCPCollectionSummary] {
            ["заметки", "письма"].map {
                MCPCollectionSummary(name: $0, documentCount: chunks.count, model: "e5", metric: "cosine", dimension: 8)
            }
        }
        func describe(collection: String) async throws -> MCPCollectionDescription {
            MCPCollectionDescription(
                summary: MCPCollectionSummary(
                    name: collection, documentCount: chunks.count, model: "e5", metric: "cosine", dimension: 8
                ),
                fields: [], hasSchema: false, allowsExtraFields: true
            )
        }
        func search(_ request: MCPSearchRequest) async throws -> MCPSearchAnswer {
            MCPSearchAnswer(
                documents: chunks.map {
                    MCPDocumentPayload(id: $0.id, text: $0.text, metadata: $0.metadata, distance: 0.2)
                },
                metric: "cosine", model: "e5"
            )
        }

        func documents(_ request: MCPDocumentsRequest) async throws -> MCPDocumentsAnswer {
            if !request.ids.isEmpty {
                return MCPDocumentsAnswer(
                    documents: chunks.filter { request.ids.contains($0.id) }, hasMore: false
                )
            }
            // Отбор по файлу сравнивается как в базе; всякий другой фильтр —
            // это обход по слову у collect_mentions, ему подходит весь файл.
            let matched: [MCPDocumentPayload]
            if let condition = request.filter?.conditions.first,
               ["source_file", "file_name", "file_id"].contains(condition.field) {
                matched = chunks.filter {
                    guard case .string(let stored)? = $0.metadata?[condition.field] else { return false }
                    return stored == condition.value
                }
            } else {
                matched = chunks
            }
            let ordered = request.orderedByChunkIndex ? MCPFileChunks.ordered(matched) : matched
            let window = MCPFileChunks.page(ordered, offset: request.offset, limit: request.limit)
            let page = request.needsText ? window.page : window.page.map {
                MCPDocumentPayload(id: $0.id, text: nil, metadata: $0.metadata)
            }
            return MCPDocumentsAnswer(
                documents: page, hasMore: window.hasMore,
                total: request.orderedByChunkIndex ? ordered.count : nil
            )
        }

        func add(_ request: MCPAddRequest) async throws -> MCPAddAnswer {
            MCPAddAnswer(ids: request.documents.map { $0.id ?? "новый" }, model: "e5")
        }
        func delete(_ request: MCPDeleteRequest) async throws -> MCPDeleteAnswer {
            MCPDeleteAnswer(deleted: request.ids, missing: [], keptInTrash: true)
        }
    }

    private func service(_ backend: Backend, responseCharacters: Int? = nil) async -> MCPToolService {
        let client = ExternalClient(
            name: "агент",
            keyHash: ClientKey.hash(key),
            keyPrefix: String(key.prefix(4)),
            permissions: ClientPermissions(
                collections: ["заметки", "письма"], allowsWrite: true,
                // Всплеск — по числу веток в проверке: она зовёт инструменты
                // подряд, и предел вызовов отказывал бы последним из них.
                burst: 100,
                maxSearchResults: 100, maxResponseCharacters: responseCharacters,
                allowsDelete: true
            )
        )
        let access = AccessController()
        await access.setClients([client])
        return MCPToolService(backend: backend, access: access)
    }
}
