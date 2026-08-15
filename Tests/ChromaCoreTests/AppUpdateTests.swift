import XCTest
@testable import ChromaCore

/// проверка обновлений приложения.
///
/// Сеть здесь не трогается ни разу: список релизов подставляется. Проверяется
/// решение, а не доступность GitHub, — иначе тест падал бы вместе с чужим
/// сервисом и ничего бы этим не сказал.
final class AppUpdateTests: XCTestCase {
    private func release(
        tag: String,
        name: String? = nil,
        body: String? = "что изменилось",
        url: String? = "https://github.com/dem2007/ChromaDB-Manager/releases/tag/v1",
        draft: Bool? = false,
        prerelease: Bool? = false,
        published: String? = "2026-08-12T18:00:00Z"
    ) -> GitHubReleaseClient.Release {
        let json = """
        {
          "tag_name": "\(tag)",
          "assets": [],
          "name": \(name.map { "\"\($0)\"" } ?? "null"),
          "body": \(body.map { "\"\($0)\"" } ?? "null"),
          "html_url": \(url.map { "\"\($0)\"" } ?? "null"),
          "draft": \(draft.map(String.init) ?? "null"),
          "prerelease": \(prerelease.map(String.init) ?? "null"),
          "published_at": \(published.map { "\"\($0)\"" } ?? "null")
        }
        """
        return try! JSONDecoder().decode(GitHubReleaseClient.Release.self, from: Data(json.utf8))
    }

    private func checker(_ releases: [GitHubReleaseClient.Release]) -> AppUpdateChecker {
        AppUpdateChecker(releases: { releases })
    }

    // MARK: - Сравнение

    func testOnlyAStrictlyNewerVersionCounts() {
        XCTAssertTrue(AppUpdateChecker.isNewer("0.2.0", than: "0.1.5"))
        XCTAssertTrue(AppUpdateChecker.isNewer("0.1.6", than: "0.1.5"))
        XCTAssertTrue(AppUpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(AppUpdateChecker.isNewer("0.1.5", than: "0.1.5"))
        // Локальная сборка обычно опережает опубликованную — предлагать
        // «обновиться» назад нельзя.
        XCTAssertFalse(AppUpdateChecker.isNewer("0.1.4", than: "0.1.5"))
    }

    func testTenIsNewerThanNine() {
        // Строковое сравнение здесь ошибается: "0.1.10" < "0.1.9" как текст.
        XCTAssertTrue(AppUpdateChecker.isNewer("0.1.10", than: "0.1.9"))
    }

    // MARK: - Выбор релиза

    func testTheNewestPublishedReleaseWins() {
        let newest = AppUpdateChecker.newest(in: [
            release(tag: "v0.1.4"),
            release(tag: "v0.2.0"),
            release(tag: "v0.1.9"),
        ])
        XCTAssertEqual(newest?.version, "0.2.0")
    }

    func testDraftsAndPrereleasesAreSkipped() {
        let newest = AppUpdateChecker.newest(in: [
            release(tag: "v0.1.5"),
            release(tag: "v0.9.0", draft: true),
            release(tag: "v0.8.0", prerelease: true),
        ])
        XCTAssertEqual(newest?.version, "0.1.5", "предлагать то, что автор ещё не считает готовым, нельзя")
    }

    func testAReleaseWithoutAPageIsIgnored() {
        // Без ссылки открывать нечего, а показывать версию, к которой некуда
        // отправить, — половина ответа.
        XCTAssertNil(AppUpdateChecker.newest(in: [release(tag: "v9.9.9", url: nil)]))
    }

    func testTagPrefixAndEmptyNameAreHandled() {
        let withPrefix = AppUpdateChecker.makeRelease(release(tag: "v0.1.5", name: nil))
        XCTAssertEqual(withPrefix?.version, "0.1.5")
        XCTAssertEqual(withPrefix?.title, "v0.1.5", "без названия заголовком служит метка")

        let withoutPrefix = AppUpdateChecker.makeRelease(release(tag: "0.1.5"))
        XCTAssertEqual(withoutPrefix?.version, "0.1.5")
    }

    func testNotesSurviveAsWritten() {
        let made = AppUpdateChecker.makeRelease(release(tag: "v0.2.0", body: "  первая строка  "))
        XCTAssertEqual(made?.notes, "первая строка")
        let empty = AppUpdateChecker.makeRelease(release(tag: "v0.2.0", body: nil))
        XCTAssertEqual(empty?.notes, "")
    }

    // MARK: - Итог проверки

    func testUpdateAvailable() async throws {
        let outcome = try await checker([release(tag: "v0.2.0")]).check(currentVersion: "0.1.5")
        guard case .available(let release, let current) = outcome else {
            return XCTFail("ожидалось «есть обновление», получено \(outcome)")
        }
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(current, "0.1.5")
    }

    func testUpToDateWhenTheLatestIsTheOneWeRun() async throws {
        let outcome = try await checker([release(tag: "v0.1.5")]).check(currentVersion: "0.1.5")
        XCTAssertEqual(outcome, .upToDate(current: "0.1.5"))
        XCTAssertNil(outcome.release)
    }

    func testUpToDateWhenThereAreNoReleasesAtAll() async throws {
        // Пустая страница релизов — это «обновления нет», а не ошибка.
        let outcome = try await checker([]).check(currentVersion: "0.1.5")
        XCTAssertEqual(outcome, .upToDate(current: "0.1.5"))
    }

    func testUnknownVersionIsSaidOutLoudRatherThanGuessed() async throws {
        // Вне бандла версии нет. Сравнивать не с чем — и придумывать «0.0.0»,
        // чтобы «обновление» нашлось всегда, было бы обманом.
        let outcome = try await checker([release(tag: "v0.2.0")]).check(currentVersion: nil)
        guard case .unknownCurrentVersion(let latest) = outcome else {
            return XCTFail("ожидалось «версия неизвестна», получено \(outcome)")
        }
        XCTAssertEqual(latest?.version, "0.2.0")
    }

    func testFailureIsAnErrorAndNotSilentSuccess() async {
        struct Offline: Error {}
        let checker = AppUpdateChecker(releases: { throw Offline() })
        do {
            _ = try await checker.check(currentVersion: "0.1.5")
            XCTFail("недоступный GitHub не должен выглядеть как «обновлений нет»")
        } catch {
            // Именно так: «проверить не удалось» и «обновления нет» —
            // разные новости.
        }
    }

    // MARK: - Настройка

    func testTheLaunchCheckIsOffUntilTurnedOn() throws {
        XCTAssertFalse(AppConfiguration().checkAppUpdatesOnLaunch)

        // Старая конфигурация без этого поля обязана читаться как «выключено»:
        // сеть по собственному почину приложение не трогает.
        let old = Data("{\"proxyPort\": 8900}".utf8)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: old)
        XCTAssertFalse(decoded.checkAppUpdatesOnLaunch)
    }

    // MARK: - Живая проверка

    /// Разбор настоящего ответа GitHub. Подставленный список проверяет
    /// решение, но не то, что поля называются так, как мы думаем: имена
    /// в чужом API меняются без нашего ведома.
    ///
    ///     CHROMA_IT=1 swift test --filter testTheRealReleasePageParses
    func testTheRealReleasePageParses() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CHROMA_IT"] == "1",
            "живая проверка включается CHROMA_IT=1"
        )
        let releases: [GitHubReleaseClient.Release]
        do {
            releases = try await GitHubReleaseClient(repository: AppUpdateChecker.repository).releases()
        } catch {
            throw XCTSkip("GitHub недоступен: \(error.localizedDescription)")
        }
        try XCTSkipIf(releases.isEmpty, "у репозитория ещё нет ни одного релиза")

        let newest = try XCTUnwrap(AppUpdateChecker.newest(in: releases), "ни один релиз не разобрался")
        XCTAssertFalse(newest.version.isEmpty)
        XCTAssertNotNil(SemanticVersion(newest.version), "версия должна читаться как номер: «\(newest.version)»")
        XCTAssertEqual(newest.pageURL.host, "github.com")
        XCTAssertNotNil(newest.publishedAt, "дата публикации должна разбираться")
    }

    func testTheSettingSurvivesASaveAndLoad() throws {
        var configuration = AppConfiguration()
        configuration.checkAppUpdatesOnLaunch = true
        let data = try JSONEncoder().encode(configuration)
        let back = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertTrue(back.checkAppUpdatesOnLaunch)
    }
}
