import XCTest
@testable import ChromaCore

/// Отказ инструмента из-за аргументов.
///
/// По спецификации `2026-07-28` («Tools», «Error Handling») это ошибка
/// **выполнения** — результат с `isError: true` и причиной, по которой модель
/// исправит вызов сама, — а не ошибка протокола. Протоколом остаются только
/// неизвестный инструмент и вызов, не отвечающий форме `tools/call`.
struct ToolInputRefusal {
    let message: String
}

extension Result where Success == JSONValue, Failure == JSONRPCError {
    /// Отказ из-за аргументов, если это он; ошибка протокола сюда не подходит.
    var inputRefusal: ToolInputRefusal? {
        guard case .success(let value) = self, value["isError"] == .bool(true) else { return nil }
        return ToolInputRefusal(message: value["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
    }
}
