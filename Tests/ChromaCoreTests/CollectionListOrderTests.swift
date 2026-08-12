import XCTest
@testable import ChromaCore

/// Порядок и отбор в списке коллекций.
final class CollectionListOrderTests: XCTestCase {

    private func collection(_ name: String, documents: Int?) -> ChromaCollection {
        var made = ChromaCollection(
            id: name, name: name, metadata: nil, dimension: 1024,
            tenant: nil, database: nil
        )
        made.documentCount = documents
        return made
    }

    // MARK: - Порядок по имени

    /// «Как в Finder»: числа сравниваются числами. Посимвольное сравнение
    /// поставило бы `files_10` перед `files_2`, и список выглядел бы
    /// неотсортированным.
    func testNamesWithNumbersSortAsNumbers() {
        let list = [
            collection("files_10", documents: 1),
            collection("files_2", documents: 1),
            collection("files_1", documents: 1),
        ]
        XCTAssertEqual(
            CollectionList.sorted(list, order: .nameAscending).map(\.name),
            ["files_1", "files_2", "files_10"]
        )
        XCTAssertEqual(
            CollectionList.sorted(list, order: .nameDescending).map(\.name),
            ["files_10", "files_2", "files_1"]
        )
    }

    func testCaseDoesNotSplitTheAlphabet() {
        let list = [collection("Wiki", documents: 1), collection("alpha", documents: 1)]
        XCTAssertEqual(
            CollectionList.sorted(list, order: .nameAscending).map(\.name),
            ["alpha", "Wiki"]
        )
    }

    // MARK: - Порядок по числу записей

    func testDocumentsSortBothWays() {
        let list = [
            collection("средняя", documents: 393),
            collection("большая", documents: 14497),
            collection("малая", documents: 50),
        ]
        XCTAssertEqual(
            CollectionList.sorted(list, order: .documentsDescending).map(\.name),
            ["большая", "средняя", "малая"]
        )
        XCTAssertEqual(
            CollectionList.sorted(list, order: .documentsAscending).map(\.name),
            ["малая", "средняя", "большая"]
        )
    }

    /// Главное свойство: непосчитанная коллекция — не пустая.
    ///
    /// `documentCount` приходит отдельным запросом, и до ответа он `nil`.
    /// Считать `nil` нулём значит поставить непосчитанную коллекцию первой
    /// при сортировке «меньше сверху» — то есть ровно туда, где на неё
    /// посмотрят и решат, что она пуста.
    func testUnknownCountsGoLastInBothDirections() {
        let list = [
            collection("неизвестна", documents: nil),
            collection("пустая", documents: 0),
            collection("полная", documents: 100),
        ]
        XCTAssertEqual(
            CollectionList.sorted(list, order: .documentsAscending).map(\.name),
            ["пустая", "полная", "неизвестна"]
        )
        XCTAssertEqual(
            CollectionList.sorted(list, order: .documentsDescending).map(\.name),
            ["полная", "пустая", "неизвестна"]
        )
    }

    /// Равные по числу идут по имени — иначе порядок прыгает от обновления
    /// к обновлению и список «шевелится» сам по себе.
    func testEqualCountsFallBackToTheName() {
        let list = [
            collection("яблоко", documents: 5),
            collection("абрикос", documents: 5),
        ]
        XCTAssertEqual(
            CollectionList.sorted(list, order: .documentsDescending).map(\.name),
            ["абрикос", "яблоко"]
        )
    }

    // MARK: - Поиск

    func testSearchMatchesAnywhereAndIgnoresCase() {
        let list = [
            collection("files_2_hierarchical", documents: 1),
            collection("wiki_files", documents: 1),
            collection("new_test", documents: 1),
        ]
        XCTAssertEqual(
            CollectionList.filtered(list, search: "FILES").map(\.name),
            ["files_2_hierarchical", "wiki_files"]
        )
        // Середина слова — обычный случай: коллекции называются длинно.
        XCTAssertEqual(CollectionList.filtered(list, search: "hier").map(\.name), ["files_2_hierarchical"])
    }

    func testAnEmptySearchKeepsEverything() {
        let list = [collection("a", documents: 1), collection("b", documents: 1)]
        XCTAssertEqual(CollectionList.filtered(list, search: "").count, 2)
        XCTAssertEqual(CollectionList.filtered(list, search: "   ").count, 2)
    }

    // MARK: - Счётчик

    /// «Коллекций: 3» в базе из одиннадцати — не сведения, а недоразумение.
    func testTheCountLineNamesBothNumbersWhileFiltering() {
        XCTAssertEqual(CollectionList.countLine(shown: 11, total: 11), "Коллекций: 11")
        XCTAssertTrue(CollectionList.countLine(shown: 3, total: 11).contains("3"))
        XCTAssertTrue(CollectionList.countLine(shown: 3, total: 11).contains("11"))
    }

    /// Отбор и порядок применяются вместе и в таком порядке: сначала что
    /// показывать, потом как расставить.
    func testArrangeFiltersThenSorts() {
        let list = [
            collection("files_10", documents: 1),
            collection("files_2", documents: 300),
            collection("wiki", documents: 900),
        ]
        XCTAssertEqual(
            CollectionList.arrange(list, order: .documentsDescending, search: "files").map(\.name),
            ["files_2", "files_10"]
        )
    }
}
