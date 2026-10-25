import XCTest
import SwiftUI
@testable import ChromaDBManagerApp

/// Переключатели не должны менять размер при нажатии, а заголовки раскрывашек
/// должны нажиматься целиком.
final class DisclosureAndWidthTests: XCTestCase {

    private static var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DisclosureAndWidthTests.swift
            .deletingLastPathComponent()   // ChromaDBManagerAppTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/ChromaDBManagerApp/Views")
    }

    /// Экраны и общие компоненты `UI/`: раскрывашки «Для опытных»
    /// и «Как это работает» живут там и обязаны соблюдать то же правило.
    private func swiftFiles() throws -> [(name: String, text: String)] {
        let ui = Self.viewsDirectory.deletingLastPathComponent().appendingPathComponent("UI")
        let urls = try (FileManager.default.contentsOfDirectory(
            at: Self.viewsDirectory, includingPropertiesForKeys: nil
        ) + FileManager.default.contentsOfDirectory(at: ui, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(urls.isEmpty, "экраны не найдены: \(Self.viewsDirectory.path)")
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    // MARK: - Заголовок раскрывашки нажимается целиком

    /// Сплошной обход: у каждого файла с `DisclosureGroup` должен быть и
    /// `togglesDisclosure`. Иначе где-то опять останется заголовок, который
    /// выглядит нажимаемым и не нажимается.
    func testEveryScreenWithADisclosureGroupMakesItsHeaderTappable() throws {
        var forgotten: [String] = []
        for file in try swiftFiles() {
            let groups = file.text.components(separatedBy: "DisclosureGroup(").count - 1
            guard groups > 0 else { continue }
            let taps = file.text.components(separatedBy: "togglesDisclosure").count - 1
            if taps < groups { forgotten.append("\(file.name): групп \(groups), нажатий \(taps)") }
        }
        XCTAssertTrue(forgotten.isEmpty, "заголовок нажимается только стрелкой — \(forgotten)")
    }

    /// Раскрывашка без привязки управляться извне не может, а значит и
    /// заголовок у неё нажать нельзя. Такой формы быть не должно.
    func testNoDisclosureGroupIsLeftWithoutABinding() throws {
        var withoutBinding: [String] = []
        for file in try swiftFiles() {
            for line in file.text.components(separatedBy: .newlines)
            where line.contains("DisclosureGroup(") && !line.contains("isExpanded:") {
                withoutBinding.append("\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(withoutBinding.isEmpty, "раскрывашка без привязки — \(withoutBinding)")
    }
}
