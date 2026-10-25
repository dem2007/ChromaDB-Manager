import XCTest
@testable import ChromaCore

/// Память об устройстве файла — и о том, когда она перестаёт годиться.
///
/// Главное здесь не попадание в кэш, а **промах**: отдать вчерашний порядок
/// кусков хуже, чем обойти файл заново. Поэтому проверок на «больше не
/// годится» больше, чем на «нашлось».
final class MCPFileChunkCacheTests: XCTestCase {
    private func chunk(_ index: Int) -> MCPDocumentPayload {
        MCPDocumentPayload(
            id: "c\(index)", text: nil,
            metadata: ["source_file": .string("папка/тз.md"), MCPFileChunks.orderKey: .int(index)]
        )
    }

    private func key(_ collection: String = "заметки", file: String = "папка/тз.md") -> MCPFileChunkCache.Key {
        var filter = DocumentFilter()
        filter.conditions = [MetadataCondition(field: "source_file", op: .equals, value: file)]
        return MCPFileChunkCache.Key(collectionID: collection, filter: filter)
    }

    private func entry(_ count: Int = 3, overflowed: Bool = false) -> MCPFileChunkCache.Entry {
        MCPFileChunkCache.Entry(documents: (0..<count).map(chunk), overflowed: overflowed)
    }

    /// Положили — нашли. Ради этого всё и затевалось.
    func testWhatWasStoredIsFound() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        let found = cache.entry(for: key(), stamp: 100)
        XCTAssertEqual(found?.documents.map(\.id), ["c0", "c1", "c2"])
        XCTAssertEqual(found?.overflowed, false)
    }

    /// Тот же файл, спрошенный другим отбором, — другой ключ.
    ///
    /// Отпечаток и путь ведут к одному файлу, но подменять один отбор другим
    /// нельзя: совпадение имён ничего не доказывает.
    func testADifferentFilterIsADifferentFile() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        XCTAssertNil(cache.entry(for: key(file: "папка/другое.md"), stamp: 100))
        XCTAssertNil(cache.entry(for: key("письма"), stamp: 100))
    }

    /// **Запись мимо приложения.** Никакой наш обработчик её не видел —
    /// ни клиент базы, ни журнал доступа, — но счёт документов коллекции
    /// изменился, и этого довольно.
    func testAWriteNobodyToldUsAboutIsCaughtByTheCount() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        XCTAssertNil(cache.entry(for: key(), stamp: 101), "чужая запись прошла незамеченной")
        // Заново: промах выше запись уже снял, и без этого проверка ниже
        // проходила бы при любом сравнении счёта.
        cache.store(entry(), for: key(), stamp: 100)
        XCTAssertNil(cache.entry(for: key(), stamp: 99), "удаление мимо нас прошло незамеченным")
    }

    /// Запись в коллекцию через наш клиент обесценивает память о её файлах
    /// сразу, не дожидаясь расхождения счёта: удалить один кусок и добавить
    /// один — это тот же счёт и другой файл.
    func testAWriteThroughOurClientDropsWhatWeRemembered() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        cache.invalidate(collectionID: "заметки")
        XCTAssertNil(cache.entry(for: key(), stamp: 100), "после записи отдаётся вчерашний порядок")
    }

    /// Чужая коллекция чужую память не трогает.
    func testAWriteToAnotherCollectionLeavesUsAlone() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        cache.invalidate(collectionID: "письма")
        XCTAssertNotNil(cache.entry(for: key(), stamp: 100))
    }

    /// Чужая запись через прокси названа коллекцией как попало — именем или
    /// идентификатором, — и сопоставлять её с ключами нечем: снимается всё.
    func testAStrangersWriteDropsEverything() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(), stamp: 100)
        cache.store(entry(), for: key("письма", file: "письмо.md"), stamp: 7)
        cache.invalidateAll()
        XCTAssertNil(cache.entry(for: key(), stamp: 100))
        XCTAssertNil(cache.entry(for: key("письма", file: "письмо.md"), stamp: 7))
    }

    /// Срок жизни — последний пояс: он ловит и то, чего не поймал счёт.
    func testAnEntryExpires() {
        let cache = MCPFileChunkCache()
        let stored: TimeInterval = 1_000
        cache.store(entry(), for: key(), stamp: 100, now: stored)
        XCTAssertNotNil(cache.entry(
            for: key(), stamp: 100, now: stored + MCPFileChunkCache.lifetime - 1
        ))
        XCTAssertNil(cache.entry(
            for: key(), stamp: 100, now: stored + MCPFileChunkCache.lifetime + 1
        ))
    }

    /// Запись посреди обхода: обход видел базу до неё и запоминаться
    /// не должен, хотя сохраняют его уже после записи.
    func testAWriteDuringTheScanIsNotLost() {
        let cache = MCPFileChunkCache()
        let ticket = cache.ticket(for: key())
        cache.invalidate(collectionID: "заметки")
        cache.store(entry(), for: key(), stamp: 100, ticket: ticket)
        XCTAssertNil(cache.entry(for: key(), stamp: 100), "обход до записи запомнен как свежий")
    }

    /// То же для чужой записи, снимающей всё.
    func testAStrangersWriteDuringTheScanIsNotLost() {
        let cache = MCPFileChunkCache()
        let ticket = cache.ticket(for: key())
        cache.invalidateAll()
        cache.store(entry(), for: key(), stamp: 100, ticket: ticket)
        XCTAssertNil(cache.entry(for: key(), stamp: 100), "обход до записи запомнен как свежий")
    }

    /// Снимок, взятый без записей между ним и сохранением, обход пропускает.
    func testAnUndisturbedScanIsRemembered() {
        let cache = MCPFileChunkCache()
        let ticket = cache.ticket(for: key())
        cache.invalidate(collectionID: "письма")
        cache.store(entry(), for: key(), stamp: 100, ticket: ticket)
        XCTAssertNotNil(cache.entry(for: key(), stamp: 100))
    }

    /// Файлов держим считанное число: метаданные большого файла весят
    /// полтора мегабайта, и держать их десятками незачем.
    func testTheOldestFileIsEvicted() {
        let cache = MCPFileChunkCache()
        for number in 0...MCPFileChunkCache.capacity {
            cache.store(entry(), for: key(file: "файл-\(number).md"), stamp: 100)
        }
        XCTAssertEqual(cache.count, MCPFileChunkCache.capacity)
        XCTAssertNil(cache.entry(for: key(file: "файл-0.md"), stamp: 100), "вытеснить надо самый старый")
        XCTAssertNotNil(cache.entry(
            for: key(file: "файл-\(MCPFileChunkCache.capacity).md"), stamp: 100
        ))
    }

    /// Обращение освежает место в очереди: вытесняем то, чем не пользуются,
    /// а не то, что положили раньше всех.
    func testUseKeepsAFileAlive() {
        let cache = MCPFileChunkCache()
        for number in 0..<MCPFileChunkCache.capacity {
            cache.store(entry(), for: key(file: "файл-\(number).md"), stamp: 100)
        }
        XCTAssertNotNil(cache.entry(for: key(file: "файл-0.md"), stamp: 100))
        cache.store(entry(), for: key(file: "новый.md"), stamp: 100)
        XCTAssertNotNil(
            cache.entry(for: key(file: "файл-0.md"), stamp: 100),
            "вытеснили то, чем только что пользовались"
        )
        XCTAssertNil(cache.entry(for: key(file: "файл-1.md"), stamp: 100))
    }

    /// Пустой обход не запоминается: «файла нет» — это ответ базы на сейчас,
    /// а не устройство файла.
    func testAnEmptyResultIsNotRemembered() {
        let cache = MCPFileChunkCache()
        cache.store(MCPFileChunkCache.Entry(documents: [], overflowed: false), for: key(), stamp: 100)
        XCTAssertEqual(cache.count, 0)
    }

    /// Признак «файл длиннее предела упорядочивания» запоминается вместе
    /// с обходом: без него страница пришла бы упорядоченной только на вид.
    func testTheOverflowFlagTravelsWithTheEntry() {
        let cache = MCPFileChunkCache()
        cache.store(entry(overflowed: true), for: key(), stamp: 100)
        XCTAssertEqual(cache.entry(for: key(), stamp: 100)?.overflowed, true)
    }

    /// держим не больше `maximumDocuments` кусков на все файлы,
    /// а последний запомненный — всегда, даже если он один больше.
    func testTheCacheIsBoundedByChunksNotOnlyFiles() {
        let cache = MCPFileChunkCache()
        let big = MCPFileChunkCache.maximumDocuments / 2 + 1
        cache.store(entry(big), for: key(file: "а.md"), stamp: 100)
        cache.store(entry(big), for: key(file: "б.md"), stamp: 100)
        XCTAssertNil(cache.entry(for: key(file: "а.md"), stamp: 100), "два больших файла сверх предела — старший уходит")
        XCTAssertNotNil(cache.entry(for: key(file: "б.md"), stamp: 100))

        cache.store(entry(MCPFileChunkCache.maximumDocuments + 10), for: key(file: "в.md"), stamp: 100)
        XCTAssertNotNil(cache.entry(for: key(file: "в.md"), stamp: 100), "последний остаётся всегда")
        XCTAssertEqual(cache.count, 1)
    }

    /// Протухшие уходят при следующей записи, а не когда их спросят.
    func testExpiredFilesLeaveOnTheNextStore() {
        let cache = MCPFileChunkCache()
        cache.store(entry(), for: key(file: "старый.md"), stamp: 100, now: 0)
        cache.store(entry(), for: key(file: "новый.md"), stamp: 100, now: MCPFileChunkCache.lifetime + 1)
        XCTAssertEqual(cache.count, 1)
    }
}
