import XCTest
@testable import ChromaCore

/// язык интерфейса: системный по умолчанию, явный выбор по желанию.
final class InterfaceLanguageTests: XCTestCase {
    /// Свой `UserDefaults`, чтобы тест не трогал язык машины, на которой
    /// собирают: запись в `standard` переключила бы язык всем приложениям
    /// пользователя.
    private func store() throws -> (InterfaceLanguageStore, UserDefaults, String) {
        let suite = "chromadb.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (InterfaceLanguageStore(defaults: defaults), defaults, suite)
    }

    func testWithoutAChoiceTheSystemDecides() throws {
        let (languages, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(languages.current, .system)
        XCTAssertNil(languages.override, "переопределения быть не должно")
        // Даже при системном `AppleLanguages`, который виден приложению
        // и без всякой записи: он наследуется от системы.
        defaults.set(["en"], forKey: "AppleLanguages")
        XCTAssertEqual(languages.current, .system, "системное значение — не выбор человека")
    }

    /// Выбор пишется в `AppleLanguages` — тот самый ключ, откуда его берёт
    /// загрузчик ресурсов. Свой ключ система не читает.
    func testAChoiceIsWrittenWhereTheSystemReadsIt() throws {
        let (languages, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(languages.apply(.english))
        XCTAssertEqual(defaults.array(forKey: "AppleLanguages") as? [String], ["en"])
        XCTAssertEqual(languages.current, .english)
    }

    /// «Как в системе» снимает переопределение, а не пишет туда язык системы:
    /// иначе выбор застыл бы на том, что было в день нажатия.
    func testGoingBackToSystemRemovesTheOverride() throws {
        let (languages, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        languages.apply(.russian)
        XCTAssertNotNil(languages.override)

        XCTAssertTrue(languages.apply(.system))
        XCTAssertNil(defaults.string(forKey: InterfaceLanguageStore.choiceKey))
        XCTAssertNil(languages.override)
        XCTAssertEqual(languages.current, .system)
    }

    /// Тот же язык — не изменение, и предлагать перезапуск незачем.
    func testChoosingTheSameLanguageChangesNothing() throws {
        let (languages, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(languages.apply(.english))
        XCTAssertFalse(languages.apply(.english), "второй раз менять нечего")
    }

    /// Чужое значение в `AppleLanguages` — не повод падать: там мог оказаться
    /// любой язык, которого у приложения нет.
    func testAnUnknownLanguageReadsAsSystem() throws {
        let (languages, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("fr", forKey: InterfaceLanguageStore.choiceKey)
        XCTAssertEqual(languages.current, .system)
    }

    /// Названия языков не переводятся: человек, попавший в незнакомый
    /// интерфейс, ищет своё название языка, а не его перевод.
    func testLanguageNamesAreWrittenInTheirOwnLanguage() {
        XCTAssertEqual(InterfaceLanguage.russian.title, "Русский")
        XCTAssertEqual(InterfaceLanguage.english.title, "English")
    }
}
