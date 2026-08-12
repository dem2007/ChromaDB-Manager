import XCTest

/// имя коллекции можно забрать из интерфейса.
///
/// Сторож по исходникам, как `SinglePresentationTests`: тут проверяется не
/// то, что код вычисляет, а то, как он написан. Пропавшее `.copyable`
/// компилируется, проходит все прочие тесты и оставляет человека наедине
/// с именем, которое видно, но не берётся, — а заметить это можно только
/// в окне, руками.
final class CopyableNamesTests: XCTestCase {
    private func collectionsView() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/CollectionsView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    }

    /// Строки функции с этим именем — от объявления до следующего объявления
    /// того же уровня.
    private func body(of function: String, in lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains("func \(function)(") }) else { return [] }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            let indent = line.prefix { $0 == " " }.count
            if indent <= 4, line.contains("func ") { break }
            end += 1
        }
        return Array(lines[start..<end])
    }

    /// Заголовок коллекции: имя берётся и мышью, и правой кнопкой.
    ///
    /// Обоими способами, и это не избыточность: имя длиной в экран обрезано
    /// посередине, и выделение мышью берёт только видимое.
    func testTheCollectionNameCanBeCopiedFromTheHeader() throws {
        let header = body(of: "collectionHeader", in: try collectionsView()).joined(separator: "\n")
        XCTAssertFalse(header.isEmpty, "функция заголовка коллекции не найдена")
        XCTAssertTrue(
            header.contains(".copyable(collection.name)"),
            "у имени коллекции должно быть «Скопировать» в правой кнопке"
        )
        XCTAssertTrue(
            header.contains(".textSelection(.enabled)"),
            "имя и строку фактов должно быть можно выделить мышью"
        )
    }

    /// И в списке слева — там выделять мышью нечего, строка занята выбором.
    func testTheCollectionNameCanBeCopiedFromTheList() throws {
        let row = body(of: "collectionRow", in: try collectionsView()).joined(separator: "\n")
        XCTAssertFalse(row.isEmpty, "функция строки списка не найдена")
        XCTAssertTrue(
            row.contains(".copyable(collection.name)"),
            "имя коллекции должно копироваться и из списка"
        )
    }
}

/// буквы колонок в разметке таблицы.
///
/// Тот же сторож по исходникам и по той же причине: буквы — единственное
/// имя колонки, не зависящее ни от строки заголовков, ни от переименований,
/// и пропажа их ломает не сборку, а работу человека.
final class ColumnLettersTests: XCTestCase {
    private func mappingView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/TableMappingView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Буквы стоят и над таблицей предпросмотра, и в списке колонок:
    /// смотрят то туда, то сюда, и опора нужна в обоих местах.
    func testBothTablesShowTheSpreadsheetLetters() throws {
        let source = try mappingView()
        let mentions = source.components(separatedBy: "XLSXReader.columnName").count - 1
        XCTAssertGreaterThanOrEqual(
            mentions, 2,
            "буквы колонок нужны и в предпросмотре строк, и в списке колонок"
        )
    }

    /// карточка «Сейчас» не меняет размеров от своего содержимого.
    ///
    /// Проверять глазами тут нечего: дефект виден только в движении — при
    /// запуске, когда подключается адрес, тикает аптайм и отвечает сервер.
    func testTheStatusCardKeepsItsSizeWhatever() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/OverviewView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            source.contains(".frame(height: Theme.Size.statusRow)"),
            "высота строки состояния задаётся числом, а не текстом в ней"
        )
        XCTAssertTrue(
            source.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "значение занимает всю оставшуюся ширину и не тянет строку за собой"
        )
        // Строка, которой может не быть, — это карточка, которая подрастает
        // на ходу. Телеметрия появлялась через секунду после запуска.
        XCTAssertFalse(
            source.contains("if let telemetry"),
            "строка телеметрии обязана стоять всегда — иначе карточка растёт на ходу"
        )
    }

    /// Строки списка колонок различаются по номеру, а не по заголовку.
    ///
    /// Заголовки в файле повторяются — «Итого» над каждым кварталом, — и на
    /// повторе `id: \.self` склеивает такие строки в одну: две колонки
    /// показываются как одна, и роль второй задать нечем.
    func testColumnRowsAreIdentifiedByPositionNotByTitle() throws {
        let source = try mappingView()
        XCTAssertFalse(
            source.contains("ForEach(binding.wrappedValue.columns, id: \\.self)"),
            "одинаковые заголовки колонок склеятся в одну строку"
        )
    }
}
