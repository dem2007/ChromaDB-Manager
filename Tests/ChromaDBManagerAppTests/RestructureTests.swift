import XCTest
@testable import ChromaDBManagerApp

/// слой экранов стал доступен тестам.
///
/// Первый тест здесь — про сам факт: до перестановки экранный слой был
/// исполняемой целью, а исполняемую цель тестовый набор импортировать не
/// может. 9700 строк моделей экранов и 15 600 строк вьюх не покрывались
/// ничем, и дефекты …,, проверялись чтением.
final class RestructureTests: XCTestCase {
    @MainActor
    func testTheAppLayerIsReachableFromTests() {
        // Любая внутренняя вещь слоя: важно, что `@testable import` до неё
        // дотягивается.
        let queue = QueueMirror()
        XCTAssertTrue(queue.tasks.isEmpty)
    }
}

/// Пример подключения, который отдают клиенту вместе с ключом.
final class ConnectionSnippetTests: XCTestCase {
    @MainActor
    func testTheSnippetFollowsTheSchemeThatIsActuallyOn() {
        let model = ClientsViewModel()
        let plain = model.snippet(for: "KEY", port: 8900, usesTLS: false)
        XCTAssertFalse(plain.contains("ssl=True"))
        XCTAssertFalse(plain.contains("chroma_server_ssl_verify"))

        let secure = model.snippet(for: "KEY", port: 8900, usesTLS: true)
        XCTAssertTrue(secure.contains("ssl=True"))
        // Путь к сертификату уходит в httpx через эту настройку — проверено
        // по исходникам установленной библиотеки. Совет про REQUESTS_CA_BUNDLE
        // был бы неверным: клиент ChromaDB ходит через httpx, а не requests.
        XCTAssertTrue(secure.contains("chroma_server_ssl_verify"))
        XCTAssertFalse(secure.contains("REQUESTS_CA_BUNDLE"))
        XCTAssertTrue(secure.contains("KEY"), "ключ подставляется в пример")
        XCTAssertTrue(secure.contains("8900"))
    }
}
