import XCTest

/// Цепочка первого запуска в «Требует решения».
///
/// Сторож по исходнику, как `CopyableNamesTests`: проверяется не то, что код
/// вычисляет, а то, как он написан. Причина та же — свойство, которое
/// защищается, **не видно в обычной работе**. У человека с настроенным
/// приложением карточка выглядит одинаково, разбей звенья на независимые
/// проверки или оставь цепочкой; разница вылезает ровно один раз — на чистой
/// машине, где вместо одного понятного шага человек получит четыре строки
/// сразу, три из которых следствия первой.
final class FirstRunChainTests: XCTestCase {
    private func overview() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/OverviewView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходник экрана не найден рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    }

    /// Тело `decisions` — от объявления до следующего объявления того же уровня.
    private func decisionsBody() throws -> [String] {
        let lines = try overview()
        guard let start = lines.firstIndex(where: { $0.contains("private var decisions: [Decision]") })
        else {
            XCTFail("не нашлось `decisions` — экран переписан, сторожа надо переписать вместе с ним")
            return []
        }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let indent = line.prefix { $0 == " " }.count
            if indent == 4, line.contains("private var") || line.contains("private func") { break }
            end += 1
        }
        return Array(lines[start..<end])
    }

    /// Звенья идут в порядке зависимости: движок → подключение → коллекции →
    /// источники. Порядок не косметика: каждое следующее имеет смысл только
    /// когда предыдущее выполнено.
    func testTheChainIsInDependencyOrder() throws {
        let body = try decisionsBody()
        let expected = ["\"engine\"", "\"connection\"", "\"empty-database\"", "\"no-sources\""]
        let positions = expected.map { identifier in
            body.firstIndex { $0.contains("id: \(identifier)") }
        }

        for (identifier, position) in zip(expected, positions) {
            XCTAssertNotNil(position, "звено \(identifier) пропало из цепочки")
        }
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "звенья переставлены: \(expected)")
    }

    /// Звенья связаны `else if`, а не стоят независимыми проверками.
    ///
    /// Это и есть «по одному за раз»: пока движок не установлен, «нет
    /// подключения» — не решение, а следствие, и отправлять человека
    /// в «Подключение» значит звать туда, где ему нечего нажать.
    func testTheLinksAreExclusive() throws {
        let body = try decisionsBody()
        for identifier in ["\"connection\"", "\"empty-database\"", "\"no-sources\""] {
            guard let position = body.firstIndex(where: { $0.contains("id: \(identifier)") })
            else { continue }
            // Ближайшая ветвь выше этого звена обязана быть `else if`.
            let branch = body[..<position].last { $0.contains("if ") }
            XCTAssertTrue(
                branch?.contains("} else if") ?? false,
                "звено \(identifier) стоит отдельной проверкой — на чистой машине оно покажется вместе с предыдущими"
            )
        }
    }

    /// Про движок спрашивается только после того, как окружение проверено.
    ///
    /// Иначе на старте, пока проба не прошла, приложение объявит движок
    /// неустановленным — то есть соврёт про то, что само ещё не выяснило.
    func testTheEngineIsClaimedOnlyAfterTheProbe() throws {
        let body = try decisionsBody()
        guard let position = body.firstIndex(where: { $0.contains("id: \"engine\"") }) else {
            return XCTFail("звено про движок пропало")
        }
        let condition = body[..<position].last { $0.contains("if ") } ?? ""
        XCTAssertTrue(
            condition.contains("checkedAt != nil"),
            "условие про движок не ждёт пробы окружения: \(condition)"
        )
    }
}
