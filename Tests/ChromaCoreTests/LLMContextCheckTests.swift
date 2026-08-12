import XCTest
@testable import ChromaCore

/// помещается ли LLM-нарезка в контекст, с которым загружена модель,
/// спрашивается **до** запуска.
final class LLMContextCheckTests: XCTestCase {
    /// Чат-модель, которая только и умеет, что сказать про свой контекст,
    /// и падает, если её попросят думать: предполётная проверка не должна
    /// ничего у модели спрашивать сверх этого.
    private struct ContextOnlyChat: ChatProvider {
        let loaded: Int?
        let maximum: Int?
        /// Измеренная скорость письма. `nil` — не мерили.
        var tokensPerSecond: Double?

        func loadedContextLength(of model: String) async -> Int? { loaded }
        func maximumContextLength(of model: String) async -> Int? { maximum }
        func generationSpeed(of model: String) async -> Double? { tokensPerSecond }

        func complete(
            prompt: String, model: String, settings: ChatGenerationSettings,
            schema: ChatJSONSchema?, timeout: TimeInterval?
        ) async throws -> String {
            XCTFail("предполётная проверка не должна дёргать модель")
            return ""
        }
    }

    private var configuration: ChunkingConfiguration {
        ChunkingConfiguration(
            strategy: .llmBased,
            sizeUnit: .characters,
            maxChunkSize: 4096,
            chatModel: "chat-model"
        )
    }

    // MARK: - Вердикт

    func testAModelLoadedWithAWideContextFits() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 131_072, maximum: 131_072)
        )
        XCTAssertTrue(check.fits)
        XCTAssertFalse(check.isReduced, "окно не урезано: \(check.summary)")
        XCTAssertFalse(check.reloadingWouldHelp, "перезагружать нечего — уже максимум")
    }

    /// Ровно случай с этой машины: потолок 131 072, поднята с 8192.
    func testAModelLoadedWellBelowItsCeilingIsReducedAndWorthReloading() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 8192, maximum: 131_072)
        )
        XCTAssertTrue(check.isReduced)
        XCTAssertTrue(check.reloadingWouldHelp)
        XCTAssertTrue(check.summary.contains("8192"), check.summary)
        XCTAssertTrue(check.summary.contains("131072"), check.summary)
    }

    func testAContextTooSmallForEvenAMinimalWindowDoesNotFit() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 512, maximum: 131_072)
        )
        XCTAssertFalse(check.fits)
        XCTAssertLessThan(check.allowed, check.minimum)
    }

    /// Неизвестный контекст — не повод мешать работать: LM Studio просто
    /// ничего не сказала, а не сказала «мало».
    func testAnUnknownContextDoesNotBlockTheRun() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: nil, maximum: nil)
        )
        XCTAssertTrue(check.isUnknown)
        XCTAssertTrue(check.fits)
        XCTAssertFalse(check.isReduced)
    }

    /// Желаемое окно считает одна функция — та же, которой пользуется сам
    /// прогон. Разойдись они, проверка разрешала бы то, на что прогон потом
    /// жалуется, и наоборот.
    func testTheWantedWindowIsTheOneTheRunUses() async {
        var bigger = configuration
        bigger.maxChunkSize = 8192
        let check = await LLMChunker.contextCheck(
            configuration: bigger, model: "chat-model",
            chat: ContextOnlyChat(loaded: 8192, maximum: 8192)
        )
        XCTAssertEqual(check.wanted, LLMChunker.wantedWindow(for: bigger))
        XCTAssertEqual(check.minimum, LLMChunker.minimumWindow)
    }

    // MARK: - Время

    /// Тот самый случай: контекста после перезагрузки на 128 000 хватает
    /// с четырёхкратным запасом, а ста двадцати секунд при 72 ток/с — нет.
    func testAWideContextStillLosesToTheClock() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 128_000, maximum: 128_000, tokensPerSecond: 72)
        )
        XCTAssertTrue(check.fits, "работать можно, просто окнами поменьше")
        XCTAssertTrue(check.timeIsTheLimit, "узкое место — время: \(check.summary)")
        XCTAssertTrue(check.isReduced)
        XCTAssertEqual(check.effective, check.allowedByTime)
        // Про время — в первой же фразе: иначе человек прочитает про контекст
        // и пойдёт перезагружать модель, то есть сделает окно ещё больше.
        XCTAssertTrue(check.summary.contains("токенов в секунду"), check.summary)
    }

    /// Быстрая модель ничего не теряет: предел по времени просто не срабатывает.
    func testAFastModelIsNotHeldBackByTheClock() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 131_072, maximum: 131_072, tokensPerSecond: 5_000)
        )
        XCTAssertFalse(check.timeIsTheLimit, check.summary)
        XCTAssertFalse(check.isReduced, check.summary)
    }

    /// Скорость не измерена — судить не по чему, и мешать нельзя. Ровно то же
    /// правило, что и для неизвестного контекста.
    func testAnUnmeasuredSpeedChangesNothing() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 131_072, maximum: 131_072)
        )
        XCTAssertNil(check.allowedByTime)
        XCTAssertNil(check.tokensPerSecond)
        XCTAssertFalse(check.timeIsTheLimit)
        XCTAssertTrue(check.fits)
    }

    /// Совсем медленная модель — отказ до прогона, и совет про время.
    func testAModelThatCannotFinishInTimeDoesNotFit() async {
        let check = await LLMChunker.contextCheck(
            configuration: configuration, model: "chat-model",
            chat: ContextOnlyChat(loaded: 131_072, maximum: 131_072, tokensPerSecond: 3)
        )
        XCTAssertFalse(check.fits)
        let error = SyncError.chunkingWindowTooSmall(check)
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(suggestion.contains("таймаут"), suggestion)
        XCTAssertFalse(
            suggestion.contains("перезагрузите"),
            "перезагрузка с бо́льшим контекстом здесь делает только хуже: \(suggestion)"
        )
    }

    // MARK: - Проверка срабатывает до первого файла

    /// База, которая падает от любого обращения: если проверка сработала до
    /// планирования, до неё дело не дойдёт.
    private final class RefusingDatabase: SyncDatabase, @unchecked Sendable {
        struct Touched: Error {}

        func createCollection(
            name: String, metadata: ChromaMetadata?, configuration: CollectionConfiguration?, getOrCreate: Bool
        ) async throws -> ChromaCollection { throw Touched() }
        func resolveID(of name: String) async throws -> String { throw Touched() }
        func updateCollection(id: String, newName: String?, metadata: ChromaMetadata?) async throws { throw Touched() }
        func upsert(collectionID: String, records: [EmbeddedRecord]) async throws { throw Touched() }
        func updateDocuments(collectionID: String, updates: [DocumentUpdate]) async throws { throw Touched() }
        func documents(collectionID: String, ids: [String]) async throws -> [DocumentRecord] { throw Touched() }
        func embeddings(collectionID: String, ids: [String]) async throws -> [String: [Double]] { throw Touched() }
        func deleteDocuments(collectionID: String, ids: [String]) async throws { throw Touched() }
        func deleteDocuments(collectionID: String, filter: DocumentFilter) async throws -> Int { throw Touched() }
    }

    private struct NeverAskedEmbeddings: EmbeddingProvider {
        func embed(texts: [String], model: String) async throws -> [[Double]] {
            XCTFail("до эмбеддинга дело дойти не должно")
            return []
        }
    }

    func testTheRunStopsBeforeTouchingAnyFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Текст файла.".write(
            to: directory.appendingPathComponent("документ.md"), atomically: true, encoding: .utf8
        )

        let service = SourceSyncService(
            manifests: ManifestStore(directory: directory.appendingPathComponent("manifests"))
        )
        let source = DataSource(
            name: "docs", path: directory.path, fileExtensions: ["md"],
            collectionName: "llm_check",
            chunking: configuration
        )

        do {
            _ = try await service.sync(
                source: source, embeddingModel: "stub", chroma: RefusingDatabase(),
                embeddings: NeverAskedEmbeddings(), binding: ModelBindingService(),
                chat: ContextOnlyChat(loaded: 512, maximum: 131_072)
            ) { _ in }
            XCTFail("прогон обязан остановиться на проверке контекста")
        } catch let error as SyncError {
            guard case .chunkingWindowTooSmall(let check) = error else {
                return XCTFail("ожидалась chunkingWindowTooSmall, получено \(error)")
            }
            XCTAssertEqual(check.loaded, 512)
            XCTAssertNotNil(error.errorDescription)
            XCTAssertTrue(
                error.recoverySuggestion?.contains("131072") ?? false,
                "подсказка обязана назвать потолок: \(error.recoverySuggestion ?? "—")"
            )
        } catch is RefusingDatabase.Touched {
            XCTFail("проверка сработала слишком поздно — прогон уже пошёл в базу")
        }
    }
}

/// вызов `lms` собирается здесь и нигде больше.
final class LMStudioLoaderTests: XCTestCase {
    /// Аргументы закреплены тестом: это чужой CLI, и молчаливая опечатка в
    /// ключе означает кнопку, которая ничего не делает.
    func testTheCommandLoadsTheModelWithTheChosenContext() {
        XCTAssertEqual(
            LMStudioLoader.loadArguments(model: "liquid/lfm2-24b-a2b", contextLength: 131_072),
            ["load", "liquid/lfm2-24b-a2b", "--context-length", "131072", "-y"]
        )
        XCTAssertEqual(LMStudioLoader.psArguments(), ["ps", "--json"])
        XCTAssertEqual(
            LMStudioLoader.unloadArguments(identifier: "liquid/lfm2-24b-a2b:2"),
            ["unload", "liquid/lfm2-24b-a2b:2"]
        )
    }

    func testWithoutTheCLIThereIsNothingToPress() {
        let loader = LMStudioLoader(paths: ["/несуществующий/путь/lms"])
        XCTAssertNil(loader.executable)
        XCTAssertFalse(loader.isAvailable)
    }

    func testTheCLIIsFoundWhereItIsInstalled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lms")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let loader = LMStudioLoader(paths: ["/нет/такого", executable.path])
        XCTAssertEqual(loader.executable?.path, executable.path)
    }

    /// Неудача загрузки — не молчание: код возврата и вывод доходят до человека.
    func testAFailedLoadCarriesTheOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lms")
        try "#!/bin/sh\necho 'не хватило памяти' >&2\nexit 3\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        do {
            _ = try await LMStudioLoader(paths: [executable.path])
                .instances()
            XCTFail("код возврата 3 — это неудача")
        } catch let error as LMStudioLoader.LoadError {
            guard case .failed(let command, let status, let output) = error else {
                return XCTFail("ожидалась failed, получено \(error)")
            }
            XCTAssertEqual(status, 3)
            XCTAssertEqual(command, "ps --json", "в сообщении названа команда, которая отказала")
            XCTAssertTrue(output.contains("не хватило памяти"), output)
            XCTAssertTrue(error.errorDescription?.contains("не хватило памяти") ?? false)
        }
    }

    func testASuccessfulLoadReturnsWhatTheCLISaid() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("lms")
        try """
        #!/bin/sh
        if [ "$1" = "ps" ]; then echo '[]'; else echo "$@"; fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let (unloaded, output) = try await LMStudioLoader(paths: [executable.path])
            .reload(model: "модель", contextLength: 32768)
        XCTAssertEqual(unloaded, 0, "выгружать было нечего")
        XCTAssertTrue(output.contains("--context-length 32768"), output)
    }

    /// Главное про перезагрузку: `lms load` сам по себе **не заменяет**
    /// загруженную модель, а ставит рядом ещё одну копию. Так и вышло на живой
    /// машине: 13 ГБ второй копии, а запросы по имени модели продолжали уходить
    /// в старый экземпляр на 8192.
    ///
    /// Поэтому проверяется вся последовательность вызовов, а не только исход.
    func testReloadUnloadsEveryInstanceOfTheModelBeforeLoading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let journal = directory.appendingPathComponent("вызовы.txt")
        // Двойник `lms`: на `ps --json` отвечает как настоящий на этой машине
        // (две копии одной модели плюс чужая), остальное записывает.
        let executable = directory.appendingPathComponent("lms")
        try """
        #!/bin/sh
        echo "$@" >> "\(journal.path)"
        if [ "$1" = "ps" ]; then
          echo '[{"identifier":"liquid/lfm2-24b-a2b","modelKey":"liquid/lfm2-24b-a2b","contextLength":8192},{"identifier":"liquid/lfm2-24b-a2b:2","modelKey":"liquid/lfm2-24b-a2b","contextLength":128000},{"identifier":"qwen/qwen3.5-9b","modelKey":"qwen/qwen3.5-9b","contextLength":262144}]'
        fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try await LMStudioLoader(paths: [executable.path])
            .reload(model: "liquid/lfm2-24b-a2b", contextLength: 128_000)

        XCTAssertEqual(result.unloaded, 2, "обе копии этой модели — и первая, и «:2»")
        let calls = try String(contentsOf: journal, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, [
            "ps --json",
            "unload liquid/lfm2-24b-a2b",
            "unload liquid/lfm2-24b-a2b:2",
            "load liquid/lfm2-24b-a2b --context-length 128000 -y",
        ], "порядок важен: сначала выгрузить всё своё, потом грузить одно")
    }

    /// Чужие модели не трогаются: выгрузка идёт по `modelKey`, а не по всему,
    /// что нашлось в памяти.
    func testReloadLeavesOtherModelsAlone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let journal = directory.appendingPathComponent("вызовы.txt")
        let executable = directory.appendingPathComponent("lms")
        try """
        #!/bin/sh
        echo "$@" >> "\(journal.path)"
        if [ "$1" = "ps" ]; then
          echo '[{"identifier":"qwen/qwen3.5-9b","modelKey":"qwen/qwen3.5-9b","contextLength":262144}]'
        fi
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        _ = try await LMStudioLoader(paths: [executable.path])
            .reload(model: "liquid/lfm2-24b-a2b", contextLength: 4096)

        let calls = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertFalse(calls.contains("unload"), "чужую загруженную модель выгружать нечего:\n\(calls)")
    }

    /// Не прочитав список загруженного, грузить нельзя: получилась бы вторая
    /// копия рядом с первой — ровно то, ради чего этот шаг и есть.
    func testWithoutAReadableInstanceListNothingIsLoaded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lms-broken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let journal = directory.appendingPathComponent("вызовы.txt")
        let executable = directory.appendingPathComponent("lms")
        try """
        #!/bin/sh
        echo "$@" >> "\(journal.path)"
        echo 'что-то не то'
        exit 0
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        do {
            _ = try await LMStudioLoader(paths: [executable.path])
                .reload(model: "модель", contextLength: 4096)
            XCTFail("без списка экземпляров грузить нельзя")
        } catch let error as LMStudioLoader.LoadError {
            guard case .instancesUnreadable = error else {
                return XCTFail("ожидалась instancesUnreadable, получено \(error)")
            }
            XCTAssertNotNil(error.recoverySuggestion)
        }

        let calls = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertFalse(calls.contains("load"), "загрузки быть не должно:\n\(calls)")
    }

    // MARK: - Строка состояния модели

    /// Модель, поднятая ровно на своём потолке, выглядела в точности как
    /// незагруженная: и там и там «128000 токенов».
    func testALoadedModelSaysSoEvenAtItsCeiling() {
        let loaded = LMStudioModel(
            id: "liquid/lfm2-24b-a2b:2", kind: .chat,
            contextLength: 128_000, loadedContextLength: 128_000
        )
        let idle = LMStudioModel(id: "microsoft/phi-4", kind: .chat, contextLength: 131_072)

        XCTAssertNotEqual(loaded.contextLine, idle.contextLine, "загруженная и незагруженная не могут читаться одинаково")
        XCTAssertTrue(loaded.contextLine?.contains("загружена") ?? false, loaded.contextLine ?? "—")
        XCTAssertFalse(idle.contextLine?.contains("загружена") ?? true, idle.contextLine ?? "—")
    }

    func testAModelLoadedBelowItsCeilingNamesBothNumbers() {
        let model = LMStudioModel(
            id: "liquid/lfm2-24b-a2b", kind: .chat,
            contextLength: 128_000, loadedContextLength: 8192
        )
        XCTAssertEqual(model.contextLine, "загружена с 8192 из 128000 токенов")
    }
}
