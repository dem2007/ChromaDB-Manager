import XCTest

/// Остановленный воротами J2 запуск виден там, где нажали.
///
/// Живой случай: человек нажал «Синхронизировать» у источника внизу длинного
/// экрана. План с баннером «Подтвердите запуск» лёг **выше** списка, вне
/// видимой части, кнопка вернулась в исходный вид — и нажатие выглядело
/// потерянным. Сторож по исходникам: разъехавшийся экран компилируется,
/// проходит все прочие тесты и виден только глазами.
final class PendingConfirmationVisibleTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Кнопка карточки называет состояние, а не предлагает то же действие
    /// второй раз.
    func testTheCardOffersConfirmationInsteadOfSyncing() throws {
        let view = try source("SourcesView.swift")
        XCTAssertTrue(
            view.contains("model.pendingConfirmations.contains(source.id)"),
            "карточка источника не знает, что его запуск ждёт подтверждения"
        )
        XCTAssertTrue(
            view.contains("Подтвердить запуск"),
            "нет кнопки подтверждения у самого источника"
        )
    }

    /// Причина — из плана, а не своим текстом рядом: два текста про один порог
    /// уже расходились однажды.
    func testTheReasonComesFromThePlanItself() throws {
        let view = try source("SourcesView.swift")
        let occurrences = view.components(separatedBy: "confirmationReasons(").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, "причина в карточке должна браться у плана")
        XCTAssertFalse(
            view.contains("больше порога \\(settings.configuration.syncPreviewThresholdFiles)"),
            "порог пересказан своими словами вместо причины плана"
        )
    }
}
