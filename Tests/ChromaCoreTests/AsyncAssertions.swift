import XCTest

/// `XCTAssertThrowsError` does not accept an async expression, and wrapping every
/// call in `do/catch` at the call site buries what the test is actually saying.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "ожидалась ошибка",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        check(error)
    }
}
