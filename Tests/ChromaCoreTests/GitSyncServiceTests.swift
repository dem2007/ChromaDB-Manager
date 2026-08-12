import XCTest
@testable import ChromaCore

/// §I2 — git-репозиторий как источник.
///
/// Репозиторий настоящий: он создаётся во временной папке здесь же. Подставить
/// вместо git заглушку значило бы проверять свои представления о его выводе,
/// а весь смысл этапа в том, что ответы даёт именно git.
final class GitSyncServiceTests: XCTestCase {
    private var root: URL!
    private var states: GitStateStore!
    private var service: GitSyncService!

    override func setUpWithError() throws {
        try XCTSkipUnless(GitRepository.isInstalled(), "git не установлен на этой машине")
        // Рабочая копия и наши служебные файлы — в разных папках: файл внутри
        // репозитория git честно посчитает неотслеживаемым и предложит
        // проиндексировать.
        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-source-\(UUID().uuidString)")
        root = box.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        states = GitStateStore(directory: box.appendingPathComponent("state"))
        service = GitSyncService(states: states)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    // MARK: - Репозиторий под рукой

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        let executable = try XCTUnwrap(ToolLocator.shared.locate("git"))
        let result = try await ShellRunner.shared.run(
            executable, arguments: arguments,
            environment: [
                "GIT_AUTHOR_NAME": "Проверка", "GIT_AUTHOR_EMAIL": "test@example.org",
                "GIT_COMMITTER_NAME": "Проверка", "GIT_COMMITTER_EMAIL": "test@example.org",
            ],
            currentDirectory: root
        )
        XCTAssertTrue(result.isSuccess, "git \(arguments.joined(separator: " ")): \(result.combinedOutput)")
        return result.standardOutput
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func makeRepository() async throws {
        try await git(["init", "--initial-branch=main"])
        try write("README.md", "# Проект\n\nОписание проекта достаточной длины, чтобы из него получился чанк.")
        try write("docs/guide.md", "# Руководство\n\nВторой документ репозитория, тоже достаточно длинный.")
        try write(".gitignore", "build/\n*.log\n")
        try write("build/artifact.md", "# Сборочный мусор\n\nЭтого в базе быть не должно.")
        try write("noise.log", "лог, которого в базе быть не должно")
        try await git(["add", "-A"])
        try await git(["commit", "-m", "первый"])
    }

    private func source(_ settings: GitSourceSettings = GitSourceSettings()) -> DataSource {
        DataSource(
            name: "репозиторий", path: root.path,
            fileExtensions: [], collectionName: "code",
            git: settings
        )
    }


    /// `XCTUnwrap` не умеет разворачивать `async` в автозамыкании — оборачиваем.
    private func unwrapPrepare(
        _ preparation: GitSyncService.Preparation?,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> GitSyncService.Preparation {
        try XCTUnwrap(preparation, "подготовка не вернула план", file: file, line: line)
    }

    // MARK: - Перечень файлов

    /// Главное, ради чего этап существует: `.git`, `.gitignore`-мусор и
    /// сборочные артефакты в базу не попадают, и не потому, что мы угадали
    /// маски, а потому, что список даёт git.
    func testTheIndexHasNeitherGitNorIgnoredFiles() async throws {
        try await makeRepository()
        let preparation = try await unwrapPrepare(service.prepare(
            source: source(), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))

        let paths = preparation.plan.items.map(\.relativePath)
        XCTAssertEqual(paths, [".gitignore", "README.md", "docs/guide.md"])
        XCTAssertFalse(paths.contains { $0.hasPrefix(".git/") })
        XCTAssertFalse(paths.contains("build/artifact.md"), "игнорируемое git не отдаёт")
        XCTAssertFalse(paths.contains("noise.log"))
    }

    func testExtensionsAndMasksNarrowTheListFurther() async throws {
        try await makeRepository()
        var source = source(GitSourceSettings(excludedGlobs: ["docs/*"]))
        source.fileExtensions = ["md"]

        let preparation = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        XCTAssertEqual(preparation.plan.items.map(\.relativePath), ["README.md"])
    }

    /// Метаданные из I2.1. `last_commit_*` — по настройке: это отдельный вызов
    /// `git log` на каждый файл.
    func testCommitMetadataIsWrittenAndTheExpensivePartIsOptional() async throws {
        try await makeRepository()
        let plain = try await unwrapPrepare(service.prepare(
            source: source(), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        let item = try XCTUnwrap(plain.plan.items.first { $0.relativePath == "README.md" })
        XCTAssertEqual(item.routeMetadata["git_relative_path"], .string("README.md"))
        XCTAssertEqual(item.routeMetadata["git_branch"], .string("main"))
        XCTAssertNotNil(item.routeMetadata["git_commit"])
        XCTAssertNil(item.routeMetadata["last_commit_author"], "по умолчанию не платим за вызов на файл")

        let detailed = try await unwrapPrepare(service.prepare(
            source: source(GitSourceSettings(includesCommitInfo: true)),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        let withInfo = try XCTUnwrap(detailed.plan.items.first { $0.relativePath == "README.md" })
        XCTAssertEqual(withInfo.routeMetadata["last_commit_author"], .string("Проверка"))
        XCTAssertNotNil(withInfo.routeMetadata["last_commit_date"])
    }

    // MARK: - Что изменилось

    /// После одного коммита в работу берётся один файл, а не весь репозиторий.
    func testOnlyTheChangedFileIsPlannedAfterACommit() async throws {
        try await makeRepository()
        let source = source()
        var manifest = SourceManifest(sourceID: source.id)

        let first = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        ))
        // Манифест такой, каким его оставила бы удачная запись.
        for item in first.plan.items {
            manifest.record(ManifestEntry(
                relativePath: item.relativePath, contentHash: item.contentHash ?? "",
                modifiedAt: item.modifiedAt, size: item.size, chunkIDs: ["\(item.relativePath)-0"],
                collectionName: "code", chunkingSignature: source.chunking.signature,
                embeddingModel: "e5", extractionSignature: source.extractionSignature
            ))
        }
        service.save(first.state, sourceID: source.id)

        try write("docs/guide.md", "# Руководство\n\nТекст переписан целиком, и это должно быть замечено.")
        try await git(["add", "-A"])
        try await git(["commit", "-m", "правка руководства"])

        let second = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        ))
        XCTAssertEqual(second.plan.writeItems.map(\.relativePath), ["docs/guide.md"])
        XCTAssertEqual(second.plan.items.filter { $0.kind == .unchanged }.count, 2)
    }

    func testAFileThatLeftTheRepositoryWaitsForADecision() async throws {
        try await makeRepository()
        let source = source()
        var manifest = SourceManifest(sourceID: source.id)
        manifest.record(ManifestEntry(
            relativePath: "docs/ушёл.md", contentHash: "x", modifiedAt: Date(), size: 1,
            chunkIDs: ["a-0"], collectionName: "code",
            chunkingSignature: source.chunking.signature, embeddingModel: "e5"
        ))

        let preparation = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        ))
        XCTAssertEqual(preparation.plan.newlyMissing.map(\.relativePath), ["docs/ушёл.md"])
    }

    // MARK: - Переименование

    func testARenameIsSeenAsARenameAndNotAsDeleteAndCreate() async throws {
        try await makeRepository()
        let source = source()
        var manifest = SourceManifest(sourceID: source.id)
        let first = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        ))
        for item in first.plan.items {
            manifest.record(ManifestEntry(
                relativePath: item.relativePath, contentHash: item.contentHash ?? "",
                modifiedAt: item.modifiedAt, size: item.size,
                chunkIDs: [SourceSyncService.documentID(relativePath: item.relativePath, chunkIndex: 0)],
                collectionName: "code", chunkingSignature: source.chunking.signature,
                embeddingModel: "e5", extractionSignature: source.extractionSignature
            ))
        }
        service.save(first.state, sourceID: source.id)

        try await git(["mv", "docs/guide.md", "docs/manual.md"])
        try await git(["commit", "-m", "переименование"])

        let second = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: manifest
        ))
        XCTAssertEqual(second.renames.map(\.from), ["docs/guide.md"])
        XCTAssertEqual(second.renames.map(\.to), ["docs/manual.md"])
        // Переименованный файл не считается ни новым, ни изменённым: текст тот
        // же, и платить за эмбеддинг второй раз не за что.
        XCTAssertTrue(second.plan.writeItems.isEmpty, "переименование не стоит ни одного вектора")
        XCTAssertTrue(second.plan.newlyMissing.isEmpty, "старое имя не должно попасть в «требуют решения»")
    }

    /// Разбор `--name-status -z` — формат недобрый: у переименования три поля,
    /// а не два, и построчно его читать нельзя.
    func testTheNameStatusFormatIsParsedFieldByField() {
        let output = "M\u{0}README.md\u{0}R100\u{0}docs/guide.md\u{0}docs/manual.md\u{0}A\u{0}new.md\u{0}D\u{0}old.md\u{0}"
        let changes = GitRepository.parseNameStatus(output)

        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes[0].kind, .modified)
        XCTAssertEqual(changes[1].path, "docs/manual.md")
        XCTAssertEqual(changes[1].kind, .renamed(from: "docs/guide.md"))
        XCTAssertEqual(changes[2].kind, .added)
        XCTAssertEqual(changes[3].kind, .deleted)
    }

    // MARK: - Рабочая копия и ветки

    func testUncommittedChangesAreIndexedOrNotByTheSetting() async throws {
        try await makeRepository()
        try write("черновик.md", "# Черновик\n\nЕщё не в коммите, но уже текст.")

        let asIs = try await unwrapPrepare(service.prepare(
            source: source(GitSourceSettings(indexesWorkingCopy: true)),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        XCTAssertTrue(asIs.plan.items.contains { $0.relativePath == "черновик.md" })

        let committedOnly = try await unwrapPrepare(service.prepare(
            source: source(GitSourceSettings(indexesWorkingCopy: false)),
            embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        XCTAssertFalse(committedOnly.plan.items.contains { $0.relativePath == "черновик.md" })
    }

    /// Смена ветки — обычное рабочее действие. Переиндексация репозитория —
    /// часы работы модели. Одно не должно запускать другое само.
    func testABranchChangeIsNoticedButStartsNothing() async throws {
        try await makeRepository()
        let source = source()
        let first = try await unwrapPrepare(service.prepare(
            source: source, embeddingModel: "e5", manifest: SourceManifest(sourceID: source.id)
        ))
        service.save(first.state, sourceID: source.id)

        try await git(["checkout", "-b", "проба"])
        try write("на_ветке.md", "# На ветке\n\nФайл, которого нет в main.")
        try await git(["add", "-A"])
        try await git(["commit", "-m", "файл ветки"])

        let status = await service.status(of: source)
        XCTAssertTrue(status.branchChanged)
        XCTAssertEqual(status.branch, "проба")
        XCTAssertEqual(status.previousBranch, "main")
        let note = try XCTUnwrap(status.branchChangeNote)
        XCTAssertTrue(note.contains("сама не запускается"), note)
        XCTAssertTrue(note.contains("проба"), note)
    }

    // MARK: - Деградация

    /// Git не установлен — источник работает как обычная папка, а не отказывается
    /// работать.
    func testWithoutGitTheSourceDegradesToAPlainFolder() async throws {
        let service = GitSyncService(states: states, makeRepository: { _ in nil })
        let preparation = try await unwrapPrepare(service.prepare(
            source: source(), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        let reason = try XCTUnwrap(preparation.degradedReason)
        XCTAssertTrue(reason.contains("Command Line Tools"), reason)
        XCTAssertTrue(preparation.plan.items.isEmpty, "план строит обычный обход папки, а не этот сервис")
    }

    func testAFolderWithoutARepositoryAlsoDegrades() async throws {
        let preparation = try await unwrapPrepare(service.prepare(
            source: source(), embeddingModel: "e5", manifest: SourceManifest(sourceID: UUID())
        ))
        let reason = try XCTUnwrap(preparation.degradedReason)
        XCTAssertTrue(reason.contains("нет git-репозитория"), reason)
    }
}
