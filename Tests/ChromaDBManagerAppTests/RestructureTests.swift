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
