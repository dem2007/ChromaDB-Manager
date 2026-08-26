import XCTest
import ChromaCore
@testable import ChromaDBManagerApp

/// Границы дней в журналах.
///
/// В строке журнала стоит одно время. Пока записи сегодняшние, этого хватает,
/// а на второй день «0:56:07» перестаёт отвечать на вопрос «когда» — заказчик
/// именно на это и наткнулся.
final class LogDayGroupingTests: XCTestCase {
    private func entry(_ date: Date) -> AuditEntry {
        AuditEntry(
            date: date, client: "hermes", method: "tools/call", path: "search",
            operation: "search", access: .read, collection: "к",
            requestBytes: 10, responseStatus: 200, responseBytes: 20,
            durationSeconds: 0.1, transport: .mcp
        )
    }

    /// «Вчера» отсчитывается календарём, а не вычитанием часов.
    ///
    /// Двадцать шесть часов назад — это вчера только начиная с двух часов
    /// дня: в половине первого ночи это уже позавчера, и сторож падал каждую
    /// ночь между полуночью и двумя. Поймано ровно так — прогоном после
    /// смены даты.
    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func testEntriesAreGroupedByDayKeepingOrder() {
        let now = Date()
        let yesterday = self.yesterday
        let older = now.addingTimeInterval(-5 * 24 * 3600)
        let groups = LogsView.byDay(
            [entry(now), entry(now.addingTimeInterval(-60)), entry(yesterday), entry(older)],
            date: \.date
        )
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.items.count), [2, 1, 1], "порядок записей не должен меняться")
        XCTAssertEqual(groups[0].title, "сегодня")
        XCTAssertEqual(groups[1].title, "вчера")
        XCTAssertFalse(groups[2].title.isEmpty)
    }

    /// Сегодня и вчера названы словами: число вместо них человек всё равно
    /// пересчитывает в «сегодня».
    func testTodayAndYesterdayAreNamedInWords() {
        XCTAssertEqual(LogsView.dayTitle(Date()), "сегодня")
        XCTAssertEqual(LogsView.dayTitle(yesterday), "вчера")
    }

    /// У давней записи в подписи есть месяц — иначе она снова ни о чём
    /// не говорит.
    func testAnOlderDayCarriesItsMonth() {
        let title = LogsView.dayTitle(Date().addingTimeInterval(-40 * 24 * 3600))
        XCTAssertTrue(title.contains(where: \.isLetter), "в подписи дня обязан быть месяц: \(title)")
    }

    /// Пустому журналу — пустая разбивка, а не группа из ничего.
    func testNothingGroupsToNothing() {
        XCTAssertTrue(LogsView.byDay([AuditEntry](), date: \.date).isEmpty)
    }
}
