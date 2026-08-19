import XCTest
@testable import ChromaCore

/// Снятие находок диагностики.
///
/// Красная кнопка «очистить все находки» и «убрать из списка» правят
/// манифест — то, что переживает перезапуск. До этого приложение читало
/// манифест снаружи, меняло его у себя и сохраняло следующим вызовом;
/// между этими двумя шагами в тот же манифест пишет идущий прогон, и
/// сохранивший последним затирает работу другого.
final class ForgetProblemsTests: XCTestCase {
    private var directory: URL!
    private var service: SourceSyncService!
    private let sourceID = UUID()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cdbm-forget-\(UUID().uuidString)")
        service = SourceSyncService(manifests: ManifestStore(directory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func manifestWithProblems(_ paths: [String]) async {
        var manifest = await service.manifest(for: sourceID)
        manifest.problems = paths.map {
            FileProblem(relativePath: $0, reason: "не прочитан", remedy: .retry)
        }
        await service.save(manifest: manifest)
    }

    /// Названные файлы уходят, соседние остаются.
    func testOnlyTheNamedProblemsAreForgotten() async {
        await manifestWithProblems(["a.pdf", "b.pdf", "папка/в.docx"])

        let removed = await service.forgetProblems(["a.pdf", "папка/в.docx"], sourceID: sourceID)

        XCTAssertEqual(removed, 2)
        let left = await service.manifest(for: sourceID).problems.map(\.relativePath)
        XCTAssertEqual(left, ["b.pdf"], "снято лишнее или не снято нужное: \(left)")
    }

    /// `nil` — очистить всё: это красная кнопка на вкладке диагностики.
    func testNilForgetsEverything() async {
        await manifestWithProblems(["a.pdf", "b.pdf"])

        let removed = await service.forgetProblems(nil, sourceID: sourceID)

        XCTAssertEqual(removed, 2)
        let left = await service.manifest(for: sourceID).problems
        XCTAssertTrue(left.isEmpty)
    }

    /// Путь, которого в манифесте нет, ничего не меняет и не пишет файл заново.
    func testAnUnknownPathChangesNothing() async {
        await manifestWithProblems(["a.pdf"])

        let removed = await service.forgetProblems(["нет-такого.pdf"], sourceID: sourceID)

        XCTAssertEqual(removed, 0)
        let left = await service.manifest(for: sourceID).problems.map(\.relativePath)
        XCTAssertEqual(left, ["a.pdf"])
    }

    /// Остальное содержимое манифеста не задевается: снятие находки — это
    /// снятие находки, а не потеря сведений о прочитанных файлах.
    func testTheRestOfTheManifestSurvives() async {
        var manifest = await service.manifest(for: sourceID)
        manifest.problems = [FileProblem(relativePath: "a.pdf", reason: "не прочитан", remedy: .retry)]
        manifest.record(ManifestEntry(
            relativePath: "b.md",
            contentHash: "hash",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            size: 12,
            chunkIDs: ["1"],
            collectionName: "docs_col",
            chunkingSignature: "sig",
            embeddingModel: "model"
        ))
        await service.save(manifest: manifest)

        await service.forgetProblems(nil, sourceID: sourceID)

        let after = await service.manifest(for: sourceID)
        XCTAssertTrue(after.problems.isEmpty)
        XCTAssertEqual(after.entries["b.md"]?.chunkIDs, ["1"], "запись о прочитанном файле обязана остаться")
    }
}
