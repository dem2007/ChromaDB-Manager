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

    private func swiftFiles() throws -> [(name: String, text: String)] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: Self.viewsDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
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

    // MARK: - Ширина не зависит от начертания

    /// Замер, ради которого всё делалось: полужирная надпись **шире** обычной,
    /// поэтому выделение выбранного пункта двигало и его, и соседей.
    func testBoldTextIsGenuinelyWiderAndSoTheProblemIsReal() {
        let titles = ["Набор запросов", "Варианты", "Прогоны", "релевантен", "частично"]
        for title in titles {
            let regular = width(of: title, weight: .regular)
            let semibold = width(of: title, weight: .semibold)
            XCTAssertGreaterThan(semibold, regular, "«\(title)»: полужирный не шире обычного?")
        }
    }

    /// Место считается по полужирному начертанию всегда — независимо от того,
    /// выбран пункт или нет. Это и есть то, что убирает дёрганье.
    func testTheReservedWidthDoesNotDependOnSelection() {
        let selected = SteadyWeightLabel(
            title: "Варианты", font: Theme.Font.caption, isEmphasised: true,
            colour: Theme.Palette.primaryText
        )
        let plain = SteadyWeightLabel(
            title: "Варианты", font: Theme.Font.caption, isEmphasised: false,
            colour: Theme.Palette.secondaryText
        )
        XCTAssertEqual(
            SteadyWeightLabel.sizingFont(selected.font),
            SteadyWeightLabel.sizingFont(plain.font),
            "начертание, по которому считается место, обязано быть одним"
        )
    }

    private func width(of text: String, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
