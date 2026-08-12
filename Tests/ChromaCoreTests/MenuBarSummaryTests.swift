import XCTest
@testable import ChromaCore

/// что показывает строка меню и как настраивается горячая клавиша.
final class MenuBarSummaryTests: XCTestCase {

    private func task(
        _ title: String, state: QueuedTaskInfo.State
    ) -> QueuedTaskInfo {
        QueuedTaskInfo(
            id: UUID(), title: title, priority: .manual, group: .lmStudio,
            connectionID: nil, submittedAt: Date(), startedAt: nil,
            state: state, progress: nil, detail: nil
        )
    }

    // MARK: - Сводка

    func testAnEmptyQueueSaysSoInsteadOfShowingZero() {
        let summary = MenuBarSummary(tasks: [], paused: false, lastSync: nil)
        XCTAssertEqual(summary.headline, "Задач нет")
        XCTAssertNil(summary.queueLine, "«Ожидают: 0» — это шум, а не новость")
        XCTAssertFalse(summary.isBusy)
    }

    func testTheRunningTaskIsNamedInTheHeadline() {
        let summary = MenuBarSummary(
            tasks: [task("Синхронизация «контракты»", state: .running)],
            paused: false, lastSync: nil
        )
        XCTAssertEqual(summary.headline, "Идёт: Синхронизация «контракты»")
        XCTAssertTrue(summary.isBusy)
    }

    /// Выполняемая задача не должна попадать ещё и в счётчик ожидающих:
    /// «идёт одна и ждёт одна» при единственной задаче — неправда.
    func testTheRunningTaskIsNotCountedAsWaiting() {
        let summary = MenuBarSummary(
            tasks: [task("Индексация", state: .running)],
            paused: false, lastSync: nil
        )
        XCTAssertNil(summary.queueLine)
    }

    func testWaitingTasksAreCountedWithRussianAgreement() {
        let one = MenuBarSummary(
            tasks: [task("A", state: .running), task("B", state: .queued)],
            paused: false, lastSync: nil
        )
        XCTAssertEqual(one.queueLine, "Ожидают: 1 задача")

        let few = MenuBarSummary(
            tasks: [task("A", state: .running)] + (1...3).map { task("\($0)", state: .queued) },
            paused: false, lastSync: nil
        )
        XCTAssertEqual(few.queueLine, "Ожидают: 3 задачи")

        let many = MenuBarSummary(
            tasks: [task("A", state: .running)] + (1...7).map { task("\($0)", state: .queued) },
            paused: false, lastSync: nil
        )
        XCTAssertEqual(many.queueLine, "Ожидают: 7 задач")
    }

    /// Пауза автоматики и «сейчас ничего не делается» — разные вещи.
    /// Запущенное руками доигрывает до конца, и об этом надо сказать.
    func testPauseIsNamedEvenWhileSomethingIsStillRunning() {
        let summary = MenuBarSummary(
            tasks: [task("Пересчёт векторов", state: .running)],
            paused: true, lastSync: nil
        )
        XCTAssertEqual(summary.headline, "Идёт: Пересчёт векторов")
        XCTAssertEqual(summary.pausedLine, "Автоматическая синхронизация на паузе")
    }

    func testAnIdlePausedAppSaysPauseInTheHeadline() {
        let summary = MenuBarSummary(tasks: [], paused: true, lastSync: nil)
        XCTAssertEqual(summary.headline, "Автоматическая синхронизация на паузе")
        XCTAssertNil(summary.pausedLine, "дважды одно и то же не пишем")
    }

    func testTheSymbolTellsBusyFromPausedFromIdle() {
        XCTAssertEqual(MenuBarSummary(tasks: [], paused: false, lastSync: nil).symbol, "tray.full")
        XCTAssertEqual(
            MenuBarSummary(tasks: [task("A", state: .running)], paused: false, lastSync: nil).symbol,
            "arrow.triangle.2.circlepath"
        )
        XCTAssertEqual(MenuBarSummary(tasks: [], paused: true, lastSync: nil).symbol, "pause.circle")
    }

    // MARK: - Горячая клавиша

    func testTheDefaultCombinationIsShownTheWayMacOSWritesIt() {
        XCTAssertEqual(HotKeyCombination.default.display, "⌃⌥⌘K")
    }

    /// Сочетание без модификаторов отобрало бы клавишу у всей системы:
    /// человек нажал бы «K» в чужом поле ввода и получил бы наш поиск.
    func testACombinationWithoutModifiersIsRefused() {
        let bare = HotKeyCombination(
            keyCode: 40, command: false, option: false, control: false, shift: false
        )
        XCTAssertFalse(bare.isUsable)
        XCTAssertTrue(HotKeyCombination.default.isUsable)
    }

    func testShiftIsShownInTheRightPlace() {
        let combination = HotKeyCombination(
            keyCode: 49, command: true, option: false, control: true, shift: true
        )
        XCTAssertEqual(combination.display, "⌃⇧⌘Пробел")
    }

    // MARK: - Настройки

    /// Ничего из H2 не включается само: значок показывается, а горячая
    /// клавиша и «жизнь без окна» — только по решению человека.
    func testNothingIntrusiveIsOnByDefault() {
        let preferences = MenuBarPreferences()
        XCTAssertTrue(preferences.showsIcon)
        XCTAssertFalse(preferences.globalHotKeyEnabled)
        XCTAssertFalse(preferences.keepsRunningWithoutWindow)
        XCTAssertNil(preferences.quickSearchCollection)
    }

    func testTheResultCountIsClampedToSomethingASmallMenuCanShow() {
        XCTAssertEqual(MenuBarPreferences(quickSearchResultCount: 0).quickSearchResultCount, 1)
        XCTAssertEqual(MenuBarPreferences(quickSearchResultCount: 500).quickSearchResultCount, 20)
    }

    /// Конфигурация, записанная до H2, обязана читаться — и читаться как
    /// «человек ничего не включал», а не как «всё включено».
    func testAConfigurationWrittenBeforeH2StillReads() throws {
        let json = """
        {"proxyPort": 8900, "notificationsEnabled": true}
        """
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.menuBar, MenuBarPreferences())
        XCTAssertFalse(configuration.menuBar.globalHotKeyEnabled)
    }

    func testABrokenHotKeyInTheFileFallsBackToTheDefaultRatherThanLosingTheSection() throws {
        let json = """
        {"menuBar": {"showsIcon": false, "hotKey": "чепуха"}}
        """
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.menuBar.hotKey, .default)
        XCTAssertFalse(
            configuration.menuBar.showsIcon,
            "испорченная клавиша не должна утаскивать за собой остальные настройки"
        )
    }
}
