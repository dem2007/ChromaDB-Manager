import XCTest
@testable import ChromaCore

/// «ни одна длительная операция не запускается в обход очереди — проверено
/// обзором кода и тестом, фиксирующим отсутствие прямых вызовов».
///
/// This is that test. It reads the app's own sources, because the rule it holds
/// is about how the code is written, not about what it computes: a new screen
/// calling `syncService.sync` straight from a button would compile, pass every
/// other test, and quietly bring back the thing F2 exists to prevent — two long
/// operations fighting over one local model.
final class NoQueueBypassTests: XCTestCase {
    /// Точки входа, которые занимают минуты — модель, базу или и то и другое.
    ///
    /// **Список обязан расти вместе с приложением.** Первая редакция знала пять
    /// операций, а приложение доросло до одиннадцати — и обзор коллекции
    /// действительно шёл мимо очереди: операция работала, а на экране «Задачи»
    /// её не было и отменить её оттуда было нечем. Сторож, который смотрит на
    /// пятую часть кода, охраняет ровно пятую часть правила.
    ///
    /// Чего здесь намеренно нет: `EvaluationRunner.run`. Это не длительная
    /// операция, а распорядитель — модель он занимает не сам, а через вызовы,
    /// каждый из которых берёт свой билет (см. `EvaluationViewModel`). Правило
    /// 2 он не нарушает, а обернуть его вторым билетом значило бы поставить
    /// билет в очередь за собственными билетами.
    private let longOperations = [
        "syncService.sync(",
        "importService.importDocuments(",
        "reembeddingService.run(",
        "lmStudio.embed(",
        "client.embed(",
        "CollectionInspector(",
        "CollectionFacetBuilder(",
        "TopicClustering(",
        "CollectionExporter(",
        "CollectionImporter(",
        // У судьи создание и вызов разнесены: собрать его можно где
        // угодно, а минуты занимает именно `run`.
        "judge.run(",
    ]

    private var appSources: [URL] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // ChromaCoreTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // package root
                .appendingPathComponent("Sources/ChromaDBManagerApp")
            let manager = FileManager.default
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw XCTSkip("исходники приложения не найдены рядом с тестами")
            }
            return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
    }

    /// Строки, лежащие внутри замыкания `queue.run { … }`, — по счёту скобок.
    ///
    /// Прежняя редакция считала иначе: «билет должен встретиться не выше чем за
    /// 25 строк». Это ломалось на любом замыкании с подготовкой внутри —
    /// кластеризация собирает называтель тем на два десятка строк и честно
    /// стоит в очереди, а сторож объявлял её нарушением. Считать скобки не
    /// сложнее, а врёт такой счёт только на скобке внутри строкового литерала —
    /// поэтому литералы и комментарии выбрасываются заранее.
    static func queuedLineNumbers(_ lines: [String]) -> Set<Int> {
        var inside: Set<Int> = []
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard stripped(lines[index]).contains("queue.run(") else { continue }
            var depth = 0
            var started = false
            var cursor = index
            while cursor < lines.count {
                for character in stripped(lines[cursor]) {
                    if character == "{" { depth += 1; started = true }
                    if character == "}" { depth -= 1 }
                }
                inside.insert(cursor)
                if started, depth <= 0 { break }
                cursor += 1
            }
        }
        return inside
    }

    /// Без строковых литералов и комментариев: и там, и там скобки не считаются.
    static func stripped(_ line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if !inString, character == "/", previous == "/" {
                result.removeLast()
                break
            }
            if !inString { result.append(character) }
            previous = character
        }
        return result
    }

    func testNoLongOperationIsStartedAroundTheQueue() throws {
        var offenders: [String] = []

        for file in try appSources {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            let queued = Self.queuedLineNumbers(lines)
            for (index, line) in lines.enumerated() {
                let code = Self.stripped(line)
                guard longOperations.contains(where: { code.contains($0) }) else { continue }
                // Объявление — не вызов.
                guard !code.contains("func ") else { continue }
                guard !queued.contains(index) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Длительная операция запускается в обход очереди. \
            Оберните вызов в `app.queue.run(ticket) { context in … }`:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Счёт скобок должен уметь то, ради чего он заведён.
    func testTheBraceCounterSeesAWholeClosure() {
        let lines = """
        func run() {
            let result = try await app.queue.run(ticket) { context in
                let helper = Helper(
                    text: "} не скобка, а буква в строке"
                )
                return try await helper.doTheLongThing()
            }
            somethingElse()
        }
        """.components(separatedBy: "\n")
        let queued = Self.queuedLineNumbers(lines)
        XCTAssertTrue(queued.contains(5), "вызов внутри замыкания обязан считаться поставленным в очередь")
        XCTAssertFalse(queued.contains(7), "то, что после закрытия замыкания, в очереди не стоит")
    }

    /// The counterpart: the guard above is worthless if it cannot see the code.
    func testTheGuardActuallyReadsTheSources() throws {
        let files = try appSources
        XCTAssertGreaterThan(files.count, 15, "тест должен читать исходники приложения, а не пустоту")
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("queue.run("), "в приложении должны быть постановки в очередь")
        XCTAssertTrue(text.contains("syncService.sync("), "и сами длительные операции")
    }
}
