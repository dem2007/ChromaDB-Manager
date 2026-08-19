import XCTest
import UniformTypeIdentifiers
@testable import ChromaCore

/// 8 по манифесту, а не по плану.
///
/// Смена версии экстрактора приходит с обновлением приложения — то есть с его
/// перезапуском. Список устаревших файлов собирался только внутри `plan`
/// и жил в памяти экрана: после перезапуска карточка источника молчала о том,
/// что текст в базе получен позапрошлой читалкой, пока человек не нажмёт
/// «План» — а нажимать его незачем, когда на карточке ничего не написано.
final class StaleExtractionFromManifestTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var manifests: ManifestStore!
    private var source: DataSource!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cdbm-stale-\(UUID().uuidString)")
        folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        manifests = ManifestStore(directory: root.appendingPathComponent("manifests"))
        source = DataSource(
            name: "тест", path: folder.path, fileExtensions: ["pdf", "md"],
            mapping: .folderToCollection, collectionName: "docs"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ entries: [ManifestEntry]) -> SourceManifest {
        var manifest = SourceManifest(sourceID: source.id)
        for entry in entries { manifest.record(entry) }
        return manifest
    }

    private func entry(_ path: String, _ stamp: ExtractorStamp) -> ManifestEntry {
        ManifestEntry(
            relativePath: path, contentHash: "text", fileHash: "bytes",
            modifiedAt: Date(timeIntervalSince1970: 1_000), size: 10,
            chunkIDs: ["id-0"], collectionName: "docs",
            chunkingSignature: "sig", embeddingModel: "model",
            extractorID: stamp.id, extractorVersion: stamp.version
        )
    }

    private func service() -> SourceSyncService {
        SourceSyncService(manifests: manifests, journal: SyncJournal(directory: root.appendingPathComponent("journals")))
    }

    /// Главное: ответ есть до того, как что-либо запущено, и файла на диске
    /// для него не нужно — вопрос про текст, который **уже** в базе.
    func testAnOlderVersionIsReportedFromTheManifestAlone() async {
        let older = ExtractorStamp(id: "pdfkit", version: PDFExtractor().version - 1)
        let stale = await service().staleExtractions(
            in: manifest([entry("книга.pdf", older)]), source: source
        )
        XCTAssertEqual(stale.map(\.relativePath), ["книга.pdf"])
        XCTAssertEqual(stale.first?.previous, older)
        XCTAssertEqual(stale.first?.current.id, "pdfkit")
        XCTAssertEqual(stale.first?.current.version, PDFExtractor().version)
    }

    func testTheCurrentVersionIsSilent() async {
        let stale = await service().staleExtractions(
            in: manifest([entry("книга.pdf", ExtractorStamp(id: "pdfkit", version: PDFExtractor().version))]),
            source: source
        )
        XCTAssertTrue(stale.isEmpty)
    }

    /// Манифест старой сборки: чем читали — неизвестно, и это не повод
    /// предлагать работу (правило то же, что у `isStale`).
    func testAnUnknownExtractorStaysSilent() async {
        let stale = await service().staleExtractions(
            in: manifest([entry("книга.pdf", ExtractorStamp(id: "", version: 0))]), source: source
        )
        XCTAssertTrue(stale.isEmpty)
    }

    /// Скан, прочитанный распознаванием. У `.pdf` первым кандидатом всегда стоит
    /// `pdfkit`, поэтому сравнение «с первым подходящим» объявляло экстрактор
    /// другим и молчало навсегда: на рабочих манифестах таких файлов 84.
    func testARecognisedScanIsComparedWithItsOwnExtractor() async {
        var ocrSource = source!
        ocrSource.ocrEnabled = true
        let older = ExtractorStamp(id: "vision-ocr", version: VisionOCRExtractor().version - 1)
        let stale = await service().staleExtractions(
            in: manifest([entry("скан.pdf", older)]), source: ocrSource
        )
        XCTAssertEqual(stale.map(\.relativePath), ["скан.pdf"])
        XCTAssertEqual(stale.first?.current.id, "vision-ocr")
    }

    /// А с выключённым распознаванием переизвлекать этот скан сегодня нечем —
    /// и молчание снова правильный ответ.
    func testAScanIsSilentWhenRecognitionIsOff() async {
        var plainSource = source!
        plainSource.ocrEnabled = false
        let older = ExtractorStamp(id: "vision-ocr", version: VisionOCRExtractor().version - 1)
        let stale = await service().staleExtractions(
            in: manifest([entry("скан.pdf", older)]), source: plainSource
        )
        XCTAssertTrue(stale.isEmpty)
    }

    /// Тот же выбор экстрактора, что у плана, — одной строкой реестра.
    func testTheRegistryComparesWithTheSameExtractor() {
        let registry = ExtractorRegistry.standard()
        let pdf = UTType.pdf
        XCTAssertEqual(
            registry.currentStamp(for: pdf, storedID: "pdfkit", options: ExtractionOptions(ocrEnabled: true)).id,
            "pdfkit"
        )
        XCTAssertEqual(
            registry.currentStamp(for: pdf, storedID: "vision-ocr", options: ExtractionOptions(ocrEnabled: true)).id,
            "vision-ocr"
        )
        XCTAssertEqual(
            registry.currentStamp(for: pdf, storedID: "vision-ocr", options: ExtractionOptions(ocrEnabled: false)).id,
            "pdfkit",
            "распознавание выключено — его экстрактор кандидатом не является"
        )
    }
}
