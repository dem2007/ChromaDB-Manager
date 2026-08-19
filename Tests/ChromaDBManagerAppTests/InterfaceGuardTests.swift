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

    /// умолчания нарезки настраиваются в окне источника.
    ///
    /// И подставляются при переключении стратегии: без этого «умолчание для
    /// всех стратегий» осталось бы умолчанием для одной.
    func testChunkingDefaultsAreSetFromTheSourceWindow() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/SourcesView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("model.makeChunkingDefault(app)"), "кнопка «Сделать умолчанием»")
        XCTAssertTrue(source.contains("model.takeChunkingDefault(app)"), "кнопка «Взять умолчание»")
        XCTAssertTrue(
            source.contains("model.chunkingStrategyChanged(to: strategy, app: app)"),
            "переключение стратегии обязано подставлять её умолчания"
        )
        // Ответ кнопки уходил бы за лист — экран источников под ним.
        XCTAssertFalse(
            source.contains("model.infoMessage = model.makeChunkingDefault"),
            "сообщение об умолчании должно оставаться в листе источника"
        )
    }

    ///, — широкий лист не строится целиком.
    ///
    /// Проверять глазами тут нечего до тех пор, пока не откроется файл
    /// на 210 колонок: обычные стеки строят 4 400 ячеек и 210 полей ввода
    /// на каждую перерисовку, и экран отвечает с задержкой в секунды.
    ///
    /// Ленивого стека мало — важно, **что** в нём лежит. Пока его элементом
    /// была строка, вертикальный стек требовал у неё полный размер, и стек
    /// строил все свои ячейки, сколько бы их ни было: замер на рабочей книге
    /// (114 колонок) — экран не отвечал минуту, при том что ядро отдаёт всю
    /// книгу за 0,04 с. Элемент ленивого стека — колонка.
    func testWideSheetsAreLaidOutLazily() throws {
        let source = try mappingView()
        XCTAssertTrue(
            source.contains("LazyHStack(alignment: .top, spacing: 0)"),
            "предпросмотр должен строиться лениво — колонок бывает две сотни"
        )
        // Номера строк — вне прокрутки, то есть объявлены до неё: по ним
        // назначают строку заголовков, а уезжали они вместе с содержимым.
        let numbers = try XCTUnwrap(source.range(of: "numberCell("))
        let scroll = try XCTUnwrap(source.range(of: "ScrollView(.horizontal)"))
        XCTAssertTrue(numbers.lowerBound < scroll.lowerBound, "колонка номеров не прокручивается вбок")
        XCTAssertTrue(
            source.contains("LazyVStack(alignment: .leading, spacing: 6)"),
            "список колонок с полями и выпадающими списками — тем более"
        )
        XCTAssertFalse(
            source.contains("binding.wrappedValue.keyMap.key(for:"),
            "ключи метаданных считаются один раз на список, а не на каждую строку"
        )
    }

    /// область хранения профиля спрашивается, а не решается за
    /// человека.
    ///
    /// Выбор, которого нет на экране, — это выбор, сделанный приложением:
    /// профиль молча уходит к источнику, и та же книга в другой папке
    /// размечается заново.
    func testTheScreenAsksWhereToKeepTheProfile() throws {
        let source = try mappingView()
        XCTAssertTrue(
            source.contains("selection: $model.scope"),
            "на экране должен быть выбор области хранения профиля"
        )
        XCTAssertTrue(
            source.contains("TableProfileScope.allCases"),
            "обе области должны быть в списке — иначе выбор половинчатый"
        )
    }

    /// Списки профилей на экране — общие вместе со своими.
    ///
    /// Экран, показывающий не то, чем файл будет прочитан, хуже отсутствия
    /// экрана: назначить можно только то, что видно.
    func testProfileListsIncludeTheSharedOnes() throws {
        let source = try mappingView()
        XCTAssertTrue(
            source.contains("ForEach(model.allProfiles)"),
            "в выборе профиля для файла должны быть и общие профили"
        )
        XCTAssertFalse(
            source.contains("ForEach(model.profiles)"),
            "список только своих профилей скрывает половину того, чем читается источник"
        )
    }
}

/// сертификат виден и переносим.
///
/// Сторож по исходникам, как соседние: отпечаток, показанный наполовину или
/// не показанный вовсе, компилируется и проходит все прочие тесты, а человеку
/// оставляет невыполнимое — сверить, тот ли сертификат он видит.
final class CertificateOnScreenTests: XCTestCase {
    private func securityView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/SecurityView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheFingerprintIsShownWholeAndCanBeTaken() throws {
        let source = try securityView()
        XCTAssertTrue(source.contains("Text(certificate.fingerprint)"), "отпечаток должен показываться целиком")
        XCTAssertFalse(
            source.contains("certificate.fingerprint.prefix"),
            "обрезанный отпечаток сверить нельзя — он для того и нужен, чтобы совпасть целиком"
        )
        XCTAssertTrue(source.contains("model.copy(certificate.fingerprint)"), "отпечаток должен копироваться кнопкой")
        XCTAssertTrue(source.contains(".textSelection(.enabled)"), "и выделяться мышью")
    }

    func testExportAndReissueAreBothOnTheScreen() throws {
        let source = try securityView()
        XCTAssertTrue(source.contains("model.exportCertificate(app)"), "сертификат должно быть можно сохранить в файл")
        XCTAssertTrue(source.contains("model.isConfirmingReissue = true"), "перевыпуск должен быть, и через подтверждение")
        XCTAssertTrue(
            source.contains("model.reissueCertificate(app)"),
            "перевыпуск вызывается только из подтверждения — он рвёт связь со всеми клиентами"
        )
    }

    func testTheRunningModeIsShownAsAFactNotAsASetting() throws {
        let source = try securityView()
        XCTAssertTrue(
            source.contains("proxy.tls == .tls"),
            "строка о шифровании должна читать режим работающего прокси, а не настройку"
        )
    }
}

/// приложение не ходит в сеть само.
///
/// Правило легко нарушить одной строкой: убрать `if` вокруг проверки, и
/// каждый запуск начнёт обращаться к GitHub. Ни один другой тест этого
/// не заметит — обращение молчаливое и успешное.
final class LaunchNetworkGuardTests: XCTestCase {
    private func rootView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views/RootView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("исходники экрана не найдены рядом с тестами")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheLaunchCheckIsGatedBySetting() throws {
        let source = try rootView()
        // Ищем именно вызов, а не имя настройки: `checkAppUpdatesOnLaunch`
        // содержит его подстрокой, и поиск попадал в само условие.
        guard let range = source.range(of: "environmentModel.checkAppUpdates(") else {
            return XCTFail("проверка обновлений при запуске пропала из RootView")
        }
        let before = source[source.startIndex..<range.lowerBound].suffix(400)
        XCTAssertTrue(
            before.contains("if settings.configuration.checkAppUpdatesOnLaunch"),
            "проверка при запуске обязана стоять под галочкой, а не выполняться всегда"
        )
        XCTAssertTrue(
            source.contains("automatic: true"),
            "молчаливая проверка не должна показывать ошибку поверх экрана"
        )
    }
}
