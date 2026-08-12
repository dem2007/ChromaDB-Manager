import XCTest
@testable import ChromaCore

/// Совместимость файлов, записанных прежними сборками.
///
/// Правило простое и уже один раз нарушено: **добавление поля в тип, который
/// лежит на диске, обязано быть терпимым к его отсутствию.** Синтезированный
/// декодер требует каждое поле, и файл, записанный вчера, становится
/// нечитаемым. Приложение в этом случае ведёт себя правильно — отказывается
/// перезаписывать и говорит об этом, — но накопленные данные перестают
/// пополняться, а человек видит ошибку на ровном месте.
final class PersistedFormatTests: XCTestCase {

    // MARK: - Статистика (тот самый случай)

    /// `metrics.json`, записанный до появления оценки чат-моделью, обязан
    /// читаться. Это дословный формат файла с машины пользователя.
    func testMetricsWrittenBeforeTheJudgeSectionStillRead() throws {
        let json = """
        {
          "models": [{"model": "text-embedding-qwen3-embedding-0.6b", "seconds": 12.5, "texts": 300}],
          "strategies": [{"characters": 40000, "runs": 2, "seconds": 3.5, "strategy": "recursive"}]
        }
        """
        let snapshot = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.models.count, 1)
        XCTAssertEqual(snapshot.strategies.count, 1)
        // Отсутствующий раздел — «ещё ничего не измерено», а не «файл испорчен».
        XCTAssertTrue(snapshot.judges.isEmpty)
        XCTAssertNil(snapshot.judgeSecondsPerCall(model: "любая"))
    }

    /// И наоборот: то, что записано сейчас, читается целиком.
    func testMetricsSurviveARoundTrip() throws {
        var snapshot = MetricsSnapshot()
        snapshot.models = [.init(model: "м", texts: 10, seconds: 1)]
        snapshot.judges = [.init(model: "ч", texts: 2, seconds: 14)]
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(MetricsSnapshot.self, from: data)
        XCTAssertEqual(back, snapshot)
        XCTAssertEqual(back.judgeSecondsPerCall(model: "ч"), 7)
    }

    /// Терпимость не должна превращаться во всеядность.
    ///
    /// Если бы годился любой JSON, посторонний файл прочитался бы как пустая
    /// статистика — и был бы ею перезаписан, то есть накопленное за недели
    /// измерение тихо исчезло бы. Хотя бы один известный раздел обязан быть.
    func testAForeignFileIsStillRefused() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricsSnapshot.self, from: Data(#"{"это": "чужое"}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(MetricsSnapshot.self, from: Data("{}".utf8))
        )
        // А один раздел из трёх — свой файл прежней сборки, и он читается.
        XCTAssertNoThrow(
            try JSONDecoder().decode(MetricsSnapshot.self, from: Data(#"{"models": []}"#.utf8))
        )
    }

    // MARK: - Спасённая копия

    /// Копия нечитаемого файла снимается **одна на состояние**, а не одна
    /// на попытку чтения.
    ///
    /// Проблема с разбором обычно постоянная: файл не читается ни сейчас,
    /// ни при следующем запуске. Прежняя редакция снимала копию каждый раз,
    /// и за один вечер в каталоге накопилось семь одинаковых файлов.
    func testAnUnreadableFileIsRescuedOnceNotOncePerAttempt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guarded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("metrics.json")
        try Data(#"{"это": "не MetricsSnapshot"}"#.utf8).write(to: url)

        for _ in 0..<5 {
            let file = GuardedJSONFile<MetricsSnapshot>(url: url, category: "Статистика")
            // Читает лениво — просто создать его мало.
            _ = file.value(or: MetricsSnapshot())
            XCTAssertNotNil(file.problem, "нечитаемый файл обязан объясняться")
        }

        let rescued = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".unreadable-") }
        XCTAssertEqual(rescued.count, 1, "копий должно быть одна, а не по одной на попытку")
    }

    /// А изменившееся содержимое — это новое состояние, и его копия нужна:
    /// иначе вторая поломка потеряется за первой.
    func testADifferentBrokenContentGetsItsOwnCopy() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guarded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("metrics.json")
        try Data(#"{"первая": "поломка"}"#.utf8).write(to: url)
        _ = GuardedJSONFile<MetricsSnapshot>(url: url, category: "Статистика")
            .value(or: MetricsSnapshot())
        // Метка времени в имени — посекундная, поэтому вторая копия обязана
        // получить другое имя; ждём смены секунды.
        Thread.sleep(forTimeInterval: 1.1)
        try Data(#"{"вторая": "поломка"}"#.utf8).write(to: url)
        _ = GuardedJSONFile<MetricsSnapshot>(url: url, category: "Статистика")
            .value(or: MetricsSnapshot())

        let rescued = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".unreadable-") }
        XCTAssertEqual(rescued.count, 2)
    }
}
