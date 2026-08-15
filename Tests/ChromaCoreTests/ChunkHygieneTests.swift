import XCTest
@testable import ChromaCore

/// Чанки без единого слова.
final class ChunkHygieneTests: XCTestCase {
    private func chunk(_ index: Int, _ text: String, level: Int = 0, parent: Int? = nil) -> TextChunk {
        TextChunk(index: index, text: text, level: level, parentIndex: parent)
    }

    func testWordsAreWhatCounts() {
        XCTAssertFalse(ChunkHygiene.carriesMeaning(")"))
        XCTAssertFalse(ChunkHygiene.carriesMeaning("]. )"))
        XCTAssertFalse(ChunkHygiene.carriesMeaning("  \n "))
        // Длина ни при чём: в этих шестнадцати знаках есть слово, и ведут они
        // себя в пространстве векторов честно.
        XCTAssertTrue(ChunkHygiene.carriesMeaning("== Примечания =="))
        XCTAssertTrue(ChunkHygiene.carriesMeaning("2024"))
    }

    /// Тот самый случай: хвост файла из одной закрывающей скобки.
    func testAWordlessTailJoinsThePreviousChunk() {
        let merged = ChunkHygiene.merged([
            chunk(0, "Первый абзац про услуги связи."),
            chunk(1, "Второй абзац (с уточнением"),
            chunk(2, ")"),
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].text, "Второй абзац (с уточнением )")
        // Номера идут подряд: разрыв в нумерации — отдельная находка
        // инспектора, и делать её из починки нельзя.
        XCTAssertEqual(merged.map(\.index), [0, 1])
    }

    /// Своих впереди ещё не было — кусок уезжает в следующий.
    func testAWordlessHeadJoinsTheNextChunk() {
        let merged = ChunkHygiene.merged([
            chunk(0, ")"),
            chunk(1, "Текст документа."),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, ") Текст документа.")
        XCTAssertEqual(merged[0].index, 0)
    }

    /// Текст не теряется: он есть в файле, и собрать документ из чанков
    /// обратно должно быть можно.
    func testNoCharacterIsLost() {
        let merged = ChunkHygiene.merged([
            chunk(0, "Раз"), chunk(1, ")"), chunk(2, "."), chunk(3, "Два"),
        ])
        XCTAssertEqual(merged.map(\.text).joined(separator: " "), "Раз ) . Два")
    }

    /// Ни одного слова во всём документе — оставляем как есть: это по-прежнему
    /// документ, и решать про него человеку, а не нарезке.
    func testADocumentWithoutAnyWordsIsKept() {
        let chunks = [chunk(0, ")"), chunk(1, "...")]
        XCTAssertEqual(ChunkHygiene.merged(chunks), chunks)
    }

    /// Обычный случай не трогается вовсе — ни одного нового объекта.
    func testChunksWithWordsAreReturnedUnchanged() {
        let chunks = [chunk(0, "Первый."), chunk(1, "Второй.")]
        XCTAssertEqual(ChunkHygiene.merged(chunks), chunks)
    }

    /// Иерархия: кусок приклеивается к соседу **своего** родителя, иначе текст
    /// уехал бы в чужой раздел. Ссылки детей на родителя переставляются
    /// вслед за номерами.
    func testAChildJoinsOnlyItsOwnParent() {
        let merged = ChunkHygiene.merged([
            chunk(0, "Родитель А целиком", level: 1),
            chunk(1, "Первый кусок А", parent: 0),
            chunk(2, ")", parent: 0),
            chunk(3, "Родитель Б целиком", level: 1),
            chunk(4, "Первый кусок Б", parent: 3),
        ])

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map(\.text), [
            "Родитель А целиком", "Первый кусок А )", "Родитель Б целиком", "Первый кусок Б",
        ])
        XCTAssertEqual(merged.map(\.index), [0, 1, 2, 3])
        // Родитель Б переехал с 3 на 2 — ссылка его ребёнка тоже.
        XCTAssertEqual(merged[1].parentIndex, 0)
        XCTAssertEqual(merged[3].parentIndex, 2)
    }

    /// Ребёнок без единого слова, у которого своих соседей нет вовсе: он
    /// остаётся при своём родителе, а не уезжает к чужому.
    func testALoneWordlessChildStaysWithItsParent() {
        let merged = ChunkHygiene.merged([
            chunk(0, "Родитель А", level: 1),
            chunk(1, ")", parent: 0),
            chunk(2, "Родитель Б", level: 1),
            chunk(3, "Кусок Б", parent: 2),
        ])
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[1].text, ")")
        XCTAssertEqual(merged[1].parentIndex, 0)
    }
}
