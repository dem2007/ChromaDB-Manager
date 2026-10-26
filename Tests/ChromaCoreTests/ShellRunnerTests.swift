import XCTest
@testable import ChromaCore

/// Вывод процесса доходит целиком — сколько бы их ни шло разом.
final class ShellRunnerTests: XCTestCase {
    /// Живой случай: на GitHub `git ls-files` вышел с кодом 0 и пустым
    /// выводом, и план индексации остался без файлов. Обработчик готовности
    /// трубы забирал последние байты, пока дочитывание после выхода уже
    /// собирало ответ. Здесь до правки терялся примерно один запуск из
    /// тысячи — гонка редкая, поэтому запусков много и они идут разом.
    func testOutputIsNeverLostUnderConcurrentRuns() async throws {
        var lost = 0
        for _ in 0..<20 {
            lost += try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        let result = try await ShellRunner.shared.run("/bin/echo", arguments: ["вывод"])
                        return result.isSuccess && result.standardOutput == "вывод\n" ? 0 : 1
                    }
                }
                return try await group.reduce(0, +)
            }
        }
        XCTAssertEqual(lost, 0, "запусков с потерянным выводом — \(lost) из 2000")
    }
}
